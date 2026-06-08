from __future__ import annotations

import os
from collections.abc import AsyncIterator

import httpx
import pytest

from helpers.tokens import create_project, create_read_token, create_write_token

META_ORG = "logfire-meta"


@pytest.fixture(scope="session")
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture(scope="session")
def base_url() -> str:
    return os.environ.get("LOGFIRE_BASE_URL", "http://localhost:8080")


@pytest.fixture(scope="session")
def meta_frontend_token() -> str:
    token = os.environ.get("META_FRONTEND_TOKEN")
    if not token:
        pytest.fail("META_FRONTEND_TOKEN env var is required")
    return token


@pytest.fixture
async def client(base_url: str) -> AsyncIterator[httpx.AsyncClient]:
    async with httpx.AsyncClient(base_url=base_url, timeout=30.0) as http:
        yield http


@pytest.fixture
async def project(client: httpx.AsyncClient, meta_frontend_token: str) -> str:
    return await create_project(client, meta_frontend_token, META_ORG)


@pytest.fixture
async def write_token(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> str:
    return await create_write_token(client, meta_frontend_token, META_ORG, project)


@pytest.fixture
async def read_token(
    client: httpx.AsyncClient, meta_frontend_token: str, project: str
) -> str:
    return await create_read_token(client, meta_frontend_token, META_ORG, project)
