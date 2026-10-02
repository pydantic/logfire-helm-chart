"""Manual synthetic queue experiments; no cluster/backend credentials are used.

Requires Helm, Docker, PyYAML. Example:
python3 tests/collector/stress_queues.py --scenario cycles --mode disk --output /tmp/disk.json
The throughput scenario accepts --io-bps DEVICE:BYTES to constrain only its container.
Tiny/cap tests scale queue/database budgets to finish locally; results say so explicitly.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import http.client
import http.server
import itertools
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import yaml

from verify_config import IMAGE, ROOT, get, ports

MIB = 1048576
SIGNALS = ("traces", "logs", "metrics")


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


class Backend:
    def __init__(self):
        self.available = threading.Event()
        self.ids = {signal: set() for signal in SIGNALS}
        self.duplicates = 0
        self.lock = threading.Lock()
        backend = self

        class Sink(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if backend.available.is_set():
                    if self.headers.get("Content-Encoding") == "gzip":
                        body = gzip.decompress(body)
                    signal = self.path.split("/")[-1]
                    document = json.loads(body)
                    if signal == "traces":
                        records = [s for r in document.get("resourceSpans", [])
                                   for scope in r["scopeSpans"] for s in scope["spans"]]
                    elif signal == "logs":
                        records = [s for r in document.get("resourceLogs", [])
                                   for scope in r["scopeLogs"] for s in scope["logRecords"]]
                    else:
                        records = [p for r in document.get("resourceMetrics", [])
                                   for scope in r["scopeMetrics"] for m in scope["metrics"]
                                   for p in m["gauge"]["dataPoints"]]
                    with backend.lock:
                        for record in records:
                            identifier = int(next(a["value"]["intValue"] for a in record["attributes"]
                                                  if a["key"] == "synthetic.id"))
                            backend.duplicates += identifier in backend.ids[signal]
                            backend.ids[signal].add(identifier)
                    status = 200
                else:
                    status = 503
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Sink)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def payload(signal, identifier, size):
    timestamp = str(time.time_ns())
    attrs = [{"key": "synthetic.id", "value": {"intValue": str(identifier)}}]
    value = "x" * size
    if signal == "traces":
        return json.dumps({"resourceSpans": [{"scopeSpans": [{"spans": [{
            "traceId": "0123456789abcdef0123456789abcdef", "spanId": f"{identifier+1:016x}",
            "name": "synthetic", "startTimeUnixNano": timestamp, "endTimeUnixNano": timestamp,
            "attributes": attrs + [{"key": "payload", "value": {"stringValue": value}}],
        }]}]}]}).encode()
    if signal == "logs":
        return json.dumps({"resourceLogs": [{"scopeLogs": [{"logRecords": [{
            "timeUnixNano": timestamp, "attributes": attrs, "body": {"stringValue": value},
        }]}]}]}).encode()
    return json.dumps({"resourceMetrics": [{"scopeMetrics": [{"metrics": [{
        "name": "synthetic_gauge", "gauge": {"dataPoints": [{
            "timeUnixNano": timestamp, "asInt": "1",
            "attributes": attrs + [{"key": "payload", "value": {"stringValue": value}}],
        }]},
    }]}]}]}).encode()


def send(connection, signal, identifier, size):
    before = time.monotonic()
    try:
        connection.request("POST", "/v1/" + signal, payload(signal, identifier, size),
                           {"Content-Type": "application/json"})
        response = connection.getresponse()
        body = response.read()
        status = response.status
        if status == 200 and body:
            partial = json.loads(body).get("partialSuccess", {})
            if any(int(v) for k, v in partial.items() if k.startswith("rejected")):
                status = "partial"
        return status, time.monotonic() - before
    except (OSError, http.client.HTTPException):
        connection.close()
        return "transport_error", time.monotonic() - before


class Collector:
    def __init__(self, args, backend, directory):
        self._closed = False
        self.args = args
        self.directory = Path(directory)
        self.name = "lf-queue-stress-" + uuid.uuid4().hex[:8]
        self.volume = self.name + "-data"
        self.identifier = itertools.count()
        self.accepted = {signal: set() for signal in SIGNALS}
        self.statuses = {}
        self.latencies = []
        self.lock = threading.Lock()
        self.snapshots = []
        self.sample_stop = threading.Event()
        rendered = subprocess.check_output([
            "helm", "template", "lf", "charts/logfire", "--set", "adminEmail=test@example.com",
            "--set", "objectStore.uri=s3://test", "--set", "sizingPreset=standard",
            "--set", "otel_collector.queueStorage.enabled=true",
        ], cwd=ROOT).decode()
        config = yaml.safe_load(next(d for d in yaml.safe_load_all(rendered)
                                    if d and d["kind"] == "ConfigMap" and
                                    d["metadata"]["name"] == "otel-collector-config")
                                ["data"]["otel-collector-config.yaml"])
        del config["processors"]["k8s_attributes"]
        for pipeline in config["service"]["pipelines"].values():
            pipeline["processors"].remove("k8s_attributes")
        exporter = config["exporters"]["otlp_http"]
        if args.debug_storage:
            config["service"].setdefault("telemetry", {}).setdefault("logs", {})["level"] = "debug"
        # Short backoffs speed up synthetic recovery. Disable retry expiry so loss accounting
        # measures the queue/storage rather than a five-minute retry deadline.
        exporter.update(endpoint=f"http://host.docker.internal:{backend.server.server_port}", encoding="json",
                        retry_on_failure={"enabled": True, "initial_interval": "100ms",
                                          "max_interval": "1s", "max_elapsed_time": "0s"})
        queue = exporter["sending_queue"]
        if args.queue_mib:
            queue["queue_size"] = args.queue_mib * MIB
        self.queue_limit = queue["queue_size"]
        if args.mode == "memory":
            queue.pop("storage")
            del config["extensions"]["file_storage/queue"]
            config["service"]["extensions"].remove("file_storage/queue")
        else:
            storage = config["extensions"]["file_storage/queue"]
            if args.fsync is not None:
                storage["fsync"] = args.fsync
            self.fsync = storage["fsync"]
            if args.database_mib:
                storage["max_size"] = args.database_mib * MIB
                storage["compaction"]["rebound_needed_threshold_mib"] = max(1, args.database_mib * 100 // 256)
                storage["compaction"]["rebound_trigger_threshold_mib"] = max(1, args.database_mib * 10 // 256)
            self.database_limit = storage["max_size"]
        path = self.directory / "collector.yaml"
        path.write_text(yaml.safe_dump(config))
        try:
            docker("volume", "create", *(["--driver", "local", "--opt", "type=tmpfs", "--opt", "device=tmpfs",
                                          "--opt", f"o=size={args.filesystem_mib}m"] if args.filesystem_mib else []),
                   self.volume)
            if args.filesystem_mib:
                # Docker unmounts a local tmpfs volume when its last container exits. Keep it
                # mounted across setup, fault injection, recovery, and directory inspection.
                self.volume_holder = self.name + "-volume"
                docker("run", "-d", "--name", self.volume_holder, "-v", f"{self.volume}:/queue",
                       "busybox:1.37", "sleep", "86400")
            docker("run", "--rm", "-v", f"{self.volume}:/queue", "busybox:1.37", "sh", "-c",
                   "mkdir -p /queue/compaction && chown -R 10001:10001 /queue")
            # Keep the config on Linux-local storage too, so container restart tests do not
            # depend on Docker Desktop retaining a macOS temporary-file bind mount.
            docker("run", "--rm", "-v", f"{path}:/cfg.yaml:ro", "-v", f"{self.volume}:/queue",
                   "busybox:1.37", "cp", "/cfg.yaml", "/queue/collector.yaml")
            if args.filler_mib:
                docker("run", "--rm", "-v", f"{self.volume}:/queue", "busybox:1.37", "sh", "-c",
                       f"dd if=/dev/zero of=/queue/filler bs=1048576 count={args.filler_mib} conv=fsync")
            docker("run", "-d", "--name", self.name, "--read-only", "--memory", "2g", "--memory-swap", "2g",
                   *(["--device-write-bps", args.io_bps] if args.io_bps else []),
                   *(["--device-write-iops", args.io_iops] if args.io_iops else []),
                   *(["--add-host", "host.docker.internal:host-gateway"] if sys.platform == "linux" else []),
                   "-e", "GOMEMLIMIT=1228MiB", "-e", "LOGFIRE_META_WRITE_TOKEN=synthetic",
                   "-p", "127.0.0.1::4318", "-p", "127.0.0.1::13133", "-p", "127.0.0.1::8888",
                   "-v", f"{self.volume}:/var/lib/otelcol/queue",
                   IMAGE, "--config=/var/lib/otelcol/queue/collector.yaml")
            self.receive, self.health, self.telemetry = ports(self.name, 4318, 13133, 8888)
            deadline = time.monotonic() + 60
            while True:
                try:
                    get(self.health, "/")
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise
                    time.sleep(.2)
            self.started = time.monotonic()
            self.sampler = threading.Thread(target=self.sample_loop, daemon=True)
            self.sampler.start()
        except BaseException:
            self.close()
            raise

    def metrics(self):
        result = {}
        for line in get(self.telemetry, "/metrics").splitlines():
            if line.startswith("#") or not any(k in line for k in
                    ("queue_size", "queue_capacity", "enqueue_failed", "receiver_refused", "memory_rss", "heap_alloc")):
                continue
            key, value = line.rsplit(" ", 1)
            result[key] = float(value)
        return result

    def sample_loop(self):
        while not self.sample_stop.is_set():
            try:
                snapshot = {"elapsed_s": time.monotonic() - self.started, "metrics": self.metrics()}
                self.snapshots.append(snapshot)
                interval = self.args.progress_interval
                if interval and len(self.snapshots) % interval == 0:
                    print(json.dumps({"progress_s": round(snapshot["elapsed_s"]),
                                      "responses": self.statuses.copy(),
                                      "metrics": snapshot["metrics"]}), flush=True)
            except OSError:
                pass
            self.sample_stop.wait(1)

    def disk(self):
        # The queue is a Linux-local Docker volume, not a macOS filesystem bind mount.
        output = docker("run", "--rm", "-v", f"{self.volume}:/queue:ro", "busybox:1.37",
                        "sh", "-c", "du -ak /queue; stat -c '%n %s' /queue/exporter* 2>/dev/null || true")
        return output

    def post(self, connection, signal, size):
        identifier = next(self.identifier)
        status, latency = send(connection, signal, identifier, size)
        with self.lock:
            self.statuses[str(status)] = self.statuses.get(str(status), 0) + 1
            self.latencies.append(latency)
            if status == 200:
                self.accepted[signal].add(identifier)
        return status

    def load(self, duration, concurrency, size, signals=SIGNALS, stop_on_full=False):
        before = self.statuses.copy()
        latencies_before = len(self.latencies)
        start = time.monotonic()
        deadline = start + duration
        stop = threading.Event()

        def worker(index):
            connection = http.client.HTTPConnection("127.0.0.1", self.receive, timeout=5)
            try:
                n = index
                while time.monotonic() < deadline and not stop.is_set():
                    status = self.post(connection, signals[n % len(signals)], size)
                    n += 1
                    if stop_on_full and status == 503:
                        stop.set()
            finally:
                connection.close()

        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            try:
                list(pool.map(worker, range(concurrency)))
            finally:
                stop.set()
        elapsed = time.monotonic() - start
        counts = {k: v - before.get(k, 0) for k, v in self.statuses.items()}
        latencies = sorted(self.latencies[latencies_before:])
        return {"duration_s": elapsed, "responses": counts,
                "accepted_requests_per_s": counts.get("200", 0) / elapsed,
                "latency_ms": {name: latencies[min(len(latencies)-1, int(len(latencies)*p))]*1000
                               for name, p in (("p50", .5), ("p95", .95), ("p99", .99))} if latencies else {},
                "metrics": self.metrics()}

    def drain(self, backend, timeout=None):
        if timeout is None:
            timeout = self.args.drain_timeout
        backend.available.set()
        before = time.monotonic()
        while time.monotonic() - before < timeout:
            metrics = self.metrics()
            if sum(v for k, v in metrics.items() if k.startswith("otelcol_exporter_queue_size")) == 0:
                break
            time.sleep(.25)
        else:
            return {"drained": False, "elapsed_s": time.monotonic()-before, "metrics": self.metrics()}
        # A zero queue metric alone is insufficient to prove final downstream delivery.
        # Allow batched/in-flight work to finish and compare every acknowledged record ID.
        delivery_deadline = time.monotonic() + 10
        while time.monotonic() < delivery_deadline:
            with backend.lock:
                if all(ids <= backend.ids[signal] for signal, ids in self.accepted.items()):
                    break
            time.sleep(.2)
        with backend.lock:
            missing = {s: len(ids - backend.ids[s]) for s, ids in self.accepted.items()}
            extra = {s: len(backend.ids[s] - ids) for s, ids in self.accepted.items()}
        return {"drained": True, "elapsed_s": time.monotonic()-before, "missing_accepted": missing,
                "delivered_without_http_200": extra, "duplicates": backend.duplicates}

    def close(self):
        if self._closed:
            return
        self._closed = True
        self.sample_stop.set()
        if hasattr(self, "sampler"):
            self.sampler.join(timeout=12)
        result = subprocess.run(["docker", "logs", self.name], capture_output=True, text=True)
        self.log = result.stdout + result.stderr
        subprocess.run(["docker", "rm", "-f", self.name], capture_output=True)
        if hasattr(self, "volume_holder"):
            subprocess.run(["docker", "rm", "-f", self.volume_holder], capture_output=True)
        subprocess.run(["docker", "volume", "rm", self.volume], capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=("throughput", "tiny", "cycles", "cap", "restart"), required=True)
    parser.add_argument("--mode", choices=("memory", "disk"), required=True)
    parser.add_argument("--duration", type=int, default=15)
    parser.add_argument("--drain-timeout", type=int, default=90)
    parser.add_argument("--progress-interval", type=int, default=0, help="Print progress every N seconds")
    parser.add_argument("--payload-bytes", type=int, default=64)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--queue-mib", type=int)
    parser.add_argument("--database-mib", type=int)
    parser.add_argument("--filesystem-mib", type=int,
                        help="Use bounded tmpfs to isolate capacity or inject ENOSPC; never an I/O benchmark")
    parser.add_argument("--filler-mib", type=int, default=0)
    parser.add_argument("--io-bps")
    parser.add_argument("--io-iops")
    parser.add_argument("--fsync", action=argparse.BooleanOptionalAction, default=None,
                        help="Override the chart fsync setting for a comparison")
    parser.add_argument("--debug-storage", action="store_true")
    parser.add_argument("--restart-signal", choices=("KILL", "TERM"), default="KILL")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--requests", type=int, default=160)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    backend = Backend()
    result = {"settings": vars(args) | {"output": str(args.output)}, "image": IMAGE}
    collector = None
    try:
        with tempfile.TemporaryDirectory() as directory:
            collector = Collector(args, backend, directory)
            result["queue_limit_bytes_per_signal"] = collector.queue_limit
            result["database_limit_bytes_per_signal"] = getattr(collector, "database_limit", None)
            result["fsync"] = getattr(collector, "fsync", None)
            if args.scenario == "throughput":
                backend.available.set()
                collector.load(3, args.concurrency, args.payload_bytes)
                result["load"] = collector.load(args.duration, args.concurrency, args.payload_bytes)
                result["drain"] = collector.drain(backend)
            elif args.scenario == "tiny":
                result["load"] = collector.load(args.duration, args.concurrency, args.payload_bytes, ("logs",), stop_on_full=True)
                result["disk_at_rejection"] = collector.disk()
                result["drain"] = collector.drain(backend)
            elif args.scenario == "restart":
                connection = http.client.HTTPConnection("127.0.0.1", collector.receive, timeout=15)
                try:
                    for _ in range(args.requests):
                        for signal in SIGNALS:
                            collector.post(connection, signal, args.payload_bytes)
                finally:
                    connection.close()
                time.sleep(2)  # Ensure exporter batches are retrying during the outage.
                result["before_restart_metrics"] = collector.metrics()
                docker("kill", "--signal=" + args.restart_signal, collector.name)
                subprocess.run(["docker", "wait", collector.name], check=True,
                               capture_output=True, timeout=60)
                result["restart_signal"] = args.restart_signal
                result["restart_exit_code"] = json.loads(docker("inspect", collector.name))[0]["State"]["ExitCode"]
                docker("start", collector.name)
                collector.receive, collector.health, collector.telemetry = ports(collector.name, 4318, 13133, 8888)
                deadline = time.monotonic() + 60
                while True:
                    try:
                        collector.receive, collector.health, collector.telemetry = ports(collector.name, 4318, 13133, 8888)
                        get(collector.health, "/")
                        break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise
                        time.sleep(.2)
                result["drain"] = collector.drain(backend)
            elif args.scenario == "cycles":
                result["cycles"] = []
                connection = http.client.HTTPConnection("127.0.0.1", collector.receive, timeout=15)
                try:
                    for cycle in range(args.cycles):
                        backend.available.clear()
                        before = collector.statuses.copy()
                        start = time.monotonic()
                        full_signals = set()
                        for _ in range(args.requests):
                            for signal in SIGNALS:
                                if signal not in full_signals:
                                    status = collector.post(connection, signal, MIB)
                                    if status == 503:
                                        full_signals.add(signal)
                            if len(full_signals) == len(SIGNALS) or time.monotonic()-start > 90:
                                break
                        item = {"cycle": cycle+1, "fill_s": time.monotonic()-start,
                                "full_signals": sorted(full_signals),
                                "responses": {k: v-before.get(k, 0) for k, v in collector.statuses.items()},
                                "full_metrics": collector.metrics(), "full_disk": collector.disk(),
                                "drain": collector.drain(backend)}
                        # Rebound compaction checks every five seconds.
                        time.sleep(6)
                        item["drained_disk"] = collector.disk()
                        result["cycles"].append(item)
                        print(json.dumps(item), flush=True)
                finally:
                    connection.close()
            else:
                result["load"] = collector.load(args.duration, args.concurrency, MIB, ("logs",), stop_on_full=True)
                result["disk_at_rejection"] = collector.disk()
                if args.filler_mib:
                    docker("run", "--rm", "-v", f"{collector.volume}:/queue", "busybox:1.37",
                           "rm", "/queue/filler")
                result["drain"] = collector.drain(backend, timeout=30)
                # A failed storage write can leave in-memory queue metadata inflated. Verify
                # that subsequent valid writes recover, rather than only checking HTTP 503.
                connection = http.client.HTTPConnection("127.0.0.1", collector.receive, timeout=15)
                try:
                    result["post_recovery_status"] = collector.post(connection, "logs", 64)
                    result["second_drain"] = collector.drain(backend, timeout=30)
                finally:
                    connection.close()
            state = json.loads(docker("inspect", collector.name))[0]["State"]
            result["state"] = {k: state[k] for k in ("Running", "OOMKilled", "ExitCode")}
            result["health"] = get(collector.health, "/")
            result["snapshots"] = collector.snapshots
            result["final_metrics"] = collector.metrics()
            result["final_disk"] = collector.disk()
            with backend.lock:
                result["final_delivery"] = {
                    "accepted": {s: len(ids) for s, ids in collector.accepted.items()},
                    "delivered": {s: len(ids) for s, ids in backend.ids.items()},
                    "missing_accepted": {s: len(ids-backend.ids[s]) for s, ids in collector.accepted.items()},
                    "missing_id_sample": {s: sorted(ids-backend.ids[s])[:12] for s, ids in collector.accepted.items()},
                    "duplicates": backend.duplicates,
                }
            collector.close()
            (args.output.with_suffix(".log")).write_text(collector.log)
            result["compactions"] = collector.log.count("finished compaction")
            result["storage_full_errors"] = collector.log.lower().count("run out of available space")
            result["error_lines"] = [line for line in collector.log.splitlines()
                                     if "storage" in line.lower() and "error" in line.lower()][-8:]
    except BaseException as error:
        result["error"] = repr(error)
        if collector:
            collector.close()
            (args.output.with_suffix(".log")).write_text(collector.log)
        raise
    finally:
        backend.close()
        args.output.write_text(json.dumps(result, indent=2))
        print(json.dumps({k: v for k, v in result.items() if k != "snapshots"}), flush=True)


if __name__ == "__main__":
    main()
