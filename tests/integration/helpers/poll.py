from __future__ import annotations

from typing import Awaitable, Callable, TypeVar

import anyio

T = TypeVar("T")


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
