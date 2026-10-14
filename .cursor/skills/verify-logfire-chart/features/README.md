# Logfire chart verification map

This map covers the deployed chart's main verification paths. Select every entry
affected by the change. A successful check of one route does not verify a different
entry point listed here.

## Preconditions

- For local runtime checks, use the isolated cluster, kubeconfig, and private
  runtime from [the skill](../SKILL.md). Documentation checks need no cluster.
- Run Doctor before driving an installed feature. Use the chart's pinned images.
- Use the optional lighter local values overlay. Keep two query API replicas for the
  canonical suite's installed-replica check.
- Use CI on the exact PR revision for the canonical suite by default. A full
  local run needs a fresh database. Focused HTTP checks can use this run's current
  installation after Doctor passes.
- Browser checks need the configured loopback API origin and the real seeded fixture.
  Read its private login URL locally. Publish only the sanitized fixture receipt.

## Features and selection

| Recipe | Use when the change affects |
| --- | --- |
| [Deployment and upgrade](deployment.md) | Images, startup settings, migrations, processes, replicas, storage, or query topology |
| [Public API contracts](api-contracts.md) | Routing, authentication, MCP, ingest, query, mail, or protocol responses |
| [Login and setup](setup.md) | Self-hosted login, project setup, or Markdown handoff routes |
| [Renderers](renderers.md) | Frontend CSP, Trusted Types, worker assets, enhanced views, or custom panels |
| [Frontend version](frontend-version.md) | Build metadata, frontend image releases, or update notification behavior |

For a release or image-pin change, inspect the canonical CI result and run the
browser recipes for affected UI behavior. Repeat the full suite locally only
when requested, when a deployment uncertainty needs investigation, or when a new
deployment recipe needs proof. Record each selected sub-feature as passed,
failed, or not run with a reason.
For ingest, query, or MCP changes, also require the stored-telemetry MCP case in
[Public API contracts](api-contracts.md). It must query the unique ingested span
through the deployed MCP tool. Its passing result from CI on the exact PR
revision is sufficient. A constant query is insufficient proof.

For authentication, ingress, Gateway, or TLS changes, select the affected path in
[Public API contracts](api-contracts.md). Its HTTP service checks do not prove
SSO, an ingress controller, or certificate verification.

## Proof

Capture the action and resulting state. Browser proof includes an inspected
screenshot and accessibility snapshot. CLI proof includes the command, result,
and exit code. Mutation proof includes a second read of the persisted result.
The browser seeder proves its exact record through the real query endpoint.

Store artifacts in `$VERIFY_RUNTIME/evidence`. Record source and image identity,
selected feature IDs, values hashes, and any missing capability. Preserve proof
after teardown. Do not call an HTTP response proof of browser rendering or an
intentional security refusal proof of unrelated security boundaries.
