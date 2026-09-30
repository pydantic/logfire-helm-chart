"""The remote MCP server's HTTP contract.

An MCP client discovers auth through these documents; a routing or TLS mistake
here breaks every MCP integration at connect time.
"""

from __future__ import annotations

import httpx
import pytest

pytestmark = pytest.mark.anyio


async def test_mcp_requires_bearer_auth(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "method": "initialize", "id": 1},
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    assert response.status_code == 401, response.text
    challenge = response.headers.get("www-authenticate", "")
    assert "resource_metadata=" in challenge, challenge
    assert 'scope="' in challenge, challenge
    assert "project:read" in challenge, challenge


async def test_mcp_protected_resource_metadata(client: httpx.AsyncClient) -> None:
    response = await client.get("/.well-known/oauth-protected-resource/mcp")
    assert response.is_success, response.text
    body = response.json()
    assert body["resource"].endswith("/mcp"), body
    assert body["authorization_servers"], body
    assert "project:read" in body["scopes_supported"], body
    assert body["bearer_methods_supported"] == ["header"], body


async def test_mcp_markdown_instructions(client: httpx.AsyncClient) -> None:
    response = await client.get("/mcp", headers={"Accept": "text/markdown"})
    assert response.is_success, response.text
    assert "text/html" not in response.headers.get("content-type", ""), response.headers
    assert response.text, "expected markdown instructions"
