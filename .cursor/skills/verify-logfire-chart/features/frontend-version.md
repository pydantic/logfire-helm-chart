# Frontend version

A user receives the frontend's build identity and can reload an existing tab
after a frontend release.

## Sub-features

- `bundle-metadata` agrees across the document, version JSON, and bundle text.
- `manual-reload` loads the new frontend and retains authentication after a rollout.
- `update-notification` polls the new version and offers the normal reload action.

## How to get to it (user POV)

- Open an authenticated project page.
- Keep that tab open while the frontend image changes.
- Use the update notification's `Reload` action, or reload the page manually.

## Driving it with the browser and HTTP

Preconditions:

- Launch and Doctor pass. A browser tab is authenticated through normal login.
- For a release transition, both old and new frontend images must be compatible
  with the same backend API epoch. Do not select arbitrary image tags.

For `bundle-metadata`, use the browser tool's read-only DOM inspection to read
`meta[name="frontend-bundle-id"]`. Request `/version.json?poll=1` and `/bundle-id.txt`.
Require all three bundle IDs to match. Require a non-local build commit, a positive
build timestamp, and `Cache-Control: no-store` for the JSON response. Save responses
and the document identity with the screenshot of the authenticated page.

For an actual image release, record the exact compatible old/new image tags and
bundle IDs. Open the old authenticated tab with `auto-app-update=0`, then upgrade
only the frontend through Helm. Preserve the old tab and its loaded route. Open a
new tab on the same origin; confirm its document and version response contain the
new bundle ID. Foreground the old tab after at least 15 minutes from its last poll.
Observe the real version request before asserting notification behavior.

On an image that contains the update-poller fix, require the old tab's version
response to contain the new ID. Require `Update available`,
`Reload to use the latest version.`, and the `Reload` action. Click `Reload`, then
confirm the new document ID and normal authenticated project page. Also verify a
manual reload for `manual-reload`; report the two paths independently.

## Gotchas

- The current `92fe3870` pin has a known automatic update-poller defect. Its version
  metadata works, but the poll and update toast do not. Report `update-notification`
  as a known failure for that image. The fix belongs to the next self-hosted image
  release; do not bump the pin or weaken the assertion as part of this skill.
- The poll interval is 15 minutes. Visibility or router changes do not force a poll
  immediately after a recent successful request.
- Navigating an old tab after rollout can trigger a stale-chunk notification.
  That does not prove version polling.
- A current endpoint response cannot prove an old tab sent a request. Capture the
  tab's actual network event. Browser timer simulation does not prove a release rollout.
