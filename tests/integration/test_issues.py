"""Exception telemetry -> Issues round trip.

Covers the issue-grouping pipeline (ingest -> fusionfire -> filter-alert worker)
that turns exceptions into grouped issues, and the issues config API. The
worker evaluates filter alerts on a ~60s cadence, so the poll budget is minutes.
"""

from __future__ import annotations

import secrets

import httpx
import pytest

from helpers.otlp import exception_log_payload
from helpers.poll import wait_for

pytestmark = pytest.mark.anyio

ORG = "logfire-meta"


async def test_exception_ingest_creates_an_issue(
    client: httpx.AsyncClient,
    meta_frontend_token: str,
    project: str,
    write_token: str,
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    run = secrets.token_hex(8)

    enabled = await client.post(
        f"/ui-api/organizations/{ORG}/projects/{project}/issues/",
        headers=headers,
        json={
            "notification_interval": "0:01:00",
            "channel_ids": [],
            "extra_sql_filter": f"attributes->>'helm.it.run' = '{run}'",
        },
    )
    assert enabled.status_code == 201, enabled.text

    ingested = await client.post(
        "/v1/logs",
        headers={"Content-Type": "application/json", "Authorization": write_token},
        json=exception_log_payload("helm-it-issues", run),
    )
    assert ingested.is_success, ingested.text

    async def _issue_appeared() -> dict | None:
        listed = await client.get(
            f"/ui-api/organizations/{ORG}/projects/{project}/issues/list/",
            headers=headers,
            params={"state": "open"},
        )
        listed.raise_for_status()
        for issue in listed.json().get("data", []):
            if issue.get("first_exception_type") == "HelmItError":
                return issue
        return None

    issue = await wait_for(_issue_appeared, timeout=240.0, interval=5.0)
    assert issue["state"] == "open", issue
