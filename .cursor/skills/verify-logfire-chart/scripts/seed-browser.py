#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx>=0.27"]
# ///
"""Seed one real OTLP record, saved enhanced view, and custom panel on local Kind."""

import argparse
import json
import os
import secrets
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode, urlsplit

import httpx

SCHEMA = {
    "type": "object",
    "properties": {"order_id": {"type": "string"}, "amount": {"type": "number"}},
    "required": ["order_id"],
}
# Revalidate this fingerprint if the schema or the pinned frontend normalizer changes.
FINGERPRINT = "69009c7a4417ab42892ec37acc372fb6bc2157846cd01c799f07d665744eaec7"
JSX = (
    '<div className="rounded border p-3"><strong>Enhanced renderer active</strong>'
    '<p>{Object.keys(data.properties || {}).join(", ")}</p></div>'
)
VIEW = """export default function EnhancedView({ record }) {
  return React.createElement('div', {className:'rounded border p-3'},
    React.createElement('strong', null, 'Enhanced renderer active'),
    React.createElement('p', null, Object.keys(record.properties || {}).join(', ')));
}"""
PANEL = """export function ChartContractPanel({ record }) {
  return React.createElement('section', {className:'rounded border p-3'},
    React.createElement('strong', null, 'Custom panel active'),
    React.createElement('p', null, record.message || 'No record message'));
}"""


def loopback_origin(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme not in {"http", "https"}
        or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise argparse.ArgumentTypeError("Use an HTTP(S) loopback origin without credentials, path, query, or fragment")
    return value.rstrip("/")


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--base-url", required=True, type=loopback_origin)
parser.add_argument("--browser-origin", required=True, type=loopback_origin)
parser.add_argument("--token-file", required=True, type=Path)
parser.add_argument(
    "--output", required=True, type=Path, help="Private receipt, such as /absolute/runtime/browser.json"
)
args = parser.parse_args()
if args.token_file.stat().st_mode & 0o077:
    parser.error("The token file must have private permissions, such as mode 0600")
token = args.token_file.read_text().strip()
if not token:
    parser.error("The token file is empty")
evidence_path = args.output.with_name("browser-evidence.json")
if args.output == evidence_path or args.output.exists() or evidence_path.exists():
    parser.error("Choose a new private receipt path and an unused sibling browser-evidence.json")
args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
origin = args.browser_origin
org = "logfire-meta"
name = f"browser-contract-{int(time.time())}-{secrets.token_hex(3)}"
auth = {"Authorization": f"Bearer {token}"}
with httpx.Client(
    base_url=args.base_url,
    headers={"Host": urlsplit(origin).netloc},
    timeout=30,
    trust_env=False,
    follow_redirects=False,
) as client:
    config = client.get("/config.1.js")
    config.raise_for_status()
    if f"apiHost: '{urlsplit(origin).netloc}'" not in config.text or "selfHosted: true" not in config.text:
        raise RuntimeError("Served frontend configuration does not match the browser origin and self-hosted mode")
    version = client.get("/version.json")
    version.raise_for_status()
    created = client.post(
        f"/ui-api/organizations/{org}/projects/", headers=auth, json={"project_name": name, "visibility": "private"}
    )
    created.raise_for_status()
    project = created.json()["project_name"]
    prefix = f"/ui-api/organizations/{org}/projects/{project}"
    minted = {}
    for kind in ("write", "read"):
        response = client.post(
            f"{prefix}/{kind}-tokens/", headers=auth, json={"description": f"Browser contract {kind} token"}
        )
        response.raise_for_status()
        minted[kind] = response.json()
    marker = f"chart browser contract {secrets.token_hex(6)}"
    trace_id, span_id = secrets.token_hex(16), secrets.token_hex(8)
    now_ns = time.time_ns()
    messages = {
        "gen_ai.input.messages": [
            {"role": "user", "parts": [{"type": "text", "content": "Show the local chart browser fixture."}]}
        ],
        "gen_ai.output.messages": [
            {"role": "assistant", "parts": [{"type": "text", "content": "This is bounded verification telemetry."}]}
        ],
    }
    attributes = {
        "logfire.msg": marker,
        "gen_ai.operation.name": "chat",
        "gen_ai.system": "chart-browser-verification",
        "gen_ai.request.model": "local-contract-fixture",
        **{key: json.dumps(value) for key, value in messages.items()},
        "gen_ai.tool.definitions": json.dumps(
            [
                {
                    "name": "browser_contract_tool",
                    "description": "Browser verification tool schema",
                    "parameters": SCHEMA,
                }
            ]
        ),
    }
    payload = {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [{"key": "service.name", "value": {"stringValue": "chart-browser-verification"}}]
                },
                "scopeSpans": [
                    {
                        "scope": {"name": "helm-browser-verification"},
                        "spans": [
                            {
                                "traceId": trace_id,
                                "spanId": span_id,
                                "name": marker,
                                "kind": 1,
                                "startTimeUnixNano": str(now_ns - 2_000_000),
                                "endTimeUnixNano": str(now_ns),
                                "attributes": [
                                    {"key": key, "value": {"stringValue": value}} for key, value in attributes.items()
                                ],
                            }
                        ],
                    }
                ],
            }
        ]
    }
    ingested = client.post("/v1/traces", headers={"Authorization": minted["write"]}, json=payload)
    ingested.raise_for_status()
    now = datetime.now(timezone.utc)
    query = {
        "sql": f"SELECT trace_id, span_id, message FROM records WHERE trace_id = '{trace_id}'",
        "min_timestamp": (now - timedelta(minutes=5)).isoformat(),
        "max_timestamp": (now + timedelta(minutes=5)).isoformat(),
    }
    expected = [{"trace_id": trace_id, "span_id": span_id, "message": marker}]
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        queried = client.post(
            "/v2/query",
            headers={"Authorization": f"Bearer {minted['read']}"},
            json=query,
            timeout=min(30, max(deadline - time.monotonic(), 0.1)),
        )
        queried.raise_for_status()
        rows = queried.json().get("data", [])
        if rows:
            if rows != expected:
                raise RuntimeError("The query did not return exactly the seeded trace, span, and message")
            break
        time.sleep(min(2, max(deadline - time.monotonic(), 0)))
    else:
        raise RuntimeError("The seeded span did not become queryable within 90 seconds")
    details = client.post(
        f"{prefix}/fetch-details/",
        headers=auth,
        json={
            "span_locators": [{"trace_id": trace_id, "span_id": span_id}],
            "min_start_timestamp": query["min_timestamp"],
            "max_start_timestamp": query["max_timestamp"],
        },
    )
    details.raise_for_status()
    records = details.json()
    if len(records) != 1 or any(records[0]["attributes"].get(key) != value for key, value in messages.items()):
        raise RuntimeError("The record details do not contain the seeded user and assistant messages")
    panel = client.post(
        f"{prefix}/panels/create/",
        headers=auth,
        json={
            "name": "chart-contract",
            "description": "Chart browser verification",
            "source_code": "import React from 'react';\n" + PANEL,
            "transpiled_code": PANEL,
            "config": {},
        },
    )
    panel.raise_for_status()
    view = client.put(
        f"{prefix}/enhanced-json-views/",
        headers=auth,
        json={
            "schema_fingerprint": FINGERPRINT,
            "json_schema": {},
            "jsx_source": JSX,
            "transpiled_code": VIEW,
            "sample_data": SCHEMA,
        },
    )
    view.raise_for_status()
    policy = client.get(f"{prefix}/panels/egress/", headers=auth)
    policy.raise_for_status()
    params = urlencode(
        {
            "traceId": trace_id,
            "spanId": span_id,
            "since": query["min_timestamp"],
            "until": query["max_timestamp"],
            "auto-app-update": "0",
        }
    )
    project_url = f"{origin}/{org}/{project}"
    receipt = {
        "version": version.json(),
        "organization": org,
        "project": project,
        "marker": marker,
        "trace_id": trace_id,
        "span_id": span_id,
        "schema_fingerprint": FINGERPRINT,
        "query_rows": rows,
        "query_range": {"since": query["min_timestamp"], "until": query["max_timestamp"]},
        "egress_policy": policy.json(),
        "project_url": project_url,
        "record_url": f"{project_url}?{params}",
        "panel_editor_url": f"{project_url}/settings/custom-panels/chart-contract/edit",
        "setup_url": f"{project_url}/settings/setup",
        "public_markdown_urls": [f"{project_url}/agent-setup.md", f"{project_url}/agent-setup.md."],
    }
    private_receipt = {**receipt, "first_login_url": f"{project_url}?{params}#" + urlencode({"token": token})}
    for path, data in ((args.output, private_receipt), (evidence_path, receipt)):
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as file:
            json.dump(data, file, indent=2)
            file.write("\n")
print(f"Created and queried real verification telemetry in {org}/{project}")
print(f"Private browser receipt: {args.output}. Do not print or publish its login URL.")
print(f"Sanitized evidence: {evidence_path}")
