"""Run the chart's rendered HAProxy in front of a stub upstream, with no cluster.

`running_proxy(values)` renders the `logfire-haproxy-config` Secret for the CI values plus `values`,
points every backend at one stub that records its requests, and runs the pinned HAProxy image with
`docker`. The stub answers 200, or a 307 whose `Location` is the request's `X-Stub-Location`.
"""

from __future__ import annotations

import json
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
import yaml

CHART = Path(__file__).resolve().parents[3] / "charts" / "logfire"


@dataclass
class Proxy:
    address: str
    container: str
    upstream_requests: list[dict[str, str]]

    def get(self, path: str = "/", headers: list[tuple[str, str]] | None = None) -> httpx.Response:
        """A GET that keeps duplicate header names and an explicit Host as given."""
        return httpx.get(f"http://{self.address}{path}", headers=headers or [], follow_redirects=False, timeout=10)

    def raw_status(self, path: str, host: str | None) -> int:
        """The status of an HTTP/1.0 GET sent byte for byte, so that no client normalises the path."""
        request = f"GET {path} HTTP/1.0\r\n" + (f"Host: {host}\r\n" if host else "") + "\r\n"
        address, port = self.address.rsplit(":", 1)
        with socket.create_connection((address, int(port)), timeout=10) as sock:
            sock.sendall(request.encode())
            return int(sock.recv(4096).split(b" ", 2)[1])

    def upstream_headers(self) -> dict[str, str]:
        """The headers of the last request that the stub upstream received."""
        return self.upstream_requests[-1]

    def logs(self) -> list[str]:
        output = subprocess.run(["docker", "logs", self.container], capture_output=True, text=True, timeout=30)
        return (output.stdout + output.stderr).splitlines()


def render_config(values: dict | None) -> str:
    """The haproxy.cfg that the chart renders for the CI values plus `values`."""
    command = ["helm", "template", "lf", str(CHART), "--show-only", "templates/logfire-service-config.yaml"]
    command += ["-f", str(CHART / "ci" / "ci-values.yaml"), "-f", "-"]
    rendered = subprocess.run(
        command, input=json.dumps(values or {}), check=True, capture_output=True, text=True, timeout=60
    ).stdout
    return yaml.safe_load(rendered)["stringData"]["haproxy.cfg"]


def _against_stub(config: str, proxy_port: int, upstream_port: int) -> str:
    """Bind the frontend to `proxy_port` and point every backend at the stub, keeping its Host rule."""
    config = re.sub(r"(?ms)^(listen stats|resolvers kubernetes)\n.*?(?=^\S)", "", config)
    config = re.sub(r"(?m)^(\s*)bind :8080 .*$", rf"\1bind 127.0.0.1:{proxy_port}", config)
    head, *backends = re.split(r"(?m)^(?=backend )", config)
    stubbed = []
    for backend in backends:
        lines = backend.split("\n")
        host_rules = [line for line in lines if "http-request set-header Host" in line]
        stubbed += [lines[0], "  mode http", *host_rules, f"  server stub 127.0.0.1:{upstream_port}", ""]
    return head + "\n".join(stubbed)


@contextmanager
def running_proxy(values: dict | None = None) -> Iterator[Proxy]:
    assert shutil.which("docker"), "These tests run HAProxy in a container and need docker"
    requests: list[dict[str, str]] = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            requests.append({key.lower(): value for key, value in self.headers.items()})
            location = self.headers.get("X-Stub-Location")
            self.send_response(307 if location else 200)
            if location:
                self.send_header("Location", location)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

        do_POST = do_OPTIONS = do_GET

        def log_message(self, *args: object) -> None:
            pass

    stub = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    image = yaml.safe_load((CHART / "values.yaml").read_text())["haproxy"]["image"]
    repository = image["repository"] if "/" in image["repository"] else f"docker.io/library/{image['repository']}"
    name = f"logfire-chart-test-haproxy-{uuid.uuid4().hex[:8]}"
    with tempfile.TemporaryDirectory() as directory:
        Path(directory).chmod(0o755)
        config = Path(directory) / "haproxy.cfg"
        config.write_text(_against_stub(render_config(values), port, stub.server_address[1]))
        config.chmod(0o644)
        subprocess.run(
            ["docker", "run", "-d", "--rm", "--name", name, "--network", "host",
             "-v", f"{directory}:/usr/local/etc/haproxy:ro,z", f"{repository}:{image['tag']}"],
            check=True, capture_output=True, text=True, timeout=300,
        )
        try:
            deadline = time.monotonic() + 30
            while True:
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=1).close()
                    break
                except OSError:
                    assert time.monotonic() < deadline, subprocess.run(["docker", "logs", name], capture_output=True, text=True).stdout
                    time.sleep(0.2)
            yield Proxy(f"127.0.0.1:{port}", name, requests)
        finally:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=60)
            stub.shutdown()
