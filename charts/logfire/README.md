# logfire

![Version: 0.14.4-rc.9](https://img.shields.io/badge/Version-0.14.4--rc.9-informational?style=flat-square) ![AppVersion: b8d349fa](https://img.shields.io/badge/AppVersion-b8d349fa-informational?style=flat-square)

Helm chart for self-hosted Pydantic Logfire

**Self-hosted Logfire is an Enterprise offering that requires a contract and payment.** Contact [sales@pydantic.dev](mailto:sales@pydantic.dev) to discuss a contract and pricing.
The chart source in this repository uses the MIT License, but the Logfire container images are private and need commercial access.

## Install paths

Use this README for the chart-level install flow and values reference.
Use the [Self-Hosted Production Requirements](https://pydantic.dev/docs/logfire/deploy/self-hosted-deployment/installation/) for background, architecture, and provider-specific procedures.

The chart needs Kubernetes 1.23 or later and Helm 3 or Helm 4. CI tests it with Helm 4.2.0.
Gateway API routing also needs the Gateway API v1 CRDs in the cluster.

Choose one path:

* **Local evaluation**: use `values.dev.yaml`. It deploys development-grade PostgreSQL, RustFS, and MailDev in the cluster.
* **Production**: start from [values.prod.yaml](https://github.com/pydantic/logfire-helm-chart/blob/main/charts/logfire/values.prod.yaml), replace the placeholders for your external services and routing, and adjust the sizing preset if needed.

> **Warning**: `values.dev.yaml` is only for local evaluation and testing. Do not use it for production deployments.

## Install the chart

### 1. Add the Helm repository

```sh
helm repo add pydantic https://charts.pydantic.dev/
helm repo update
```

### 2. Create the image pull secret

Logfire images are private. Contact [sales@pydantic.dev](mailto:sales@pydantic.dev) to get the `key.json` file for your image pull credentials.

Create the namespace before creating the secret:

```sh
kubectl create namespace logfire
kubectl -n logfire create secret docker-registry logfire-image-key \
  --docker-server=us-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat key.json)" \
  --docker-email=YOUR-EMAIL@example.com
```

Reference the secret from your values file:

```yaml
imagePullSecrets:
  - logfire-image-key
```

If you mirror Logfire images into your own registry, keep the chart version and mirrored image tags aligned.
By default, workload images use the chart `appVersion` tag unless you explicitly override tags in values.

### 3a. Local evaluation

From the chart repository package:

```sh
helm pull pydantic/logfire --untar
helm upgrade --install logfire ./logfire \
  -f ./logfire/values.dev.yaml \
  --namespace logfire
```

Or from this source repository:

```sh
helm dependency build charts/logfire
helm upgrade --install logfire charts/logfire \
  -f charts/logfire/values.dev.yaml \
  --namespace logfire
```

Then port-forward Logfire and MailDev in separate terminals:

```sh
kubectl -n logfire port-forward svc/logfire-service 8080:8080
kubectl -n logfire port-forward svc/logfire-maildev 1080:1080
```

Open Logfire at `http://localhost:8080` and MailDev at `http://localhost:1080`.
MailDev is available for testing local email flows.
Use the first-access step below to log in to the meta project.

### 3b. Production starter

A minimal production overlay is checked in at [values.prod.yaml](https://github.com/pydantic/logfire-helm-chart/blob/main/charts/logfire/values.prod.yaml). Use it as a starting point for production installs and replace the placeholder hostnames, credentials, and provider-specific settings.

The starter uses Gateway API. The chart also supports Ingress.

> **Important**: `values.prod.yaml` turns off password login, so nobody can sign in after the first access step until you add a Dex connector or turn password login back on.
> See [Authentication](#authentication) before you install.

Before installing in production, confirm that you have:

* Image pull credentials configured through `imagePullSecrets`.
* Public hostname and TLS values set through `ingress.*` or `gateway.*`, even if you expose the Service another way.
* External PostgreSQL databases for `crud`, `ff`, and `dex`.
* Object storage using `s3://`, `gs://`, or `az://`.
* A managed Redis endpoint configured through `redisDsn`, or through `redisSecret.name` when the DSNs live in an externally managed Secret.
* A Dex connector for your identity provider, or password login with `smtp.*` configured.
* HorizontalPodAutoscaler metrics available in the cluster when using a sizing preset.
* StorageClass behavior chosen for chart-managed PVCs: use the cluster default, or set `defaultStorageClassName` in [values.prod.yaml](https://github.com/pydantic/logfire-helm-chart/blob/main/charts/logfire/values.prod.yaml).

Install with your production values file:

```sh
helm upgrade --install logfire pydantic/logfire \
  -f values.prod.yaml \
  --namespace logfire
```

### 4. First access

On first install, the chart creates the `logfire-meta` organization and stores a frontend access token in a Kubernetes Secret:

```sh
kubectl -n logfire get secret logfire-meta-frontend-token \
  -o "jsonpath={.data.logfire-meta-frontend-token}" | base64 -d
```

Open the meta project with your hostname and token:

```text
https://logfire.example.com/logfire-meta/logfire-meta#token=LOGFIRE_META_FRONTEND_TOKEN
```

For local evaluation with the port-forward above, use `http://localhost:8080/logfire-meta/logfire-meta#token=LOGFIRE_META_FRONTEND_TOKEN`.

After you have access, create an invite link from **Settings** > **Invite** and assign the **Admin** organization role.
The invited administrator signs in with the method you chose: a Dex connector, or email and password.
If you use a connector, make sure that it works and that its redirect URI matches your hostname before you send the invite.

## Configuration notes

### Sizing

Start with a sizing preset instead of hand-sizing every workload:

```yaml
sizingPreset: standard
```

Use `standard` for general production deployments, `large` for higher throughput, or `small` for lower traffic.
Use `tiny` for the smallest production footprint without high availability.
Presets set resources, autoscaling, PodDisruptionBudgets, and best-effort topology spreading.
Configure the [production prerequisites](#3b-production-starter) separately.

Each preset gives the query API these resources:

| Preset | CPU request | Memory request | Scratch | Replicas |
| --- | ---: | ---: | ---: | ---: |
| `tiny` | 1 | 2 GiB | 1 GiB | 1–6 |
| `small` | 2 | 4 GiB | 2 GiB | 1–8 |
| `standard` | 4 | 8 GiB | 6 GiB | 3–8 |
| `large` | 4 | 8 GiB | 6 GiB | 3–16 |

Without a preset or per-workload resources, the chart sets no Kubernetes CPU or memory requests or limits.
FusionFire uses the `tiny` resource baseline for internal execution limits.
These defaults increase some no-preset FusionFire budgets compared with earlier chart versions.
Select a preset or explicit workload resources for constrained clusters.

Override individual workloads only after selecting a preset:

```yaml
sizingPreset: standard

logfire-worker:
  resources:
    cpu: "500m"
    memory: "1Gi"
    ephemeralStorage: "1Gi"
```

Nested `resources.requests` set requests without mandatory limits.
The flat resource shorthand sets both requests and limits.

#### Resize bcache storage

bcache uses one PersistentVolumeClaim per pod.
Changing `logfire-ff-bcache.disk.storage` after installation fails `helm upgrade` because StatefulSet volume claim templates are immutable.
Expand the existing `bcache-data-*` PVCs if the storage class allows it.
Alternatively, run `kubectl delete statefulset logfire-ff-bcache --cascade=orphan` and upgrade.

### Hostnames and exposure

Set at least one public hostname so the chart can generate correct public URLs and CORS settings.
The hostname and TLS values are used by the application even when you expose `logfire-service` with infrastructure outside this chart.

For Gateway API, which `values.prod.yaml` uses:

```yaml
gateway:
  enabled: true
  gatewayClassName: nginx
  tls: true
  hostnames:
    - logfire.example.com
```

The chart creates a Gateway by default. To attach the HTTPRoute to an existing Gateway instead, set `gateway.create: false`.

For an Ingress:

```yaml
ingress:
  enabled: true
  tls: true
  hostnames:
    - logfire.example.com
  ingressClassName: nginx
```

If you expose `logfire-service` with infrastructure outside this chart, keep `ingress.enabled: false` and still set the public hostname and TLS behavior:

```yaml
ingress:
  enabled: false
  tls: true
  hostnames:
    - logfire.example.com
```

Logfire Live View needs WebSockets.
Every proxy in front of `logfire-service` must keep the WebSocket upgrade and the `Sec-WebSocket-Protocol` header.
A successful handshake returns `101 Switching Protocols`.
Some controllers need extra configuration.
For example, the [F5 NGINX Ingress Controller](https://docs.nginx.com/nginx-ingress-controller/configuration/ingress-resources/advanced-configuration-with-annotations/) needs this annotation:

```yaml
ingress:
  annotations:
    nginx.org/websocket-services: logfire-service
```

### Authentication

Users sign in through Dex, either with an email and password or with an SSO provider that you configure as a Dex connector.
Password login is on by default. `values.prod.yaml` turns it off with `logfire-dex.config.enablePasswordDB: false`, so an install based on that file needs at least one connector.

To add an SSO provider:

1. Create an OAuth app in the provider with the redirect URI `<logfire_url>/auth-api/callback`, for example `https://logfire.example.com/auth-api/callback`.
2. Add a connector for the provider under `logfire-dex.config.connectors`.
   The chart sets the connector's `redirectURI` to the same URL unless you set it yourself.

The [SSO provider examples](https://pydantic.dev/docs/logfire/deploy/self-hosted-deployment/examples/#sso-provider-examples) show connectors for GitHub, Azure AD, and Okta.
The chart passes connector settings to Dex as written, so any provider in the Dex [connector overview](https://dexidp.io/docs/connectors/) works.

This GitHub connector reads its credentials from a Kubernetes Secret:

```yaml
logfire-dex:
  env:
    - name: GITHUB_CLIENT_ID
      valueFrom:
        secretKeyRef:
          name: my-github-secret
          key: client-id
    - name: GITHUB_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: my-github-secret
          key: client-secret
  config:
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: $GITHUB_CLIENT_ID
          clientSecret: $GITHUB_CLIENT_SECRET
          getUserInfo: true
```

#### Organization group mappings

Use `groupOrganizationMapping` to grant Logfire organization and project roles to members of identity-provider groups.
Each `group_id` must match a group that your connector returns to Dex.
Depending on the connector and its settings, that value is a group name or a group ID.

```yaml
groupOrganizationMapping:
  - group_id: engineering
    organization_roles:
      - organization_name: logfire-meta
        role: member
        project_roles:
          - project_name: logfire-meta
            role: write
```

Logfire applies these mappings when a user signs in.
Mappings can change or remove access in the listed organizations and projects.
Logfire leaves unlisted organizations, unlisted projects, and personal organization membership unchanged.
When groups grant different roles in the same scope, Logfire grants the most permissive role.

`groupOrganizationMapping` overrides mappings that you manage with the public Group Mappings API.
The API reports `api_mapping_status: overridden_by_environment` and rejects update requests with HTTP 409.

### Object storage

Logfire requires object storage for data. Supported URI schemes are `s3://`, `gs://`, and `az://`.
Provider credentials can come from `objectStore.env`, mounted secrets, or the Kubernetes ServiceAccount that Logfire runs as.

To use a cloud identity, let the chart create the ServiceAccount and annotate it for your provider.
This example uses AWS IAM roles for service accounts:

```yaml
serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/logfire
```

The identity needs read and write access to the bucket.
On AWS, grant `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket`.
On GCP, grant the `Storage Object Admin` role on the bucket.

For local evaluation, `dev.deployRustfs` (or the deprecated `dev.deployMinio`) deploys RustFS.
It fills in any missing `objectStore.uri`, `AWS_ENDPOINT`, and AWS credential environment variables, so the workloads reach the in-cluster bucket.
An `s3://` `objectStore.uri` also sets the bucket that RustFS creates.

#### Bucket settings

Logfire deletes the objects it no longer needs.
Compaction replaces small files with larger ones and deletes the old files a few minutes later.
Retention deletes data older than each project's retention period.
Configure the bucket so that it does not keep or move these objects:

* Turn off object versioning.
* Turn off soft delete. Google Cloud Storage turns on a 7-day soft delete for new buckets, and Azure Storage can keep deleted blobs for a period. Compaction deletes objects all the time, so soft-deleted objects can become a large part of the storage bill.
* On Amazon S3 and Google Cloud Storage, add a lifecycle rule that aborts incomplete multipart uploads after 1 day. A worker that stops during an upload leaves parts behind. These parts are billed, but they do not appear in object listings.
* Do not add lifecycle rules that delete objects or change their storage class by age. An age-based delete removes files that the `ff` database still references, and queries over those files then fail.

On Google Cloud Storage, you can turn on Autoclass to lower the cost of data that is read less often.

### PostgreSQL

Logfire requires three separate PostgreSQL databases: `crud`, `ff`, and `dex`.
They may run on the same PostgreSQL instance, but they must be separate databases to avoid schema collisions.
Each database user needs owner permissions so migrations can run.

PostgreSQL stores metadata only. Telemetry data is in object storage.
An instance with 2 vCPU and 16 GB of memory is a good starting size. Resize it from the CPU and connection use that you see.

FusionFire migrations set autovacuum settings on the `ff` tables that change most often. Do not override them.

Connect each DSN directly to PostgreSQL, or through a connection pooler in transaction mode as [Connection poolers](#connection-poolers) describes.
The migration jobs, `logfire-ff-maintenance-scheduler`, and Dex then need a session-mode pool or a direct connection.

Each pod opens its own connection pool. [Connection counts](#connection-counts) lists the default size and the variable for each workload.

### Redis

The bundled Redis is for evaluation. For production, set `logfire-redis.enabled: false` and connect a managed Redis:

* Use one Redis endpoint: a standalone instance, or a primary with replicas behind one write endpoint. Logfire does not support Redis Cluster mode.
* Redis 7.2 is the tested version.
* Logfire accepts `redis://` and `rediss://` DSNs. Put the password, or the ACL user and password, in the DSN, for example `rediss://USER:PASSWORD@redis.example.com:6379`.
* With `rediss://`, Logfire verifies the Redis server certificate. If a private CA signs it, such as the CA that Memorystore creates for each instance with in-transit encryption, set `trustedCaBundle`. See [Private CA certificates](#private-ca-certificates).

To keep the DSNs out of your values file, create a Secret with the `sharedDsn`, `tailDsn`, `tokenDsn`, and `usageDsn` keys, and reference it.
All four keys can hold the same DSN:

```yaml
logfire-redis:
  enabled: false

redisSecret:
  enabled: true
  name: logfire-redis-dsn
```

### AI

To turn on Logfire AI features, set a model and the provider's API key under `ai`.
This example reads the OpenAI key from a Kubernetes Secret:

```yaml
ai:
  model: provider:model-name
  openAi:
    apiKey:
      valueFrom:
        secretKeyRef:
          name: logfire-ai
          key: openai-api-key
```

## Advanced configuration

### External secrets and automatic reloads

For Argo CD deployments, use the chart's existing-Secret options with an external secret controller. Updating a Kubernetes Secret does not restart pods that consume its values through environment variables, so configure a reload controller such as [Reloader](https://github.com/stakater/Reloader) as well.

Add the reload controller's workload annotations to the relevant Secret values. The chart copies them only to workloads that consume that Secret and omits its Helm checksum annotations, leaving rotation to the reload controller:

```yaml
postgresSecret:
  enabled: true
  name: logfire-postgres
  annotations:
    reloader.stakater.com/auto: "true"
```

The same `annotations` pattern is supported by `existingSecret`, `adminSecret`, and `existingGatewaySecret`. The chart does not install a reload controller.

### Connection poolers

`postgresDsn` and `postgresFFDsn` can point at a connection pooler in transaction mode.
Migrations and the FusionFire maintenance scheduler need session state, such as advisory locks and `SET`.
So for each pooled database, set a session DSN that points at a session-mode pool or directly at PostgreSQL:

```yaml
postgresDsn: postgresql://USER:PASSWORD@pooler:6432/crud
postgresFFDsn: postgresql://USER:PASSWORD@pooler:6432/ff
postgresSessionDsn: postgresql://USER:PASSWORD@postgres.example.com:5432/crud
postgresFFSessionDsn: postgresql://USER:PASSWORD@postgres.example.com:5432/ff
```

`logfire-backend-migrations` uses `postgresSessionDsn`.
`logfire-ff-migrations` and the maintenance scheduler use `postgresFFSessionDsn`.
Each one is optional and applies only to its own database.
With `postgresSecret`, add the same keys to the Secret, and set `postgresSecret.sessionDsn: true` and `postgresSecret.ffSessionDsn: true` for the keys that it has.
Dex also needs a session-mode pool or a direct connection.

Do not point a session DSN at a transaction-mode pool.
The session state then stays on server connections that other clients get.
For example, the scheduler sets `statement_timeout` to `0` for an index rebuild.

The pooler must:

* Support protocol-level named prepared statements in transaction mode. For PgBouncer, set `max_prepared_statements` above `0`.
* Accept the `options` startup parameter.
* Set `statement_timeout`, `lock_timeout`, and `idle_in_transaction_session_timeout` for each server connection, for example with PgBouncer's `connect_query` or with `ALTER ROLE ... SET`.

The chart is tested with PgBouncer 1.22 and later. Other poolers are not tested.
Behind a transaction-mode pool, two concurrent installs or uninstalls of the same integration in one project can overlap and leave it half configured.

#### Connection counts

Each pod opens up to its pool size. The pooler must accept the sum over all pods.

| Workload | Database | Variable | Default per pod |
|----------|----------|----------|-----------------|
| FusionFire workloads except `logfire-ff-ingest` | `ff` | `FF_PG_POOL_MAX_CONNECTIONS` | 32, and 4 on `logfire-ff-query-worker` |
| `logfire-ff-query-api` and `logfire-ff-query-worker` | `crud` | `FF_EXTERNAL_TABLES_PG_MAX_CONNECTIONS` | 32 |
| Python services | `crud` | `CRUD_PG_POOL_MAX_CONNECTIONS` | 32 |
| `logfire-ai-gateway` | `crud` | None | 10 |

Set the variable in the workload's `env`:

```yaml
logfire-ff-ingest-processor:
  env:
    - name: FF_PG_POOL_MAX_CONNECTIONS
      value: "16"
```

### In-cluster HTTPS

`inClusterTls.enabled` switches supported in-cluster service-to-service traffic to HTTPS with certificate verification.
This is independent from public `ingress.tls` or `gateway.tls`.

Certificate verification uses `inClusterTls.caBundle.*`, or the chart-created CA Secret when using cert-manager auto-Issuer mode.

CA bundle requirements by mode:

* `inClusterTls.certs.mode=certManager` with empty `issuerRef.name`: CA bundle is optional.
* `inClusterTls.certs.mode=certManager` with custom `issuerRef.name`: set exactly one of `inClusterTls.caBundle.existingConfigMap` or `inClusterTls.caBundle.existingSecret`.
* `inClusterTls.certs.mode=existingSecrets`: set exactly one of `inClusterTls.caBundle.existingConfigMap` or `inClusterTls.caBundle.existingSecret`.

FusionFire readers dial the headless `logfire-ff-bcache-internal` service directly and verify
that hostname, so the bcache certificate must include the bare `logfire-ff-bcache-internal`
DNS name. Include the `logfire-ff-bcache` names and the namespace and cluster-domain variants as
well.

bcache loads its certificate at startup, so after rotating the Secret restart
`statefulset/logfire-ff-bcache` so the pods serve the new certificate, or configure a reload
controller as described in [External secrets and automatic reloads](#external-secrets-and-automatic-reloads).

For Kind or local development, you can optionally deploy cert-manager as a Helm dependency with `dev.deployCertManager`.
When working from this repository, run `helm dependency build charts/logfire` to fetch the locked dependency charts.

If you enable in-cluster TLS with bundled cert-manager on a fresh install, omit `--wait`.
Also omit `--atomic` on Helm 3 or `--rollback-on-failure` on Helm 4, because those flags enable readiness waits.
The chart creates its TLS certificates in post-install hooks, which run after Helm waits for ordinary workloads.
Those workloads need the certificate Secrets to become ready, so a readiness wait cannot finish.
Check workload readiness after the hooks finish.
For installations that require readiness waits or automatic rollback, install cert-manager separately and leave `dev.deployCertManager=false`.

### Private CA certificates

Logfire verifies the certificate of each TLS server it connects to, such as a `rediss://` Redis or an SMTP relay.
By default, it trusts only the system trust store of its images.
If the server certificate is signed by a private CA, put the CA certificate (PEM) in a ConfigMap or Secret and set `trustedCaBundle`.
For example, Memorystore for Redis with in-transit encryption signs the server certificate with a CA for each instance.
Download the server CA certificates of the instance into `redis-ca.pem`, then create the ConfigMap:

```sh
kubectl create configmap logfire-private-ca --from-file=ca.crt=redis-ca.pem -n logfire
```

```yaml
trustedCaBundle:
  existingConfigMap:
    name: logfire-private-ca
    key: ca.crt
```

An init container in each Logfire workload that connects to Redis or sends email joins the system trust store and your certificates into one file.
Python and FusionFire workloads read that file through `SSL_CERT_FILE`, and `logfire-ai-gateway` reads it through `NODE_EXTRA_CA_CERTS`.
Public endpoints, such as object storage and model providers, stay trusted.
The file can hold more than one CA, so one bundle can serve Redis and SMTP.
A bundle that cert-manager's trust-manager builds with `useDefaultCAs: true` also works as it is. The duplicate public CAs do no harm.
FusionFire and the AI gateway also check the host name, so the server certificate must name the host in the DSN.
The Python workloads verify certificates strictly, as RFC 5280 requires.
For example, the CA certificate needs a key usage extension, and the server certificate needs an authority key identifier.
To check a CA that you made yourself, run `openssl verify -x509_strict -CAfile ca.crt server.crt`.
The pods read the certificates when they start. After you change them, restart the Logfire workloads.

`smtp.caBundle` still works and adds its CA to the same file in `logfire-task-runner` and `logfire-worker`.
Use `trustedCaBundle` for new installs.

### Restricted Pod Security

Containers default to a non-root identity, no privilege escalation, dropped capabilities, and `RuntimeDefault` seccomp.
They use a read-only root with writable paths mounted.
Override `securityContext` or `<workload>.securityContext` when your cluster requires different settings.

The bundled Redis is the exception.
A `restricted` namespace rejects it unless you set `logfire-redis.securityContext`.
Setting it replaces the Redis pod.
FusionFire pods that start before the new Redis pod is ready exit and restart until Redis is back.

### Istio compatibility

If you run Istio and see protocol or mTLS sidecar issues on HAProxy, migration, or infrastructure workloads, enable:

```yaml
istio:
  disableSidecarOnKnownWorkloads: true
```

This sets `sidecar.istio.io/inject: "false"` on known-sensitive workloads.
You can still override labels per workload using `<workload>.podLabels`.

## Configure SDKs

Create a write token for your project as described in [Create write tokens](https://pydantic.dev/docs/logfire/manage/create-write-tokens/).
Then point the SDK at your hostname:

```python
import logfire

logfire.configure(
    token='<your_logfire_token>',
    advanced=logfire.AdvancedOptions(base_url="https://logfire.example.com")
)
logfire.info('Hello, {place}!', place='World')
```

For other languages, see the [Logfire documentation](https://pydantic.dev/docs/logfire/get-started/).

## Troubleshooting and support

### Quick checks

* Check that the Logfire identity has the bucket permissions listed in [Object storage](#object-storage).
* If you set `defaultStorageClassName` or a per-workload `storageClassName`, check that the StorageClass exists:

  ```sh
  kubectl get storageclass
  ```

  If you omit the StorageClass, Kubernetes uses the cluster's default.
* Check that the image pull Secret exists in the release namespace and appears in `imagePullSecrets`.

### Additional resources

See the [self-hosted troubleshooting guide](https://pydantic.dev/docs/logfire/deploy/self-hosted-deployment/troubleshooting/) for common issues and internal logs.
For GitHub issues, include the chart version, Kubernetes version, relevant redacted values, and redacted error logs.
For enterprise support, contact [sales@pydantic.dev](mailto:sales@pydantic.dev).

## Optional dev dependencies

These subcharts deploy only when you set `dev.deployPostgres` or `dev.deployCertManager`.
Production installs use external PostgreSQL, and a separately installed cert-manager when in-cluster TLS uses cert-manager.

| Repository | Name | Version |
|------------|------|---------|
| https://charts.bitnami.com/bitnami | postgresql | 16.7.27 |
| https://charts.jetstack.io | cert-manager | v1.19.2 |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| adminEmail | string | `"hello@example.dev"` | Starter admin email address |
| adminSecret | object | `{"annotations":{},"enabled":false,"name":""}` | Existing Secret with the following keys:  - logfire-admin-password  - logfire-admin-totp-secret  - logfire-admin-totp-recovery-codes (string containing a JSON list) |
| adminSecret.annotations | object | `{}` | Optional workload annotations for external Secret reload controllers.    Rendered on workloads that consume this existing Secret; not applied to Secret metadata.    Per-workload `annotations` override duplicate keys. |
| adminSecret.enabled | bool | `false` | Use an existing Secret (recommended for Argo CD users). |
| adminSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| affinity | object | `{}` | Node/Pod affinity applied to all workloads |
| ai.azureOpenAi.apiKey | string | `nil` | Azure OpenAI API key. Can be a plain string or a map with valueFrom (e.g., secretKeyRef). |
| ai.azureOpenAi.apiVersion | string | `nil` | Azure OpenAI API version |
| ai.azureOpenAi.endpoint | string | `nil` | Azure OpenAI endpoint |
| ai.chatModel | string | `nil` | AI provider+model string for chat-oriented workloads. Falls back to `ai.model` in the application when unset. |
| ai.llmJudgeModel | string | `nil` | AI provider+model string for LLM-as-a-judge evaluation workloads. Falls back to `ai.model` in the application when unset. |
| ai.model | string | `nil` | AI provider+model string. Prefix the model with the provider (e.g., `azure:gpt-4o`). Use `openai-chat:<model>` to use the Chat Completions API for OpenAI-compatible endpoints. See https://ai.pydantic.dev/models/ for more information. |
| ai.openAi.apiKey | string | `nil` | OpenAI API key. Can be a plain string or a map with valueFrom (e.g., secretKeyRef). |
| ai.openAi.baseUrl | string | `nil` | OpenAI base URL for custom endpoints (e.g., Azure OpenAI proxy, local models). |
| ai.reasoningModel | string | `nil` | AI provider+model string for reasoning-oriented worker workloads such as workflows. Falls back to `ai.model` in the chart when unset. |
| ai.vertexAi.anthropicBaseUrl | string | `nil` | Anthropic Vertex partner-models API base URL. |
| ai.vertexAi.anthropicProjectId | string | `nil` | GCP project ID for Anthropic Vertex models. |
| ai.vertexAi.multiRegionLocation | string | `nil` | Vertex AI multi-region location for models offered only through US/EU multi-regions. Allowed values are `us` and `eu`. This is optional unless a configured model or fallback is `google-cloud:gemini-3.5-flash`. Do not use `global` as a data-residency workaround. |
| ai.vertexAi.region | string | `nil` | Vertex AI region for regionally available models. Required when a configured model or fallback uses a regional `google-cloud:` model. |
| aiGatewayOauth | object | `{"issuer":"","resourceUrl":""}` | AI gateway OAuth metadata configuration. If left empty, the chart derives self-hosted defaults from the primary Logfire URL:   resourceUrl = <logfire.url>/proxy   issuer      = <logfire.url> |
| aiGatewayOauth.issuer | string | `""` | OAuth authorization server issuer URL used by the AI gateway. |
| aiGatewayOauth.resourceUrl | string | `""` | Public AI gateway resource URL (RFC 8707 audience). |
| cert-manager | object | `{"installCRDs":true}` | cert-manager chart values (only used when `dev.deployCertManager` is true) |
| clusterDomain | string | `"cluster.local"` | Kubernetes cluster domain for service discovery. |
| defaultStorageClassName | string | `""` | Default StorageClass for chart-managed PVCs. Set this when chart PVCs should use a specific class. Per-workload `storageClassName` values take precedence. Leave empty to let Kubernetes use the cluster default StorageClass. |
| dev.deployCertManager | bool | `false` | Deploy cert-manager (NOT for production; includes cluster-scoped resources). |
| dev.deployMaildev | bool | `false` | Deploy MailDev to test emails |
| dev.deployMinio | bool | `false` | Deprecated alias for `dev.deployRustfs` that existing MinIO values keep working. While set, the chart keeps the `logfire-minio` Service name and uses the credentials from `minio.auth` (including `minio.auth.existingSecret`) or `objectStore.env` and the persistence from `minio.persistence`, so `objectStore.env` keeps matching the deployed object store. Remove it after moving to `dev.deployRustfs` and the `rustfs.*` values. |
| dev.deployPostgres | bool | `false` | Deploy internal Postgres (NOT for production) |
| dev.deployRustfs | bool | `false` | Deploy a local RustFS instance as S3-compatible object storage (NOT for production) |
| existingGatewaySecret | object | `{"annotations":{},"enabled":false,"name":""}` | Existing Secret for the AI Gateway with the following keys:  - key (gateway encryption key)  - internalSecret (gateway internal secret) |
| existingGatewaySecret.annotations | object | `{}` | Optional workload annotations for external Secret reload controllers.    Rendered on workloads that consume this existing Secret; not applied to Secret metadata.    Per-workload `annotations` override duplicate keys. |
| existingGatewaySecret.enabled | bool | `false` | Use an existing Secret (recommended for Argo CD users). |
| existingGatewaySecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| existingSecret | object | `{"annotations":{},"enabled":false,"name":""}` | Existing Secret with the following keys:  - logfire-dex-client-secret  - logfire-encryption-key  - logfire-meta-write-token  - logfire-meta-frontend-token  - logfire-jwt-secret  - logfire-unsubscribe-secret  - logfire-mcp-oauth-client-secret  - logfire-web-push-vapid-key (only when webPush.enabled is true) |
| existingSecret.annotations | object | `{}` | Optional workload annotations for external Secret reload controllers.    Rendered on workloads that consume this existing Secret; not applied to Secret metadata.    Per-workload `annotations` override duplicate keys. |
| existingSecret.enabled | bool | `false` | Use an existing Secret (recommended for Argo CD users). |
| existingSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| extraObjects | list | `[]` | Additional Kubernetes objects to render with this release. Templating is supported. |
| fusionfireForceConsoleLogging | bool | `false` | Also write Fusionfire telemetry to the container console in addition to sending it through OTLP. |
| fusionfireMaterializedViews | object | `{"derivedBaseReads":false,"derivedMembers":false,"initialBackfillWindow":"1d","minSourceBytes":"5gb"}` | Materialized-view creation policy shared by all Fusionfire services. |
| fusionfireMaterializedViews.derivedBaseReads | bool | `false` | Read whole hours and days from the derived views when the requested bucket width allows. Requires `derivedMembers`. |
| fusionfireMaterializedViews.derivedMembers | bool | `false` | Create a 1 hour and a 1 day derived view for each eligible aggregating view. The derived views are refreshed by `derived_mv_refresh` jobs. |
| fusionfireMaterializedViews.initialBackfillWindow | string | `"1d"` | Maximum source-history window to materialize when a new view is created. Set to `0s` to opt into a full-history initial backfill. Existing views retain the floor stamped when they were created. |
| fusionfireMaterializedViews.minSourceBytes | string | `"5gb"` | Minimum source data written over the trailing seven days required to materialize a new view. Set to `0` to disable the source-volume floor. |
| gateway.addresses | list | `[]` | Gateway addresses (optional, only used when create is true). Used to request specific addresses for the Gateway. |
| gateway.annotations | object | `{}` | HTTPRoute annotations |
| gateway.create | bool | `true` | Create a Gateway resource. Set to false to use an existing Gateway. |
| gateway.enabled | bool | `false` | Enable the Gateway API resources (Gateway and/or HTTPRoute). Use this as an alternative to Ingress for environments using Gateway API. |
| gateway.filters | list | `[]` | Additional HTTPRoute filters (e.g., request/response header modification). |
| gateway.gatewayAnnotations | object | `{}` | Gateway annotations (only used when create is true) |
| gateway.gatewayClassName | string | `""` | GatewayClass name to use (required when create is true). Common values: istio, cilium, nginx, envoy-gateway, gke-l7-rilb, gke-l7-global-external-managed |
| gateway.gatewayLabels | object | `{}` | Gateway labels (only used when create is true) |
| gateway.hostnames | list | `[]` | Hostname(s) for the Gateway listener and HTTPRoute. If not set, falls back to ingress.hostnames for backward compatibility. These hostnames also override the app's URL/CORS hostnames whenever set. |
| gateway.labels | object | `{}` | HTTPRoute labels (in addition to standard labels) |
| gateway.listeners | list | `[]` | Gateway listeners configuration. If not specified, a default HTTP/HTTPS listener will be auto-generated based on tls setting. |
| gateway.maildevHostname | string | `""` | Hostname for the maildev HTTPRoute (only used when dev.deployMaildev is true). If not set, no hostname filter is applied to the maildev HTTPRoute. |
| gateway.matches | list | `[]` | Path matches for the HTTPRoute rules. Defaults to a single prefix match on "/" if not specified. |
| gateway.name | string | `""` | Name of the Gateway. Used for both created Gateway and HTTPRoute parentRef. If not set, defaults to "logfire-gateway". |
| gateway.namespace | string | `""` | Namespace of an existing Gateway (only used when create is false). Leave empty to use the same namespace as the HTTPRoute. |
| gateway.sectionName | string | `""` | Section name within the Gateway to attach the HTTPRoute to (optional). Use this when the Gateway has multiple listeners. |
| gateway.timeouts | object | `{}` | Timeout settings for the HTTPRoute backend. |
| gateway.tls | string | nil (uses ingress.tls) | Enable TLS/HTTPS for the Gateway listener. If not set, falls back to ingress.tls for backward compatibility. Also overrides the app's public URL scheme/CORS behavior (http vs https URLs) whenever set. |
| gateway.tlsSecretName | string | nil (uses ingress.secretName) | TLS Secret name for the Gateway listener certificate. If not set, falls back to ingress.secretName for backward compatibility. |
| groupOrganizationMapping | list | `[]` | Grant Logfire organization and project roles to members of identity-provider groups when they sign in |
| haproxy | object | `{"image":{"pullPolicy":"IfNotPresent","repository":"haproxy","tag":"3.4"},"podSecurityContext":{},"securityContext":{}}` | HAProxy image configuration (used by the service and feature-flag proxies) |
| haproxy.podSecurityContext | object | `{}` | Pod SecurityContext for the HAProxy pod. Defaults to the chart-wide `podSecurityContext`. |
| haproxy.securityContext | object | `{}` | Container SecurityContext for the HAProxy proxies. The chart default pins the numeric identity the image already uses, so the kubelet can verify `runAsNonRoot`, applies the portable controls (no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp), and makes the image root read-only. The chart-wide `securityContext` merges over that default and this value merges over both; set a field to `null` to clear it. HAProxy writes no file outside its mounts, so it needs no scratch volume. |
| hooksAnnotations | string | `nil` | Custom annotations for migration Jobs (uncomment as needed, e.g., with Argo CD hooks) |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| imagePullSecrets | list | `[]` | Image pull secrets used by all pods |
| inClusterTls | object | `{"caBundle":{"existingConfigMap":{"key":"ca.crt","name":""},"existingSecret":{"key":"ca.crt","name":""}},"certs":{"certManager":{"issuerRef":{"group":"cert-manager.io","kind":"Issuer","name":""}},"mode":"existingSecrets"},"enabled":false,"httpsPort":8443,"secretNamePrefix":"","waitImage":{"pullPolicy":"","repository":"curlimages/curl","tag":"8.12.1"}}` | Enable full in-cluster HTTPS with certificate verification. This is independent from `ingress.tls` / `gateway.tls`.  NOTE: Implementation is incremental; see the README's "In-cluster HTTPS" section for usage notes. |
| inClusterTls.caBundle | object | `{"existingConfigMap":{"key":"ca.crt","name":""},"existingSecret":{"key":"ca.crt","name":""}}` | CA bundle used by clients (HAProxy and other workloads) to verify service certificates. Required when: - certs.mode=existingSecrets - certs.mode=certManager with a non-empty certs.certManager.issuerRef.name (custom issuer) Optional when: - certs.mode=certManager with an empty issuerRef.name (chart-managed namespaced Issuer + CA) Provide exactly one of existingConfigMap or existingSecret. The referenced resource must exist in the same namespace as this Helm release. |
| inClusterTls.certs | object | `{"certManager":{"issuerRef":{"group":"cert-manager.io","kind":"Issuer","name":""}},"mode":"existingSecrets"}` | Certificate provisioning for in-cluster TLS. certs.mode=certManager requires cert-manager CRDs to be installed in the cluster. (Helm will fail fast if cert-manager.io/v1 is not available, unless dev.deployCertManager=true.) |
| inClusterTls.certs.certManager | object | `{"issuerRef":{"group":"cert-manager.io","kind":"Issuer","name":""}}` | Settings only used when certs.mode=certManager |
| inClusterTls.certs.certManager.issuerRef | object | `{"group":"cert-manager.io","kind":"Issuer","name":""}` | IssuerRef used to issue service certificates. If name is empty, the chart will create a namespaced Issuer + CA (dev-friendly default). |
| inClusterTls.certs.mode | string | `"existingSecrets"` | Use existingSecrets for customer-provided certs, or certManager to have the chart create cert-manager Certificate resources. |
| inClusterTls.httpsPort | int | `8443` | Port used for in-cluster HTTPS on Services. Use a non-privileged port to avoid securityContext constraints. |
| inClusterTls.secretNamePrefix | string | `""` | Convention-based certificate secret naming. When enabled, the chart expects a kubernetes.io/tls Secret per service:   <release>-<service>-tls This also controls secret names used by chart-created cert-manager Certificates. If secretNamePrefix is empty, the prefix defaults to the Helm release name. |
| inClusterTls.waitImage | object | `{"pullPolicy":"","repository":"curlimages/curl","tag":"8.12.1"}` | Image for the in-cluster TLS wait Job. The Job only runs when certs.mode=certManager and dev.deployCertManager=true. Point this at a registry mirror for private-registry installs. The default container securityContext pins the uid/gid of `curlimages/curl`; override `tls-wait.securityContext` if you substitute an image that runs as a different user. |
| inClusterTls.waitImage.pullPolicy | string | `""` | Image pull policy. Defaults to `image.pullPolicy` when unset. |
| inClusterTls.waitImage.repository | string | `"curlimages/curl"` | Image repository |
| inClusterTls.waitImage.tag | string | `"8.12.1"` | Image tag |
| ingress.annotations | object | `{}` | Ingress annotations. Logfire Live View requires WebSocket support, and some controllers require an explicit annotation. For example, F5 NGINX Ingress Controller uses `nginx.org/websocket-services: logfire-service`. |
| ingress.enabled | bool | `true` | Enable the Ingress resource. If you are NOT using an ingress resource, you still need to set `tls` and `hostnames` via either `ingress.*` or `gateway.*` so the application can generate correct URLs/CORS. |
| ingress.hostname | string | `"logfire.example.com"` | DEPRECATED (kept for backward compatibility). Use `hostnames` (list) for all new deployments. |
| ingress.hostnames | list | `["logfire.example.com"]` | Hostname(s) for Pydantic Logfire. Preferred method. Supports one or more hostnames; put the primary domain first. |
| ingress.ingressClassName | string | `"nginx"` | IngressClass to use (e.g., nginx) |
| ingress.secretName | string | `"logfire-frontend-cert"` | TLS Secret name if you want to do a custom one |
| ingress.tls | bool | `false` | Enable TLS/HTTPS. Required for correct CORS behavior. |
| intakeOauth | object | `{"resourceUrl":""}` | OTLP intake OAuth metadata configuration. When `resourceUrl` is empty, the chart derives the self-hosted resource URL from the primary Logfire URL:   resourceUrl = <logfire.url>/v1 |
| intakeOauth.resourceUrl | string | `""` | Public OTLP intake resource URL (RFC 8707 audience). |
| istio | object | `{"disableSidecarOnKnownWorkloads":false}` | Istio compatibility options |
| istio.disableSidecarOnKnownWorkloads | bool | `false` | When enabled, automatically sets `sidecar.istio.io/inject: "false"` on known-sensitive workloads:    logfire-service, logfire-backend-migrations,    logfire-ff-migrations, logfire-redis, and logfire-otel-collector.    You can still override per workload via `<workload>.podLabels`. |
| keepAliveTimeout | string | `"120s"` | Idle keep-alive timeout for the HAProxy entry point. Keep it above the idle timeout of the ingress or tunnel in front of the release; if HAProxy closes an idle connection first, the client sees a 502/520 when it reuses it. |
| logfire-ai-gateway | object | disabled | Autoscaling & resources for the `logfire-ai-gateway` pod |
| logfire-ai-gateway.enabled | bool | `false` | Enable the AI gateway service |
| logfire-ai-gateway.proxyTimeout | string | `"600s"` | HAProxy inactivity timeout for public `/proxy` requests to the AI gateway. |
| logfire-dex | object | `{"annotations":{},"config":{"connectors":[],"enablePasswordDB":true,"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}},"env":[],"labels":{},"podAnnotations":{},"podLabels":{},"service":{"annotations":{}}}` | Configuration, autoscaling & resources for `logfire-dex` deployment |
| logfire-dex.annotations | object | `{}` | Workload annotations |
| logfire-dex.config | object | `{"connectors":[],"enablePasswordDB":true,"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}}` | Dex configuration (see https://dexidp.io/docs/) |
| logfire-dex.config.connectors | list | `[]` | Dex auth connectors (see https://dexidp.io/docs/connectors/) The redirectURI can be omitted—it will be generated automatically. If specified, the custom value will be honored. |
| logfire-dex.config.enablePasswordDB | bool | `true` | Enable password authentication. Set to false if undesired, but ensure another connector is configured first. |
| logfire-dex.config.storage | object | `{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}` | Dex storage configuration (see https://dexidp.io/docs/configuration/storage/) |
| logfire-dex.env | list | `[]` | Extra environment variables for the Dex pod. Accepts `valueFrom`, so a credential can come from a Secret. Dex expands `$VAR` from this environment in the storage and connector config, so `DEX_EXPAND_ENV=false` keeps a literal `$` in a password or DN. |
| logfire-dex.labels | object | `{}` | Workload labels |
| logfire-dex.podAnnotations | object | `{}` | Pod annotations |
| logfire-dex.podLabels | object | `{}` | Pod labels |
| logfire-dex.service.annotations | object | `{}` | Service annotations |
| logfire-ff-bcache | object | `{"disk":{},"pdb":{},"replicas":3,"topology":{"zone":"","zoneAware":false}}` | Replicas, resources and disk for bcache, the shared read cache that Fusionfire readers use |
| logfire-ff-bcache.disk | object | `{}` | Persistent disk tier of each bcache pod. storage accepts Kubernetes quantities (e.g. 32Gi, 10G) of at least 1Mi. bcache uses 80% of it. A StatefulSet cannot change its volumeClaimTemplates, so a later change to storage fails `helm upgrade`. To resize, expand the existing `bcache-data-*` PVCs if the storage class allows it, or delete the StatefulSet with `kubectl delete statefulset logfire-ff-bcache --cascade=orphan` and upgrade. Unset `disk.storage` takes the sizing preset's size, or 32Gi without a preset. |
| logfire-ff-bcache.replicas | int | `3` | Number of bcache replicas when autoscaling is not configured. |
| logfire-ff-bcache.topology | object | `{"zone":"","zoneAware":false}` | Topology routing for the readers that use this cache. Zone routing is off by default. |
| logfire-ff-bcache.topology.zone | string | `""` | Static topology zone, for tests and for single-zone clusters whose nodes carry no zone label. Every pod gets this zone, so it must match the zone the pods run in. It does not serve a multi-zone cluster that refuses node-read RBAC: leave `zoneAware` off there and take global routing instead. Takes precedence over `zoneAware`, and then no cluster role is created. |
| logfire-ff-bcache.topology.zoneAware | bool | `false` | Route reads to cache pods in this pod's topology zone. The reader resolves the zone from its own node label at startup, so this needs a cluster-wide `nodes` `get` role, and every zone must run a cache pod or reads in the other zones get no caching at all. |
| logfire-ff-ingest | object | `{"annotations":{},"env":[{"name":"RUST_LOG","value":"warn,otel::tracing=info"}],"labels":{},"podAnnotations":{},"podLabels":{},"service":{"annotations":{}},"volumeClaimTemplates":{"storage":"16Gi"}}` | Autoscaling & resources for the `logfire-ff-ingest` pod |
| logfire-ff-ingest-processor | object | `{"annotations":{},"env":[{"name":"RUST_LOG","value":"warn"}],"labels":{},"podAnnotations":{},"podLabels":{},"service":{"annotations":{}}}` | Autoscaling & resources for the `logfire-ff-ingest-processor` pod |
| logfire-ff-ingest-processor.annotations | object | `{}` | Workload annotations |
| logfire-ff-ingest-processor.env | list | `[{"name":"RUST_LOG","value":"warn"}]` | Extra env vars for the ingest processor pod |
| logfire-ff-ingest-processor.labels | object | `{}` | Workload labels |
| logfire-ff-ingest-processor.podAnnotations | object | `{}` | Pod annotations |
| logfire-ff-ingest-processor.podLabels | object | `{}` | Pod labels |
| logfire-ff-ingest-processor.service.annotations | object | `{}` | Service annotations |
| logfire-ff-ingest.annotations | object | `{}` | Workload annotations |
| logfire-ff-ingest.env | list | `[{"name":"RUST_LOG","value":"warn,otel::tracing=info"}]` | Extra env vars for the ingest pod |
| logfire-ff-ingest.labels | object | `{}` | Workload labels |
| logfire-ff-ingest.podAnnotations | object | `{}` | Pod annotations |
| logfire-ff-ingest.podLabels | object | `{}` | Pod labels |
| logfire-ff-ingest.service.annotations | object | `{}` | Service annotations |
| logfire-ff-ingest.volumeClaimTemplates | object | `{"storage":"16Gi"}` | Configuration for the StatefulSet PersistentVolumeClaim template |
| logfire-ff-ingest.volumeClaimTemplates.storage | string | `"16Gi"` | Storage provisioned for each pod |
| logfire-ff-maintenance-scheduler | object | `{"env":[]}` | Environment overrides for the maintenance scheduler pod |
| logfire-ff-query-api | object | `{"env":[]}` | Environment overrides for the query API pod |
| logfire-otel-collector | object | `{"livenessProbe":{"failureThreshold":3,"httpGet":{"path":"/","port":"health"},"periodSeconds":30,"timeoutSeconds":5},"readinessProbe":{"failureThreshold":3,"httpGet":{"path":"/","port":"health"},"periodSeconds":10,"timeoutSeconds":3},"startupProbe":{"failureThreshold":24,"httpGet":{"path":"/","port":"health"},"periodSeconds":5,"timeoutSeconds":3},"strategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0},"type":"RollingUpdate"},"terminationGracePeriodSeconds":60}` | Collector health checks and rollout settings. Override probes here, or set a probe to null to disable it. GOMEMLIMIT defaults to 60% of the rendered memory limit (409MiB with no limit); an explicit GOMEMLIMIT in env takes precedence. |
| logfire-redis.affinity | object | `{}` | Affinity for the bundled Redis pod. |
| logfire-redis.enabled | bool | `true` | Deploy Redis as part of this chart. Disable to use an external Redis instance.  The bundled Redis is a single-node instance intended for development, evaluation, and simple self-contained installs. It is not highly available, and upgrades that change its pod template cause a brief interruption while Redis is replaced. For production, disable this and set redisDsn to a managed Redis endpoint. |
| logfire-redis.image | object | `{"pullPolicy":"IfNotPresent","repository":"redis","tag":"7.2"}` | Redis image configuration |
| logfire-redis.image.pullPolicy | string | `"IfNotPresent"` | Redis image pull policy |
| logfire-redis.image.repository | string | `"redis"` | Redis image repository |
| logfire-redis.image.tag | string | `"7.2"` | Redis image tag |
| logfire-redis.livenessProbe | object | `{"initialDelaySeconds":30,"periodSeconds":10,"tcpSocket":{"port":"redis"},"timeoutSeconds":1}` | Redis liveness probe. Override or set to null to disable. |
| logfire-redis.nodeSelector | object | `{}` | Node selector for the bundled Redis pod. |
| logfire-redis.pdb | object | `{}` | PodDisruptionBudget override for the bundled Redis pod. Defaults to minAvailable: 1 when empty. Example:   maxUnavailable: 0 |
| logfire-redis.persistence | object | `{"accessModes":["ReadWriteOnce"],"annotations":{},"enabled":false,"existingClaim":"","size":"1Gi","storageClassName":""}` | Persistence for the bundled Redis data directory. This improves recovery across pod restarts but does not make Redis highly available. |
| logfire-redis.podAnnotations | object | `{}` | Pod annotations for the bundled Redis pod. Example:   cluster-autoscaler.kubernetes.io/safe-to-evict: "false" |
| logfire-redis.podSecurityContext | object | `{}` | Pod SecurityContext for the bundled Redis pod. Merged over the chart-wide `podSecurityContext` and a default of `fsGroup: 999` with `fsGroupChangePolicy: OnRootMismatch`, so the non-root Redis user can write a fresh data volume. |
| logfire-redis.readinessProbe | object | `{"initialDelaySeconds":5,"periodSeconds":10,"tcpSocket":{"port":"redis"},"timeoutSeconds":1}` | Redis readiness probe. Override or set to null to disable. |
| logfire-redis.resources | object | `{}` | Resource requests/limits. Supports the chart shorthand, for example:   cpu: "100m"   memory: "128Mi" or native requests/limits. |
| logfire-redis.securityContext | object | `{}` | Container SecurityContext for the bundled Redis container. Merged over the chart-wide `securityContext` and the image defaults: uid and gid 999, all capabilities dropped, no privilege escalation, the `RuntimeDefault` seccomp profile, and a read-only image root. |
| logfire-redis.startupProbe | object | `{"failureThreshold":30,"periodSeconds":10,"tcpSocket":{"port":"redis"},"timeoutSeconds":1}` | Redis startup probe. Override or set to null to disable. |
| logfire-redis.tolerations | list | `[]` | Tolerations for the bundled Redis pod. |
| logfire-redis.topologySpreadConstraints | list | `[]` | Topology spread constraints for the bundled Redis pod. |
| logfire-remote-mcp | object | `{"enabled":true}` | Autoscaling & resources for the `logfire-remote-mcp` pod |
| logfire-remote-mcp.enabled | bool | `true` | Enable the remote MCP service. When disabled, the deployment is not rendered and the `/mcp` and `/.well-known/oauth-protected-resource/mcp` haproxy routes are removed. |
| maildev | object | `{"image":{"pullPolicy":"IfNotPresent","repository":"maildev/maildev","tag":"3.0.0"},"podSecurityContext":{},"securityContext":{}}` | MailDev configuration (only used when `dev.deployMaildev` is true) |
| maildev.podSecurityContext | object | `{}` | Pod SecurityContext for the MailDev pod. Defaults to the chart-wide `podSecurityContext` when unset. |
| maildev.securityContext | object | `{}` | Container SecurityContext for the MailDev container. Merged over the chart-wide `securityContext` and the image defaults: uid and gid 1000, all capabilities dropped, no privilege escalation, the `RuntimeDefault` seccomp profile, and a read-only image root with a writable `/tmp` emptyDir. Set a field here to override a default. |
| migrations | object | `{"activeDeadlineSeconds":3600}` | CRUD database migration Job settings. |
| migrations.activeDeadlineSeconds | int | `3600` | Maximum time the backend migration Job may run, in seconds. The deadline covers all retries. Raise it for large databases where a concurrent index build takes several minutes. |
| nodeSelector | object | `{}` | Node selector applied to all workloads |
| objectStore | object | `{"env":{},"sessionReplayUri":null,"sseCKeyB64":null,"uri":null,"visualTestsUri":null,"volumeMounts":[],"volumes":[]}` | Object storage details |
| objectStore.env | object | `{}` | Additional environment variables for the object store connection. String values support Helm templating. When the in-cluster RustFS store is enabled, missing `AWS_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_ALLOW_HTTP` values are filled in from the in-cluster store. The backend and the worker read the same names: `AWS_ENDPOINT` is the endpoint alias the Python S3 client accepts, and Azure clients read `AZURE_STORAGE_ACCOUNT_NAME` and `AZURE_STORAGE_ACCOUNT_KEY`, or `AZURE_STORAGE_CONNECTION_STRING`. |
| objectStore.sessionReplayUri | string | `nil` | Optional override for the session-replay blob store, e.g. `s3://logfire-replays`. Defaults to `<uri>/session-replays`. The bucket or container must exist, and it must be reachable with the same endpoint and credentials as `uri`: a different account or provider needs its own `env` and credential volumes, which the per-service `env` lists under `logfire-backend` and `logfire-worker` can carry. |
| objectStore.sseCKeyB64 | string | `nil` | Opt-in S3 Server-Side Encryption with Customer-provided Keys (SSE-C). Base64-encoded 256-bit key applied to all S3 PUT/GET/HEAD/multipart/copy requests. Only used when the object store is S3, and only for FusionFire: the session-replay and visual-test objects do not use SSE-C.  IMPORTANT: this MUST be set from day one on an empty bucket. Enabling it on a bucket that already contains FusionFire data will break all reads of the pre-existing objects. losing the key means losing the data — AWS does not store it. |
| objectStore.uri | string | `nil` | URI for object storage (e.g., `s3://bucket`). Supports Helm templating, e.g. `s3://logfire-{{ .Release.Name }}` to derive a bucket per release. When `dev.deployRustfs` (or the deprecated `dev.deployMinio`) is enabled and this is empty, it defaults to `s3://<rustfs.bucket>`.  The backend and the worker keep session replay and visual-test blobs under the `session-replays/` and `visual-tests/` prefixes of the same bucket, and receive the `env` entries and `volumeMounts` below, so one object store serves FusionFire and both Python services. |
| objectStore.visualTestsUri | string | `nil` | Optional override for the visual-test blob store, e.g. `az://logfirefiles/visual-tests`. Defaults to `<uri>/visual-tests`, with the same requirements as `sessionReplayUri`. |
| objectStore.volumeMounts | list | `[]` | Volume mounts for object store credentials, on FusionFire, the backend and the worker. The chart reserves the mount paths `/tmp`, `/scratch`, `/fusionfire/ingest-data`, and `/var/lib/logfire` for its own volumes, adds `/etc/tls` and `/etc/logfire/incluster-ca` when in-cluster TLS is enabled, and `/etc/logfire/smtp-ca` while the SMTP CA bundle is configured. |
| objectStore.volumes | list | `[]` | Volumes for object store credentials, on FusionFire, the backend and the worker. The chart reserves the volume names `tmp`, `scratch-data`, `ingest-data`, and `logfire-data` for its own volumes, adds `logfire-incluster-tls` and `logfire-incluster-ca-bundle` when in-cluster TLS is enabled, and `logfire-smtp-ca-bundle` while the SMTP CA bundle is configured. |
| otelResourceAttributes | object | `{}` | Additional OTEL resource attributes to stamp onto internal telemetry emitted by Logfire workloads. These are merged on top of the chart defaults and can override them. Example:   deployment.environment.name: prod   service.namespace: logfire |
| otel_collector | object | `{"debug":{"enabled":false},"exporter":{"endpoint":"http://logfire-ff-ingest:8012","headers":{},"sending_queue":{"batch":{"flush_timeout":"1s","max_size":4194304,"min_size":1048576,"sizer":"bytes"}},"tls":{"insecure":true}},"extraExporters":{},"extraPipelines":{},"extraProcessors":{},"image":{"pullPolicy":"IfNotPresent","repository":"ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib","tag":"0.163.1@sha256:1175b03003053962012f5a231f5567f66a3e8fdb960c7835c0e48f7aa1555806"},"prometheus":{"add_metric_suffixes":false,"delta_to_cumulative":true,"enable_open_metrics":true,"enabled":false,"endpoint":"0.0.0.0","max_stale":"5m","max_streams":10000,"metric_expiration":"180m","port":9090,"resource_to_telemetry_conversion":{"enabled":true},"send_timestamp":true,"translation_strategy":""},"queueStorage":{"enabled":true,"ephemeralStorageLimit":"5Gi","ephemeralStorageRequest":"512Mi","fsync":false,"maxSizeBytes":536870912,"sizeLimit":"4Gi"},"selfMetrics":{"enabled":true},"selfMetricsPort":8888,"sendingQueueBytes":67108864,"serviceAccount":{"annotations":{}}}` | otel-collector configuration |
| otel_collector.debug.enabled | bool | `false` | Emit per-request summaries to collector logs. Enable for troubleshooting; disabled by default to avoid logging every incoming telemetry request. |
| otel_collector.exporter | object | `{"endpoint":"http://logfire-ff-ingest:8012","headers":{},"sending_queue":{"batch":{"flush_timeout":"1s","max_size":4194304,"min_size":1048576,"sizer":"bytes"}},"tls":{"insecure":true}}` | exporter configuration for the otlp_http exporter Override these to send telemetry data to a different OTLP-compatible destination. |
| otel_collector.exporter.sending_queue | object | `{"batch":{"flush_timeout":"1s","max_size":4194304,"min_size":1048576,"sizer":"bytes"}}` | Exporter queue overrides. Batching here keeps queue rejection synchronous with OTLP ingestion, so senders can retry refused data. Queue limits measure serialized bytes. The queue capacity still comes from the sizing preset or sendingQueueBytes unless queue_size is explicitly overridden here. Each signal has its own queue and consumers. |
| otel_collector.extraExporters | object | `{}` | Additional collector exporters. Chart-owned component names are reserved. |
| otel_collector.extraPipelines | object | `{}` | Additional collector pipelines. The chart's existing telemetry pipelines stay unchanged. |
| otel_collector.extraProcessors | object | `{}` | Additional collector processors. These only run in pipelines that reference them. |
| otel_collector.prometheus.delta_to_cumulative | bool | `true` | Convert delta metrics to cumulative for Prometheus with the alpha `delta_to_cumulative` processor. Runs only when `otel_collector.prometheus.enabled` is true. The OTLP pipeline keeps delta metrics unchanged. Each stream must reach the same collector replica. Cumulative state resets when that replica is replaced. Set false to pass metrics through unchanged. |
| otel_collector.prometheus.max_stale | string | `"5m"` | Retention of inactive delta-to-cumulative streams. Independent of metric_expiration. |
| otel_collector.prometheus.max_streams | int | `10000` | Cap on the delta-to-cumulative stream map. The in-pipeline `memory_limiter` bounds ingress but cannot evict this processor's state, so an unbounded cap lets high-cardinality attributes grow until the collector refuses telemetry. Streams past the cap are dropped, so raise this for high-cardinality scrapes. |
| otel_collector.prometheus.resource_to_telemetry_conversion | object | `{"enabled":true}` | OpenTelemetry resource attributes exposed as Prometheus metric labels. Review this deprecated option when upgrading the collector to use resource_constant_labels instead. |
| otel_collector.prometheus.translation_strategy | string | `""` | Override the Prometheus exporter `translation_strategy`. When empty it is derived from `add_metric_suffixes`: `UnderscoreEscapingWithoutSuffixes` when false, and `UnderscoreEscapingWithSuffixes` when true. The exporter no longer emits `add_metric_suffixes` (deprecated and ignored by recent collectors); this value drives `translation_strategy`. |
| otel_collector.queueStorage | object | `{"enabled":true,"ephemeralStorageLimit":"5Gi","ephemeralStorageRequest":"512Mi","fsync":false,"maxSizeBytes":536870912,"sizeLimit":"4Gi"}` | Disk-backed OTLP queues on a per-pod emptyDir. Survives container restarts, but not pod replacement, rollouts, or eviction. Disable to use memory queues. Storage exhaustion can still lose already-acknowledged records. |
| otel_collector.queueStorage.ephemeralStorageLimit | string | `"5Gi"` | Container limit for node-local storage, including queues, compaction, and logs. |
| otel_collector.queueStorage.ephemeralStorageRequest | string | `"512Mi"` | Scheduling reservation for node-local storage, including logs. Explicit logfire-otel-collector.resources ephemeral-storage settings take precedence. |
| otel_collector.queueStorage.fsync | bool | `false` | Force each database write to stable storage. Off by default, like upstream: process-restart recovery uses the live node filesystem; unclean host failure can lose unsynced writes or corrupt the database. Enabling this adds substantial disk I/O cost. |
| otel_collector.queueStorage.maxSizeBytes | int | `536870912` | Per-database limit. There are three signal databases. Keep the volume large enough for all three plus their temporary compaction copies (at least 6x this value). Byte queues require at least 4x payload capacity per database for page/index overhead; this headroom minimum is not a guarantee for arbitrary request shapes or disk failure. |
| otel_collector.selfMetrics.enabled | bool | `true` | Forward collector queue, delivery, and receiver metrics to the configured OTLP exporter every 60 seconds. Each pod scrapes only itself. Independent external monitoring is still needed to detect a collector or destination outage. |
| otel_collector.selfMetricsPort | int | `8888` | Port for the collector's own Prometheus self-metrics. Must differ from `prometheus.port` (the application exporter), or the collector cannot bind both and fails to start. |
| otel_collector.sendingQueueBytes | int | `67108864` | Byte size of the OTLP/HTTP exporter sending queue. The sizing presets set this per profile; this value applies when no sizing preset is used. |
| otel_collector.serviceAccount.annotations | object | `{}` | Annotations for the collector's ServiceAccount, for example a Workload Identity binding. |
| podSecurityContext | object | `{}` | Pod SecurityContext (https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-pod) See: https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context for details Fusionfire and bcache pods merge this context over their default `fsGroup: 1000` and `fsGroupChangePolicy: OnRootMismatch`, which let their uid 1000 images write chart-managed scratch volumes. `logfire-ff-ingest` defaults to `fsGroupChangePolicy: Always` instead, because its spool is a retained volume that `OnRootMismatch` can leave unrepaired. A per-service `podSecurityContext` wins over both. |
| postgresDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/crud"` | Postgres DSN used for the `crud` database |
| postgresFFDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/ff"` | Postgres DSN used for the `ff` database |
| postgresFFSessionDsn | string | `""` | Optional session DSN for the `ff` database: a session-mode pool or a direct connection to PostgreSQL. Set it when `postgresFFDsn` points at a transaction-mode pool. `logfire-ff-migrations` and the index rebuilds of `logfire-ff-maintenance-scheduler` then use it, because they need session state: advisory locks, `SET`, and concurrent index DDL. See "Connection poolers" in the README. |
| postgresSecret | object | `{"annotations":{},"enabled":false,"ffSessionDsn":false,"name":"","sessionDsn":false}` | User-provided Secret containing database credentials Must include `postgresDsn` and `postgresFFDsn` keys. |
| postgresSecret.annotations | object | `{}` | Optional workload annotations for external Secret reload controllers.    Rendered on workloads that consume this existing Secret; not applied to Secret metadata.    Per-workload `annotations` override duplicate keys. |
| postgresSecret.enabled | bool | `false` | Set to true to use an existing Secret (recommended for Argo CD users). |
| postgresSecret.ffSessionDsn | bool | `false` | Set to true when the Secret also has a `postgresFFSessionDsn` key. See `postgresFFSessionDsn`. |
| postgresSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| postgresSecret.sessionDsn | bool | `false` | Set to true when the Secret also has a `postgresSessionDsn` key. See `postgresSessionDsn`. |
| postgresSessionDsn | string | `""` | Optional session DSN for the `crud` database: a session-mode pool or a direct connection to PostgreSQL. Set it when `postgresDsn` points at a transaction-mode pool. `logfire-backend-migrations` then uses it, because migrations need session state: advisory locks, `SET`, and concurrent index DDL. See "Connection poolers" in the README. |
| postgresql.auth.postgresPassword | string | `"postgres"` |  |
| postgresql.fullnameOverride | string | `"logfire-postgres"` |  |
| postgresql.image.registry | string | `"docker.io"` |  |
| postgresql.image.repository | string | `"bitnamilegacy/postgresql"` |  |
| postgresql.postgresqlDataDir | string | `"/var/lib/postgresql/data/pgdata"` |  |
| postgresql.primary.initdb.scripts."create_databases.sql" | string | `"CREATE DATABASE crud;\nCREATE DATABASE dex;\nCREATE DATABASE ff;\n"` |  |
| postgresql.primary.persistence.mountPath | string | `"/var/lib/postgresql"` |  |
| postgresql.primary.persistence.size | string | `"10Gi"` |  |
| postgresql.primary.resourcesPreset | string | `"small"` |  |
| priorityClassName | string | `""` | Pod priority class See: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#pod-priority). |
| rateLimits | object | `{}` | Configure Rate Limiting rules for Logfire endpoints |
| redisDsn | string | `"redis://logfire-redis:6379"` | Redis DSN for the shared role, and the live-tail DSN. Change if using an external Redis instance. |
| redisSecret | object | `{"annotations":{},"enabled":false,"name":""}` | User-provided Secret containing the Redis DSNs, one key per role:   - `sharedDsn`  shared caches, the generic `REDIS_DSN` of every service, and                 the arq queues (`WORKER_REDIS_DSN`, `BACKEND_REDIS_DSN`)  - `tailDsn`    Fusionfire live-tail registration (`FF_REDIS_TAIL_DSN`)  - `tokenDsn`   auth token caches  - `usageDsn`   usage, autocomplete, and rate limiting data  The chart reads the DSNs only from a Secret, so a password never reaches a ConfigMap or a plain env value. When `enabled` is false the chart creates its own Secret from `redisDsn`, `tokenRedis.dsn` and `usageRedis.dsn`. |
| redisSecret.annotations | object | `{}` | Optional workload annotations for external Secret reload controllers.    Rendered on workloads that consume this existing Secret; not applied to Secret metadata.    Per-workload `annotations` override duplicate keys. |
| redisSecret.enabled | bool | `false` | Set to true to use an existing Secret (recommended for Argo CD users). |
| redisSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| releaseVersion | string | `"v2026-10-23.01"` | Platform release tag reported to API clients in the `Logfire-Version` response header, for example `v2026-09-15.01`. Set this when releasing a chart built from a platform release so clients can tell which release an instance runs. When empty, workloads report their image identity, which clients treat as an unknown version. |
| revisionHistoryLimit | int | `2` | Number of deployment revisions to keep. See: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#clean-up-policy) May be set to 0 when using a GitOps workflow. |
| rustfs | object | `{"auth":{"accessKey":"logfire-rustfs","secretKey":"logfire-rustfs"},"bucket":"logfire","image":{"pullPolicy":"","repository":"rustfs/rustfs","tag":"1.0.0"},"persistence":{"enabled":true,"existingClaim":"","size":"32Gi","storageClassName":""},"podSecurityContext":{},"resources":{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}},"securityContext":{}}` | RustFS configuration (only used when `dev.deployRustfs` is true) |
| rustfs.auth | object | `{"accessKey":"logfire-rustfs","secretKey":"logfire-rustfs"}` | Root credentials. Ignored while `dev.deployMinio` is set. Set `objectStore.env.AWS_ACCESS_KEY_ID` and `objectStore.env.AWS_SECRET_ACCESS_KEY` to the same values. |
| rustfs.bucket | string | `"logfire"` | Bucket that RustFS creates at startup when `objectStore.uri` is not an `s3://` URI. With an `s3://` `objectStore.uri`, the bucket in the URI is used. |
| rustfs.image.pullPolicy | string | `""` | RustFS image pull policy. Defaults to `image.pullPolicy` when unset. |
| rustfs.image.repository | string | `"rustfs/rustfs"` | RustFS image repository |
| rustfs.image.tag | string | `"1.0.0"` | RustFS image tag |
| rustfs.persistence.enabled | bool | `true` | Store data on a PersistentVolumeClaim. Set false to use an emptyDir. Ignored while `dev.deployMinio` is set and `minio.persistence` is present. |
| rustfs.persistence.existingClaim | string | `""` | Existing PersistentVolumeClaim to use in place of a chart-managed claim |
| rustfs.persistence.size | string | `"32Gi"` | Size of the chart-managed claim |
| rustfs.persistence.storageClassName | string | `""` | Storage class for the chart-managed claim. Defaults to `defaultStorageClassName`. |
| rustfs.podSecurityContext | object | `{}` | Pod SecurityContext for the RustFS pod. Merged over the chart-wide `podSecurityContext` and a default of `fsGroup: 10001`. |
| rustfs.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resource requests and limits for the RustFS container |
| rustfs.securityContext | object | `{}` | Container SecurityContext for the RustFS container. Merged over the chart-wide `securityContext` and the image defaults: uid and gid 10001, all capabilities dropped, no privilege escalation, the `RuntimeDefault` seccomp profile, and a read-only image root with the `/data` and `/logs` emptyDirs writable. |
| securityContext | object | `{}` | Container SecurityContext (https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-container) See: https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context-1 for details Chart-owned containers (the Python, Fusionfire, gateway, and frontend images) and HAProxy merge this context over chart defaults: the image's verified identity, `allowPrivilegeEscalation: false`, all capabilities dropped, the `RuntimeDefault` seccomp profile, and a read-only root. The bundled third-party containers (Redis, Dex, RustFS, MailDev, and the OTel collector) merge it over the same portable controls with their own verified identities. A per-workload `<workload>.securityContext` merges over both layers, for example `logfire-backend.securityContext` or `logfire-dex.securityContext`. Set a field to `null` to clear it, for example `runAsUser: null` for OpenShift, or set `readOnlyRootFilesystem: false` to restore a writable root. |
| serviceAccount | object | `{"annotations":{},"create":false,"name":""}` | ServiceAccount configuration |
| serviceAccount.annotations | object | `{}` | Annotations to add to the ServiceAccount (e.g., for IAM roles) Example for AWS IRSA:   annotations:     eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/my-role Example for GCP Workload Identity:   annotations:     iam.gke.io/gcp-service-account: my-sa@my-project.iam.gserviceaccount.com |
| serviceAccount.create | bool | `false` | Create a ServiceAccount |
| serviceAccount.name | string | `""` | Name of the ServiceAccount. If not set and create is true, a name is generated using the fullname template. If create is false and this is not set, the default ServiceAccount is used. |
| serviceAccountName | string | `"default"` | DEPRECATED: Use serviceAccount.name instead. Kept for backward compatibility. @deprecated |
| sizingPreset | string | `""` | Workload sizing preset. Leave empty to skip preset sizing, or set to `large`, `standard`, `small`, or `tiny` to apply built-in customer sizing defaults. |
| smtp.caBundle | object | `{"existingConfigMap":{"key":"ca.crt","name":""},"existingSecret":{"key":"ca.crt","name":""}}` | CA bundle (PEM) that verifies the SMTP server certificate, for a relay signed by an internal CA. Provide exactly one of existingConfigMap or existingSecret, in the release namespace. `logfire-task-runner` and `logfire-worker` trust these certificates in addition to the system trust store. `trustedCaBundle` does the same for these and the other workloads that connect to Redis, so prefer it for new installs. |
| smtp.fromAddress | string | `nil` | Sender address of every email Logfire sends (`From` and SMTP envelope sender), such as `logfire@example.com`. Required when `smtp.host` is set. Use an address on a domain that your SMTP server may send for. Logfire does not send email as `pydantic.dev` from a self-hosted install. |
| smtp.fromName | string | `nil` | Sender display name of every email Logfire sends. If it is not set, the name is `Pydantic Logfire`. |
| smtp.host | string | `nil` | SMTP server hostname |
| smtp.password | string | `nil` | SMTP password. Can be a plain string or a map with valueFrom (e.g., secretKeyRef). |
| smtp.port | int | `25` | SMTP server port |
| smtp.use_tls | bool | `false` | Use implicit TLS from the first byte, for SMTPS ports such as 465. If it is false, Logfire connects in plaintext and upgrades with STARTTLS whenever the server offers it, which is what a port 25 or 587 relay expects. |
| smtp.username | string | `nil` | SMTP username. Can be a plain string or a map with valueFrom (e.g., secretKeyRef). Leave both username and password unset for a relay that does not use authentication; set both or neither. |
| smtp.validate_certs | bool | `nil` | Verify the SMTP server certificate. If it is not set, Logfire verifies it. Setting it to false sends email, including password reset links, over a connection open to interception. Prefer `smtp.caBundle` for a relay signed by an internal CA. |
| tokenRedis | object | `{"dsn":"","prefix":""}` | Redis settings for auth token caches. Empty DSN falls back to `redisDsn`. Use a prefix only when sharing one Redis instance with other data. |
| tokenRedis.dsn | string | `""` | Redis DSN for auth token caches. |
| tokenRedis.prefix | string | `""` | Key prefix for auth token cache keys. |
| tolerations | list | `[]` | Tolerations applied to all workloads |
| topologySpreadConstraints | list | `[]` | topologySpreadConstraints applied to all workloads |
| trustedCaBundle | object | `{"existingConfigMap":{"key":"ca.crt","name":""},"existingSecret":{"key":"ca.crt","name":""}}` | CA certificates (PEM) that Logfire workloads trust for outbound TLS, in addition to the system trust store of each image. Use it for a `rediss://` Redis or an SMTP relay whose certificate is signed by a private CA, such as Memorystore with in-transit encryption. Provide exactly one of existingConfigMap or existingSecret, in the release namespace. It applies to every Logfire workload that connects to Redis or sends email. An init container joins the system trust store and these certificates into one file. Python and FusionFire workloads read that file through `SSL_CERT_FILE`, and `logfire-ai-gateway` reads it through `NODE_EXTRA_CA_CERTS`. Public endpoints stay trusted. The pods read the certificates when they start, so restart them after you change the certificates. In-cluster TLS is not affected. |
| usageRedis | object | `{"dsn":"","prefix":""}` | Redis settings for usage, autocomplete, and rate limiting data. Empty DSN falls back to `redisDsn`. Use a prefix only when sharing one Redis instance with other data. |
| usageRedis.dsn | string | `""` | Redis DSN for usage, autocomplete, and rate limiting data. |
| usageRedis.prefix | string | `""` | Key prefix for usage keys. |
| variablesApiKey | string | `""` | Client-safe API key used by the frontend to evaluate external managed variables through OFREP. The key is written to the public runtime configuration, so it must only have the `project:read_external_variables` scope. |
| webPush.enabled | bool | `false` | Let users turn on browser push notifications for alerts. Needs the deployment to be served over HTTPS, since browsers register a service worker only on a secure origin. While this is false the settings panel reports push as unavailable. |
| webPush.privateKey | string | `""` | VAPID private key: 32 bytes of P-256 private scalar, unpadded base64url, as `npx web-push generate-vapid-keys` prints it. Leave empty to have the chart generate one and keep it across upgrades. Replacing it unregisters every device that had push on, which each browser recovers from by subscribing again on its next visit. |
| webPush.subject | string | `""` | Contact the push service operator can reach you on, a `mailto:` or `https:` URL (RFC 8292). Defaults to `mailto:` and `adminEmail`. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
