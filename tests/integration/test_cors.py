"""The CORS grant that the installed HAProxy and the backend answer together."""

from __future__ import annotations

import os

import httpx
import pytest

pytestmark = pytest.mark.anyio

# Must match the deployment's public URL (ci-values: gateway.hostnames with TLS on).
PUBLIC_URL = os.environ.get("LOGFIRE_PUBLIC_URL", "https://logfire.example.com")


async def test_public_origin_is_granted_with_one_vary_origin(client: httpx.AsyncClient) -> None:
    path = "/ui-api/platform-config/"
    preflight = await client.options(path, headers={"Origin": PUBLIC_URL, "Access-Control-Request-Method": "GET"})
    assert preflight.status_code == 204, preflight.text
    assert preflight.headers["access-control-allow-credentials"] == "true"

    response = await client.get(path, headers={"Origin": PUBLIC_URL})
    assert response.is_success, response.text
    assert response.headers["access-control-allow-origin"] == PUBLIC_URL
    varied = [v.strip().lower() for line in response.headers.get_list("vary") for v in line.split(",")]
    assert varied.count("origin") == 1, response.headers
