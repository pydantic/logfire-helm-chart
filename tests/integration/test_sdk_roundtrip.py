from __future__ import annotations

import secrets
from collections.abc import AsyncIterator
from datetime import datetime, timedelta, timezone

import httpx
import logfire
import pytest

from helpers.poll import wait_for

pytestmark = pytest.mark.anyio

SQL = "SELECT count(*) AS count FROM records WHERE message LIKE '%{marker}%'"


@pytest.fixture
def sdk(
    base_url: str, write_token: str, monkeypatch: pytest.MonkeyPatch
) -> AsyncIterator[None]:
    """Configure the real Logfire SDK against the deployed chart.

    This is the one test path a raw OTLP post cannot cover: token minted through
    the API, accepted by the SDK, exported over the SDK's own OTLP pipeline into
    the same ingest the product uses. `OTEL_BSP_MAX_EXPORT_BATCH_SIZE=1` makes
    the batch processor export eagerly instead of waiting on its batch timer.

    `logfire.configure` also spawns a background `check_tokens` thread that GETs
    `/v1/info`; when the deployment does not serve that path the SDK prints a
    warning. It is harmless — do not chase it.
    """
    monkeypatch.setenv("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", "1")
    logfire.configure(
        token=write_token,
        send_to_logfire=True,
        service_name="helm-it-sdk",
        environment=f"helm-it-{secrets.token_hex(4)}",
        inspect_arguments=False,
        advanced=logfire.AdvancedOptions(base_url=base_url),
    )
    yield
    logfire.force_flush()


async def _poll_for_marker(client: httpx.AsyncClient, read_token: str, marker: str) -> dict | None:
    now = datetime.now(timezone.utc)
    response = await client.post(
        "/v2/query",
        json={
            "sql": SQL.format(marker=marker),
            "min_timestamp": (now - timedelta(hours=1)).isoformat(),
            "max_timestamp": (now + timedelta(seconds=10)).isoformat(),
        },
        headers={"Authorization": f"Bearer {read_token}", "Accept": "application/json"},
    )
    response.raise_for_status()
    rows = response.json().get("data") or []
    if rows and int(rows[0].get("count", 0)) >= 1:
        return rows
    return None


async def test_sdk_emitted_telemetry_is_queryable(
    client: httpx.AsyncClient,
    sdk: None,
    read_token: str,
) -> None:
    """Span and log emitted through the SDK become queryable via the query API."""
    marker = f"helm-it-sdk-{secrets.token_hex(6)}"
    with logfire.span("sdk-round-trip {marker}", marker=marker):
        logfire.info("hello from the SDK: {marker}", marker=marker)
    # Surface export failure here rather than as a 90s poll timeout below; a
    # failed flush logs its own warning (e.g. 401 for a rejected write token).
    assert logfire.force_flush(timeout_millis=30_000), (
        "Logfire SDK export failed — see the logfire warnings above"
    )

    await wait_for(
        lambda: _poll_for_marker(client, read_token, marker),
        timeout=90.0,
        interval=2.0,
    )
