from __future__ import annotations

import httpx
import pytest

pytestmark = pytest.mark.anyio


async def test_platform_config_reachable(client: httpx.AsyncClient) -> None:
    response = await client.get("/ui-api/platform-config/")
    assert response.is_success, response.text


async def test_proxy_reachable(client: httpx.AsyncClient) -> None:
    response = await client.get("/proxy/")
    assert response.is_success, response.text
