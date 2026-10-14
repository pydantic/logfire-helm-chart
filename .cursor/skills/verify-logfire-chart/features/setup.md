# Login and setup

A self-hosted user signs in, opens the selected project, and copies its setup
instructions for a coding agent.

## Sub-features

- `self-hosted-login` accepts the configured token through the normal app entrypoint.
- `fixture-visible` opens the exact ingested record under the selected project.
- `setup-copy` copies the project-scoped wizard command or prompt through the real UI.
- `setup-markdown` returns the public Markdown document with either trailing form.

## How to get to it (user POV)

- Use the self-hosted token login URL for the disposable admin session.
- Open the seeded project from the project selector or its receipt URL.
- Open project `Settings` > `Setup`, then choose the visible `Copy wizard command`
  or `Copy setup prompt` action.
- Open the public `/<org>/<project>/agent-setup.md` document.

## Driving it with the browser and curl

Preconditions:

- Launch configured the browser origin, Doctor passes, and the seeder completed.
- Read `browser.json` privately. Use `browser-evidence.json` for record identity.
- Use a fresh browser session on this origin, or sign out through the UI first.

Open `first_login_url` with the available browser tool. Inspect a fresh accessibility
snapshot. Require the app to remove `#token`, persist the authenticated session, and
open the project. Navigate to `record_url`; require the selected trace/span and
unique message to match the sanitized receipt. Reload and confirm the same user
can still open that record. Capture the authenticated result after token removal.

Open `setup_url` and locate `Set up with your coding agent`. Record the visible
layout and copy action. Click `Copy wizard command` or `Copy setup prompt`, whichever
the page offers. Read the resulting clipboard through the browser tool's supported
clipboard capability. Require `uvx logfire-cli`, the local base URL, and the selected
organization and project. A copied prompt also contains its Markdown link.
A wizard command does not. Do not infer that copying worked because a button exists.

Set `VERIFY_PROJECT_URL` to the sanitized receipt's `project_url`, then compare
both public documents without an Authorization header:

```bash
curl --fail --silent --show-error -D "$VERIFY_RUNTIME/evidence/setup-md.headers" \
  "$VERIFY_PROJECT_URL/agent-setup.md" > "$VERIFY_RUNTIME/evidence/setup.md"
curl --fail --silent --show-error -D "$VERIFY_RUNTIME/evidence/setup-md-dot.headers" \
  "$VERIFY_PROJECT_URL/agent-setup.md." > "$VERIFY_RUNTIME/evidence/setup-dot.md"
cmp "$VERIFY_RUNTIME/evidence/setup.md" "$VERIFY_RUNTIME/evidence/setup-dot.md"
```

Require `text/markdown`, `Cache-Control: no-store`, the selected `org/project`, and
`uvx logfire-cli` in the response. Open the receipt's Markdown link in the browser
too, or the copied link when the UI offers a prompt. Rendering or downloading
Markdown is valid; record the observed outcome and response.

## Gotchas

- The token fragment is accepted only when no unexpired session already exists.
  Sign out instead of injecting browser storage.
- The `guided_setup_flow` feature flag changes the setup layout. A browser can
  retain a QA override. The backend can offer a wizard command in either layout.
  Record the actual copy action instead of inferring it from the layout.
- Some browser tools block Markdown navigation/download. Record that browser check
  as unavailable and retain the separate HTTP result. Do not report a rendered document.
- The public document does not prove that a project exists. Use the authenticated
  record and setup screen for project identity.
- This recipe proves the self-hosted token entrypoint. It does not complete Dex
  password login, an external SSO connector, or its callback through ingress.
  Select those paths separately when authentication or exposure changes.
