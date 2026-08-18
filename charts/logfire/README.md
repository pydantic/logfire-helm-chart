# logfire

![Version: 0.13.41-rc.1](https://img.shields.io/badge/Version-0.13.41--rc.1-informational?style=flat-square) ![AppVersion: 4ae3e48d](https://img.shields.io/badge/AppVersion-4ae3e48d-informational?style=flat-square)

Helm chart for self-hosted Pydantic Logfire

This repository and the chart source it contains are licensed under the MIT License. Deploying the official self-hosted Pydantic Logfire product requires separate commercial access to private container images.
**Self-hosted Logfire is an Enterprise offering that requires a contract and payment.** Please contact sales@pydantic.dev to discuss setting up a contract and pricing.

## Install Paths

Use this README for the chart-level install flow and values reference.
Use the [Self-Hosted Production Requirements](https://docs.pydantic.dev/logfire/reference/self-hosted/installation/) for background, architecture, and provider-specific procedures.

Choose one path:

* **Local evaluation**: use `values.dev.yaml`. It deploys development-grade PostgreSQL, MinIO, and MailDev in the cluster.
* **Production**: start from [values.prod.yaml](https://github.com/pydantic/logfire-helm-chart/blob/main/charts/logfire/values.prod.yaml), replace the placeholders for your external services and routing, and adjust the sizing preset if needed.

> **Warning**: `values.dev.yaml` is only for local evaluation and testing. Do not use it for production deployments.

## Install the Chart

### 1. Add the Helm Repository

```sh
helm repo add pydantic https://charts.pydantic.dev/
helm repo update
```

### 2. Create the Image Pull Secret

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

### 3a. Local Evaluation

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

### 3b. Production Starter

A minimal production overlay is checked in at [values.prod.yaml](https://github.com/pydantic/logfire-helm-chart/blob/main/charts/logfire/values.prod.yaml). Use it as a starting point for production installs and replace the placeholder hostnames, credentials, and provider-specific settings.

The starter uses Gateway API, but the chart supports both Gateway API and Ingress. Use whichever routing interface your cluster standardizes on. The core shape is:

```yaml
imagePullSecrets:
  - logfire-image-key

sizingPreset: standard
adminEmail: sre@example.com

# Optional: set a StorageClass for chart-managed PVCs:
# defaultStorageClassName: fast-storage

ingress:
  enabled: false

gateway:
  enabled: true
  gatewayClassName: nginx
  tls: true
  hostnames:
    - logfire.example.com

postgresDsn: postgresql://logfire_crud:PASSWORD@postgres.example.com:5432/crud
postgresFFDsn: postgresql://logfire_ff:PASSWORD@postgres.example.com:5432/ff

logfire-dex:
  config:
    enablePasswordDB: false
    storage:
      type: postgres
      config:
        host: postgres.example.com
        port: 5432
        user: logfire_dex
        database: dex
        password: PASSWORD
        ssl:
          mode: require

objectStore:
  uri: s3://logfire-prod
  env:
    AWS_DEFAULT_REGION: us-east-1

logfire-redis:
  enabled: false

redisDsn: redis://redis.example.com:6379
```

Configure an identity provider under `logfire-dex.config.connectors`; see [Authentication](#authentication).

Before installing in production, confirm that you have:

* Image pull credentials configured through `imagePullSecrets`.
* Public hostname and TLS values set through `ingress.*` or `gateway.*`, even if you expose the Service another way.
* External PostgreSQL databases for `crud`, `ff`, and `dex`.
* Object storage using `s3://`, `gs://`, or `az://`.
* A managed Redis endpoint configured through `redisDsn`.
* A Dex connector configured for your identity provider.
* HorizontalPodAutoscaler metrics available in the cluster when using a sizing preset.
* StorageClass behavior chosen for chart-managed PVCs: use the cluster default, or set `defaultStorageClassName` in [values.prod.yaml](https://github.com/pydantic/logfire-helm-chart/blob/main/charts/logfire/values.prod.yaml).

Install with your production values file:

```sh
helm upgrade --install logfire pydantic/logfire \
  -f values.prod.yaml \
  --namespace logfire
```

### 4. First Access

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

## Configuration Notes

### Hostnames and Exposure

Set at least one public hostname so the chart can generate correct public URLs and CORS settings.
The hostname and TLS values are used by the application even when you expose `logfire-service` with infrastructure outside this chart.

For a standard Ingress:

```yaml
ingress:
  enabled: true
  tls: true
  hostnames:
    - logfire.example.com
  ingressClassName: nginx
```

If you expose `logfire-service` directly instead of rendering an Ingress or Gateway, keep `ingress.enabled: false` and still set the public hostname and TLS behavior:

```yaml
ingress:
  enabled: false
  tls: true
  hostnames:
    - logfire.example.com
```

Gateway API is supported through `gateway.enabled`.
Set `gateway.create: true` to create a Gateway, or `gateway.create: false` to attach the HTTPRoute to an existing Gateway.

### Authentication

Dex is used as the identity service for Logfire.
When creating an OAuth app in your provider, set the redirect URI to `<logfire_url>/auth-api/callback`, for example `https://logfire.example.com/auth-api/callback`.
Connector configuration is passed through to Dex; see the Dex [connector overview](https://dexidp.io/docs/connectors/) for supported providers and settings.

Example GitHub connector using Kubernetes Secret references:

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

#### Organization Group Mappings

Use `groupOrganizationMapping` to grant Logfire organization and project roles from identity-provider group IDs:

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

The mapping is authoritative for the organizations and projects it lists and is reconciled when a user signs in. Access in those scopes may be changed or removed; unlisted organizations and projects are left unchanged, and personal organization membership is preserved. When multiple matching groups grant roles in the same scope, the most permissive role is applied.

Setting `groupOrganizationMapping` overrides mappings managed through the public Group Mappings API. The API reports `api_mapping_status: overridden_by_environment`, and update requests return HTTP 409.

### Object Storage

Logfire requires object storage for data. Supported URI schemes are `s3://`, `gs://`, and `az://`.
Provider credentials can come from `objectStore.env`, mounted secrets, or the Kubernetes service account used by Logfire.

Do not enable bucket versioning. Logfire manages its own data lifecycle, and bucket versioning can increase cost and interfere with lifecycle behavior.

### PostgreSQL

Logfire requires three separate PostgreSQL databases: `crud`, `ff`, and `dex`.
They may run on the same PostgreSQL instance, but they must be separate databases to avoid schema collisions.
Each database user needs owner permissions so migrations can run.

### AI

Pydantic Logfire AI features can be enabled by setting the `ai` configuration in your values file:

```yaml
ai:
  model: provider:model-name
  openAi:
    apiKey: openai-api-key
```

## Sizing

Start with a sizing preset instead of hand-sizing every workload:

```yaml
sizingPreset: standard
```

Use `large` for higher-throughput deployments, `standard` for general production deployments, `small` for lower-traffic deployments that still need ingest and query headroom, or `tiny` for the smallest production footprint.
Presets apply workload resources, autoscaling, PDBs, and best-effort topology spreading for HA-sensitive workloads. FusionFire derives its execution settings from the effective resources.
They do not configure environment-specific prerequisites such as hostnames, TLS, PostgreSQL, object storage, image pull secrets, or StorageClasses.

Query API capacity is resource-oriented:

| Preset | CPU request | Memory request | Query cost capacity per pod | Scratch | Replicas |
| --- | ---: | ---: | ---: | ---: | ---: |
| `tiny` | 1 | 2 GiB | 1 | 1 GiB | 1–6 |
| `small` | 2 | 4 GiB | 2 | 2 GiB | 1–8 |
| `standard` | 4 | 8 GiB | 4 | 6 GiB | 3–8 |
| `large` | 4 | 8 GiB | 4 | 6 GiB | 3–16 |

Query cost capacity defaults to the effective execution-worker CPU rounded up to a whole core. With separate query workers enabled, both the dispatcher and workers derive it from query-worker CPU. Advanced installations can override it with `logfire-ff-query-api.maxQueryCostPerPod`.

The `standard` preset keeps the public request path, query API, and ingest path at a minimum of three replicas.
The `large` preset inherits `standard` and increases selected FusionFire worker, ingest processor, and byte-cache capacity.
The `small` preset keeps ingest and the edge service more available while preserving a smaller footprint.
The `tiny` preset intentionally favors the smallest resource footprint over high availability.

If you do not set a sizing preset or per-workload resources, the chart does not render Kubernetes CPU/memory requests or limits.
FusionFire still needs internal execution limits, so those derived settings use the `tiny` preset resource baseline without rendering the preset's Kubernetes resources.
This increases some no-preset FusionFire budgets compared with earlier chart versions. Operators running constrained clusters should select a sizing preset or configure explicit workload resources.

Override individual workloads only after selecting a preset:

```yaml
sizingPreset: standard

logfire-worker:
  resources:
    cpu: "500m"
    memory: "1Gi"
    ephemeralStorage: "1Gi"
```

Nested `resources.requests` do not add mandatory limits, allowing workloads to use spare node capacity. The legacy flat resource shorthand continues to use the configured values for both requests and limits.

## Advanced Configuration

### In-cluster HTTPS

`inClusterTls.enabled` switches supported in-cluster service-to-service traffic to HTTPS with certificate verification.
This is independent from public `ingress.tls` or `gateway.tls`.

Certificate verification uses `inClusterTls.caBundle.*`, or the chart-created CA Secret when using cert-manager auto-Issuer mode.

CA bundle requirements by mode:

* `inClusterTls.certs.mode=certManager` with empty `issuerRef.name`: CA bundle is optional.
* `inClusterTls.certs.mode=certManager` with custom `issuerRef.name`: set exactly one of `inClusterTls.caBundle.existingConfigMap` or `inClusterTls.caBundle.existingSecret`.
* `inClusterTls.certs.mode=existingSecrets`: set exactly one of `inClusterTls.caBundle.existingConfigMap` or `inClusterTls.caBundle.existingSecret`.

For Kind or local development, you can optionally deploy cert-manager as a Helm dependency with `dev.deployCertManager`.
When working from this repository, run `helm dependency update charts/logfire` to fetch dependency charts.

### OTLP/gRPC Ingest

OTLP over HTTP (`/v1/traces`, `/v1/metrics`, `/v1/logs`) is always routed. To also accept OTLP over gRPC, enable:

```yaml
grpcIngest:
  enabled: true
```

This gives `logfire-service` a dedicated HTTP/2 listener on port 8444 that proxies OTLP/gRPC traces, metrics, and logs to the ingest pods, and routes the OTLP collector gRPC methods to it from the chart-managed Ingress or HTTPRoute.

gRPC needs HTTP/2 end to end, so whatever fronts `logfire-service` must be able to forward HTTP/2 to the gRPC port:

* **ingress-nginx**: handled automatically; the chart renders a dedicated Ingress (`logfire-ingress-grpc`) with the appropriate `backend-protocol` annotation. ingress-nginx only serves gRPC on TLS listeners, so `ingress.tls` must be enabled.
* **Gateway API**: the chart adds an HTTPRoute rule targeting the gRPC Service port, whose `appProtocol` (`kubernetes.io/h2c` by default, `HTTP2` when `inClusterTls.enabled` is true, overridable via `grpcIngest.appProtocol`) tells the controller to speak HTTP/2 towards the backend. Controllers that need explicit backend TLS configuration (e.g. a `BackendTLSPolicy`) must be configured accordingly when `inClusterTls.enabled` is true.
* **Custom exposure**: route the OTLP collector gRPC method paths (`/opentelemetry.proto.collector.<trace|logs|metrics>.v1.*`) to `logfire-service` port 8444 over HTTP/2.

SDKs then need no special port or path; point the standard OTLP environment at your public endpoint:

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=https://logfire.example.com
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <your write token>"
```

### Istio Compatibility

If you run Istio and see protocol or mTLS sidecar issues on HAProxy, migration, or infrastructure workloads, enable:

```yaml
istio:
  disableSidecarOnKnownWorkloads: true
```

This sets `sidecar.istio.io/inject: "false"` on known-sensitive workloads.
You can still override labels per workload using `<workload>.podLabels`.

## Configure SDKs

Once your self-hosted instance is running, configure client SDKs to send data to your endpoint:

```python
import logfire

logfire.configure(
    token='<your_logfire_token>',
    advanced=logfire.AdvancedOptions(base_url="https://logfire.example.com")
)
logfire.info('Hello, {place}!', place='World')
```

## Troubleshooting & Support

### Quick Checks

Before diving deeper, verify these common configuration issues:

* **Object Storage Permissions**: Ensure the ServiceAccount (configured via `serviceAccount.annotations`) has read/write access to your object storage bucket. For AWS, this means the IAM role needs `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket` permissions. For GCP, the service account needs the `Storage Object Admin` role on the bucket.

* **StorageClass Exists**: If you set `defaultStorageClassName` or any per-workload `storageClassName`, verify the StorageClass exists in your cluster:
  ```bash
  kubectl get storageclass
  ```
  If omitted, Kubernetes uses the cluster's default StorageClass.

* **Image Pull Secrets**: Ensure the secret exists in the same namespace as the release and is correctly referenced in `imagePullSecrets`.

### Additional Resources

* **Troubleshooting Guide**: If you encounter issues, your first stop should be the [Troubleshooting Self-Hosted guide](https://docs.pydantic.dev/logfire/reference/self-hosted/troubleshooting/), which includes common issues and steps for accessing internal logs.

* **GitHub Issues**: If your issue persists, please open up an issue with details about your deployment (Chart version, Kubernetes version, values file, any relevant error logs).

* **Enterprise Support**: For commercial support, contact us at [sales@pydantic.dev](mailto:sales@pydantic.dev).

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| https://charts.bitnami.com/bitnami | minio | 17.0.21 |
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
| dev.deployMinio | bool | `false` | Use a local MinIO instance as object storage (NOT for production) |
| dev.deployPostgres | bool | `false` | Deploy internal Postgres (NOT for production) |
| existingGatewaySecret | object | `{"annotations":{},"enabled":false,"name":""}` | Existing Secret for the AI Gateway with the following keys:  - key (gateway encryption key)  - internalSecret (gateway internal secret) |
| existingGatewaySecret.annotations | object | `{}` | Optional workload annotations for external Secret reload controllers.    Rendered on workloads that consume this existing Secret; not applied to Secret metadata.    Per-workload `annotations` override duplicate keys. |
| existingGatewaySecret.enabled | bool | `false` | Use an existing Secret (recommended for Argo CD users). |
| existingGatewaySecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| existingSecret | object | `{"annotations":{},"enabled":false,"name":""}` | Existing Secret with the following keys:  - logfire-dex-client-secret  - logfire-encryption-key  - logfire-meta-write-token  - logfire-meta-frontend-token  - logfire-jwt-secret  - logfire-unsubscribe-secret  - logfire-mcp-oauth-client-secret |
| existingSecret.annotations | object | `{}` | Optional workload annotations for external Secret reload controllers.    Rendered on workloads that consume this existing Secret; not applied to Secret metadata.    Per-workload `annotations` override duplicate keys. |
| existingSecret.enabled | bool | `false` | Use an existing Secret (recommended for Argo CD users). |
| existingSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| extraObjects | list | `[]` | Additional Kubernetes objects to render with this release. Templating is supported. |
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
| groupOrganizationMapping | list | `[]` | List of mapping to automatically assign members of OIDC group to logfire roles |
| grpcIngest | object | `{"appProtocol":"","enabled":false,"ingressAnnotations":{}}` | OTLP/gRPC ingest support. When enabled, `logfire-service` gets a dedicated HTTP/2 listener on port 8444 that proxies OTLP/gRPC (traces, metrics, logs) to the ingest pods, and the chart-managed Ingress / HTTPRoute (whichever is enabled) routes the OTLP collector gRPC methods to that port. gRPC needs HTTP/2 end to end: whatever fronts `logfire-service` must be able to forward HTTP/2 to the gRPC port. With ingress-nginx the chart sets the `backend-protocol` annotation automatically; other controllers may need extra configuration (e.g. a BackendTLSPolicy when `inClusterTls.enabled` is true). SDKs then only need `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` pointed at the regular public endpoint; no extra port or path. |
| grpcIngest.appProtocol | string | "" (auto) | `appProtocol` set on the gRPC port of the `logfire-service` Service, used by Gateway/Ingress controllers to select HTTP/2 towards the backend. Defaults to `kubernetes.io/h2c` (cleartext HTTP/2), or `HTTP2` (HTTP/2 over TLS, e.g. for GKE Gateway) when `inClusterTls.enabled` is true. |
| grpcIngest.ingressAnnotations | object | `{}` | Annotations for the dedicated gRPC Ingress resource (only rendered when `ingress.enabled` is true). The gRPC Ingress inherits the main `ingress.annotations` so host-level access controls keep covering the gRPC paths; keys set here take precedence over both the inherited annotations and the automatic nginx `backend-protocol` value. |
| haproxy | object | `{"image":{"pullPolicy":"IfNotPresent","repository":"haproxy","tag":"3.2"}}` | HAProxy image configuration (used by the service and feature-flag proxies) |
| hooksAnnotations | string | `nil` | Custom annotations for migration Jobs (uncomment as needed, e.g., with Argo CD hooks) |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| imagePullSecrets | list | `[]` | Image pull secrets used by all pods |
| inClusterTls | object | `{"caBundle":{"existingConfigMap":{"key":"ca.crt","name":""},"existingSecret":{"key":"ca.crt","name":""}},"certs":{"certManager":{"issuerRef":{"group":"cert-manager.io","kind":"Issuer","name":""}},"mode":"existingSecrets"},"enabled":false,"httpsPort":8443,"secretNamePrefix":""}` | Enable full in-cluster HTTPS with certificate verification. This is independent from `ingress.tls` / `gateway.tls`.  NOTE: Implementation is incremental; see the README's "In-cluster HTTPS" section for usage notes. |
| inClusterTls.caBundle | object | `{"existingConfigMap":{"key":"ca.crt","name":""},"existingSecret":{"key":"ca.crt","name":""}}` | CA bundle used by clients (HAProxy and other workloads) to verify service certificates. Required when: - certs.mode=existingSecrets - certs.mode=certManager with a non-empty certs.certManager.issuerRef.name (custom issuer) Optional when: - certs.mode=certManager with an empty issuerRef.name (chart-managed namespaced Issuer + CA) Provide exactly one of existingConfigMap or existingSecret. The referenced resource must exist in the same namespace as this Helm release. |
| inClusterTls.certs | object | `{"certManager":{"issuerRef":{"group":"cert-manager.io","kind":"Issuer","name":""}},"mode":"existingSecrets"}` | Certificate provisioning for in-cluster TLS. certs.mode=certManager requires cert-manager CRDs to be installed in the cluster. (Helm will fail fast if cert-manager.io/v1 is not available, unless dev.deployCertManager=true.) |
| inClusterTls.certs.certManager | object | `{"issuerRef":{"group":"cert-manager.io","kind":"Issuer","name":""}}` | Settings only used when certs.mode=certManager |
| inClusterTls.certs.certManager.issuerRef | object | `{"group":"cert-manager.io","kind":"Issuer","name":""}` | IssuerRef used to issue service certificates. If name is empty, the chart will create a namespaced Issuer + CA (dev-friendly default). |
| inClusterTls.certs.mode | string | `"existingSecrets"` | Use existingSecrets for customer-provided certs, or certManager to have the chart create cert-manager Certificate resources. |
| inClusterTls.httpsPort | int | `8443` | Port used for in-cluster HTTPS on Services. Use a non-privileged port to avoid securityContext constraints. |
| inClusterTls.secretNamePrefix | string | `""` | Convention-based certificate secret naming. When enabled, the chart expects a kubernetes.io/tls Secret per service:   <release>-<service>-tls This also controls secret names used by chart-created cert-manager Certificates. If secretNamePrefix is empty, the prefix defaults to the Helm release name. |
| ingress.annotations | object | `{}` | Ingress annotations |
| ingress.enabled | bool | `true` | Enable the Ingress resource. If you are NOT using an ingress resource, you still need to set `tls` and `hostnames` via either `ingress.*` or `gateway.*` so the application can generate correct URLs/CORS. |
| ingress.hostname | string | `"logfire.example.com"` | DEPRECATED (kept for backward compatibility). Use `hostnames` (list) for all new deployments. |
| ingress.hostnames | list | `["logfire.example.com"]` | Hostname(s) for Pydantic Logfire. Preferred method. Supports one or more hostnames; put the primary domain first. |
| ingress.ingressClassName | string | `"nginx"` | IngressClass to use (e.g., nginx) |
| ingress.secretName | string | `"logfire-frontend-cert"` | TLS Secret name if you want to do a custom one |
| ingress.tls | bool | `false` | Enable TLS/HTTPS. Required for correct CORS behavior. |
| intakeOauth | object | `{"resourceUrl":""}` | OTLP intake OAuth metadata configuration. When `resourceUrl` is empty, the chart derives the self-hosted resource URL from the primary Logfire URL:   resourceUrl = <logfire.url>/v1 |
| intakeOauth.resourceUrl | string | `""` | Public OTLP intake resource URL (RFC 8707 audience). |
| istio | object | `{"disableSidecarOnKnownWorkloads":false}` | Istio compatibility options |
| istio.disableSidecarOnKnownWorkloads | bool | `false` | When enabled, automatically sets `sidecar.istio.io/inject: "false"` on known-sensitive workloads:    logfire-service, logfire-ff-proxy-cache-byte, logfire-backend-migrations,    logfire-ff-migrations, logfire-redis, and logfire-otel-collector.    You can still override per workload via `<workload>.podLabels`. |
| logfire-ai-gateway | object | disabled | Autoscaling & resources for the `logfire-ai-gateway` pod |
| logfire-ai-gateway.enabled | bool | `false` | Enable the AI gateway service |
| logfire-ai-gateway.proxyTimeout | string | `"600s"` | HAProxy inactivity timeout for public `/proxy` requests to the AI gateway. |
| logfire-dex | object | `{"annotations":{},"config":{"connectors":[],"enablePasswordDB":true,"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}},"labels":{},"podAnnotations":{},"podLabels":{},"service":{"annotations":{}}}` | Configuration, autoscaling & resources for `logfire-dex` deployment |
| logfire-dex.annotations | object | `{}` | Workload annotations |
| logfire-dex.config | object | `{"connectors":[],"enablePasswordDB":true,"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}}` | Dex configuration (see https://dexidp.io/docs/) |
| logfire-dex.config.connectors | list | `[]` | Dex auth connectors (see https://dexidp.io/docs/connectors/) The redirectURI can be omitted—it will be generated automatically. If specified, the custom value will be honored. |
| logfire-dex.config.enablePasswordDB | bool | `true` | Enable password authentication. Set to false if undesired, but ensure another connector is configured first. |
| logfire-dex.config.storage | object | `{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}` | Dex storage configuration (see https://dexidp.io/docs/configuration/storage/) |
| logfire-dex.labels | object | `{}` | Workload labels |
| logfire-dex.podAnnotations | object | `{}` | Pod annotations |
| logfire-dex.podLabels | object | `{}` | Pod labels |
| logfire-dex.service.annotations | object | `{}` | Service annotations |
| logfire-ff-cache-byte | object | `{"clientSideRouting":{"enabled":true,"zoneAware":false},"pdb":{},"replicas":3,"scratchVolume":{"storage":"32Gi"}}` | Autoscaling & resources for the byte cache pods |
| logfire-ff-cache-byte.clientSideRouting.enabled | bool | `true` | Route query byte-cache requests directly using EndpointSlice discovery. HAProxy remains for unmigrated consumers; stale zoneless discovery can use ClusterIP. |
| logfire-ff-cache-byte.clientSideRouting.zoneAware | bool | `false` | Restrict direct routing to zone-local cache pods. Requires nodes/get cluster RBAC and adds soft zone/hostname spreading. Cache replicas must cover every query zone; local misses use durable storage. |
| logfire-ff-cache-byte.replicas | int | `3` | Number of byte-cache replicas when autoscaling is not configured. |
| logfire-ff-cache-byte.scratchVolume | object | `{"storage":"32Gi"}` | Cache byte ephemeral volume. storage accepts Kubernetes quantities (e.g. 32Gi, 1.5Gi, 10G) of at least 1Mi. |
| logfire-ff-ingest | object | `{"annotations":{},"env":[{"name":"RUST_LOG","value":"warn"}],"labels":{},"podAnnotations":{},"podLabels":{},"service":{"annotations":{}},"volumeClaimTemplates":{"storage":"16Gi"}}` | Autoscaling & resources for the `logfire-ff-ingest` pod |
| logfire-ff-ingest-processor | object | `{"annotations":{},"env":[{"name":"RUST_LOG","value":"warn"}],"labels":{},"podAnnotations":{},"podLabels":{},"service":{"annotations":{}}}` | Autoscaling & resources for the `logfire-ff-ingest-processor` pod |
| logfire-ff-ingest-processor.annotations | object | `{}` | Workload annotations |
| logfire-ff-ingest-processor.env | list | `[{"name":"RUST_LOG","value":"warn"}]` | Extra env vars for the ingest processor pod |
| logfire-ff-ingest-processor.labels | object | `{}` | Workload labels |
| logfire-ff-ingest-processor.podAnnotations | object | `{}` | Pod annotations |
| logfire-ff-ingest-processor.podLabels | object | `{}` | Pod labels |
| logfire-ff-ingest-processor.service.annotations | object | `{}` | Service annotations |
| logfire-ff-ingest.annotations | object | `{}` | Workload annotations |
| logfire-ff-ingest.env | list | `[{"name":"RUST_LOG","value":"warn"}]` | Extra env vars for the ingest pod |
| logfire-ff-ingest.labels | object | `{}` | Workload labels |
| logfire-ff-ingest.podAnnotations | object | `{}` | Pod annotations |
| logfire-ff-ingest.podLabels | object | `{}` | Pod labels |
| logfire-ff-ingest.service.annotations | object | `{}` | Service annotations |
| logfire-ff-ingest.volumeClaimTemplates | object | `{"storage":"16Gi"}` | Configuration for the StatefulSet PersistentVolumeClaim template |
| logfire-ff-ingest.volumeClaimTemplates.storage | string | `"16Gi"` | Storage provisioned for each pod |
| logfire-ff-maintenance-scheduler | object | `{"env":[]}` | Environment overrides for the maintenance scheduler pod |
| logfire-ff-query-api | object | `{"env":[]}` | Environment overrides for the query API pod |
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
| logfire-redis.readinessProbe | object | `{"initialDelaySeconds":5,"periodSeconds":10,"tcpSocket":{"port":"redis"},"timeoutSeconds":1}` | Redis readiness probe. Override or set to null to disable. |
| logfire-redis.resources | object | `{}` | Resource requests/limits. Supports the chart shorthand, for example:   cpu: "100m"   memory: "128Mi" or native requests/limits. |
| logfire-redis.startupProbe | object | `{"failureThreshold":30,"periodSeconds":10,"tcpSocket":{"port":"redis"},"timeoutSeconds":1}` | Redis startup probe. Override or set to null to disable. |
| logfire-redis.tolerations | list | `[]` | Tolerations for the bundled Redis pod. |
| logfire-redis.topologySpreadConstraints | list | `[]` | Topology spread constraints for the bundled Redis pod. |
| logfire-remote-mcp | object | `{"enabled":true}` | Autoscaling & resources for the `logfire-remote-mcp` pod |
| logfire-remote-mcp.enabled | bool | `true` | Enable the remote MCP service. When disabled, the deployment is not rendered and the `/mcp` and `/.well-known/oauth-protected-resource/mcp` haproxy routes are removed. |
| maildev | object | `{"image":{"pullPolicy":"IfNotPresent","repository":"maildev/maildev","tag":"latest"},"podSecurityContext":{},"securityContext":{}}` | MailDev configuration (only used when `dev.deployMaildev` is true) |
| maildev.podSecurityContext | object | `{}` | Pod SecurityContext for the MailDev pod. Defaults to the chart-wide `podSecurityContext` when unset. |
| maildev.securityContext | object | `{}` | Container SecurityContext for the MailDev container. Defaults to the chart-wide `securityContext` when unset. Set this when running under a restricted PodSecurity policy, e.g.:   runAsNonRoot: true   runAsUser: 1000   allowPrivilegeEscalation: false   capabilities:     drop: ["ALL"]   seccompProfile:     type: RuntimeDefault |
| minio.args[0] | string | `"server"` |  |
| minio.args[1] | string | `"/data"` |  |
| minio.auth.rootPassword | string | `"logfire-minio"` |  |
| minio.auth.rootUser | string | `"logfire-minio"` |  |
| minio.command[0] | string | `"minio"` |  |
| minio.console.image.registry | string | `"docker.io"` |  |
| minio.console.image.repository | string | `"bitnamilegacy/minio-object-browser"` |  |
| minio.fullnameOverride | string | `"logfire-minio"` |  |
| minio.image.registry | string | `"docker.io"` |  |
| minio.image.repository | string | `"bitnamilegacy/minio"` |  |
| minio.lifecycleHooks.postStart.exec.command[0] | string | `"sh"` |  |
| minio.lifecycleHooks.postStart.exec.command[1] | string | `"-c"` |  |
| minio.lifecycleHooks.postStart.exec.command[2] | string | `"# Wait for the server to start\nsleep 5\n# Create a bucket\nmc alias set local http://localhost:9000 logfire-minio logfire-minio\nmc mb local/logfire\nmc anonymous set public local/logfire\n"` |  |
| minio.persistence.mountPath | string | `"/data"` |  |
| minio.persistence.size | string | `"32Gi"` |  |
| nodeSelector | object | `{}` | Node selector applied to all workloads |
| objectStore | object | `{"env":{},"sseCKeyB64":null,"uri":null,"volumeMounts":[],"volumes":[]}` | Object storage details |
| objectStore.env | object | `{}` | Additional environment variables for the object store connection |
| objectStore.sseCKeyB64 | string | `nil` | Opt-in S3 Server-Side Encryption with Customer-provided Keys (SSE-C). Base64-encoded 256-bit key applied to all S3 PUT/GET/HEAD/multipart/copy requests. Only used when the object store is S3. Can be a plain string or a map with valueFrom (e.g., secretKeyRef).  IMPORTANT: this MUST be set from day one on an empty bucket. Enabling it on a bucket that already contains FusionFire data will break all reads of the pre-existing objects. losing the key means losing the data — AWS does not store it. |
| objectStore.uri | string | `nil` | URI for object storage (e.g., `s3://bucket`) |
| objectStore.volumeMounts | list | `[]` | Volume mounts for object store credentials |
| objectStore.volumes | list | `[]` | Volumes for object store credentials |
| otelResourceAttributes | object | `{}` | Additional OTEL resource attributes to stamp onto internal telemetry emitted by Logfire workloads. These are merged on top of the chart defaults and can override them. Example:   deployment.environment.name: prod   service.namespace: logfire |
| otel_collector | object | `{"exporter":{"endpoint":"http://logfire-ff-ingest:8012","headers":{},"tls":{"insecure":true}},"image":{"pullPolicy":"IfNotPresent","repository":"ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib","tag":"0.152.0"},"prometheus":{"add_metric_suffixes":false,"enable_open_metrics":true,"enabled":false,"endpoint":"0.0.0.0","metric_expiration":"180m","port":9090,"resource_to_telemetry_conversion":{"enabled":true},"send_timestamp":true}}` | otel-collector configuration |
| otel_collector.exporter | object | `{"endpoint":"http://logfire-ff-ingest:8012","headers":{},"tls":{"insecure":true}}` | exporter configuration for the otlp_http exporter Override these to send telemetry data to a different OTLP-compatible destination. |
| podSecurityContext | object | `{}` | Pod SecurityContext (https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-pod) See: https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context for details |
| postgresDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/crud"` | Postgres DSN used for the `crud` database |
| postgresFFDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/ff"` | Postgres DSN used for the `ff` database |
| postgresSecret | object | `{"annotations":{},"enabled":false,"name":""}` | User-provided Secret containing database credentials Must include `postgresDsn` and `postgresFFDsn` keys. |
| postgresSecret.annotations | object | `{}` | Optional workload annotations for external Secret reload controllers.    Rendered on workloads that consume this existing Secret; not applied to Secret metadata.    Per-workload `annotations` override duplicate keys. |
| postgresSecret.enabled | bool | `false` | Set to true to use an existing Secret (recommended for Argo CD users). |
| postgresSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
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
| redisDsn | string | `"redis://logfire-redis:6379"` | Redis DSN. Change if using an external Redis instance. |
| revisionHistoryLimit | int | `2` | Number of deployment revisions to keep. See: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#clean-up-policy) May be set to 0 when using a GitOps workflow. |
| securityContext | object | `{}` | Container SecurityContext (https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-container) See: https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context-1 for details |
| serviceAccount | object | `{"annotations":{},"create":false,"name":""}` | ServiceAccount configuration |
| serviceAccount.annotations | object | `{}` | Annotations to add to the ServiceAccount (e.g., for IAM roles) Example for AWS IRSA:   annotations:     eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/my-role Example for GCP Workload Identity:   annotations:     iam.gke.io/gcp-service-account: my-sa@my-project.iam.gserviceaccount.com |
| serviceAccount.create | bool | `false` | Create a ServiceAccount |
| serviceAccount.name | string | `""` | Name of the ServiceAccount. If not set and create is true, a name is generated using the fullname template. If create is false and this is not set, the default ServiceAccount is used. |
| serviceAccountName | string | `"default"` | DEPRECATED: Use serviceAccount.name instead. Kept for backward compatibility. @deprecated |
| sizingPreset | string | `""` | Workload sizing preset. Leave empty to skip preset sizing, or set to `large`, `standard`, `small`, or `tiny` to apply built-in customer sizing defaults. |
| smtp.host | string | `nil` | SMTP server hostname |
| smtp.password | string | `nil` | SMTP password. Can be a plain string or a map with valueFrom (e.g., secretKeyRef). |
| smtp.port | int | `25` | SMTP server port |
| smtp.use_tls | bool | `false` | Use TLS for SMTP |
| smtp.username | string | `nil` | SMTP username. Can be a plain string or a map with valueFrom (e.g., secretKeyRef). |
| tokenRedis | object | `{"dsn":"","prefix":""}` | Redis settings for auth token caches. Empty DSN falls back to `redisDsn`. Use a prefix only when sharing one Redis instance with other data. |
| tokenRedis.dsn | string | `""` | Redis DSN for auth token caches. |
| tokenRedis.prefix | string | `""` | Key prefix for auth token cache keys. |
| tolerations | list | `[]` | Tolerations applied to all workloads |
| topologySpreadConstraints | list | `[]` | topologySpreadConstraints applied to all workloads |
| usageRedis | object | `{"dsn":"","prefix":""}` | Redis settings for usage, autocomplete, and rate limiting data. Empty DSN falls back to `redisDsn`. Use a prefix only when sharing one Redis instance with other data. |
| usageRedis.dsn | string | `""` | Redis DSN for usage, autocomplete, and rate limiting data. |
| usageRedis.prefix | string | `""` | Key prefix for usage keys. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
