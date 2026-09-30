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
        "client_uri": "https://pydantic.dev/docs/ai/overview/gateway/",
        "grant_types": [
            "authorization_code",
            "refresh_token",
            "urn:ietf:params:oauth:grant-type:device_code",
        ],
        "redirect_uris": ["http://127.0.0.1/callback", "http://localhost/callback"],
        "response_types": ["code"],
        "logo_uri": "https://logfire.pydantic.dev/clients/logfire-gateway.svg",
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


async def test_dex_jwks(client: httpx.AsyncClient) -> None:
    response = await client.get("/auth-api/keys")
    assert response.is_success, response.text
    assert response.json()["keys"], response.text


async def test_token_endpoint_rejects_bad_credentials(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/auth-api/token",
        data={
            "grant_type": "password",
            "username": "nobody@example.com",
            "password": "wrong",
        },
    )
    assert response.status_code >= 400, response.text
    assert "json" in response.headers.get("content-type", ""), response.headers


async def test_device_flow_mints_a_working_user_token(
    client: httpx.AsyncClient, meta_frontend_token: str
) -> None:
    """The full `logfire login` CLI flow: device code -> session approval -> user token.

    The token then authenticates against the SDK's /v1/info, which is exactly what
    the Logfire SDK's check_tokens thread does with it.
    """
    created = await client.post(
        "/v1/device-auth/new/", params={"machine_name": "helm-it-e2e"}
    )
    assert created.is_success, created.text
    device_code = created.json()["device_code"]
    assert device_code in created.json()["frontend_auth_url"]

    approved = await client.post(
        "/ui-api/auth/device-auth",
        params={"deviceCode": device_code},
        headers={"Authorization": f"Bearer {meta_frontend_token}"},
        json={},
    )
    assert approved.is_success, approved.text
    assert approved.json()["status"] == "success", approved.text

    waited = await client.get(f"/v1/device-auth/wait/{device_code}")
    assert waited.is_success, waited.text
    token = waited.json()["token"]
    assert token, waited.text

    info = await client.get("/v1/info", headers={"Authorization": f"Bearer {token}"})
    assert info.is_success, info.text
