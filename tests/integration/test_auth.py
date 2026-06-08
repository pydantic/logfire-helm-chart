from __future__ import annotations

import httpx
import pytest

pytestmark = pytest.mark.anyio


async def test_oidc_discovery(client: httpx.AsyncClient) -> None:
    response = await client.get("/auth-api/.well-known/openid-configuration")
    assert response.is_success, response.text
    body = response.json()
    assert body.get("issuer"), body
    assert body.get("token_endpoint"), body
