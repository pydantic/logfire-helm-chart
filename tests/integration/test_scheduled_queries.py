from __future__ import annotations

import csv
import io
import json
import os
import secrets
from datetime import datetime, timedelta, timezone

import anyio
import httpx
import pytest
from helpers.poll import wait_for
from pyarrow import parquet

pytestmark = pytest.mark.anyio

ORG = "logfire-meta"
RESULTS_ROOT = "/var/lib/logfire/scheduled-query-results"


async def _kind_target() -> tuple[str, str] | None:
    namespace = os.environ.get("LOGFIRE_TEST_NAMESPACE")
    if namespace is None:
        if os.environ.get("CI", "").lower() in ("true", "1"):
            pytest.fail("LOGFIRE_TEST_NAMESPACE is required in CI")
        return None
    assert namespace and namespace == namespace.strip(), (
        "LOGFIRE_TEST_NAMESPACE must name a namespace"
    )
    context = os.environ.get("LOGFIRE_TEST_KUBE_CONTEXT")
    if context is None:
        result = await anyio.run_process(["kubectl", "config", "current-context"])
        context = result.stdout.decode().strip()
    assert context.startswith("kind-"), (
        f"deployment tests require a Kind context, got {context!r}"
    )
    return context, namespace


async def _kubectl(target: tuple[str, str], *args: str) -> str:
    context, namespace = target
    with anyio.fail_after(200):
        result = await anyio.run_process(
            ["kubectl", "--context", context, "--namespace", namespace, *args]
        )
    return result.stdout.decode()


async def _stored_files(target: tuple[str, str], directory: str) -> list[str]:
    script = (
        "import json, sys; from pathlib import Path; "
        "root = Path(sys.argv[1]); "
        "print(json.dumps(sorted(str(p.relative_to(root)) for p in root.rglob('*.parquet'))))"
    )
    output = await _kubectl(
        target,
        "exec",
        "deployment/logfire-backend",
        "--",
        "python",
        "-c",
        script,
        directory,
    )
    return json.loads(output)


async def _assert_downloads(
    client: httpx.AsyncClient, result_url: str, headers: dict[str, str]
) -> None:
    async def download(format: str) -> httpx.Response | None:
        response = await client.get(
            result_url, params={"format": format}, headers=headers
        )
        if response.status_code in (502, 503, 504):
            return None
        assert response.status_code == 200, response.text
        return response

    csv_response = await wait_for(lambda: download("csv"), timeout=60.0)
    assert csv_response.headers["content-type"].startswith("text/csv")
    assert list(csv.DictReader(io.StringIO(csv_response.text))) == [{"answer": "42"}]
    assert ".csv" in csv_response.headers["content-disposition"]

    parquet_response = await wait_for(lambda: download("parquet"), timeout=60.0)
    assert parquet_response.headers["content-type"] == "application/vnd.apache.parquet"
    assert parquet.read_table(io.BytesIO(parquet_response.content)).to_pylist() == [
        {"answer": 42}
    ]
    assert ".parquet" in parquet_response.headers["content-disposition"]


async def test_scheduled_query_runs_and_keeps_its_result_across_pod_restarts(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> None:
    target = await _kind_target()
    if target is not None:
        worker = json.loads(
            await _kubectl(target, "get", "deployment/logfire-worker", "-o", "json")
        )
        # The worker needs time for its poll loop, 31-second jobs, cancellation, and probe shutdown.
        assert worker["spec"]["template"]["spec"]["terminationGracePeriodSeconds"] >= 50
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    prefix = f"/ui-api/organizations/{ORG}/projects/{project}/scheduled-queries"
    # Leave at least 15 seconds to create the query before its scheduled minute.
    run_at = (datetime.now(timezone.utc) + timedelta(seconds=75)).replace(
        second=0, microsecond=0
    )
    created = await client.post(
        f"{prefix}/",
        headers=headers,
        json={
            "name": f"helm-it-scheduled-{secrets.token_hex(4)}",
            "query": "SELECT 42 AS answer",
            "cadence": "hourly",
            "run_at": f"00:{run_at.minute:02d}:00",
            "timezone": "UTC",
            "lookback": "PT1H",
            "send_condition": "always",
            "channel_ids": [],
        },
    )
    assert created.status_code == 201, created.text
    scheduled = created.json()
    assert scheduled["active"] is True, scheduled
    assert scheduled["paused_reason"] is None, scheduled
    query_url = f"{prefix}/{scheduled['id']}/"
    deleted = False
    try:

        async def completed_run() -> dict | None:
            response = await client.get(f"{query_url}runs/", headers=headers)
            assert response.status_code == 200, response.text
            runs = response.json()["runs"]
            if not runs:
                return None
            assert len(runs) == 1, runs
            run = runs[0]
            assert run["status"] != "failed", run
            if run["status"] != "succeeded":
                return None
            assert {
                key: run[key]
                for key in (
                    "status",
                    "row_count",
                    "truncated",
                    "error_kind",
                    "error_message",
                    "has_result",
                )
            } == {
                "status": "succeeded",
                "row_count": 1,
                "truncated": False,
                "error_kind": None,
                "error_message": None,
                "has_result": True,
            }, run
            return run

        run = await wait_for(completed_run, timeout=150.0, interval=2.0)
        result_url = f"{query_url}runs/{run['id']}/result/"
        await _assert_downloads(client, result_url, headers)

        if target is not None:
            directory = (
                f"{RESULTS_ROOT}/scheduled-query-results/{scheduled['organization_id']}/"
                f"{scheduled['project_id']}/{scheduled['id']}"
            )
            expected_files = [f"{run['id']}-a0.parquet"]
            assert await _stored_files(target, directory) == expected_files
            for deployment in ("logfire-worker", "logfire-backend"):
                await _kubectl(target, "rollout", "restart", f"deployment/{deployment}")
                await _kubectl(
                    target,
                    "rollout",
                    "status",
                    f"deployment/{deployment}",
                    "--timeout=180s",
                )
                await _assert_downloads(client, result_url, headers)
                assert await _stored_files(target, directory) == expected_files

        removed = await client.delete(query_url, headers=headers)
        assert removed.status_code == 204, removed.text
        deleted = True
        missing_query = await client.get(query_url, headers=headers)
        assert missing_query.status_code == 404, missing_query.text
        assert missing_query.json()["detail"] == (
            "No scheduled query with this ID is visible in this project. "
            "Check the project and the scheduled-query ID."
        )
        missing_result = await client.get(result_url, headers=headers)
        assert missing_result.status_code == 404, missing_result.text
        assert missing_result.json()["detail"] == (
            "No run with this ID is visible for this scheduled query. "
            "Check the scheduled-query ID and the run ID."
        )
        if target is not None:
            assert await _stored_files(target, directory) == []
    finally:
        if not deleted:
            await client.delete(query_url, headers=headers)
