from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx
import pytest

from helpers.otlp import firehose_delivery, log_payload, metric_payload, trace_payload
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


async def test_firehose_endpoint_stores_log(
    client: httpx.AsyncClient, write_token: str, read_token: str
) -> None:
    # CI sets FF_ENABLE_FIREHOSE_INGEST on logfire-ff-ingest. Without the chart's
    # route, HAProxy sends this path to the backend, which answers 404.
    request_id, body, headers = firehose_delivery("helm-it-firehose", "helm integration firehose log")
    response = await client.post(
        "/v1/firehose/logs",
        headers={**headers, "X-Amz-Firehose-Access-Key": write_token},
        content=body,
    )
    assert response.status_code == 200, response.text
    assert response.json().get("requestId") == request_id, response.text

    async def stored_messages() -> list[str] | None:
        now = datetime.now(timezone.utc)
        response = await client.post(
            "/v2/query",
            json={
                "sql": "SELECT message FROM records WHERE service_name = 'helm-it-firehose'",
                "min_timestamp": (now - timedelta(hours=1)).isoformat(),
                "max_timestamp": (now + timedelta(seconds=10)).isoformat(),
            },
            headers={"Authorization": f"Bearer {read_token}", "Accept": "application/json"},
        )
        response.raise_for_status()
        return [row["message"] for row in response.json().get("data") or []] or None

    assert await wait_for(stored_messages) == ["helm integration firehose log"]
