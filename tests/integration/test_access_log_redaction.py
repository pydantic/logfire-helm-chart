from __future__ import annotations

import asyncio
import os
import secrets
import subprocess
from collections import Counter
from urllib.parse import urlsplit

import httpx
import pytest
from helpers.poll import wait_for

pytestmark = pytest.mark.anyio


def _logs(context: str, namespace: str, component: str) -> list[str]:
    result = subprocess.run(
        [
            "kubectl", "--context", context, "-n", namespace, "logs",
            "-l", f"app.kubernetes.io/component={component}",
            "--all-containers=true", "--prefix=true", "--max-log-requests=20",
            "--since=5m", "--tail=-1",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.stdout.splitlines()


async def _new_log_line(
    context: str, namespace: str, component: str, before: Counter[str], marker: str
) -> str:
    async def find_line() -> str | None:
        current = Counter(_logs(context, namespace, component))
        for line in (current - before).elements():
            if marker in line:
                return line
        return None

    return await wait_for(find_line, timeout=30, interval=1)


def _kind_target() -> tuple[str, str]:
    context = os.environ.get("LOGFIRE_TEST_KUBE_CONTEXT")
    namespace = os.environ.get("LOGFIRE_TEST_NAMESPACE")
    if not context or not namespace:
        pytest.skip("Access log checks need the Kind runner's explicit context and namespace")
    return context, namespace


@pytest.mark.parametrize(
    ("page", "param"),
    [
        ("/auth/email-callback", "token"),
        ("/auth/reset-password-callback", "token"),
        ("/auth/totp-reset/complete", "session_token"),
    ],
)
async def test_auth_page_token_is_redacted_from_access_logs(client: httpx.AsyncClient, page: str, param: str) -> None:
    context, namespace = _kind_target()
    components = ("logfire-service", "logfire-frontend-service")
    before = {component: Counter(_logs(context, namespace, component)) for component in components}
    token = f"synthetic-token-{secrets.token_hex(12)}"
    response = await client.get(f"{page}?{param}={token}&continue=dashboard")
    assert response.status_code == 200
    assert response.headers["referrer-policy"] == "no-referrer"
    for component in components:
        line = await _new_log_line(context, namespace, component, before[component], page)
        assert token not in line, line


@pytest.mark.parametrize(
    ("path", "redacted"),
    [
        ("/ui-api/auth/users/email-session-data/{token}/", "/ui-api/auth/users/email-session-data/[redacted]/"),
        ("/ui-api/%61uth/users/email-session-data/{token}/", "/ui-api/auth/users/email-session-data/[redacted]/"),
        ("/ui-api/auth/totp/reset/session/{token}/", "/ui-api/auth/totp/reset/session/[redacted]/"),
    ],
)
async def test_session_token_path_is_redacted_from_access_logs(
    client: httpx.AsyncClient, path: str, redacted: str
) -> None:
    context, namespace = _kind_target()
    before = Counter(_logs(context, namespace, "logfire-service"))
    token = f"synthetic-token-{secrets.token_hex(12)}"
    response = await client.get(path.format(token=token))
    assert response.status_code == 400
    line = await _new_log_line(context, namespace, "logfire-service", before, redacted)
    assert token not in line, line


async def test_ordinary_requests_keep_query_and_referer(client: httpx.AsyncClient) -> None:
    context, namespace = _kind_target()
    components = ("logfire-service", "logfire-frontend-service")
    before = {component: Counter(_logs(context, namespace, component)) for component in components}
    marker = f"log-check-{secrets.token_hex(12)}"
    referer = "http://example.test/ordinary?value=visible"
    response = await client.get(f"/{marker}?ordinary=visible", headers={"Referer": referer})
    assert response.status_code < 500
    assert "referrer-policy" not in response.headers
    lines = {
        component: await _new_log_line(context, namespace, component, before[component], marker)
        for component in components
    }
    for line in lines.values():
        assert "ordinary=visible" in line, line
    assert referer in lines["logfire-frontend-service"]


async def test_haproxy_escapes_request_line(base_url: str) -> None:
    context, namespace = _kind_target()

    before = Counter(_logs(context, namespace, "logfire-service"))
    marker = f"log-check-{secrets.token_hex(12)}"
    url = urlsplit(base_url)
    assert url.hostname
    port = url.port or (443 if url.scheme == "https" else 80)
    reader, writer = await asyncio.open_connection(url.hostname, port, ssl=url.scheme == "https")
    try:
        writer.write(f'GET /{marker}?visible="hello" HTTP/1.1\r\nHost: {url.netloc}\r\nConnection: close\r\n\r\n'.encode())
        await writer.drain()
        assert (await reader.readline()).startswith(b"HTTP/1.1 ")
        await reader.read()
    finally:
        writer.close()
        await writer.wait_closed()
    line = await _new_log_line(context, namespace, "logfire-service", before, marker)
    assert f'"GET /{marker}?visible=#22hello#22 HTTP/1.1"' in line, line
