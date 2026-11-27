"""A redirect that the backend builds from the Host it received must not name the in-cluster service."""

from __future__ import annotations

import httpx
import pytest

pytestmark = pytest.mark.anyio


async def test_redirect_stays_on_the_requested_host(client: httpx.AsyncClient) -> None:
    path = "/ui-api/platform-config"
    response = await client.get(path, follow_redirects=False)
    assert response.status_code in (301, 302, 307, 308), f"{path} no longer redirects; pick a route that does"
    assert response.headers["location"] == path + "/", response.headers["location"]
