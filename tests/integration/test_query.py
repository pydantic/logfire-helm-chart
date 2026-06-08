from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx
import pytest

from helpers.otlp import trace_payload
from helpers.poll import wait_for

pytestmark = pytest.mark.anyio

SQL = "SELECT count(*) AS count FROM records"


async def _ingest_trace(client: httpx.AsyncClient, write_token: str) -> None:
    response = await client.post(
        "/v1/traces",
        headers={"Content-Type": "application/json", "Authorization": write_token},
        json=trace_payload("helm-it-query"),
    )
    response.raise_for_status()


async def _poll_v1_count(
    client: httpx.AsyncClient, read_token: str
) -> dict | None:
    response = await client.get(
        "/v1/query",
        params={"sql": SQL},
        headers={"Authorization": f"Bearer {read_token}", "Accept": "application/json"},
    )
    response.raise_for_status()
    body = response.json()
    for column in body.get("columns", []):
        if column.get("name") == "count":
            values = column.get("values") or []
            if values and int(values[0]) >= 1:
                return body
    return None


async def _poll_v2_count(
    client: httpx.AsyncClient, read_token: str
) -> dict | None:
    now = datetime.now(timezone.utc)
    response = await client.post(
        "/v2/query",
        json={
            "sql": SQL,
            "min_timestamp": (now - timedelta(hours=1)).isoformat(),
            "max_timestamp": (now + timedelta(seconds=10)).isoformat(),
        },
        headers={"Authorization": f"Bearer {read_token}", "Accept": "application/json"},
    )
    response.raise_for_status()
    body = response.json()
    rows = body.get("data") or []
    if rows and int(rows[0].get("count", 0)) >= 1:
        return body
    return None


async def test_query_v1_returns_ingested_data(
    client: httpx.AsyncClient,
    write_token: str,
    read_token: str,
) -> None:
    await _ingest_trace(client, write_token)
    await wait_for(
        lambda: _poll_v1_count(client, read_token),
        timeout=60.0,
        interval=2.0,
    )


async def test_query_v2_returns_ingested_data(
    client: httpx.AsyncClient,
    write_token: str,
    read_token: str,
) -> None:
    await _ingest_trace(client, write_token)
    await wait_for(
        lambda: _poll_v2_count(client, read_token),
        timeout=60.0,
        interval=2.0,
    )
