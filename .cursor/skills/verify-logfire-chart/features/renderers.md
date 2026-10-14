# Renderers

Users inspect enhanced JSON, edit its JSX, and display custom panels in record
details. The chart must permit these flows while enforcing their security boundaries.

## Sub-features

- `enhanced-render` renders the saved tool-schema view and toggles to raw JSON.
- `enhanced-editor` compiles and previews JSX through the real editor worker.
- `enhanced-fetch-guard` rejects fetch inside the enhanced view renderer.
- `panel-render` displays the exact record message inside the real custom panel.
- `panel-boundaries` refuses nested frames and extra Trusted Types policies.
- `panel-editor-restore` saves the positive panel and renders it again.

## How to get to it (user POV)

- Open the seeded record's `Model Run` tab, then expand `Model details` >
  `browser_contract_tool` > `Parameters schema`.
- In the legacy conversation view, expand `Tools available` instead of `Model details`.
- Use `Show raw JSON`, `Show enhanced view`, and `Edit custom panel` in that view.
- Open the record's `Details` tab for the custom panel.
- Open project `Settings` > `Custom panels`, then edit `chart-contract`.

## Driving it with the browser and editor fixtures

Preconditions:

- Launch and Doctor pass. The real browser fixture is seeded and authenticated.
- Open the receipt's `record_url` and match the exact trace/span and message.
- Start console/network capture before the actions. Keep intended negative errors
  separate from ordinary application failures.

Select `Model Run`, expand `Model details`, then expand `browser_contract_tool`.
In the legacy conversation view, use `Tools available` to reach the same schema.
Require `Enhanced renderer active`
and `order_id, amount`. Toggle `Show raw JSON` and `Show enhanced view`; confirm
both contain the same schema. Capture the actual `/assets/safe-render-<hash>.js`
worker request. Its header must have `script-src blob:`, `connect-src 'none'`, and
`worker-src 'none'`. The existing HTTP contract tests also verify this asset header.

Click `Edit custom panel`, then `JSX Source`. Use the editor's supported text-input
actions to paste `fixtures/enhanced-guard-negative.jsx`. Select `Preview`. Require
`fetch is unavailable in the enhanced view renderer` and no successful probe
request. Cancel the edit so the original saved view remains usable. Capture the
error and restored golden view. Do not replace the editor by a direct API save.

Select `Details`. Require `Custom panel active` and the exact record message in the
custom-panel iframe. Observe its `/custom-components-iframe.html#channel=...`
request and completed render. Open `panel_editor_url`, enter
`fixtures/custom-panel-negative.tsx` through the code editor, and preview or save it.
Click `Run boundary checks` inside the panel. Require all three visible PASS results:

- Direct frame creation is refused.
- An extra Trusted Types policy is refused.
- Detached HTML produces `BLOCKED-IFRAME`.

Require the intended Trusted Types violation for `chart-contract-probe`. The frame
header must contain `require-trusted-types-for 'script'`, `trusted-types default`,
`frame-src 'none'`, and `object-src 'none'`. Record the fixture receipt's actual
organization egress policy. The runtime policy can narrow the response policy.

Restore `fixtures/custom-panel-positive.tsx` through the same editor and save it.
Return to the record and confirm the positive panel and exact message render again.
Capture screenshots of the golden view, negative result, and restored panel.

## Gotchas

- The seeder includes recognized input/output chat messages as well as tool
  definitions. Definitions alone do not expose the pinned image's `Model Run` tab.
- The schema fingerprint belongs to the literal fixture. Revalidate it when the
  fixture or the pinned image's fingerprint normalizer changes. A missing enhanced
  view is a failed fixture prerequisite, not a passing renderer check.
- AI-disabled organizations still render existing saved views and their editor.
  This recipe does not call a model or need a provider credential.
- The worker fetch guard and worker response header are separate proofs. Claim
  native worker CSP enforcement only if the browser tool captures that actual refusal.
- The negative panel uses detached DOM and sends no record to a remote host.
  Do not weaken CSP or organization egress settings to make a negative case pass.
