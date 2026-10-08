# Chart integration tests

These tests send real requests through the installed chart's public service. CI first
uses chart-testing for install and upgrade checks, then runs `ci/run-kind-tests.sh` in
its prepared `logfire-restricted` namespace.

The runner installs published chart 0.14.0, ingests a unique trace and confirms its exact
record, upgrades to the current chart, and queries that same trace again. It then runs
the full suite in the default combined query topology, enables the optional query
worker, repeats query and SQL-format checks, and restores combined mode. It leaves the
current chart installed and removes its port-forwards and temporary token state.

Use a fresh prepared local Kind namespace with the CI development services and Secrets.
Each stable-upgrade run starts from 0.14.0 database state; reuse a namespace only for
HTTP-only test runs against its current installation.

```sh
# Use a kubeconfig for your Kind cluster, and build chart dependencies first.
helm dependency build charts/logfire
LOGFIRE_TEST_NAMESPACE=logfire-restricted ci/run-kind-tests.sh
```

The runner refuses other cluster contexts. It expects the `logfire-tokens` Secret and
the database, admin, and gateway Secrets used by `charts/logfire/ci/ci-values.yaml`.
Set `LOGFIRE_TEST_VALUES` to an additional values file for image pull credentials or
local resource sizing. Set `LOGFIRE_TEST_BASELINE_CHART` to an already downloaded
0.14.0 `.tgz` to avoid fetching the baseline package again.
Keep `logfire-ff-query-api.replicas=2` in local overrides so the installed replica-count
check exercises the same disabled-autoscaler configuration as CI.

To run HTTP tests against an existing installation, set `LOGFIRE_BASE_URL`,
`META_FRONTEND_TOKEN`, and `MAILDEV_BASE_URL`, then run:

```sh
uv run --directory tests/integration pytest -v
```

`LOGFIRE_PUBLIC_HOST` and `LOGFIRE_PUBLIC_URL` must match a customized public hostname
and URL when exercising MCP and problem responses.

The release checks cover:

| Contract | Evidence |
| --- | --- |
| Stable upgrade | An exact trace remains queryable after migrations and rollouts |
| Replica ownership | Both requested query API replicas become ready with HPA and KEDA disabled |
| SQL format | Dialect-specific output and invalid syntax on combined and split query modes |
| Remote MCP | Authentication, initialization, tool discovery, and a literal query result |
| OTLP errors | Invalid-token errors decode as JSON and protobuf for all three signals |
| Query errors | v1/v2 legacy and problem-response negotiation, including the public error URL |
| Variable SSE | An immediate first frame reaches the client through the service |
| Metric storage | An ingested counter is queried through its value struct |

Kind uses RustFS for the existing telemetry object store. The suite does not test live
cloud IAM. Scheduled-query storage remains a follow-up while Reports is experimental.
The metric fixture uses a numeric JSON int: the pinned platform decoder drops string-valued
`asInt` points, including canonical OTLP JSON int64 strings. That compatibility defect
also exists in 0.14.0 and needs an upstream fix.
