from __future__ import annotations

import os
import secrets
import subprocess
from collections import Counter

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


async def test_url_credentials_stay_out_of_proxy_logs(client: httpx.AsyncClient) -> None:
    context = os.environ.get("LOGFIRE_TEST_KUBE_CONTEXT")
    namespace = os.environ.get("LOGFIRE_TEST_NAMESPACE")
    if not context or not namespace:
        pytest.skip("Access log checks need the Kind runner's explicit context and namespace")

    before = {component: Counter(_logs(context, namespace, component)) for component in COMPONENTS}
    token = f"synthetic-token-{secrets.token_hex(12)}"
    short_code = secrets.token_hex(5)
    link = f"/auth/email-callback?token={token}"
    # With `.js`, this stays below the 20 characters at which HAProxy redacts a path segment.
    marker = f"lc-{secrets.token_hex(6)}"

    assert (await client.get(link)).status_code == 200
    await client.get(f"/ui-api/auth/users/email-session-data/{token}/")
    await client.get(f"/l/{short_code}")
    # A missing file is the case where the nginx error log records the request line and referrer.
    await client.get(f"/{marker}.js?token={token}", headers={"Referer": f"http://example.test{link}"})

    logged = {}
    for component in COMPONENTS:

        async def new_lines() -> list[str] | None:
            lines = list((Counter(_logs(context, namespace, component)) - before[component]).elements())
            return lines if any(marker in line for line in lines) else None

        logged[component] = await wait_for(new_lines, timeout=30, interval=1)
        assert not [line for line in logged[component] if token in line or short_code in line]

    # HAProxy can be the only record of a request that does not reach a service.
    assert any("/ui-api/auth/users/email-session-data/[redacted]/" in line for line in logged["logfire-service"])
