"""Session replay through the installed chart's own object store.

The chart points the backend and the worker at `session-replays/` in the configured object store,
so a chunk the browser SDK uploads is written to that bucket and served back from it. These tests
exercise that path against the real deployment: the ingest and playback routes, a pod restart
between the two, and the strict policy the replay iframe is served under.
"""

from __future__ import annotations

import gzip
import json
import subprocess

import httpx
import pytest

pytestmark = pytest.mark.anyio

ORG = "logfire-meta"

# One rrweb-style event with the only field the ingest route requires.
_EVENT = {"type": 4, "timestamp": 1_700_000_000_000, "data": {"href": "https://app.example/"}}


def _gzipped_envelope(event: dict[str, object] = _EVENT) -> bytes:
    """The envelope the browser SDK sends: one gzipped chunk."""
    envelope = {
        "version": 1,
        "meta": {
            "eventCount": 1,
            "clickCount": 0,
            "keypressCount": 0,
            "errorCount": 0,
            "hasFullSnapshot": True,
            "urls": ["https://app.example/"],
            "distinctId": "helm-it-replay",
        },
        "events": [event],
    }
    return gzip.compress(json.dumps(envelope).encode())


async def _upload_chunk(
    client: httpx.AsyncClient, write_token: str, session_id: str, event: dict[str, object] = _EVENT
) -> httpx.Response:
    return await client.post(
        f"/v1/replay/{session_id}",
        params={"seq": 0},
        headers={
            "Content-Type": "application/json",
            "Content-Encoding": "gzip",
            "Authorization": write_token,
        },
        content=_gzipped_envelope(event),
    )


async def _read_chunk(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str, session_id: str
) -> httpx.Response:
    return await client.get(
        f"/ui-api/organizations/{ORG}/projects/{project}/replays/{session_id}/chunks/0",
        headers={"Authorization": f"Bearer {meta_frontend_token}"},
    )


async def test_replay_chunk_round_trips_through_the_object_store(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str, write_token: str
) -> None:
    """A chunk uploaded through the SDK route reads back through the playback route.

    The two routes run in different requests, and the chart's object store carries the bytes
    between them. With no shared store the upload is accepted and the playback answers 404, so the
    assertion is on the served events rather than on the status codes.
    """
    session_id = "helm-it-replay"
    uploaded = await _upload_chunk(client, write_token, session_id)
    assert uploaded.is_success, uploaded.text

    served = await _read_chunk(client, meta_frontend_token, project, session_id)
    assert served.is_success, served.text
    # The playback route answers the stored gzip blob, which httpx decodes transparently.
    body = json.loads(served.content)
    assert body["events"] == [_EVENT], body


async def test_a_second_writer_cannot_replace_a_chunk(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str, write_token: str
) -> None:
    """The same sequence uploaded with different events is refused, whatever pod serves it.

    The conditional PUT is what makes that true across replicas: without it the second upload
    would replace the first writer's recording and the playback would show the loser's events.
    """
    session_id = "helm-it-replay-conflict"
    first = await _upload_chunk(client, write_token, session_id)
    assert first.is_success, first.text

    conflicting = await _upload_chunk(
        client, write_token, session_id, event={**_EVENT, "data": {"href": "https://app.example/other"}}
    )
    assert conflicting.status_code == 409, conflicting.text

    served = await _read_chunk(client, meta_frontend_token, project, session_id)
    assert served.is_success, served.text
    assert json.loads(served.content)["events"] == [_EVENT]


async def test_replay_chunk_survives_a_backend_restart(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str, write_token: str
) -> None:
    """The same chunk reads back after the pod that accepted it is replaced.

    A pod-local directory loses the blob while the Postgres index survives, which surfaces as a
    session with no playable chunks. Restarting the backend between the two calls is what tells
    the two storage paths apart.
    """
    session_id = "helm-it-replay-restart"
    uploaded = await _upload_chunk(client, write_token, session_id)
    assert uploaded.is_success, uploaded.text

    restart = subprocess.run(
        ["kubectl", "rollout", "restart", "deployment/logfire-backend"],
        capture_output=True,
        text=True,
        check=False,
    )
    if restart.returncode != 0:
        pytest.skip(f"kubectl cannot restart the backend here: {restart.stderr.strip()}")
    ready = subprocess.run(
        ["kubectl", "rollout", "status", "deployment/logfire-backend", "--timeout=5m"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert ready.returncode == 0, ready.stderr

    served = await _read_chunk(client, meta_frontend_token, project, session_id)
    assert served.is_success, served.text
    assert json.loads(served.content)["events"] == [_EVENT]


async def test_replay_frame_is_served_under_the_strict_frame_policy(client: httpx.AsyncClient) -> None:
    """rrweb renders the recording in this iframe, so its policy stays the narrow one.

    The location block is what keeps a recorded page from loading scripts or reaching the network
    through the app's policy. Without it the file falls back to the app CSP, which allows both.
    """
    response = await client.get("/replay-frame.html")
    assert response.is_success, response.text
    policy = response.headers.get("content-security-policy", "")
    assert "default-src 'none'" in policy, policy
    assert "script-src 'none'" in policy, policy
    assert "img-src 'self' https: blob: data:" in policy, policy
