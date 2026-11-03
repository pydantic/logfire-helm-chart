from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx
import pytest

from helpers.otlp import log_payload, metric_payload, profiles_payload, trace_payload
from helpers.poll import wait_for

pytestmark = pytest.mark.anyio


async def test_traces_endpoint_accepts_payload(
    client: httpx.AsyncClient, write_token: str
) -> None:
    response = await client.post(
        "/v1/traces",
        headers={"Content-Type": "application/json", "Authorization": write_token},
        json=trace_payload("helm-it-ingest-traces"),
    )
    assert response.is_success, response.text


async def test_metrics_endpoint_accepts_payload(
    client: httpx.AsyncClient, write_token: str
) -> None:
    response = await client.post(
        "/v1/metrics",
        headers={"Content-Type": "application/json", "Authorization": write_token},
        json=metric_payload("helm-it-ingest-metrics"),
    )
    assert response.is_success, response.text


async def test_logs_endpoint_accepts_payload(
    client: httpx.AsyncClient, write_token: str
) -> None:
    response = await client.post(
        "/v1/logs",
        headers={"Content-Type": "application/json", "Authorization": write_token},
        json=log_payload("helm-it-ingest-logs"),
    )
    assert response.is_success, response.text


async def test_profiles_endpoint_stores_profile(
    client: httpx.AsyncClient, write_token: str, read_token: str
) -> None:
    # CI sets FF_ENABLE_PROFILES_INGEST on logfire-ff-ingest. Without the chart's
    # route, HAProxy sends this path to the backend, which answers 404.
    response = await client.post(
        "/v1development/profiles",
        headers={"Content-Type": "application/x-protobuf", "Authorization": write_token},
        content=profiles_payload("helm-it-ingest-profiles", (123, 7)),
    )
    assert response.status_code == 200, response.text

    async def stored_total() -> int | None:
        now = datetime.now(timezone.utc)
        response = await client.post(
            "/v2/query",
            json={
                "sql": "SELECT service_name, sum(value) AS total FROM profiles GROUP BY service_name",
                "min_timestamp": (now - timedelta(hours=1)).isoformat(),
                "max_timestamp": (now + timedelta(seconds=10)).isoformat(),
            },
            headers={"Authorization": f"Bearer {read_token}", "Accept": "application/json"},
        )
        response.raise_for_status()
        rows = response.json().get("data") or []
        assert all(row["service_name"] == "helm-it-ingest-profiles" for row in rows), rows
        return int(rows[0]["total"]) if rows else None

    assert await wait_for(stored_total) == 130
