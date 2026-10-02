"""Local OTel 0.160.0 smoke test: python3 tests/collector/verify_config.py.

Requires Helm (with built chart dependencies) and Docker. No cluster credentials are used.
Renders the chart, replaces Kubernetes enrichment with synthetic resource attributes, and
checks dashboard names, histogram conversion, and unchanged OTLP delta temporality.
"""
import gzip
import http.server
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid
import tempfile
import threading
import time
import urllib.error
import urllib.request

# PyYAML is only needed to extract the embedded collector config from Helm's output.
import yaml

ROOT = Path(__file__).resolve().parents[2]
IMAGE = "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.160.0"
NAME = "logfire-chart-collector-smoke-" + uuid.uuid4().hex[:8]
received = []


class Sink(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        received.append(json.loads(body))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


def get(port, path, data=None):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=data,
        headers={"Content-Type": "application/json"},
    )
    return urllib.request.urlopen(request, timeout=10).read().decode()


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Sink)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    rendered = subprocess.check_output([
        "helm", "template", "lf", "charts/logfire", "--set", "adminEmail=test@example.com",
        "--set", "objectStore.uri=s3://test-bucket", "--set", "sizingPreset=standard",
        "--set", "otel_collector.prometheus.enabled=true",
    ], cwd=ROOT).decode()
    configmap = next(d for d in yaml.safe_load_all(rendered)
                     if d and d["kind"] == "ConfigMap" and d["metadata"]["name"] == "otel-collector-config")
    config = yaml.safe_load(configmap["data"]["otel-collector-config.yaml"])
    del config["processors"]["k8s_attributes"]
    for pipeline in config["service"]["pipelines"].values():
        pipeline["processors"].remove("k8s_attributes")
    config["exporters"]["otlp_http"].update(
        endpoint=f"http://host.docker.internal:{server.server_port}", encoding="json",
    )
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "collector.yaml"
        path.write_text(yaml.safe_dump(config))
        subprocess.run([
            "docker", "run", "-d", "--name", NAME, "--memory", "2g",
            *(["--add-host", "host.docker.internal:host-gateway"] if sys.platform == "linux" else []),
            "-e", "GOMEMLIMIT=1228MiB", "-e", "LOGFIRE_META_WRITE_TOKEN=synthetic",
            "-p", "127.0.0.1::4318", "-p", "127.0.0.1::9090", "-p", "127.0.0.1::13133",
            "-v", f"{path}:/cfg.yaml:ro", IMAGE, "--config=/cfg.yaml",
        ], check=True, capture_output=True)
        try:
            bindings = json.loads(subprocess.check_output(["docker", "inspect", NAME]))[0]["NetworkSettings"]["Ports"]
            receive, scrape, health = [int(bindings[f"{port}/tcp"][0]["HostPort"]) for port in (4318, 9090, 13133)]
            for _ in range(80):
                try:
                    get(health, "/")
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(.25)
            start = time.time_ns() - 2_000_000_000
            metrics = []
            counters = [
                ("ingest_request_count", ""), ("logfire.traces.ingest_request_count", ""),
                ("logfire.logs.ingest_request_count", ""), ("logfire.metrics.ingest_request_count", ""),
                ("logfire.traces.num_bytes", "By"), ("logfire.logs.num_bytes", "By"),
                ("logfire.metrics.num_bytes", "By"), ("compaction_files_in", "{file}"),
                ("compaction_files_out", "{file}"), ("compaction_bytes_in", "By"),
                ("compaction_bytes_out", "By"),
            ]
            for name, unit in counters:
                metrics.append({"name": name, "unit": unit, "sum": {
                    "aggregationTemporality": 1, "isMonotonic": True, "dataPoints": [{
                        "startTimeUnixNano": str(start), "timeUnixNano": str(start+1_000_000_000), "asInt": "5",
                    }],
                }})
            for name in ("ingest_queue_unattempted_item_count", "maintenance_jobs_in_flight"):
                metrics.append({"name": name, "gauge": {"dataPoints": [{
                    "timeUnixNano": str(start+1_000_000_000), "asInt": "3",
                }]}})
            for name, unit in (("ingest_queue_latency_ms", "ms"), ("http.server.request.duration", "s"),
                               ("compaction_job_completion_latency", "s")):
                metrics.append({"name": name, "unit": unit, "histogram": {
                    "aggregationTemporality": 1, "dataPoints": [{
                        "startTimeUnixNano": str(start), "timeUnixNano": str(start+1_000_000_000),
                        "count": "2", "sum": 15.0, "explicitBounds": [10.0], "bucketCounts": ["1", "1"],
                    }],
                }})
            # Scale changes at an unaligned offset reproduce the exporter's double-counting bug.
            for scale, offset, step in ((1, 1, 1), (0, 0, 2)):
                metrics.append({"name": "ingest_batch_num_payloads", "exponentialHistogram": {
                    "aggregationTemporality": 1, "dataPoints": [{
                        "startTimeUnixNano": str(start+(step-1)*1_000_000_000),
                        "timeUnixNano": str(start+step*1_000_000_000), "count": "1", "sum": 1.5,
                        "scale": scale, "positive": {"offset": offset, "bucketCounts": ["1"]},
                    }],
                }})
            payload = {"resourceMetrics": [{"resource": {"attributes": [{
                "key": "service.name", "value": {"stringValue": "synthetic"},
            }]}, "scopeMetrics": [{"scope": {"name": "synthetic"}, "metrics": metrics}]}]}
            get(receive, "/v1/metrics", json.dumps(payload).encode())
            deadline = time.monotonic()+10
            while not received and time.monotonic() < deadline:
                time.sleep(.1)
            assert received, "No OTLP export received"
            text = get(scrape, "/metrics")
            names = {re.split(r"[\s{]", line, maxsplit=1)[0] for line in text.splitlines() if line and not line.startswith("#")}
            expected = {name.replace(".", "_") for name, _ in counters}
            expected.update(["ingest_queue_unattempted_item_count", "maintenance_jobs_in_flight",
                             "ingest_queue_latency_ms_bucket", "http_server_request_duration_bucket",
                             "http_server_request_duration_count", "http_server_request_duration_sum",
                             "compaction_job_completion_latency_bucket"])
            assert expected <= names, expected - names
            assert re.search(r"^ingest_batch_num_payloads_count(?:\{[^\n]*\})? 2(?:\.0)?(?: \d+)?$", text, re.M), text
            forwarded = [m for body in received for r in body.get("resourceMetrics", [])
                         for scope in r["scopeMetrics"] for m in scope["metrics"]]
            for metric in forwarded:
                for kind in ("sum", "histogram", "exponentialHistogram"):
                    if kind in metric:
                        assert metric[kind]["aggregationTemporality"] in (1, "AGGREGATION_TEMPORALITY_DELTA"), metric
            raw_histograms = [m["exponentialHistogram"] for m in forwarded if m["name"] == "ingest_batch_num_payloads"]
            assert sum(len(h["dataPoints"]) for h in raw_histograms) == 2, raw_histograms
            assert all(str(p["count"]) == "1" for h in raw_histograms for p in h["dataPoints"]), raw_histograms
            logs = subprocess.run(["docker", "logs", NAME], capture_output=True, text=True)
            assert "failed to convert metric" not in logs.stdout+logs.stderr
            print(f"PASS: {len(expected)} dashboard names; scale-changing histogram count=2; raw OTLP remains delta; health responds")
        finally:
            subprocess.run(["docker", "rm", "-f", NAME], capture_output=True)
            server.shutdown()


if __name__ == "__main__":
    main()
