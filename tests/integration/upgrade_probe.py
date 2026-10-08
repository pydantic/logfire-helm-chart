from __future__ import annotations

import argparse
import json
import os
import re
import stat
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import anyio
import httpx
from helpers.otlp import trace_payload
from helpers.poll import wait_for
from helpers.tokens import create_project, create_read_token, create_write_token


@dataclass(frozen=True)
class Seed:
    trace_id: str
    read_token: str
    min_timestamp: str
    max_timestamp: str

    @classmethod
    def read(cls, path: Path) -> Seed:
        if stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise ValueError("The upgrade state file must have mode 0600")
        value = json.loads(path.read_text())
        if not isinstance(value, dict) or set(value) != {
            "trace_id",
            "read_token",
            "min_timestamp",
            "max_timestamp",
        }:
            raise ValueError("The upgrade state file has an invalid shape")
        if not all(isinstance(item, str) and item for item in value.values()):
            raise ValueError("The upgrade state file has invalid field values")
        if re.fullmatch(r"[0-9a-f]{32}", value["trace_id"]) is None:
            raise ValueError("The upgrade state file has an invalid trace ID")
        lower = datetime.fromisoformat(value["min_timestamp"])
        upper = datetime.fromisoformat(value["max_timestamp"])
        if lower.tzinfo is None or upper.tzinfo is None or lower >= upper:
            raise ValueError("The upgrade state file has an invalid time window")
        return cls(**value)

    def write(self, path: Path) -> None:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as state_file:
            json.dump(
                {
                    "trace_id": self.trace_id,
                    "read_token": self.read_token,
                    "min_timestamp": self.min_timestamp,
                    "max_timestamp": self.max_timestamp,
                },
                state_file,
            )


async def check(client: httpx.AsyncClient, seed: Seed) -> None:
    async def exact_trace() -> bool | None:
        try:
            response = await client.post(
                "/v2/query",
                headers={
                    "Authorization": f"Bearer {seed.read_token}",
                    "Accept": "application/json",
                },
                json={
                    "sql": f"SELECT count(*) AS count FROM records WHERE trace_id='{seed.trace_id}'",
                    "min_timestamp": seed.min_timestamp,
                    "max_timestamp": seed.max_timestamp,
                },
            )
        except httpx.TransportError:
            return None
        if response.status_code in (429, 502, 503, 504):
            return None
        response.raise_for_status()
        rows = response.json()["data"]
        if rows == [{"count": 0}]:
            return None
        if rows != [{"count": 1}]:
            raise AssertionError(
                "The seeded trace query must return exactly one record"
            )
        return True

    await wait_for(exact_trace, timeout=600.0, interval=2.0)
    print("Verified exactly one record for the seeded trace")


async def seed(client: httpx.AsyncClient, path: Path) -> None:
    meta_token = os.environ.get("META_FRONTEND_TOKEN")
    if not meta_token:
        raise ValueError("META_FRONTEND_TOKEN is required to seed upgrade data")
    project = await create_project(client, meta_token, "logfire-meta")
    write_token = await create_write_token(client, meta_token, "logfire-meta", project)
    read_token = await create_read_token(client, meta_token, "logfire-meta", project)
    payload = trace_payload("helm-it-upgrade")
    span = payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
    now = datetime.now(timezone.utc)
    record = Seed(
        trace_id=span["traceId"],
        read_token=read_token,
        min_timestamp=(now - timedelta(minutes=5)).isoformat(),
        max_timestamp=(now + timedelta(minutes=5)).isoformat(),
    )
    response = await client.post(
        "/v1/traces",
        headers={"Content-Type": "application/json", "Authorization": write_token},
        json=payload,
    )
    response.raise_for_status()
    await check(client, record)
    record.write(path)
    print("Saved the upgrade probe state with mode 0600")


async def run(action: str, path: Path) -> None:
    base_url = os.environ.get("LOGFIRE_BASE_URL", "http://localhost:8080")
    async with httpx.AsyncClient(base_url=base_url, timeout=30.0) as client:
        if action == "seed":
            await seed(client, path)
        else:
            await check(client, Seed.read(path))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Verify exact trace persistence across a Helm upgrade"
    )
    parser.add_argument("action", choices=("seed", "check"))
    parser.add_argument("state_file", type=Path)
    args = parser.parse_args()
    anyio.run(run, args.action, args.state_file)


if __name__ == "__main__":
    main()
