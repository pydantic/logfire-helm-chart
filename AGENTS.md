# Chart verification

Use [verify-logfire-chart](.cursor/skills/verify-logfire-chart/SKILL.md) to select
and run the checks that cover a chart change before claiming it works.
The skill covers isolated Kind installs, stable upgrades, public API contracts,
and browser behavior against the chart's pinned platform images.

Read its [feature map](.cursor/skills/verify-logfire-chart/features/README.md).
Record the source and image identity, observable results, and checks that did
not run. Keep credentials and local values out of Git. Preserve proof artifacts
after cleanup.

Follow the [chart test policy](charts/logfire/tests/README.md). Prefer the real
deployment and integration suite for behavior they can show.
