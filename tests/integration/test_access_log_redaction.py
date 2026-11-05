from __future__ import annotations

import os
import secrets
import subprocess
from collections import Counter

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


async def test_url_credentials_stay_out_of_proxy_logs(client: httpx.AsyncClient) -> None:
    context = os.environ.get("LOGFIRE_TEST_KUBE_CONTEXT")
    namespace = os.environ.get("LOGFIRE_TEST_NAMESPACE")
    if not context or not namespace:
        pytest.skip("Access log checks need the Kind runner's explicit context and namespace")

    # Each proxy writes the line of the final PATCH request after the lines of the requests before it.
    arrival_signs = {"logfire-service": '"PATCH"', "logfire-frontend-service": '"PATCH /'}
    before = {component: Counter(_logs(context, namespace, component)) for component in arrival_signs}
    token = f"synthetic-token-{secrets.token_hex(12)}"
    link = f"/auth/email-callback?token={token}"

    assert (await client.get(link)).status_code == 200
    # A missing file is the case where the nginx error log records the request line and referrer.
    await client.get(f"/log-check-missing.js?token={token}", headers={"Referer": f"http://example.test{link}"})
    await client.patch("/log-check.js")

    for component, arrival_sign in arrival_signs.items():

        async def new_lines() -> list[str] | None:
            lines = list((Counter(_logs(context, namespace, component)) - before[component]).elements())
            return lines if any(arrival_sign in line for line in lines) else None

        lines = await wait_for(new_lines, timeout=30, interval=1)
        assert not [line for line in lines if token in line]
