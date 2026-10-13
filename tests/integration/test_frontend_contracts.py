from __future__ import annotations

import re

import httpx
import pytest

pytestmark = pytest.mark.anyio


def _policy(response: httpx.Response) -> dict[str, list[str]]:
    return {
        parts[0]: parts[1:]
        for directive in response.headers["content-security-policy"].split(";")
        if (parts := directive.split())
    }


async def test_frontend_version_identifies_the_served_bundle(client: httpx.AsyncClient) -> None:
    response = await client.get("/version.json?poll=1")
    assert response.status_code == 200, response.text
    assert response.headers["content-type"].startswith("application/json")
    assert response.headers["cache-control"] == "no-store"
    version = response.json()
    bundle = await client.get("/bundle-id.txt")
    assert bundle.status_code == 200, bundle.text
    assert version["bundleId"] == bundle.text.strip()
    assert re.fullmatch(r"[a-f0-9]{64}", version["bundleId"])
    assert version["commit"] != "local"
    assert version["builtAt"] > 0


async def test_built_enhanced_view_worker_receives_its_network_restrictions(client: httpx.AsyncClient) -> None:
    manifest = await client.get("/frontend-assets.txt")
    assert manifest.status_code == 200, manifest.text
    workers = [asset for asset in manifest.text.splitlines() if re.fullmatch(r"/?assets/safe-render-[^/]+\.js", asset)]
    assert len(workers) == 1, workers
    response = await client.get(f"/{workers[0].lstrip('/')}")
    assert response.status_code == 200, response.text
    policy = _policy(response)
    assert policy["script-src"] == ["blob:"]
    assert policy["connect-src"] == ["'none'"]
    assert policy["worker-src"] == ["'none'"]


async def test_custom_panel_frame_enforces_its_nested_document_boundary(client: httpx.AsyncClient) -> None:
    response = await client.get("/custom-components-iframe.html")
    assert response.status_code == 200, response.text
    policy = _policy(response)
    assert policy["require-trusted-types-for"] == ["'script'"]
    assert policy["trusted-types"] == ["default"]
    assert policy["frame-src"] == ["'none'"]
    assert policy["object-src"] == ["'none'"]
    assert response.headers["x-dns-prefetch-control"] == "off"


@pytest.mark.parametrize("suffix", [".md", ".md."])
async def test_project_setup_handoff_returns_markdown(client: httpx.AsyncClient, suffix: str) -> None:
    response = await client.get(f"/synthetic-org/synthetic-project/agent-setup{suffix}")
    assert response.status_code == 200, response.text
    assert response.headers["content-type"].startswith("text/markdown")
    assert response.headers["cache-control"] == "no-store"
    assert "`synthetic-org/synthetic-project`" in response.text
    assert "uvx logfire-cli" in response.text
