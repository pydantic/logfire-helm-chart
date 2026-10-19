"""The remote MCP server's HTTP contract.

An MCP client discovers auth through these documents; a routing or TLS mistake
here breaks every MCP integration at connect time. The server runs
TrustedHostMiddleware against ALLOWED_HOSTS (the chart's public hostnames), so
requests carry the public Host header even though CI reaches it by port-forward.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from helpers.otlp import trace_payload
from helpers.poll import wait_for

pytestmark = pytest.mark.anyio

# Must match the deployment's public hostname (ci-values: gateway.hostnames).
PUBLIC_HOST = os.environ.get("LOGFIRE_PUBLIC_HOST", "logfire.example.com")
HOST_HEADERS = {"Host": PUBLIC_HOST}


def _rpc_result(response: httpx.Response) -> dict:
    response.raise_for_status()
    if "text/event-stream" in response.headers.get("content-type", ""):
        messages = [json.loads(line[5:].strip()) for line in response.text.splitlines() if line.startswith("data:")]
        body = next(message for message in messages if "id" in message)
    else:
        body = response.json()
    assert "error" not in body, body
    return body["result"]


async def test_mcp_authenticated_query(
    client: httpx.AsyncClient,
    meta_frontend_token: str,
    project: str,
    write_token: str,
) -> None:
    payload = trace_payload("helm-it-mcp")
    span = payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
    now = datetime.now(timezone.utc)
    query = {
        "project": project,
        "query": (
            "SELECT trace_id, span_id, service_name, span_name FROM records "
            f"WHERE trace_id = '{span['traceId']}' LIMIT 2"
        ),
        "start_timestamp": (now - timedelta(minutes=5)).isoformat(),
        "end_timestamp": (now + timedelta(minutes=5)).isoformat(),
    }
    ingested = await client.post(
        "/v1/traces",
        headers={"Content-Type": "application/json", "Authorization": write_token},
        json=payload,
    )
    ingested.raise_for_status()
    minted = await client.post(
        f"/ui-api/organizations/logfire-meta/projects/{project}/api-keys/",
        headers={"Authorization": f"Bearer {meta_frontend_token}"},
        json={
            "name": "helm MCP query",
            "description": "Helm integration MCP query",
            "scopes": ["project:read"],
        },
    )
    assert minted.status_code == 201, minted.text
    headers = {
        **HOST_HEADERS,
        "Authorization": f"Bearer {minted.json()['token']}",
        "Accept": "application/json, text/event-stream",
    }
    initialized = _rpc_result(
        await client.post(
            "/mcp",
            headers=headers,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "helm-integration", "version": "1"},
                },
            },
        )
    )
    assert initialized["protocolVersion"] == "2025-06-18", initialized
    notification = await client.post(
        "/mcp",
        headers=headers,
        json={
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        },
    )
    assert notification.status_code == 202, notification.text
    tools = _rpc_result(
        await client.post(
            "/mcp",
            headers=headers,
            json={
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
            },
        )
    )
    assert "query_run" in {tool["name"] for tool in tools["tools"]}, tools
    expected = [
        {
            "trace_id": span["traceId"],
            "span_id": span["spanId"],
            "service_name": "helm-it-mcp",
            "span_name": "integration-span",
        }
    ]

    async def exact_trace() -> list[dict[str, str]] | None:
        result = _rpc_result(
            await client.post(
                "/mcp",
                headers=headers,
                json={
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "query_run",
                        "arguments": query,
                    },
                },
            )
        )
        assert not result.get("isError"), result
        rows = result["structuredContent"]["rows"]
        if not rows:
            return None
        assert rows == expected, result
        return rows

    rows = await wait_for(exact_trace, timeout=90.0, interval=2.0)
    print(
        json.dumps(
            {"mcp_endpoint": str(client.base_url.join("/mcp")), "public_host": PUBLIC_HOST, **query, "rows": rows}
        )
    )


async def test_mcp_requires_bearer_auth(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "method": "initialize", "id": 1},
        headers={
            **HOST_HEADERS,
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
    response = await client.get("/.well-known/oauth-protected-resource/mcp", headers=HOST_HEADERS)
    assert response.is_success, response.text
    body = response.json()
    assert body["resource"].endswith("/mcp"), body
    assert body["authorization_servers"], body
    assert "project:read" in body["scopes_supported"], body
    assert body["bearer_methods_supported"] == ["header"], body


async def test_mcp_markdown_instructions(client: httpx.AsyncClient) -> None:
    response = await client.get("/mcp", headers={**HOST_HEADERS, "Accept": "text/markdown"})
    assert response.is_success, response.text
    assert "text/html" not in response.headers.get("content-type", ""), response.headers
    assert response.text, "expected markdown instructions"
