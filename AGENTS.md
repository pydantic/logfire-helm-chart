# Chart verification

Use [verify-logfire-chart](.cursor/skills/verify-logfire-chart/SKILL.md) to select
and run the checks that cover a chart change before claiming it works.
The skill covers isolated Kind installs, stable upgrades, public API contracts,
and browser behavior against the chart's pinned platform images.

Use focused local checks and CI evidence for the exact PR revision. The full
Kind install/upgrade suite normally runs in CI. Repeat it locally when requested,
when a deployment failure needs investigation, or when a new deployment recipe
needs proof. Do not start a cluster for documentation checks.

For release, image, ingest, query, or MCP changes, verify a uniquely ingested span
through the installed Logfire MCP `query_run` tool. A constant SQL result or Ready
pod does not prove that stored telemetry is available through MCP. The canonical
CI suite supplies this proof when it passes for the exact PR revision.

Read its [feature map](.cursor/skills/verify-logfire-chart/features/README.md).
Record the source and image identity, observable results, and checks that did
not run. Keep credentials and local values out of Git. Preserve proof artifacts
after cleanup.

Follow the [chart test policy](charts/logfire/tests/README.md). Prefer the real
deployment and integration suite for behavior they can show.
