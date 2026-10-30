# Agent Sandboxes

Agent Sandboxes connects Logfire projects, execution keys and the workbench to
isolated Monty workers. It is disabled by default. The standalone Monty chart is
not a substitute for this integration.

## Prerequisites

- Install the upstream [Agent Sandbox operator and extensions](https://agent-sandbox.sigs.k8s.io/docs/getting_started/install_prerequisites/).
  The controller uses the `v1beta1` APIs for `Sandbox`, `SandboxClaim`,
  `SandboxTemplate` and `SandboxWarmPool`.
- Install an isolated runtime, such as gVisor or Kata, and its `RuntimeClass`.
  Configure node selectors and tolerations for that runtime. The chart does not
  install a runtime or require GKE.
- Use a CNI that enforces Kubernetes NetworkPolicy. Workers can receive relay
  connections and export telemetry to the controller. They cannot reach the
  database, Redis or snapshot storage.
- Enable the chart's in-cluster TLS configuration. Supply certificates through
  cert-manager or existing Secrets. Existing certificate sets must also cover
  `monty-controller`, `monty-reconciler` and `monty-admission`.
- Select a compatible image revision that contains the dedicated Monty control
  image and database-backed receipt collection. Make the Python, frontend,
  relay and worker images available in `image.repository`. The chart's implicit
  older image revision is insufficient. The sandbox image selection leaves
  FusionFire and its migrations on their chart-selected revision.
- Supply working Postgres, Redis and object storage through the chart's existing
  settings. The broker uses the object-store provider environment and credential
  mounts. Only the broker receives these storage credentials. Cloud identity can
  use `agentSandboxes.broker.serviceAccountAnnotations`.

## Configuration

```yaml
agentSandboxes:
  enabled: true
  imageTag: "<compatible-platform-revision>"
  allowedOrganizations:
    - "<organization-uuid>"
  workers:
    runtimeClassName: gvisor
    warmReplicas: 1
    ceiling: 8
```

Use organization UUIDs, not organization names. Create the organization first.
Project administrators then enable Agent Sandboxes and create execution keys
through the normal product UI. The configured allowlist does not bypass project
permissions, quotas or execution stops.

The default worker namespace is `<release namespace>-sandboxes`. The operator
must watch that namespace. A custom cluster suffix uses `clusterDomain` on the
chart and the operator's matching cluster-domain option. Node-local DNS needs an
additional egress rule for its DNS address. Create registry pull Secrets with the
configured names in both the Logfire and worker namespaces.

The public SDK endpoint is `<Logfire URL>/monty-ws/`. The existing chart ingress
and HAProxy route this endpoint to the relay. The browser workbench uses the
backend's authenticated WebSocket endpoint. The outer ingress must support
WebSocket upgrades and connection timeouts appropriate for interactive sessions.

The chart creates separate internal credentials for management, assignment,
state, snapshots, volume cleanup and telemetry. It retains generated credentials
across upgrades. For external credential management, set
`agentSandboxes.existingSecret`. Supply all documented keys in that Secret and
create `<existingSecret>-telemetry` in the worker namespace. Its `token` key must
match the main Secret's `telemetry` key. Rotate the two telemetry copies together.
The worker receives no service-account token or control credential.

## Persistence and usage

Snapshots use `<objectStore.uri>/monty-snapshots` unless `snapshotUri` overrides
that prefix. A different store must accept the same provider credentials and
credential mounts. Test its write, read, delete and restart behavior before use.
The snapshot catalogue, profile metadata and metering ledger use Logfire's
Postgres database. Existing migration Jobs install their schema. Back up both the
catalogue database and the object bytes. Neither alone can restore saved state.

The chart enables receipt collection by default when sandboxes are enabled.
The relay commits receipts through admission to Postgres. The existing worker
runs contribution compaction, receipt reconciliation, retention and storage-time
refresh jobs. Read `logfire.monty_metering_usage` for combined compacted and pending
execution quantities. Snapshot byte and object limits apply to each project. Receipt
collection requires no StatefulSet or receipt volume. Receipt pruning does not
delete snapshot objects. Permanent project retirement needs catalogue-aware
object cleanup. A bucket lifecycle rule alone cannot reconcile catalogue charges.
CPU usage and storage time are separate from invocation counts. Confirm all three against real execution.

The product's activity pages also need worker spans to reach the project's intake.
An assigned worker or a nonzero metering ledger does not prove that telemetry is
queryable. The internal SaaS operator console is not installed by this chart.

File volumes are a separate opt-in through `volumesEnabled`. They require profiles
and the broker's volume catalogue. Keep them off until the selected storage
provider and image revision pass the file-volume journey.

## Upgrades and removal

Take a database and object-store backup before an image upgrade. Keep admission,
controller, relay and worker private protocols compatible throughout the rollout.
A chart rollback does not roll back database migrations.

The warm pool uses `Recreate` by default. It replaces unclaimed spares after a
worker template change. It does not migrate or terminate claimed sessions.
Drain active workers through the execution controls before retiring their images.
Do not lower worker capacity below active demand during that drain.

Stop new execution and drain active sessions before disabling or uninstalling
Agent Sandboxes. The chart retains the worker namespace and generated control
Secret. Inspect remaining claims and saved data before removing them explicitly.
Uninstall does not delete the external object store or Postgres data.

## Verification

Require a real chart install with the selected images and upstream operator.
Exercise project activation, SDK execution, the browser workbench, cross-project
snapshot refusal, catalogue usage and receipt collection. Restore the same saved
snapshot after process restart, chart upgrade and rollback. Verify project spans
through Logfire's query API. Keep runtime E2E tests in the private Platform
repository. A rendering test or standalone Monty test cannot establish this path.

A Kind test with the standard runtime verifies application behavior only. It does
not qualify kernel isolation, NetworkPolicy enforcement, a cloud storage provider,
capacity or disaster-recovery targets.
