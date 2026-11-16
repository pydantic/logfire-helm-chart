from __future__ import annotations

import warnings
from typing import Awaitable, Callable, TypeVar

import anyio
import httpx

T = TypeVar("T")

# A rollout can answer these for a moment. A poll retries them, and `wait_for` still fails at its
# timeout if they do not stop.
TRANSIENT_STATUSES = frozenset({429, 502, 503, 504})


def is_transient(response: httpx.Response) -> bool:
    """Whether a poll should retry this response. A warning shows which layer sent it."""
    if response.status_code not in TRANSIENT_STATUSES:
        return False
    warnings.warn(
        f"{response.request.method} {response.url.path} answered {response.status_code} "
        f"(server={response.headers.get('server')}, "
        f"x-ff-shutting-down={response.headers.get('x-ff-shutting-down')}): {response.text[:200]}"
    )
    return True


async def wait_for(
    predicate: Callable[[], Awaitable[T | None]],
    *,
    timeout: float = 60.0,
    interval: float = 2.0,
) -> T:
    with anyio.fail_after(timeout):
        while True:
            result = await predicate()
            if result:
                return result
            await anyio.sleep(interval)
