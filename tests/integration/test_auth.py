from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import struct
import subprocess
import time

import httpx
import pytest

pytestmark = pytest.mark.anyio


def _kubectl_jsonpath(resource: str, jsonpath: str) -> str:
    """Read one field of a resource in the runner's release namespace."""
    context = os.environ.get("LOGFIRE_TEST_KUBE_CONTEXT")
    namespace = os.environ.get("LOGFIRE_TEST_NAMESPACE")
    if not context or not namespace:
        pytest.skip("This check needs the Kind runner's explicit context and namespace")
    result = subprocess.run(
        ["kubectl", "--context", context, "get", resource, "-n", namespace, "-o", f"jsonpath={jsonpath}"],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.stdout


def _secret_value(name: str, key: str) -> str:
    return base64.b64decode(_kubectl_jsonpath(f"secret/{name}", f"{{.data.{key}}}")).decode()


def _backend_secret_env(name: str) -> str:
    """Read the Secret value that a `logfire-backend` variable references, wherever it lives."""
    ref = _kubectl_jsonpath(
        "deployment/logfire-backend",
        f'{{.spec.template.spec.containers[0].env[?(@.name=="{name}")].valueFrom.secretKeyRef}}',
    )
    secret_ref = json.loads(ref)
    return _secret_value(secret_ref["name"], secret_ref["key"])


def _totp_code(secret: str) -> str:
    """Return the current RFC 6238 code with authenticator-app defaults: SHA-1, 6 digits, 30 seconds."""
    key = base64.b32decode(secret.strip().upper() + "=" * (-len(secret.strip()) % 8))
    digest = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = (struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
    return f"{code:06d}"


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
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    """The full `logfire login` CLI flow: device code -> session approval -> SDK token.

    The minted token is a machine (SDK) token: SDK endpoints accept it, the ui-api
    session endpoints deliberately do not ("SDK tokens can only be used for SDK
    endpoints"), and /v1/info only accepts project write tokens. /v1/project-list/
    is the SDK's own view of the user's projects, so the token is asserted there.
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

    listed = await client.get(
        "/v1/project-list/", headers={"Authorization": f"Bearer {token}"}
    )
    assert listed.is_success, listed.text
    assert project in [p["project_name"] for p in listed.json()], listed.text


async def test_chart_declared_admin_api_key_calls_the_instance_api(client: httpx.AsyncClient) -> None:
    token = _secret_value("logfire-tokens", "logfire-admin-api-key")

    response = await client.get("/api/v1/instance/organizations/", headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 200, response.text
    assert "logfire-meta" in [organization["organization_name"] for organization in response.json()]


async def test_password_sign_in_through_the_logfire_page(client: httpx.AsyncClient) -> None:
    """Sign in as the bootstrapped admin with a password on the Logfire page, then sign out.

    The Logfire page checks the password through Dex. The test proves that this path and the
    resulting session work in the installed chart.
    """
    bootstrap = _kubectl_jsonpath(
        "deployment/logfire-backend",
        '{.spec.template.spec.containers[0].env[?(@.name=="BOOTSTRAPPED_ORGANIZATIONS")].value}',
    )
    email_match = re.search(r'"admin_user_email": "([^"]+)"', bootstrap)
    assert email_match, "BOOTSTRAPPED_ORGANIZATIONS names no admin user"
    password = _backend_secret_env("ADMIN_PASSWORD")
    totp_secret = _backend_secret_env("ADMIN_TOTP_SECRET")

    providers = await client.get("/ui-api/auth/providers")
    assert providers.is_success, providers.text
    assert "local" in [provider["id"] for provider in providers.json()], providers.text

    signed_in = await client.post(
        "/ui-api/auth/email/login/",
        json={"email": email_match.group(1), "password": password, "totp_code": _totp_code(totp_secret)},
    )
    assert signed_in.status_code == 200, signed_in.text
    session = {"Authorization": f"Bearer {signed_in.json()['access_token']}"}

    projects = await client.get("/ui-api/organizations/logfire-meta/projects/", headers=session)
    assert projects.status_code == 200, projects.text
    assert "logfire-meta" in [project["project_name"] for project in projects.json()], projects.text

    signed_out = await client.post("/ui-api/account/logout/", headers=session)
    assert signed_out.is_success, signed_out.text
    after = await client.get("/ui-api/organizations/logfire-meta/projects/", headers=session)
    assert after.status_code == 401, after.text
