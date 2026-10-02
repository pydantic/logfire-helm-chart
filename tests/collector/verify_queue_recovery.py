"""Verify all three disk queues replay after SIGKILL; requires Helm, Docker, PyYAML.

The writable directory represents an emptyDir retained across a container restart.
No cluster access. The backend is a local synthetic server returning 503 until restart.
"""
import gzip
import http.server
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid

import yaml

from verify_config import IMAGE, ROOT, get, ports


def main():
    name = "logfire-queue-recovery-" + uuid.uuid4().hex[:8]
    available = threading.Event()
    delivered = []
    failures = []

    class Sink(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            if available.is_set():
                delivered.append(json.loads(body))
                self.send_response(200)
            else:
                failures.append(self.path)
                self.send_response(503)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Sink)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    rendered = subprocess.check_output([
        "helm", "template", "lf", "charts/logfire", "--set", "adminEmail=test@example.com",
        "--set", "objectStore.uri=s3://test-bucket", "--set", "sizingPreset=standard",
    ], cwd=ROOT).decode()
    configmap = next(d for d in yaml.safe_load_all(rendered)
                     if d and d["kind"] == "ConfigMap" and d["metadata"]["name"] == "otel-collector-config")
    config = yaml.safe_load(configmap["data"]["otel-collector-config.yaml"])
    assert config["exporters"]["otlp_http"]["sending_queue"]["storage"] == "file_storage/queue"
    del config["processors"]["k8s_attributes"]
    for pipeline in config["service"]["pipelines"].values():
        pipeline["processors"].remove("k8s_attributes")
    config["exporters"]["otlp_http"].update(
        endpoint=f"http://host.docker.internal:{server.server_port}", encoding="json",
        retry_on_failure={"enabled": True, "initial_interval": "100ms", "max_interval": "500ms", "max_elapsed_time": "60s"},
    )
    with tempfile.TemporaryDirectory() as directory:
        queue = Path(directory) / "queue"
        queue.mkdir(mode=0o777)
        queue.chmod(0o777)  # Synthetic data; Kubernetes fsGroup is verified separately.
        path = Path(directory) / "collector.yaml"
        path.write_text(yaml.safe_dump(config))
        subprocess.run([
            "docker", "run", "-d", "--name", name, "--read-only", "--memory", "2g",
            *(["--add-host", "host.docker.internal:host-gateway"] if sys.platform == "linux" else []),
            "-e", "GOMEMLIMIT=1228MiB", "-e", "LOGFIRE_META_WRITE_TOKEN=synthetic",
            "-p", "127.0.0.1::4318", "-p", "127.0.0.1::13133",
            "-v", f"{path}:/cfg.yaml:ro", "-v", f"{queue}:/var/lib/otelcol/queue",
            IMAGE, "--config=/cfg.yaml",
        ], check=True, capture_output=True)
        try:
            receive, health = ports(name, 4318, 13133)

            def wait_ready():
                for _ in range(100):
                    try:
                        get(health, "/")
                        return
                    except OSError:
                        time.sleep(.1)
                logs = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
                raise AssertionError("Collector did not start: " + logs.stdout + logs.stderr)

            wait_ready()
            count = 250
            start = time.time_ns() - 1_000_000_000
            trace = {"resourceSpans": [{"scopeSpans": [{"spans": [{
                "traceId": "0123456789abcdef0123456789abcdef", "spanId": f"{i+1:016x}",
                "name": "synthetic-recovery", "startTimeUnixNano": str(start), "endTimeUnixNano": str(start+1000),
            } for i in range(count)]}]}]}
            logs = {"resourceLogs": [{"scopeLogs": [{"logRecords": [{
                "timeUnixNano": str(start), "body": {"stringValue": f"synthetic-record-{i}"},
            } for i in range(count)]}]}]}
            metrics = {"resourceMetrics": [{"scopeMetrics": [{"metrics": [{
                "name": "synthetic_recovery_counter", "sum": {
                    "aggregationTemporality": 1, "isMonotonic": True, "dataPoints": [{
                        "startTimeUnixNano": str(start), "timeUnixNano": str(start+1000), "asInt": "1",
                        "attributes": [{"key": "stream.id", "value": {"stringValue": str(i)}}],
                    } for i in range(count)],
                },
            }]}]}]}
            for signal, body in (("traces", trace), ("logs", logs), ("metrics", metrics)):
                get(receive, "/v1/"+signal, json.dumps(body).encode())
            deadline = time.monotonic()+10
            while len(set(failures)) < 3 and time.monotonic() < deadline:
                time.sleep(.1)
            assert set(failures) == {"/v1/traces", "/v1/logs", "/v1/metrics"}, failures
            assert not delivered
            # An abrupt exit tests actual disk recovery, rather than graceful shutdown drain.
            subprocess.run(["docker", "kill", "--signal=KILL", name], check=True, capture_output=True)
            assert len(list(queue.glob("exporter*"))) == 3, list(queue.iterdir())
            available.set()
            subprocess.run(["docker", "start", name], check=True, capture_output=True)
            # Docker may reallocate ephemeral host ports when the container is started again.
            health, = ports(name, 13133)
            wait_ready()
            deadline = time.monotonic()+15
            while len(delivered) < 3 and time.monotonic() < deadline:
                time.sleep(.1)
            spans = [s for body in delivered for r in body.get("resourceSpans", [])
                     for scope in r["scopeSpans"] for s in scope["spans"]]
            records = [l for body in delivered for r in body.get("resourceLogs", [])
                       for scope in r["scopeLogs"] for l in scope["logRecords"]]
            points = [p for body in delivered for r in body.get("resourceMetrics", [])
                      for scope in r["scopeMetrics"] for m in scope["metrics"] for p in m["sum"]["dataPoints"]]
            assert len(spans) == len(records) == len(points) == count, (len(spans), len(records), len(points))
            assert len({s["spanId"] for s in spans}) == count
            assert len({l["body"]["stringValue"] for l in records}) == count
            assert len({p["attributes"][0]["value"]["stringValue"] for p in points}) == count
            print(f"PASS: {count} spans, logs, and metric points recovered after SIGKILL with a read-only image root")
        finally:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
            server.shutdown()


if __name__ == "__main__":
    main()
