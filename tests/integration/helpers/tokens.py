from __future__ import annotations

import secrets
import time

import httpx


async def create_project(client: httpx.AsyncClient, meta_token: str, org: str) -> str:
    name = f"helm-it-{int(time.time())}-{secrets.token_hex(3)}"
    response = await client.post(
        f"/ui-api/organizations/{org}/projects/",
        headers={"Authorization": f"Bearer {meta_token}"},
        json={"project_name": name, "visibility": "public"},
    )
    response.raise_for_status()
    return response.json()["project_name"]


async def _mint_token(
    client: httpx.AsyncClient,
    meta_token: str,
    org: str,
    project: str,
    kind: str,
) -> str:
    response = await client.post(
        f"/ui-api/organizations/{org}/projects/{project}/{kind}-tokens/",
        headers={"Authorization": f"Bearer {meta_token}"},
        json={"description": f"helm integration {kind} token"},
    )
    response.raise_for_status()
    return response.json()


async def create_write_token(
    client: httpx.AsyncClient, meta_token: str, org: str, project: str
) -> str:
    return await _mint_token(client, meta_token, org, project, "write")


async def create_read_token(
    client: httpx.AsyncClient, meta_token: str, org: str, project: str
) -> str:
    return await _mint_token(client, meta_token, org, project, "read")
