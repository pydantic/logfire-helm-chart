# Agent Sandboxes

Agent Sandboxes connects Logfire projects, execution keys and the workbench to
isolated Monty workers. It is disabled by default. The standalone Monty chart is
not a substitute for this integration.

## Prerequisites

- Use Kubernetes 1.25 or later with CRD CEL validation enabled.
  The upstream operator recommends Kubernetes 1.29 or later, where this validation is stable.
  On Kubernetes 1.25 through 1.28, verify that the cluster retains the operator's CEL validation rules when it installs the CRDs.
  The chart checks the Kubernetes version, but cannot verify this feature gate or the installed validation rules.
  This requirement applies only when Agent Sandboxes is enabled. The base chart supports Kubernetes 1.23 or later.
- Install the upstream [Agent Sandbox operator and extensions](https://agent-sandbox.sigs.k8s.io/docs/getting_started/install_prerequisites/).
  The controller uses the `v1beta1` APIs for `Sandbox`, `SandboxClaim`,
  `SandboxTemplate` and `SandboxWarmPool`.
- Install an isolated runtime, such as gVisor or Kata, and its `RuntimeClass`.
  Configure node selectors and tolerations for that runtime. The chart does not
  install a runtime or require GKE.
- Use a CNI that enforces Kubernetes NetworkPolicy. Workers receive relay
  connections and admission identity and termination checks.
  They export telemetry to the controller.
  They cannot reach the database, Redis or snapshot storage.
- Select the internal transport described below. The public ingress TLS setting is independent.
- The Monty images come from the same platform release as the rest of the chart,
  under `image.repository`. Use a chart release that ships Agent Sandboxes.
- Supply the canonical Postgres database and Redis through the chart's existing settings.
  Supply the independent Monty stores as described below.
  The broker uses the object-store provider environment and credential
  mounts. Only the broker receives these storage credentials. Cloud identity can
  use `agentSandboxes.broker.serviceAccountAnnotations`.

## Configuration

```yaml
agentSandboxes:
  enabled: true
  capacityOwnerId: "<installation-uuid>"
  allowedOrganizations:
    - "<organization-uuid>"
  stores:
    postgresTopology: direct
    postgresSecret:
      name: monty-stores
      runtimeKey: runtimeDsn
      authKey: authDsn
      migrationKey: migrationDsn
    redisSecret:
      name: monty-stores
      key: redisDsn
  workers:
    runtimeClassName: gvisor
    warmReplicas: 1
    ceiling: 8
```

Use organization UUIDs, not organization names. Create the organization first.
Project administrators then enable Agent Sandboxes and create execution keys
through the normal product UI. The configured allowlist does not bypass project
permissions, quotas or execution stops.

Generate one installation UUID before the first enabled install, for example with `uuidgen`.
Save it as `capacityOwnerId` in your values file.
Every admission replica shares this capacity owner.
Keep it unchanged across restarts, upgrades and rollbacks.
Use a different UUID for another installation that shares the database.
Stop new execution and drain active workers before changing this identity.

Self-hosted assignment requests can wait up to 20 seconds for a cold worker bank.
The routing wait covers the controller's bounded preparation window.
The chart enables CPU-clock execution and binds each worker to its immutable Pod UID.
A worker without that execution identity fails at startup.

## Runtime stores and migrations

Create a separate PostgreSQL database for Monty before installation.
Do not point a Monty DSN at the canonical Logfire database.
The runtime migrator and services verify the database identity and reject the canonical schema.
Use PostgreSQL 17 or later for the runtime database.

The migration login needs `CREATE` on the runtime database. It creates and owns the runtime schema.

With `stores.restrictRuntimeRoles: true`, the default, the migration grants the application logins only the access they need:

- Create the `monty_runtime` and `monty_auth` roles as `NOLOGIN` roles before the migration job runs.
  These roles must not own objects, inherit other roles, or hold elevated privileges.
- Create separate login roles for runtime services and auth.
  Grant each login role only its corresponding `NOLOGIN` role.
- Keep the migration login separate from both application logins.

With `stores.restrictRuntimeRoles: false`, the migration applies no grants and needs no roles.
The three DSN keys may then hold the same schema-owning login.

Supply the three DSNs in the Secret keys above.
Each DSN must select the Monty database and its corresponding login.
The chart mounts only the auth DSN in auth, and only the runtime DSN in runtime consumers.
The migration Job alone receives the migration DSN.
Set `postgresTopology: pgbouncer` for a transaction-pooled application endpoint.
The migration DSN must always use a direct or session-pooled connection.
Configure database TLS and certificate trust in the DSNs for your deployment.
The `inClusterTls` setting governs service HTTP transport, not database transport.

The chart runs `logfire-monty-migrations` before an install or upgrade with an external database.
It installs the independent schema, and the restricted runtime grants when `stores.restrictRuntimeRoles` is true.
The bundled development database uses a normal migration Job after database startup.
That development setup still needs the database and roles to exist through its initialization scripts.
Migrations do not require a service drain and do not transfer canonical Logfire data.
Size the development database for both service pool sets.
The private functional fixture uses a 2 GiB memory limit.
The base development default can be too small with sandboxes enabled.

Supply a dedicated Redis endpoint through `stores.redisSecret`.
A separate logical Redis database can isolate keys during development, but does not isolate failures or resource use.
Keep the runtime database, Redis and object-store access unavailable to sandbox workers.
Back up the canonical database, runtime database and snapshot objects together.

## Internal transport

Agent Sandboxes follows the chart's `inClusterTls.enabled` setting.
With this setting enabled, the Python control services and Rust admission use HTTPS with certificate verification.
Supply certificates through cert-manager or existing Secrets.
Existing certificate sets must also cover `monty-controller`, `monty-reconciler` and `monty-admission`.

With this setting disabled, the control services use HTTP and require no application certificates.
Admission runs with `TLS_MODE=disabled` and serves only HTTP.
This internal traffic is unencrypted, including service credentials.
Service credentials, project authorization and durable metering remain required in each configuration.
The chart always enables execution and storage accounting.
Kubernetes API calls always use its own CA and HTTPS.

The in-cluster TLS setting does not encrypt every sandbox connection.
Native gRPC sessions, broker calls and worker telemetry use HTTP at the application layer.
Use compatible cluster transport protection if these connections require encryption.

### Service meshes

Agent Sandboxes currently requires direct application connections for worker telemetry.
This extension does not support injected sidecars that replace the worker's source address.
Istio integration is deferred. The base chart's mesh support does not cover Agent Sandboxes.
Do not enable this extension in an injected mesh until that integration is available.

The Monty workloads accept the chart's existing `podAnnotations` and `podLabels` settings.
Additional worker egress uses `agentSandboxes.workers.extraEgress`.
These generic settings do not enable mesh support.

## Worker namespace and networking

The default worker namespace is `<release namespace>-sandboxes`. The operator must watch that namespace.
The chart creates and retains it by default.
Set `agentSandboxes.createWorkerNamespace: false` to use a namespace that an administrator creates first.
Set `agentSandboxes.workerNamespace` if its name differs from the default.
The namespace must be separate from the Logfire namespace and enforce the restricted Pod Security Standard.
The installer needs permission to manage the chart's resources in both namespaces.
The operator, its CRDs and the isolated RuntimeClass still need separate cluster administrator setup.
The chart does not adopt an externally managed namespace.

The controller needs namespaced Pod read and patch access for immutable worker bindings and termination evidence.
Constrain that patch access with an admission policy.
The application chart does not create cluster-wide admission policies.
An administrator must install an equivalent admission policy before enabling sandboxes.
On Kubernetes 1.30 or later, use the [administrator bootstrap example](examples/agent-sandboxes-pod-patch-policy.yaml).
Set its controller namespace, worker namespace, and unique policy and binding names for this installation.
Apply the edited file with `kubectl apply -f <edited-policy-file>` before installing the chart.
The example requires cluster administrator permissions and remains administrator-owned across Helm upgrades and removal.
For older Kubernetes versions, use an administrator-managed policy engine with the same restrictions.
The policy must allow only the controller's termination finalizer and initial worker-binding annotation changes.
It must reject changes to Pod specs, labels, owner references, other finalizers and existing binding identities.
Scope it to this installation's worker namespace and controller service account.
The base chart retains its existing Kubernetes version requirements.

Workers use `restartPolicy: Never` so a stopped process remains available as termination evidence.
The controller retains its Pod finalizer until that evidence reaches the durable ledger.
Do not remove worker finalizers or restart failed containers to clear an occupied capacity charge.

A custom cluster suffix uses `clusterDomain` on the chart and the operator's matching cluster-domain option.
Create registry pull Secrets with the configured names in both the Logfire and worker namespaces.

### Worker DNS and resource metrics

`agentSandboxes.workers.dnsEgress` replaces the default DNS exception with standard Kubernetes NetworkPolicy egress rules.
The default permits TCP and UDP port 53 to `k8s-app: kube-dns` pods in `kube-system`.
Use your cluster's actual DNS namespace, labels and destination port.
For example, an OpenShift DNS deployment can require port 5353 in `openshift-dns`.
Node-local DNS can instead require an IP exception:

```yaml
agentSandboxes:
  workers:
    dnsEgress:
      - to:
          - ipBlock: {cidr: 169.254.20.10/32}
        ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
```

Replace this example address with the cluster's configured resolver address.
Set `dnsEgress: []` to remove the DNS exception.
The controller telemetry rule remains. Additional worker egress requires an explicit `extraEgress` rule.
Verify DNS resolution and policy enforcement with the selected CNI.
Kubernetes does not define how every CNI applies policy to node-local traffic.

Pressure sensing is disabled by default and does not require the resource metrics API.
Set `agentSandboxes.pressureEnabled: true` only if the cluster provides PodMetrics through `metrics.k8s.io`, usually through metrics-server.
This setting enables `MONTY_PRESSURE_ENABLED` and grants the controller read access to PodMetrics in the worker namespace.
It lets the controller avoid workers with high measured resource use.
Session capacity limits remain active when pressure sensing is disabled or metrics are unavailable.
This setting does not configure metrics for HPA or KEDA.

Use the Logfire HTTP or HTTPS origin as the SDK base URL with `pydantic-monty-client` 1.5.0.
The SDK calls `/monty.v1.MontySession/Session` over gRPC.
`logfire-service` serves this path on its gRPC port, 8444, which accepts HTTP/2 only.
The port uses TLS when `inClusterTls.enabled` is set.
Its Service port declares `appProtocol: kubernetes.io/h2c`, or `HTTP2` with in-cluster TLS.
Web traffic keeps its existing ports and protocols.

The chart routes the path to the gRPC port from the resources it manages:

- `gateway.enabled`: the HTTPRoute gets an exact-path rule for it. The rule keeps
  `gateway.filters` except `URLRewrite` and `RequestRedirect`, and takes no `gateway.timeouts`.
- `ingress.enabled`: the chart adds the `logfire-ingress-grpc` Ingress with the main
  Ingress's annotations. For NGINX classes it sets `backend-protocol` to `GRPC`, or `GRPCS` with in-cluster TLS.
  ingress-nginx serves gRPC only on TLS listeners, so it needs `ingress.tls`.

The edge must reach the port over HTTP/2 and keep long-lived streams open.
Gateway controllers that need explicit backend TLS settings, such as a `BackendTLSPolicy`, need them with in-cluster TLS.
For other exposure, route the path to `logfire-service` port 8444 over HTTP/2.
`inClusterTls.httpsPort` cannot be 8444 while Agent Sandboxes is enabled.
Verify the external SDK origin with the selected ingress controller before use.
The browser workbench uses the backend's authenticated WebSocket endpoint.
The outer ingress must also support WebSocket upgrades and suitable interactive-session timeouts.

The remote MCP server exposes `run_sandboxed_code` when Agent Sandboxes is enabled.
An acting user must consent to `project:execute_agent_sandboxes` for the target project.
Each call uses a fresh session and keeps project authorization and execution limits.
The chart supplies the private admission and relay endpoints to the MCP server.
It adds the execution scope to the configured MCP OAuth client.
The relay and admission ingress policies also permit the MCP service.

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
The snapshot catalogue, profile metadata and execution ledger use the independent
Monty database. The background worker settles execution quantities into the canonical
Logfire database. Back up both databases and the object bytes.
Neither database nor the object bytes alone can restore the full saved state.

The chart requires receipt collection when sandboxes are enabled.
The relay commits receipts through admission to Postgres. The existing worker
runs contribution compaction, receipt reconciliation, retention and storage-time
refresh jobs. Read the canonical `logfire.monty_metering_usage` view for combined compacted and pending
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
