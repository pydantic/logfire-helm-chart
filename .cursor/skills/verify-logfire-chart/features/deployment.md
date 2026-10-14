# Deployment and upgrade

An operator installs the chart, upgrades it without losing queryable telemetry,
and chooses combined or split query processing.

## Sub-features

- `install-current` starts the current chart and completes its migration Jobs.
- `stable-upgrade` preserves an exact trace across the published baseline upgrade.
- `query-replicas` starts two query API replicas with both autoscalers disabled.
- `split-query` preserves query behavior with the optional query worker enabled.
- `combined-restore` returns to combined mode with the same trace still queryable.

## How to get to it (user POV)

- Install or upgrade the chart with Helm.
- Set `logfire-ff-query-worker.enabled` to select split query processing.
- Use the public ingest and query endpoints to observe data after each rollout.

## Driving it with Helm and the Kind runner

### Use the CI result by default

`.github/workflows/pr.yaml` runs Helm unit tests, chart lint, configuration rendering,
and `ct install --upgrade`. It then runs `ci/run-kind-tests.sh` in a fresh Kind
cluster with bundled Postgres, Redis, RustFS, and Maildev.

The runner installs published chart `0.14.0`, ingests a unique trace, upgrades to
the current chart, and queries that exact record again. It runs all integration
cases in combined mode, repeats query, SQL-format, and MCP telemetry cases in
split mode, then restores combined mode and repeats the record and MCP checks.
It checks migration/rollout completion and two ready query API replicas.

Use a completed successful run for the exact PR revision. Record the PR revision,
CI run URL, test names/results, installed chart/image pins, and relevant log lines.
Require both `Run chart testing` and `Test stable upgrade, release contracts, and
split query topology` to complete successfully. The final runner line must say
`Kind upgrade and integration tests passed`. An older run or a local uncommitted
runtime change cannot supply proof for the current source.

The suite proves these contracts with the bundled dependencies and its selected
topologies. It does not prove managed dependency credentials, cloud IAM, an
ingress controller, TLS handshakes, SSO login, browser behavior, or capacity.
The [API recipe](api-contracts.md) describes the auth and transport boundaries.

### Repeat the canonical suite locally when needed

Use this path when requested, when a startup or upgrade uncertainty needs
investigation, or when a new deployment recipe needs runtime proof. Focused local
checks do not require a second full run when CI already proves the same contract.

Preconditions:

- Complete Launch through cluster preparation and dependency installation.
- Use a fresh cluster with the CI Secrets and no installed `lf` release.
- Keep the original CI public hostname during this suite. Configure the browser
  origin only after the suite completes.

Run the existing runner without overriding its cases:

```bash
unset LOGFIRE_BASE_URL MAILDEV_BASE_URL META_FRONTEND_TOKEN LOGFIRE_PUBLIC_HOST LOGFIRE_PUBLIC_URL
export LOGFIRE_TEST_NAMESPACE=logfire-restricted
export LOGFIRE_TEST_VALUES="$VERIFY_RUNTIME/values.yaml"
bash ci/run-kind-tests.sh 2>&1 | tee "$VERIFY_RUNTIME/evidence/install-upgrade.log"
runner_status=${PIPESTATUS[0]}
printf '%s\n' "$runner_status" > "$VERIFY_RUNTIME/evidence/install-upgrade.exit"
test "$runner_status" -eq 0
```

Require the same checks and final success line described above, plus exit code
`0`. Confirm the record checks and selected tests ran in the log.

For a focused fresh-install check, use the current-chart install command in Launch.
That result proves `install-current`; it does not prove `stable-upgrade` or the
query topology transitions. Run Doctor and capture the final workload/image state.

## Gotchas

- Never install the old baseline into a namespace whose database has already been
  upgraded. Create a fresh cluster for another canonical run.
- `LOGFIRE_TEST_VALUES` accepts one additional file. The preparation helper merges
  the local values and preserves the two-replica contract.
- The runner removes its port-forwards and temporary token state. It leaves the
  chart and cluster installed for Doctor and browser checks.
- A failed Helm wait is a failed check. Save pod events and Job logs before cleanup.
- Kind uses RustFS for telemetry storage. This does not verify cloud IAM, scheduled
  query storage, session replay, or production capacity.
