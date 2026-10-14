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

The runner installs published chart `0.14.0`, ingests a unique trace, upgrades to
the current chart, and queries the exact record again. It runs the full integration
suite, enables split query mode, repeats query and SQL-format cases, and restores
combined mode. Require the final `Kind upgrade and integration tests passed` line
and exit code `0`. Confirm the record checks and selected tests ran in the log.

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
