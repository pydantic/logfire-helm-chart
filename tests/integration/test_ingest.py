from __future__ import annotations

import httpx
import pytest

from helpers.otlp import log_payload, metric_payload, trace_payload

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
