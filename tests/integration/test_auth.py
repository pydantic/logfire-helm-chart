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


@pytest.mark.parametrize(
    "path",
    ["/internal/write-tokens/get-state", "/internal/read-tokens/get-state"],
)
async def test_internal_token_lookups_are_not_exposed(
    client: httpx.AsyncClient, write_token: str, read_token: str, path: str
) -> None:
    """The `/internal/*` credential lookups must not answer from the public entry point.

    They authenticate nobody: hand one a token and it returns that token's organization and
    project, so a route to them from the edge is a token-validation oracle. Only
    `logfire-backend-auth` serves them and no haproxy backend points at it, so the request
    falls through to the frontend. Driven with real tokens because a reachable endpoint
    answers `{"state": "active", ...}` for these, which is exactly what must not come back;
    the sibling gateway lookup rides the same router, so it is unreachable by construction.
    """
    token = write_token if "write" in path else read_token
    response = await client.post(path, json={"token": token})
    try:
        body = response.json()
    except ValueError:
        return
    assert not isinstance(body, dict) or "state" not in body, body
