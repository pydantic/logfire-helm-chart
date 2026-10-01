"""Probes for every HAProxy route class: the response must come from the
backend that owns the path, not the frontend SPA catch-all.

A mis-routed path usually still answers 200 (the SPA shell), so these assert on
response signatures rather than status alone.
"""

from __future__ import annotations

import httpx
import pytest

pytestmark = pytest.mark.anyio


async def test_oauth_protected_resource_metadata(client: httpx.AsyncClient) -> None:
    response = await client.get("/.well-known/oauth-protected-resource")
    assert response.is_success, response.text
    body = response.json()
    assert body["resource"], body
    assert body["authorization_servers"], body
    assert body["bearer_methods_supported"] == ["header"], body


async def test_oauth_authorization_server_metadata(client: httpx.AsyncClient) -> None:
    response = await client.get("/.well-known/oauth-authorization-server")
    assert response.is_success, response.text
    body = response.json()
    assert body["token_endpoint"], body
    assert body["device_authorization_endpoint"], body


async def test_health_endpoint(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/health")
    assert response.status_code == 200, response.text
    assert not response.text, "health must stay unauthenticated and empty"


async def test_info_requires_a_token(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/info")
    assert response.status_code == 401, response.text
    assert "token" in response.text.lower(), response.text


async def test_integrations_route_reaches_the_backend(client: httpx.AsyncClient) -> None:
    """The webhook receiver must not fall through to the SPA."""
    response = await client.get("/integrations/")
    assert "json" in response.headers.get("content-type", ""), (
        f"expected a backend JSON response, got SPA or proxy fallback: {response.status_code}"
    )
    assert response.status_code >= 400, "no handler is mounted at the bare prefix"


async def test_frontend_shell_serves_the_spa(client: httpx.AsyncClient) -> None:
    response = await client.get("/")
    assert response.is_success, response.text
    assert "text/html" in response.headers.get("content-type", ""), response.headers
