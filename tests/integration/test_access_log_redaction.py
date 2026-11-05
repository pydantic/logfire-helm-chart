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

COMPONENTS = ("logfire-service", "logfire-frontend-service")


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


async def _new_lines_through(
    context: str, namespace: str, component: str, before: Counter[str], marker: str
) -> list[str]:
    """Wait for the log line that has `marker`, then return every line that the test added."""

    async def find_lines() -> list[str] | None:
        lines = list((Counter(_logs(context, namespace, component)) - before).elements())
        return lines if any(marker in line for line in lines) else None

    return await wait_for(find_lines, timeout=30, interval=1)


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
        ("/settings/emails/change-email-callback", "token"),
    ],
)
async def test_mailed_link_token_stays_out_of_access_logs(client: httpx.AsyncClient, page: str, param: str) -> None:
    context, namespace = _kind_target()
    before = {component: Counter(_logs(context, namespace, component)) for component in COMPONENTS}
    token = f"synthetic-token-{secrets.token_hex(12)}"
    link = f"{page}?{param}={token}&continue=dashboard"

    response = await client.get(link)
    assert response.status_code == 200
    assert response.headers["referrer-policy"] == "no-referrer"

    # An asset request of a page without the header sends the link as its `Referer`.
    marker = f"log-check-{secrets.token_hex(12)}"
    await client.get(f"/{marker}.js", headers={"Referer": f"http://example.test{link}"})

    for component in COMPONENTS:
        lines = await _new_lines_through(context, namespace, component, before[component], marker)
        assert not [line for line in lines if token in line]


@pytest.mark.parametrize(
    ("path", "redacted"),
    [
        ("/ui-api/auth/users/email-session-data/{token}/", "/ui-api/auth/users/email-session-data/[redacted]/"),
        ("/ui-api/%61uth/users/email-session-data/{token}/", "/ui-api/auth/users/email-session-data/[redacted]/"),
        ("/ui-api/auth/totp/reset/session/{token}/", "/ui-api/auth/totp/reset/session/[redacted]/"),
        ("/join/acme/-/organization-invitation/ce/{token}", "/join/[redacted]"),
        ("/l/{token}", "/l/[redacted]"),
    ],
)
async def test_capability_path_is_redacted_from_access_logs(
    client: httpx.AsyncClient, path: str, redacted: str
) -> None:
    context, namespace = _kind_target()
    before = Counter(_logs(context, namespace, "logfire-service"))
    token = f"synthetic-token-{secrets.token_hex(12)}"
    response = await client.get(path.format(token=token))
    assert response.status_code < 500
    lines = await _new_lines_through(context, namespace, "logfire-service", before, redacted)
    assert not [line for line in lines if token in line]


async def test_ordinary_requests_keep_the_path_and_drop_query_and_referer(client: httpx.AsyncClient) -> None:
    context, namespace = _kind_target()
    before = {component: Counter(_logs(context, namespace, component)) for component in COMPONENTS}
    marker = f"log-check-{secrets.token_hex(12)}"

    page = await client.get(f"/{marker}-page")
    assert "referrer-policy" not in page.headers

    await client.get(f"/{marker}.js?query=hidden", headers={"Referer": "http://example.test/page?referer=hidden"})

    for component in COMPONENTS:
        lines = await _new_lines_through(context, namespace, component, before[component], f"/{marker}.js")
        assert not [line for line in lines if "=hidden" in line]


async def test_haproxy_escapes_request_line(base_url: str) -> None:
    context, namespace = _kind_target()

    before = Counter(_logs(context, namespace, "logfire-service"))
    marker = f"log-check-{secrets.token_hex(12)}"
    url = urlsplit(base_url)
    assert url.hostname
    port = url.port or (443 if url.scheme == "https" else 80)
    reader, writer = await asyncio.open_connection(url.hostname, port, ssl=url.scheme == "https")
    try:
        writer.write(f'GET /{marker}"hello HTTP/1.1\r\nHost: {url.netloc}\r\nConnection: close\r\n\r\n'.encode())
        await writer.drain()
        assert (await reader.readline()).startswith(b"HTTP/1.1 ")
        await reader.read()
    finally:
        writer.close()
        await writer.wait_closed()
    lines = await _new_lines_through(context, namespace, "logfire-service", before, marker)
    assert any(f'"GET /{marker}#22hello HTTP/1.1"' in line for line in lines), lines
