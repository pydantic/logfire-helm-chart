from __future__ import annotations

import json
import os
import secrets
from datetime import datetime, timedelta, timezone

import anyio
import httpx
import pytest
from google.rpc.status_pb2 import Status
from helpers.otlp import metric_payload
from helpers.poll import wait_for

pytestmark = pytest.mark.anyio

UNKNOWN_TOKEN_MESSAGE = (
    "This write token is not valid, and retrying will not change that. It may have "
    "been revoked, or it may belong to a different Logfire region than the endpoint you sent it "
    "to. Create a new token: https://pydantic.dev/docs/logfire/manage/create-write-tokens/"
)
UNKNOWN_TOKEN_WARNING = (
    "Logfire rejected this export: the write token is not valid. Create a new "
    "token, or check it matches the region you are sending to."
)
SQL_ERROR_MESSAGE = (
    "sql parser error: Expected: an SQL statement, found: SELET at Line: 1, Column: 1"
)
SQL_ERROR_DETAILS = {
    "error_type": "UserError",
    "kind": "Error",
    "code": "sql_syntax",
    "message": SQL_ERROR_MESSAGE,
    "span": {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 6}},
}


@pytest.mark.parametrize("path", ["/v1/traces", "/v1/logs", "/v1/metrics"])
@pytest.mark.parametrize("encoding", ["json", "protobuf"])
async def test_otlp_invalid_token_returns_a_decodable_rpc_status(
    client: httpx.AsyncClient, path: str, encoding: str
) -> None:
    content_type = (
        "application/json" if encoding == "json" else "application/x-protobuf"
    )
    response = await client.post(
        path,
        headers={
            "Authorization": "helm-invalid-write-token",
            "Content-Type": content_type,
        },
        content=b"{}" if encoding == "json" else b"",
    )
    assert response.status_code == 401, response.content
    assert response.headers["content-type"] == content_type
    assert response.headers["x-logfire-warning"] == UNKNOWN_TOKEN_WARNING
    assert "retry-after" not in response.headers
    if encoding == "json":
        assert response.json() == {"code": 16, "message": UNKNOWN_TOKEN_MESSAGE}
    else:
        status = Status.FromString(response.content)
        assert status.code == 16
        assert status.message == UNKNOWN_TOKEN_MESSAGE
        assert list(status.details) == []


async def _query(
    client: httpx.AsyncClient, path: str, read_token: str, sql: str, accept: str
) -> httpx.Response:
    now = datetime.now(timezone.utc)
    payload = {
        "sql": sql,
        "min_timestamp": (now - timedelta(hours=1)).isoformat(),
        "max_timestamp": (now + timedelta(seconds=10)).isoformat(),
    }
    headers = {"Authorization": f"Bearer {read_token}", "Accept": accept}
    if path == "/v1/query":
        return await client.get(path, params=payload, headers=headers)
    return await client.post(path, json=payload, headers=headers)


@pytest.mark.parametrize("path", ["/v1/query", "/v2/query"])
async def test_query_error_negotiation_preserves_the_engine_verdict(
    client: httpx.AsyncClient, read_token: str, path: str
) -> None:
    response = await _query(
        client,
        path,
        read_token,
        "SELET * FROM records",
        "application/problem+json, application/json",
    )
    assert response.status_code == 400, response.text
    assert response.headers["content-type"].startswith("application/problem+json")
    assert "accept" in response.headers["vary"].lower()
    assert "retry-after" not in response.headers
    body = response.json()
    public_url = os.environ.get(
        "LOGFIRE_PUBLIC_URL", "https://logfire.example.com"
    ).rstrip("/")
    assert {
        key: body[key]
        for key in (
            "type",
            "title",
            "status",
            "error_code",
            "error_category",
            "retryable",
        )
    } == {
        "type": f"{public_url}/-/errors/query-error",
        "title": "Query Error",
        "status": 400,
        "error_code": "query_error",
        "error_category": "query",
        "retryable": False,
    }, body
    if path == "/v1/query":
        assert response.headers["x-logfire-source"] == "fusionfire"
        assert json.loads(body["detail"]) == {
            "error": "invalid query",
            "details": SQL_ERROR_DETAILS,
        }
    else:
        assert body["detail"] == SQL_ERROR_MESSAGE
        assert body["error_details"] == SQL_ERROR_DETAILS

    legacy = await _query(
        client, path, read_token, "SELET * FROM records", "application/json"
    )
    assert legacy.status_code == 400, legacy.text
    assert legacy.headers["content-type"].startswith("application/json")
    if path == "/v1/query":
        assert json.loads(legacy.json()["detail"]) == {
            "error": "invalid query",
            "details": SQL_ERROR_DETAILS,
        }
    else:
        assert legacy.json() == {"error": "invalid query", "details": SQL_ERROR_DETAILS}


async def test_variable_updates_stream_sends_its_first_frame_immediately(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    minted = await client.post(
        f"/ui-api/organizations/logfire-meta/projects/{project}/api-keys/",
        headers={"Authorization": f"Bearer {meta_frontend_token}"},
        json={
            "name": f"helm-it-variable-stream-{secrets.token_hex(4)}",
            "description": "helm integration variable updates",
            "scopes": ["project:read_variables"],
        },
    )
    assert minted.status_code == 201, minted.text
    with anyio.fail_after(5.0):
        async with client.stream(
            "GET",
            "/v1/variable-updates/",
            headers={
                "Authorization": f"Bearer {minted.json()['token']}",
                "Accept": "text/event-stream",
            },
        ) as response:
            assert response.status_code == 200
            assert response.headers["content-type"].startswith("text/event-stream")
            lines = response.aiter_lines()
            assert [await anext(lines), await anext(lines)] == [": keepalive", ""]


async def test_ingested_metric_is_queryable_through_its_value_struct(
    client: httpx.AsyncClient, write_token: str, read_token: str
) -> None:
    service_name = f"helm-it-metric-{secrets.token_hex(6)}"
    ingested = await client.post(
        "/v1/metrics",
        headers={"Authorization": write_token, "Content-Type": "application/json"},
        json=metric_payload(service_name),
    )
    assert ingested.status_code == 200, ingested.text
    sql = (
        "SELECT metric_name, metric_sum(value) AS total, metric_count(value) AS points "
        f"FROM metrics WHERE service_name = '{service_name}'"
    )

    async def persisted_metric() -> list[dict] | None:
        response = await _query(
            client, "/v2/query", read_token, sql, "application/json"
        )
        assert response.status_code == 200, response.text
        rows = response.json()["data"]
        if not rows:
            return None
        assert rows == [
            {"metric_name": "helm.integration.counter", "total": 1.0, "points": 1}
        ], rows
        return rows

    await wait_for(persisted_metric, timeout=60.0, interval=2.0)
