# Upgrade prerequisites

Read the release's upgrade notes before changing the chart or image version.
Complete database prerequisites against the CRUD database, not the Fusionfire
or Dex database. Keep image tags aligned with the chart's supported release.

## Unreleased: independently scheduled SLO history

The upcoming independent SLO history scheduler changes the lock order used by
history writers. Existing installations must disable and drain optional history
before replacing worker images, then enable it only after all old writers have
stopped. A normal rolling image update with history enabled is not sufficient.
The release notes must identify the first affected application version before
shipping it. These steps are separate from the alert-history index prerequisite
below; follow both when the destination release requires both.

### Existing installations

1. Keep the currently installed application version and add this override to
   your existing values file. Preserve any other entries in the worker's `env`
   list, and keep live SLO evaluation enabled:

   ```yaml
   logfire-worker:
     env:
       - name: SLO_HISTORY_BACKFILL_ENABLED
         value: "false"
   ```

2. Apply the values change using your normal controlled rollout, without
   changing application images yet. The setting is read at process startup,
   not dynamically. Verify every worker has restarted with optional history
   disabled, all previous worker processes have stopped, and their in-flight
   history queries and database transactions have drained. Check any additional
   worker deployments or manually operated workers, not only the Helm-managed
   Deployment. Do not use `SLOS_ENABLED=false`: live SLO evaluation should
   continue during this procedure.
3. Upgrade to the new release while retaining the explicit history override.
   Allow the normal backend migration job to finish before new workers start.
   It creates the additive `logfire.slo_history_backfill_state` table; new
   workers require the table even with optional history disabled. Leave
   `CRUD_MIGRATIONS_RESPECT_AUTO_RUN_FLAG` enabled. No manual migration or
   modification of bucket rows is needed for this scheduler change.
4. Verify all workers now use the corrected release and no old writers remain.
   Confirm live SLO results still refresh. Set the history override to `"true"`
   and roll out that configuration. Existing objectives may wait for their next
   successful live evaluation before history becomes eligible; do not edit
   stored status timestamps to accelerate it.
5. Check history progress and failures, live evaluation freshness, database
   contention, and interactive query availability. If these regress, disable
   optional history through another controlled rollout and investigate. Record
   the installed versions and the fleet/drain verification in the upgrade
   change record.

### Fresh installations and rollback

A fresh installation has no old writer fleet. Let automatic schema bootstrap
complete before starting workers, then use the normal history default.

Before rolling back to an older worker implementation, disable optional history
on the new fleet, replace its processes with that setting, and verify its
in-flight history work has drained. Only then introduce old workers. Keep the
additive state table and migration bookkeeping; do not delete history buckets
or hand-edit admission timestamps. After the rollback fleet is consistent,
restore the history configuration supported by that release.

## Unreleased: SLO alert-history completion index

This prerequisite applies to the upcoming completion-ordered SLO alert-history
reader. No released chart version is identified yet. The release owner must
identify the first affected chart and application version in its upgrade notes
and link this procedure before shipping that reader.

### When to build

For an existing database, build and verify the index below **before upgrading**
to the affected reader. The index is additive and works with the old reader.
Do not treat a successful Helm upgrade as evidence that this prerequisite ran.

For a fresh database, install normally so the automatic migrations create
`logfire.alert_runs`, then build and verify the index immediately after schema
bootstrap, before configuring SLOs or admitting customer traffic. There is no
existing SLO history to migrate. Do not try to create the index before its table
exists or add a pre-install check that would prevent schema bootstrap.

The chart's backend migration job skips migrations marked for manual execution
and has a 300-second deadline. This index's migration,
`add_slo_alert_history_completion_index`, is manual because a concurrent index
build over existing alert history can exceed that deadline. Do not disable
`CRUD_MIGRATIONS_RESPECT_AUTO_RUN_FLAG` or run all outstanding manual migrations
to install this one index.

### Prepare a direct database session

Arrange the build with your database operator. Confirm sufficient database disk
and I/O capacity, allow for two scans of the alert-history table, and monitor
the build and application latency. Concurrent builds permit ordinary writes
but can wait for long-lived transactions, including read-only transactions.

Use a dedicated `psql` session to the primary CRUD PostgreSQL database with
table-owner permissions. Use a direct PostgreSQL endpoint, not a
transaction-pooled endpoint. A repeated backend PID does not prove that a
connection is session-affine. Make sure any connection proxy and administrative
job allow the build to finish.

Do not use `BEGIN`, `psql --single-transaction`, or another transaction wrapper:
`CREATE INDEX CONCURRENTLY` and `DROP INDEX CONCURRENTLY` cannot run inside one.
Enable `ON_ERROR_STOP` in `psql`. Use this session only for the build and close it
afterwards, including on error, so the temporary timeout overrides cannot leak
into other work.

In that direct session, set the build's timeout policy:

```sql
\set ON_ERROR_STOP on
SET lock_timeout = '45min';
SET statement_timeout = 0;
SELECT 'SET transaction_timeout = 0'
WHERE current_setting('transaction_timeout', true) IS NOT NULL
\gexec
```

The last statement disables PostgreSQL 17's [transaction timeout](https://www.postgresql.org/docs/17/runtime-config-client.html#GUC-TRANSACTION-TIMEOUT) when available
and does nothing on versions without that setting. The 45-minute lock timeout
bounds individual lock waits, not the total build duration. Review that bound
against your longest transactions. A timeout or disconnect can leave an invalid
index that must be repaired before retrying.

### Inspect, build, and verify

Inspect the exact index name before changing anything:

```sql
SELECT i.indisvalid, i.indisready, pg_get_indexdef(i.indexrelid) AS definition
FROM pg_catalog.pg_index AS i
WHERE i.indexrelid = to_regclass(
    'logfire.alert_runs_alert_id_observed_at_window_max_idx'
);
```

If there is no row, create the index:

```sql
CREATE INDEX CONCURRENTLY alert_runs_alert_id_observed_at_window_max_idx
ON logfire.alert_runs
(alert_id, COALESCE(run_finished_at, window_max) DESC, window_max DESC);
```

If the inspection returns a valid, ready index with this definition, do not
rebuild it. If the definition differs, stop and resolve the name collision with
your database operator. Do not remove an unrelated index.

If an earlier interrupted attempt left the expected index invalid, first confirm
that no build of this index is still running. Then drop only that invalid index
in the same direct, timeout-configured session and retry the create statement:

```sql
DROP INDEX CONCURRENTLY logfire.alert_runs_alert_id_observed_at_window_max_idx;
```

Do not use `CREATE INDEX IF NOT EXISTS` as a repair: it leaves an invalid index
in place. See PostgreSQL's [concurrent index build guidance](https://www.postgresql.org/docs/17/sql-createindex.html#SQL-CREATEINDEX-CONCURRENTLY).
After the build completes, rerun the inspection. Require exactly one
row with `indisvalid = true`, `indisready = true`, and the expected definition
before proceeding. Record that verification in the upgrade change record, then
close the build session.

### Complete the upgrade

For an existing installation, upgrade the reader only after the verified build.
For a fresh installation, finish the build before configuring SLOs or opening
customer traffic. Check that SLO alert history loads after rollout.

When the application version containing the named migration is available,
arrange for it to be recorded through the supported administrative migration
workflow. Its already-valid-index path does not rebuild the index or change
session timeouts. The chart does not deploy the administrative service; contact
your Pydantic support representative for that step and for any earlier pending
manual migrations. Do not insert migration-history records by hand.

If the reader must be rolled back, keep this additive index. The older reader
can continue using the database, and keeping the index avoids another build on
the next upgrade.
