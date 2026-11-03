from __future__ import annotations

from typing import Any

import httpx

from helpers.poll import wait_for


async def wait_for_email(
    client: httpx.AsyncClient,
    *,
    recipient: str,
    subject_contains: str,
    timeout: float = 60.0,
    interval: float = 2.0,
) -> dict[str, Any]:
    """Poll the MailDev REST API until an email matching the filters arrives.

    MailDev (dev.deployMaildev) catches everything the task runner sends over
    SMTP, and its REST API on :1080 exposes the inbox. This is the only way to
    assert the task runner -> SMTP path end to end without a real mailbox.
    """
    async def _poll() -> dict[str, Any] | None:
        response = await client.get("/api/email")
        response.raise_for_status()
        for email in response.json():
            to = {t.get("address", "").lower() for t in email.get("to", [])}
            if recipient.lower() in to and subject_contains in email.get("subject", ""):
                return email
        return None

    try:
        return await wait_for(_poll, timeout=timeout, interval=interval)
    except TimeoutError:
        # Dump the inbox so a delivery failure is diagnosable from CI logs.
        inbox = (await client.get("/api/email")).json()
        subjects = [(e.get("subject"), [t.get("address") for t in e.get("to", [])]) for e in inbox]
        raise AssertionError(
            f"no email for {recipient!r} with subject containing {subject_contains!r} "
            f"within {timeout}s; MailDev inbox: {subjects}"
        ) from None
