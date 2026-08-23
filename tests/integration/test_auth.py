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


async def test_gateway_client_metadata_document(client: httpx.AsyncClient) -> None:
    response = await client.get("/clients/logfire-gateway.json")
    assert response.is_success, response.text
    assert response.headers["content-type"].startswith("application/json")

    body = response.json()
    assert body == {
        "client_id": "https://logfire.example.com/clients/logfire-gateway.json",
        "client_name": "Logfire Gateway CLI",
        "grant_types": [
            "authorization_code",
            "refresh_token",
            "urn:ietf:params:oauth:grant-type:device_code",
        ],
        "redirect_uris": ["http://127.0.0.1/callback", "http://localhost/callback"],
        "response_types": ["code"],
        "scope": "project:gateway_proxy",
        "token_endpoint_auth_method": "none",
    }


@pytest.mark.parametrize(
    "path",
    ["/internal/write-tokens/get-state", "/internal/read-tokens/get-state"],
)
async def test_internal_token_lookups_are_not_exposed(
    client: httpx.AsyncClient, write_token: str, read_token: str, path: str
) -> None:
    """Driven with real tokens because a reachable endpoint answers `{"state": "active", ...}`.

    Asserted on the body, not the status: the request falls through to the frontend, which
    answers 200 with the SPA shell.
    """
    token = write_token if "write" in path else read_token
    response = await client.post(path, json={"token": token})
    try:
        body = response.json()
    except ValueError:
        return
    assert not isinstance(body, dict) or "state" not in body, body
