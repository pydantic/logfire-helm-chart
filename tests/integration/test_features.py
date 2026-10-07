"""Feature coverage for the ui-api resource surface.

Each test creates a resource through the same API the frontend uses and reads
it back, so a chart-level wiring mistake (wrong service, broken secret, missing
migration) surfaces as a failing CRUD round trip.
"""

from __future__ import annotations

import json
import secrets

import httpx
import pytest

pytestmark = pytest.mark.anyio

ORG = "logfire-meta"


def _p(project: str) -> str:
    return f"/ui-api/organizations/{ORG}/projects/{project}"


async def test_dashboard_crud_round_trip(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    slug = f"helm-it-{secrets.token_hex(4)}"
    created = await client.post(
        f"{_p(project)}/dashboards/",
        headers=headers,
        json={
            "name": slug,
            "slug": slug,
            "definition": {
                "kind": "Dashboard",
                "metadata": {"name": slug, "project": project},
                "spec": {"display": None, "panels": {}, "layouts": []},
            },
        },
    )
    assert created.status_code == 200, created.text
    assert created.json()["dashboard_slug"] == slug

    panel_key = "panel-1"
    updated = await client.put(
        f"{_p(project)}/dashboards/{slug}/panels-and-layouts/",
        headers=headers,
        json={
            "panels": {
                panel_key: {
                    "kind": "Panel",
                    "spec": {
                        "display": {"name": "Panel 1"},
                        "plugin": {"kind": "Markdown", "spec": {}},
                    },
                }
            },
            "layouts": [
                {
                    "kind": "Grid",
                    "spec": {
                        "items": [
                            {
                                "x": 0,
                                "y": 0,
                                "width": 6,
                                "height": 4,
                                "content": {"$ref": f"#/spec/panels/{panel_key}"},
                            }
                        ]
                    },
                }
            ],
        },
    )
    assert updated.is_success, updated.text

    fetched = await client.get(f"{_p(project)}/dashboards/{slug}/", headers=headers)
    assert fetched.is_success, fetched.text
    assert panel_key in fetched.json()["dashboard"]["spec"]["panels"]


async def test_alert_crud_round_trip(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    name = f"helm-it-alert-{secrets.token_hex(4)}"
    created = await client.post(
        f"{_p(project)}/alerts/",
        headers=headers,
        json={
            "name": name,
            "query": "SELECT 1",
            "time_window": "PT1H",
            "frequency": "PT5M",
            "watermark": "PT30S",
            "notify_when": "has_matches",
        },
    )
    assert created.status_code == 201, created.text
    alert_id = created.json()["id"]

    listed = await client.get(f"{_p(project)}/alerts/", headers=headers)
    assert listed.is_success, listed.text
    assert any(a["id"] == alert_id for a in listed.json()), listed.text

    from datetime import datetime, timedelta, timezone

    now = datetime.now(timezone.utc)
    history = await client.get(
        f"{_p(project)}/alerts/{alert_id}/history/",
        headers=headers,
        params={
            "start_timestamp": (now - timedelta(hours=1)).isoformat(),
            "end_timestamp": (now + timedelta(minutes=5)).isoformat(),
        },
    )
    assert history.is_success, history.text
    assert "total_runs" in history.json(), history.text


async def test_slo_creates_managed_alerts(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    created = await client.post(
        f"{_p(project)}/slos/",
        headers=headers,
        json={
            "scope_kind": "service",
            "scope_value": "helm-it-svc",
            "name": f"helm-it-slo-{secrets.token_hex(4)}",
            "total_query": "parent_span_id IS NULL",
            "bad_query": "otel_status_code = 'ERROR'",
            "target_percent": "99.9",
            "rolling_window_seconds": 3600,
        },
    )
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["name"].startswith("helm-it-slo-"), body
    assert body["alerts"]["fast"]["alert_id"], body


async def test_dataset_case_round_trip(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    name = f"helm-it-dataset-{secrets.token_hex(4)}"
    created = await client.post(
        f"{_p(project)}/datasets/", headers=headers, json={"name": name}
    )
    assert created.status_code == 201, created.text
    dataset_id = created.json()["id"]

    case = await client.post(
        f"{_p(project)}/datasets/{dataset_id}/cases/",
        headers=headers,
        json={"inputs": {"q": "hello"}},
    )
    assert case.status_code == 201, case.text
    assert case.json()["dataset_id"] == dataset_id

    listed = await client.get(f"{_p(project)}/datasets/", headers=headers)
    assert listed.is_success, listed.text
    assert any(d["name"] == name for d in listed.json()["datasets"]), listed.text


async def test_email_channel_and_capabilities(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    created = await client.post(
        f"{_p(project)}/channels/",
        headers=headers,
        json={
            "label": "helm-it email",
            "config": {
                "type": "email",
                "recipients": ["helm-it@example.com"],
            },
        },
    )
    assert created.status_code == 201, created.text
    assert created.json()["config"]["type"] == "email"

    capabilities = await client.get(f"{_p(project)}/channels/capabilities/", headers=headers)
    assert capabilities.is_success, capabilities.text
    assert "pagerduty" in capabilities.json(), capabilities.text


async def test_managed_variable_serves_over_v1_and_ofrep(
    client: httpx.AsyncClient,
    meta_frontend_token: str,
    project: str,
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    name = f"helm_it_flag_{secrets.token_hex(4)}"
    created = await client.post(
        f"{_p(project)}/variables/",
        headers=headers,
        json={
            "name": name,
            "description": "helm integration flag",
            "json_schema": None,
            "rollout": {"labels": {}},
            "overrides": [],
            "external": True,
            "initial_serialized_value": json.dumps(True),
        },
    )
    assert created.status_code == 201, created.text
    variable_id = created.json()["id"]

    # A flag without a served value evaluates to the code-default reply (no
    # `value`); set one through the value endpoint the UI uses. `latest_value`
    # is a JSON-serialized string, not a bare JSON value.
    valued = await client.put(
        f"{_p(project)}/variables/{variable_id}/value-and-rollout/",
        headers=headers,
        json={"latest_value": json.dumps(True), "rollout": {"labels": {}}, "overrides": []},
    )
    assert valued.is_success, valued.text

    # The SDK serving path takes a scoped API key, not a read token.
    minted = await client.post(
        f"{_p(project)}/api-keys/",
        headers=headers,
        json={
            "name": f"helm-it-flags-{secrets.token_hex(4)}",
            "description": "helm integration flags key",
            "scopes": ["project:read_variables"],
        },
    )
    assert minted.status_code == 201, minted.text
    key_headers = {"Authorization": f"Bearer {minted.json()['token']}"}

    served = await client.get("/v1/variables/", headers=key_headers)
    assert served.is_success, served.text
    assert name in served.json()["variables"], served.text

    evaluated = await client.post(
        f"/v1/ofrep/v1/evaluate/flags/{name}",
        headers=key_headers,
        json={"context": {"targetingKey": "helm-it-user"}},
    )
    assert evaluated.is_success, evaluated.text
    body = evaluated.json()
    assert body["key"] == name, body
    assert body["value"] is True, body


async def test_sql_tooling(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}

    functions = await client.get(f"{_p(project)}/autocomplete/functions/", headers=headers)
    assert functions.is_success, functions.text
    assert "upper" in functions.json(), functions.text

    records = await client.get(f"{_p(project)}/autocomplete/records/", headers=headers)
    assert records.is_success, records.text
    assert "service_names" in records.json(), records.text

    # Deliberately no sql/format (the SQL editor's format button) test here:
    # POST .../sql/format/ 404s on the default topology. /query/format/ is
    # mounted only by fusionfire's 'query' subcommand (query_api_router), while
    # the chart runs the combined 'query-worker' subcommand (logfire-ff-query-worker
    # is opt-in), whose router serves /query/validate/ and /query/historic/ but
    # not /query/format/. Being fixed upstream; restore the round-trip test from
    # PR #262's history (test_sql_format) once the pinned fusionfire build serves
    # the endpoint on the combined arm.




async def test_org_members_and_project_stats(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    members = await client.get(
        f"/ui-api/organizations/{ORG}/members/", headers=headers
    )
    assert members.is_success, members.text
    assert members.json()["members"], members.text

    # Keyset-paginated (projects accumulate across CI runs), so scan pages
    # instead of assuming the first page holds the fresh project.
    params: dict[str, str | int] = {"limit": 100}
    names: set[str] = set()
    for _ in range(10):
        stats = await client.get(
            f"/ui-api/organizations/{ORG}/projects/stats", headers=headers, params=params
        )
        assert stats.is_success, stats.text
        body = stats.json()
        names |= {row["project_name"] for row in body["data"]}
        cursor = body.get("next_cursor")
        if not cursor:
            break
        params["cursor"] = cursor
    assert project in names, f"{project} not found in org project stats"


async def test_public_api_with_project_api_key(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    minted = await client.post(
        f"{_p(project)}/api-keys/",
        headers=headers,
        json={
            "name": f"helm-it-key-{secrets.token_hex(4)}",
            "description": "helm integration key",
            "scopes": ["project:read"],
        },
    )
    assert minted.status_code == 201, minted.text
    token = minted.json()["token"]

    listed = await client.get(
        "/api/v1/projects/", headers={"Authorization": f"Bearer {token}"}
    )
    assert listed.is_success, listed.text
