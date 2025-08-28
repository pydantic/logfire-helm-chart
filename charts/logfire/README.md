# logfire

![Version: 0.8.4](https://img.shields.io/badge/Version-0.8.4-informational?style=flat-square) ![AppVersion: b0c84812](https://img.shields.io/badge/AppVersion-b0c84812-informational?style=flat-square)

Helm chart for self-hosted Pydantic Logfire

This chart exists as public documentation of how to set up and run self-hosted Pydantic Logfire but requires an image pull key to actually use.
**Self-hosted Logfire is an Enterprise offering that requires a contract and payment, it is not free software**. Please contact sales@pydantic.dev to discuss setting up a contract and pricing.

## Local Quickstart (Evaluation & Testing)

For a fast, local setup to evaluate Logfire, follow our [Local Quickstart Guide](https://logfire.pydantic.dev/docs/reference/self-hosted/local-quickstart/).
It uses development-grade dependencies like an in-cluster PostgreSQL, MinIO and MailDev to get you up and running in minutes.

## Production installation

For a production-ready deployment, you'll need to connect to your own infrastructure (PostgreSQL, Object Storage, etc.). Our complete guide walks you through every prerequisite and configuration step.
Check out the full [Self Hosted Installation Guide](https://logfire.pydantic.dev/docs/reference/self-hosted/installation/)

## Chart installation

``` sh
$ helm repo add pydantic https://charts.pydantic.dev/
$ helm upgrade --install logfire pydantic/logfire
```

## Prerequisites

There are a number of Pydantic Logfire external prerequisites including PostgreSQL, Dex and Object Storage.

### Image Secrets

You will require image pull secrets to pull down the docker images from our private repository. Contact us at [sales@pydantic.dev](mailto:sales@pydantic.dev) to get a copy of them.

When you have the `key.json` file you can load it in as a secret like so:

```
kubectl create secret docker-registry logfire-image-key \
  --docker-server=us-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat key.json)" \
  --docker-email=YOUR-EMAIL@example.com
```

Then you can either configure your [service account](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#add-imagepullsecrets-to-a-service-account) to use them or specify this in `values.yaml` under `imagePullSecrets`:

```yaml
imagePullSecrets:
  - logfire-image-key
```

### Hostnames

There is at least a hostname that is required to be set: I.e, `logfire.example.com`. Set via the `ingress.hostnames` value.

We have an ingress configuration that will allow you to set up ingress:

```yaml
ingress:
  enabled: true
  tls: true
  hostnames:
  - logfire.example.com
  ingressClassName: nginx
```

#### Using the direct service

We expose a service called `logfire-service` which will route traffic appropriately.

If you don't want to use the ingress controller, you will still need to define hostnames and whether you are externally using TLS:

I.e, this config will turn off the ingress resource, but still set appropriate cors headers for the `logfire-service`:

```yaml
ingress:
  # this turns off the ingress resource
  enabled: false
  # used to ensure appropriate CORS headers are set.  If your browser is accessing it on https, then needs to be enabled here
  tls: true
  # used to ensure appropriate CORS headers are set.
  hostnames:
  - logfire.example.com
```

If you are *not* using kubernetes ingress, you must still set the hostnames under the `ingress` configuration.

### Dex

Dex is used as the identity service for logfire & can be configured for many different types of connectors.  The full list of connectors can be found here: [https://dexidp.io/docs/connectors/](https://dexidp.io/docs/connectors/)

We have some connector examples at our [Auth Examples](https://logfire.pydantic.dev/docs/reference/self-hosted/examples/#Auth) section

There is some default configuration provided in `values.yaml`.

#### Authentication Configuration

Depending on what [connector you want to use](https://dexidp.io/docs/connectors/), you can configure dex connectors accordingly.

:envelope: Note: when creating an app in a provider, you should set the RedirectURI/Callback URL to ```<logfire_url>/auth-api/callback```, where ```<logfire_url>``` is your hostname with scheme, like ```https://logfire-example.com/auth-api/callback```

Here's an example using `github` as a connector:

```yaml
logfire-dex:
  ...
  config:
    connectors:
      - type: "github"
        id: "github"
        name: "GitHub"
        config:
          # You get clientID and clientSecret by creating a GitHub OAuth App
          # See https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app
          clientID: client_id
          clientSecret: client_secret
```

To use GitHub as an example, you can find general instructions for creating an OAuth app [in the GitHub docs](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app).

Dex allows configuration parameters to reference environment variables.
This can be done by using the `$` symbol.  For example, the `clientID` and `clientSecret` can be set as environment variables:

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
      - type: "github"
        id: "github"
        name: "GitHub"
        config:
          clientID: $GITHUB_CLIENT_ID
          clientSecret: $GITHUB_CLIENT_SECRET
          getUserInfo: true
```

You would have to manually (or via IaC, etc.) create `my-github-secret`.
This allows you to avoid putting any secrets into a `values.yaml` file.

### Object Storage

Pydantic Logfire requires Object Storage to store data.  There are a number of different integrations that can be used:

* Amazon S3
* Google Cloud Storage
* Azure Storage

Each has their own set of environment variables that can be used to configure them. However if your kubernetes service account has the appropriate credentials, that be used by setting `serviceAccountName`.

#### Amazon S3

Variables extracted from environment:

 * `AWS_ACCESS_KEY_ID` -> access_key_id
 * `AWS_SECRET_ACCESS_KEY` -> secret_access_key
 * `AWS_DEFAULT_REGION` -> region
 * `AWS_ENDPOINT` -> endpoint
 * `AWS_SESSION_TOKEN` -> token
 * `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` -> <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html>
 * `AWS_ALLOW_HTTP` -> set to "true" to permit HTTP connections without TLS

Example:

```yaml
objectStore:
  uri: s3://<bucket_name>
  # Note: not needed if the service account specified by `serviceAccountName` itself has credentials
  env:
    AWS_DEFAULT_REGION: <region>
    AWS_SECRET_ACCESS_KEY:
      valueFrom:
        secretKeyRef:
          name: my-aws-secret
          key: secret-key
    AWS_ACCESS_KEY_ID: <access_key>
```

#### Google Cloud Storage

Variables extracted from environment:

 * `GOOGLE_SERVICE_ACCOUNT`: location of service account file
 * `GOOGLE_SERVICE_ACCOUNT_PATH`: (alias) location of service account file
 * `SERVICE_ACCOUNT`: (alias) location of service account file
 * `GOOGLE_SERVICE_ACCOUNT_KEY`: JSON serialized service account key
 * `GOOGLE_BUCKET`: bucket name
 * `GOOGLE_BUCKET_NAME`: (alias) bucket name

Example:

```yaml
objectStore:
  uri: gs://<bucket>
  # Note: not needed if the service account specified by `serviceAccountName` itself has credentials
  env:
    GOOGLE_SERVICE_ACCOUNT_PATH: /path/to/service/account
```

#### Azure Storage

Variables extracted from environment:

 * `AZURE_STORAGE_ACCOUNT_NAME`: storage account name
 * `AZURE_STORAGE_ACCOUNT_KEY`: storage account master key
 * `AZURE_STORAGE_ACCESS_KEY`: alias for AZURE_STORAGE_ACCOUNT_KEY
 * `AZURE_STORAGE_CLIENT_ID`: client id for service principal authorization
 * `AZURE_STORAGE_CLIENT_SECRET`: client secret for service principal authorization
 * `AZURE_STORAGE_TENANT_ID`: tenant id used in oauth flows

Example:

```yaml
objectStore:
  uri: az://<container_name>
  env:
    AZURE_STORAGE_ACCOUNT_NAME: <storage_account_name>
    AZURE_STORAGE_ACCOUNT_KEY:
      valueFrom:
        secretKeyRef:
          name: my-azure-secret
          key: account-key
```

### PostgreSQL

Pydantic Logfire nominally needs 3 separate PostgreSQL databases: `crud`, `ff`, and `dex`.  Each will need a user with owner permissions to allow migrations to run.
While they can all be ran on the same instance, they are required to be separate databases to prevent naming/schema collisions.

Here's an example set of values using `postgres.example.com` as the host:

```yaml
postgresDsn: postgres://postgres:postgres@postgres.example.com:5432/crud
postgresFFDsn: postgres://postgres:postgres@postgres.example.com:5432/ff

dex:
  ...
  # note that the dex chart does not use the uri style connector
  config:
    storage:
      type: postgres
      config:
        host: postgres.example.com
        port: 5432
        user: postgres
        database: dex
        password: postgres
        ssl:
          mode: disable
```

### Email

Pydantic Logfire uses SMTP to send emails.  You will need to configure email using the following values:

```yaml
smtp:
  host: smtp.example.com
  port: 25
  username: user
  password: pass
  use_tls: false
```

### AI

Pydantic Logfire AI features can be enabled by setting the `ai` configuration in `values.yaml`.
You need to specify the model provider and model name you want to use:

```yaml
ai:
  model: provider:model-name
  openAi:
    apiKey: openai-api-key
  vertexAi:
    region: region  # Optional, only needed for Vertex AI if not using default region
  azureOpenAi:
    endpoint: azure-openai-endpoint
    apiKey: azure-openai-api-key
    apiVersion: azure-openai-api-version
```

## Configuring Logfire

Once your self-hosted instance is running, configure your client SDK to send data to your new endpoint by setting the ```base_url``` to send data to.

```python
import logfire

logfire.configure(
    token='<your_logfire_token>',
    advanced=logfire.AdvancedOptions(base_url="https://logfire.example.com")
)
logfire.info('Hello, {place}!', place='World')
```

## Scaling

Logfire is designed to be horizontally scalable. You can adjust the replica counts and resources for each component to handle your specific workload.

This is how you can configure each service:

```yaml
<service_name>:
  # -- Number of pod replicas
  replicas: 1
  # -- Resource limits and allocations
  resources:
    cpu: "1"
    memory: "1Gi"
  # -- Autoscaler settings
  autoscaling:
    minReplicas: 2
    maxReplicas: 4
    memAverage: 65
    cpuAverage: 20
```

See our [`Scaling guide`](https://logfire.pydantic.dev/docs/reference/self-hosted/scaling/) for some production level values and DB recommended settings.

## Troubleshooting & Support

* Troubleshooting Guide: If you encounter issues, your first stop should be the [Troubleshooting Self Hosted guide](https://logfire.pydantic.dev/docs/reference/self-hosted/troubleshooting/), which includes common issues and steps for accessing internal logs.

* GitHub Issues: If your issue persists, please open up an issue with details about your deployment (Chart version, Kubernetes version, values file, any relevant error logs).

* Enterprise Support: For commercial support, contact us at [sales@pydantic.dev](mailto:sales@pydantic.dev).
# logfire

![Version: 0.8.4](https://img.shields.io/badge/Version-0.8.4-informational?style=flat-square) ![AppVersion: b0c84812](https://img.shields.io/badge/AppVersion-b0c84812-informational?style=flat-square)

Helm chart for self-hosted Pydantic Logfire

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| https://charts.bitnami.com/bitnami | minio | 17.0.16 |
| https://charts.bitnami.com/bitnami | postgresql | 16.7.21 |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| adminEmail | string | `"hello@example.dev"` | Starter admin email address |
| adminSecret | object | `{"annotations":{},"enabled":false,"name":""}` | Existing Secret with the following keys:  - logfire-admin-password  - logfire-admin-totp-secret  - logfire-admin-totp-recovery-codes (string containing a JSON list) |
| adminSecret.annotations | object | `{}` | Optional annotations for the Secret (e.g., for external secret managers). |
| adminSecret.enabled | bool | `false` | Use an existing Secret (recommended for Argo CD users). |
| adminSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| affinity | object | `{}` | Node/Pod affinity applied to all workloads |
| ai.azureOpenAi.apiKey | string | `nil` | Azure OpenAI API key |
| ai.azureOpenAi.apiVersion | string | `nil` | Azure OpenAI API version |
| ai.azureOpenAi.endpoint | string | `nil` | Azure OpenAI endpoint |
| ai.model | string | `nil` | AI provider+model string. Prefix the model with the provider (e.g., `azure:gpt-4o`). See https://ai.pydantic.dev/models/ for more information. |
| ai.openAi.apiKey | string | `nil` | OpenAI API key |
| ai.vertexAi.region | string | `nil` | Vertex AI region |
| dev.deployMaildev | bool | `false` | Deploy MailDev to test emails |
| dev.deployMinio | bool | `false` | Use a local MinIO instance as object storage (NOT for production) |
| dev.deployPostgres | bool | `false` | Deploy internal Postgres (NOT for production) |
| existingSecret | object | `{"annotations":{},"enabled":false,"name":""}` | Existing Secret with the following keys:  - logfire-dex-client-secret  - logfire-meta-write-token  - logfire-meta-frontend-token  - logfire-jwt-secret |
| existingSecret.annotations | object | `{}` | Optional annotations for the Secret (e.g., for external secret managers). |
| existingSecret.enabled | bool | `false` | Use an existing Secret (recommended for Argo CD users). |
| existingSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| hooksAnnotations | string | `nil` | Custom annotations for migration Jobs (uncomment as needed, e.g., with Argo CD hooks) |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| imagePullSecrets | list | `[]` | Image pull secrets used by all pods |
| ingress.annotations | object | `{}` | Ingress annotations |
| ingress.enabled | bool | `true` | Enable the Ingress resource. If you are NOT using an ingress resource, you still need to set `tls` and `hostnames` so the application can generate correct URLs/CORS. |
| ingress.hostname | string | `"logfire.example.com"` | DEPRECATED (kept for backward compatibility). Use `hostnames` (list) for all new deployments. |
| ingress.hostnames | list | `["logfire.example.com"]` | Hostname(s) for Pydantic Logfire. Preferred method. Supports one or more hostnames; put the primary domain first. |
| ingress.ingressClassName | string | `""` | IngressClass to use (e.g., nginx), if not specified, default ingress class will be used (https://kubernetes.io/docs/concepts/services-networking/ingress/#default-ingress-class) |
| ingress.secretName | string | `"logfire-frontend-cert"` | TLS Secret name if you want to do a custom one |
| ingress.tls | bool | `false` | Enable TLS/HTTPS. Required for correct CORS behavior. |
| logfire-dex | object | `{"annotations":{},"config":{"connectors":[],"enablePasswordDB":true,"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}},"podAnnotations":{},"replicas":1,"resources":{"cpu":"1","memory":"1Gi"},"service":{"annotations":{}}}` | Configuration, autoscaling & resources for `logfire-dex` deployment |
| logfire-dex.annotations | object | `{}` | Workload annotations |
| logfire-dex.config | object | `{"connectors":[],"enablePasswordDB":true,"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}}` | Dex configuration (see https://dexidp.io/docs/) |
| logfire-dex.config.connectors | list | `[]` | Dex auth connectors (see https://dexidp.io/docs/connectors/) The redirectURI can be omitted—it will be generated automatically. If specified, the custom value will be honored. |
| logfire-dex.config.enablePasswordDB | bool | `true` | Enable password authentication. Set to false if undesired, but ensure another connector is configured first. |
| logfire-dex.config.storage | object | `{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}` | Dex storage configuration (see https://dexidp.io/docs/configuration/storage/) |
| logfire-dex.podAnnotations | object | `{}` | Pod annotations |
| logfire-dex.replicas | int | `1` | Number of replicas |
| logfire-dex.resources | object | `{"cpu":"1","memory":"1Gi"}` | Resource requests/limits |
| logfire-dex.service.annotations | object | `{}` | Service annotations |
| logfire-ff-ingest | object | `{"annotations":{},"podAnnotations":{},"service":{"annotations":{}},"volumeClaimTemplates":{"storage":"16Gi"}}` | Autoscaling & resources for the `logfire-ff-ingest` pod |
| logfire-ff-ingest-processor | object | `{"annotations":{},"podAnnotations":{},"service":{"annotations":{}}}` | Autoscaling & resources for the `logfire-ff-ingest-processor` pod |
| logfire-ff-ingest-processor.annotations | object | `{}` | Workload annotations |
| logfire-ff-ingest-processor.podAnnotations | object | `{}` | Pod annotations |
| logfire-ff-ingest-processor.service.annotations | object | `{}` | Service annotations |
| logfire-ff-ingest.annotations | object | `{}` | Workload annotations |
| logfire-ff-ingest.podAnnotations | object | `{}` | Pod annotations |
| logfire-ff-ingest.service.annotations | object | `{}` | Service annotations |
| logfire-ff-ingest.volumeClaimTemplates | object | `{"storage":"16Gi"}` | Configuration for the StatefulSet PersistentVolumeClaim template |
| logfire-ff-ingest.volumeClaimTemplates.storage | string | `"16Gi"` | Storage provisioned for each pod |
| logfire-redis.enabled | bool | `true` | Deploy Redis as part of this chart. Disable to use an external Redis instance. |
| logfire-redis.image | object | `{"pullPolicy":"IfNotPresent","repository":"redis","tag":"7.2"}` | Redis image configuration |
| logfire-redis.image.pullPolicy | string | `"IfNotPresent"` | Redis image pull policy |
| logfire-redis.image.repository | string | `"redis"` | Redis image repository |
| logfire-redis.image.tag | string | `"7.2"` | Redis image tag |
| minio.args[0] | string | `"server"` |  |
| minio.args[1] | string | `"/data"` |  |
| minio.auth.rootPassword | string | `"logfire-minio"` |  |
| minio.auth.rootUser | string | `"logfire-minio"` |  |
| minio.command[0] | string | `"minio"` |  |
| minio.fullnameOverride | string | `"logfire-minio"` |  |
| minio.lifecycleHooks.postStart.exec.command[0] | string | `"sh"` |  |
| minio.lifecycleHooks.postStart.exec.command[1] | string | `"-c"` |  |
| minio.lifecycleHooks.postStart.exec.command[2] | string | `"# Wait for the server to start\nsleep 5\n# Create a bucket\nmc alias set local http://localhost:9000 logfire-minio logfire-minio\nmc mb local/logfire\nmc anonymous set public local/logfire\n"` |  |
| minio.persistence.mountPath | string | `"/data"` |  |
| minio.persistence.size | string | `"32Gi"` |  |
| nodeSelector | object | `{}` | Node selector applied to all workloads |
| objectStore | object | `{"env":{},"uri":null}` | Object storage details |
| objectStore.env | object | `{}` | Additional environment variables for the object store connection |
| objectStore.uri | string | `nil` | URI for object storage (e.g., `s3://bucket`) |
| otel_collector | object | `{"prometheus":{"add_metric_suffixes":false,"enable_open_metrics":true,"enabled":false,"endpoint":"0.0.0.0","metric_expiration":"180m","port":9090,"resource_to_telemetry_conversion":{"enabled":true},"send_timestamp":true}}` | otel-collector configuration |
| podSecurityContext | object | `{}` | Pod SecurityContext (https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-pod) See: https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context for details |
| postgresDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/crud"` | Postgres DSN used for the `crud` database |
| postgresFFDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/ff"` | Postgres DSN used for the `ff` database |
| postgresSecret | object | `{"annotations":{},"enabled":false,"name":""}` | User-provided Secret containing database credentials Must include `postgresDsn` and `postgresFFDsn` keys. |
| postgresSecret.annotations | object | `{}` | Optional annotations for the Secret (e.g., for external secret managers). |
| postgresSecret.enabled | bool | `false` | Set to true to use an existing Secret (recommended for Argo CD users). |
| postgresSecret.name | string | `""` | Name of the Kubernetes Secret resource. |
| postgresql.auth.postgresPassword | string | `"postgres"` |  |
| postgresql.fullnameOverride | string | `"logfire-postgres"` |  |
| postgresql.postgresqlDataDir | string | `"/var/lib/postgresql/data/pgdata"` |  |
| postgresql.primary.initdb.scripts."create_databases.sql" | string | `"CREATE DATABASE crud;\nCREATE DATABASE dex;\nCREATE DATABASE ff;\n"` |  |
| postgresql.primary.persistence.mountPath | string | `"/var/lib/postgresql"` |  |
| postgresql.primary.persistence.size | string | `"10Gi"` |  |
| postgresql.primary.resourcesPreset | string | `"small"` |  |
| priorityClassName | string | `""` | Pod priority class See: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#pod-priority). |
| redisDsn | string | `"redis://logfire-redis:6379"` | Redis DSN. Change if using an external Redis instance. |
| revisionHistoryLimit | int | `2` | Number of deployment revisions to keep. See: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#clean-up-policy) May be set to 0 when using a GitOps workflow. |
| securityContext | object | `{}` | Container SecurityContext (https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-container) See: https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context-1 for details |
| serviceAccountName | string | `"default"` | ServiceAccount used by pods |
| smtp.host | string | `nil` | SMTP server hostname |
| smtp.password | string | `nil` | SMTP password |
| smtp.port | int | `25` | SMTP server port |
| smtp.use_tls | bool | `false` | Use TLS for SMTP |
| smtp.username | string | `nil` | SMTP username |
| tolerations | list | `[]` | Tolerations applied to all workloads |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
