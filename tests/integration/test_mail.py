"""Task runner -> SMTP -> MailDev round trip.

Covers the cross-component mail wiring end to end: an HTTP action enqueues an
Absurd task, the task runner drains it and sends via SMTP, and MailDev (the dev
inbox, dev.deployMaildev) catches the message. Its REST API on :1080 is the
assertion surface; CI port-forwards svc/logfire-maildev.
"""

from __future__ import annotations

import secrets

import httpx
import pytest

from helpers.maildev import wait_for_email

pytestmark = pytest.mark.anyio

ORG = "logfire-meta"


async def test_org_invitation_email_reaches_maildev(
    client: httpx.AsyncClient,
    maildev_client: httpx.AsyncClient,
    meta_frontend_token: str,
) -> None:
    headers = {"Authorization": f"Bearer {meta_frontend_token}"}
    roles = await client.get(f"/ui-api/organizations/{ORG}/roles/", headers=headers)
    assert roles.is_success, roles.text
    role_list = roles.json()
    assert role_list, roles.text
    role_id = next(
        (r["id"] for r in role_list if r.get("name") in ("admin", "member")),
        role_list[0]["id"],
    )

    invitee = f"helm-it-invite-{secrets.token_hex(4)}@example.com"
    created = await client.post(
        f"/ui-api/organizations/{ORG}/invitations/email/",
        headers=headers,
        json={"email": invitee, "role_id": role_id},
    )
    assert created.status_code == 201, created.text
    assert created.json()["invitee_email"] == invitee

    email = await wait_for_email(
        maildev_client, recipient=invitee, subject_contains="Join"
    )
    assert invitee in str(email.get("to")), email


async def test_email_login_code_reaches_maildev(
    client: httpx.AsyncClient,
    maildev_client: httpx.AsyncClient,
) -> None:
    recipient = f"helm-it-code-{secrets.token_hex(4)}@example.com"
    requested = await client.post(
        "/ui-api/auth/email/code/", json={"email": recipient}
    )
    assert requested.status_code == 200, requested.text
    assert requested.json()["retry_after_seconds"], requested.text

    email = await wait_for_email(
        maildev_client, recipient=recipient, subject_contains="verification code"
    )
    assert recipient in str(email.get("to")), email
