# Chart verification

Use [verify-logfire-chart](.cursor/skills/verify-logfire-chart/SKILL.md) to select
and run checks before claiming a chart change works. The skill defines CI reuse,
local Kind and browser recipes, real telemetry proof through MCP, and cleanup.

Follow the [chart test policy](charts/logfire/tests/README.md).

# Chart README and public docs

The chart README and the public self-hosted docs (`docs/reference/self-hosted/` in
`pydantic/logfire`) do not state the same fact twice.

- The chart README owns every fact that a chart or platform release can change:
  minimum versions, extensions, permissions, value names and shapes, ports, and
  provider settings. Edit `charts/logfire/README.md.gotmpl`, not the generated README.
  Each chart tag carries the README of its own release.
- The public docs own planning, architecture, and procedures that stay true across
  versions, such as bucket and database migrations and SSO examples. They link to a
  README section for a requirement. They do not restate it.

If a chart change adds or changes a requirement that the public docs restate, replace
that text with a link to the README section in a `pydantic/logfire` PR.
