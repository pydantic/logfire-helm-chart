# logfire

![Version: 0.1.11](https://img.shields.io/badge/Version-0.1.11-informational?style=flat-square) ![AppVersion: 796a41fb](https://img.shields.io/badge/AppVersion-796a41fb-informational?style=flat-square)

Helm chart for self-hosted Logfire

## Chart installation

``` sh
$ helm repo add pydantic https://charts.pydantic.dev/
$ helm upgrade --install logfire pydantic/logfire
```

## Prerequisites

There are a number of logfire external prerequisites including PostgreSQL, Dex and Object Storage.

### Image Secrets

You will require image pull secrets to pull down the docker images from our private repository.  Get in contact with us to get a copy of them.

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

There is a hostname that is required to be set: I.e, `logfire.example.com`. Set via the `ingress.hostname` value.

We have an ingress configuration that will allow you to set up ingress:

```yaml
ingress:
  enabled: true
  tls: true
  hostname: logfire.example.com
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
  hostname: logfire.example.com
```

If you are *not* using kubernetes ingress, you must still set the hostnames under the `ingress` configuration.

### Dex

Dex is used as the identity service for logfire & can be configured for many different types of connectors.  The full list of connectors can be found here: [https://dexidp.io/docs/connectors/](https://dexidp.io/docs/connectors/)

There is some default configuration provided in `values.yaml`.

#### Authentication Configuration

Depending on what [connector you want to use](https://dexidp.io/docs/connectors/), you can configure dex connectors accordingly.

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
          getUserInfo: true
```

To use GitHub as an example, you can find general instructions for creating an OAuth app [in the GitHub docs](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app).
It should look something like this:

![GitHub OAuth App Example](https://raw.githubusercontent.com/pydantic/logfire-helm-chart/refs/heads/main/docs/images/local-github-oauth-app.png)

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

#### Image pull secrets

Remember to add the image pull secrets to dex's service account `logfire-dex` if you're not using `imagePullSecrets`.

We recommend you set secrets as Kubernetes secrets and reference them in the `values.yaml` file instead of hardcoding secrets which is more likely to be exposed and harder to rotate.

### Object Storage

Logfire requires Object Storage to store data.  There are a number of different integrations that can be used:

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

Logfire nominally needs 4 separate PostgreSQL databases: `crud`, `ff`, `ingest` and `dex`.  Each will need a user with owner permissions to allow migrations to run.
  While they can all be ran on the same instance, they are required to be separate databases to prevent naming/schema collisions.

Here's an example set of values using `postgres.example.com` as the host:

```yaml
postgresDsn: postgres://postgres:postgres@postgres.example.com:5432/crud
postgresFFDsn: postgres://postgres:postgres@postgres.example.com:5432/ff
postgresIngestDsn: postgres://postgres:postgres@postgres.example.com:5432/ingest

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

Logfire uses SMTP to send emails.  You will need to configure email using the following values:

```yaml
smtp:
  host: smtp.example.com
  port: 25
  username: user
  password: pass
  use_tls: false
```

### AI

Logfire AI features can be enabled by setting the `ai` configuration in `values.yaml`.
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

## Scaling

A number of components within logfire allow containers/pods to be horizontally scaled. Also: depending on your setup you may want a number of replicas to run to ensure redundancy if a node fails.

Each service has both resources and autoscaling configured in the same way:

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

See [`values.yaml`](./values.yaml) for some production level values

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| ai.azureOpenAi.apiKey | string | `nil` | The Azure OpenAI API key |
| ai.azureOpenAi.apiVersion | string | `nil` | The Azure OpenAI API version |
| ai.azureOpenAi.endpoint | string | `nil` | The Azure OpenAI endpoint |
| ai.model | string | `nil` | The AI provide and model to use |
| ai.openAi.apiKey | string | `nil` | The OpenAI API key |
| ai.vertexAi.region | string | `nil` | The region for Vertex AI |
| dev | object | `{"deployMaildev":false,"deployMinio":false,"deployPostgres":false}` | Development mode settings |
| dev.deployMaildev | bool | `false` | Deploy maildev for testing emails |
| dev.deployMinio | bool | `false` | Do NOT use this in production! |
| dev.deployPostgres | bool | `false` | Do NOT use this in production! |
| image.pullPolicy | string | `"IfNotPresent"` | The pull policy for docker images |
| imagePullSecrets | list | `[]` | The secret used to pull down container images for pods |
| ingress.annotations | object | `{}` | Any annotations required. |
| ingress.enabled | bool | `false` | Enable Ingress Resource. If you're not using an ingress resource, you still need to configure `tls`, `hostname` |
| ingress.hostname | string | `"logfire.example.com"` | The hostname used for Logfire |
| ingress.ingressClassName | string | `"nginx"` |  |
| ingress.tls | bool | `false` | Enable TLS/HTTPS connections.  Required for CORS headers |
| logfire-dex | object | `{"config":{"connectors":[],"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}},"replicas":1,"resources":{"cpu":"1","memory":"1Gi"}}` | Configuration, autoscaling & resources for `logfire-dex` deployment |
| logfire-dex.config | object | `{"connectors":[],"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}}` | Dex Config |
| logfire-dex.config.connectors | list | `[]` | Dex auth connectors, see https://dexidp.io/docs/connectors/ redirectURI config option can be omitted, as it will be automatically generated however if specified, the custom value will be honored |
| logfire-dex.config.storage | object | `{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}` | Dex storage configuration, see https://dexidp.io/docs/configuration/storage/ |
| logfire-dex.replicas | int | `1` | Number of replicas |
| logfire-dex.resources | object | `{"cpu":"1","memory":"1Gi"}` | resources |
| logfire-redis.enabled | bool | `true` | Enable redis as part of this helm chart |
| objectStore | object | `{"env":{},"uri":null}` | Object storage details |
| objectStore.env | object | `{}` | additional env vars for the object store connection |
| objectStore.uri | string | `nil` | Uri for object storage i.e, `s3://bucket` |
| podSecurityContext | object | `{}` | Pod [security context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-pod). See the [API reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context) for details. |
| postgresDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/crud"` | Postgres DSN used for `crud` database |
| postgresFFDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/ff"` | Postgres DSN used for `ff` database |
| postgresIngestDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/ingest"` | Postgres DSN used for `ingest` database |
| postgresJSONSecret | object | `{"enabled":false,"name":""}` | User provided postgres credentials formatted as JSON string  this secret will be autogenerated from values or postgresSecret, however, autogeneration requires a lookup for an existing secret, in case where that is not possible, such as apply with `helm template` use this setting to pass an existing secret with the correct format must contain `postgresIngestDsn` key containing a JSON list like: ["postgres://postgres:postgres@logfire-postgres:5432/ingest"] |
| postgresJSONSecret.enabled | bool | `false` | Whether to use an existing secret |
| postgresJSONSecret.name | string | `""` | Secret name |
| postgresSecret | object | `{"enabled":false,"name":""}` | User provided postgres credentials containing `postgresDsn`, `postgresFFDsn`, `postgresIngestDsn` keys |
| postgresSecret.enabled | bool | `false` | Whether to use an existing secret |
| postgresSecret.name | string | `""` | Secret name |
| priorityClassName | string | `""` | Specify a priority class name to set [pod priority](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#pod-priority). |
| redisDsn | string | `"redis://logfire-redis:6379"` | The DSN for redis.  Change from default if you have an external redis instance |
| revisionHistoryLimit | int | `2` | Define the [count of deployment revisions](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#clean-up-policy) to be kept. May be set to 0 in case of GitOps deployment approach. |
| securityContext | object | `{}` | Container [security context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-container). See the [API reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context-1) for details. |
| serviceAccountName | string | `"default"` | the Kubernetes Service Account that is used by the pods |
| smtp.host | string | `nil` | Hostname of the SMTP server |
| smtp.password | string | `nil` | SMTP password |
| smtp.port | int | `25` | Port of the SMTP server |
| smtp.use_tls | bool | `false` | Whether to use TLS |
| smtp.username | string | `nil` | SMTP username |

## Configuring Logfire

Since this is self-hosted you will need to update your logfire configuration to include a different URL to send data to.  You can do this by specifying the `base_url` in advanced config:

```python
import logfire

logfire.configure(
    token='<your_logfire_token>',
    advanced=logfire.AdvancedOptions(base_url="https://logfire.example.com")
)
logfire.info('Hello, {place}!', place='World')
```

## Development

There are various development options you can set to test out the helm chart.  We have two flavours: `values.docker-desktop.yaml` and `values.k3s.yaml`.  Both of which are intended for development of the helm chart only and should not be considered production ready.

### Postgres

You can run up a dev instance of PostgreSQL within the chart if you are just starting out.  This deployment will take care of creating all the databases needed

Put the following values in your `values.yaml` file:

```yaml
# To enable deployment of internal PostgreSQL
dev:
  deployPostgres: true

postgresDsn: postgres://postgres:postgres@logfire-postgres:5432/crud
postgresFFDsn: postgres://postgres:postgres@logfire-postgres:5432/ff
postgresIngestDsn: postgres://postgres:postgres@logfire-postgres:5432/ingest

dex:
  ...
  config:
    storage:
      type: postgres
      config:
        host: logfire-postgres
        port: 5432
        user: postgres
        database: dex
        password: postgres
        ssl:
          mode: disable
```

### MailDev

You can run `maildev` which will allow you to send/receive emails without an external SMTP server.  Add the following to your `values.yaml`:

```yaml
ingress:
  ...
  maildevHostname: maildev.example.com

dev:
  ...
  deployMaildev: true
```

### Object Storage

By default we bundle a single-node [MinIO](https://min.io/) instance to allow you to test out object storage.
This is not intended for production use, but is useful for development.
# logfire

![Version: 0.1.11](https://img.shields.io/badge/Version-0.1.11-informational?style=flat-square) ![AppVersion: 796a41fb](https://img.shields.io/badge/AppVersion-796a41fb-informational?style=flat-square)

Helm chart for self-hosted Logfire

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| ai.azureOpenAi.apiKey | string | `nil` | The Azure OpenAI API key |
| ai.azureOpenAi.apiVersion | string | `nil` | The Azure OpenAI API version |
| ai.azureOpenAi.endpoint | string | `nil` | The Azure OpenAI endpoint |
| ai.model | string | `nil` | The AI provide and model to use |
| ai.openAi.apiKey | string | `nil` | The OpenAI API key |
| ai.vertexAi.region | string | `nil` | The region for Vertex AI |
| dev | object | `{"deployMaildev":false,"deployMinio":false,"deployPostgres":false}` | Development mode settings |
| dev.deployMaildev | bool | `false` | Deploy maildev for testing emails |
| dev.deployMinio | bool | `false` | Do NOT use this in production! |
| dev.deployPostgres | bool | `false` | Do NOT use this in production! |
| image.pullPolicy | string | `"IfNotPresent"` | The pull policy for docker images |
| imagePullSecrets | list | `[]` | The secret used to pull down container images for pods |
| ingress.annotations | object | `{}` | Any annotations required. |
| ingress.enabled | bool | `false` | Enable Ingress Resource. If you're not using an ingress resource, you still need to configure `tls`, `hostname` |
| ingress.hostname | string | `"logfire.example.com"` | The hostname used for Logfire |
| ingress.ingressClassName | string | `"nginx"` |  |
| ingress.tls | bool | `false` | Enable TLS/HTTPS connections.  Required for CORS headers |
| logfire-dex | object | `{"config":{"connectors":[],"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}},"replicas":1,"resources":{"cpu":"1","memory":"1Gi"}}` | Configuration, autoscaling & resources for `logfire-dex` deployment |
| logfire-dex.config | object | `{"connectors":[],"storage":{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}}` | Dex Config |
| logfire-dex.config.connectors | list | `[]` | Dex auth connectors, see https://dexidp.io/docs/connectors/ redirectURI config option can be omitted, as it will be automatically generated however if specified, the custom value will be honored |
| logfire-dex.config.storage | object | `{"config":{"database":"dex","host":"logfire-postgres","password":"postgres","port":5432,"ssl":{"mode":"disable"},"user":"postgres"},"type":"postgres"}` | Dex storage configuration, see https://dexidp.io/docs/configuration/storage/ |
| logfire-dex.replicas | int | `1` | Number of replicas |
| logfire-dex.resources | object | `{"cpu":"1","memory":"1Gi"}` | resources |
| logfire-redis.enabled | bool | `true` | Enable redis as part of this helm chart |
| objectStore | object | `{"env":{},"uri":null}` | Object storage details |
| objectStore.env | object | `{}` | additional env vars for the object store connection |
| objectStore.uri | string | `nil` | Uri for object storage i.e, `s3://bucket` |
| podSecurityContext | object | `{}` | Pod [security context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-pod). See the [API reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context) for details. |
| postgresDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/crud"` | Postgres DSN used for `crud` database |
| postgresFFDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/ff"` | Postgres DSN used for `ff` database |
| postgresIngestDsn | string | `"postgresql://postgres:postgres@logfire-postgres:5432/ingest"` | Postgres DSN used for `ingest` database |
| postgresJSONSecret | object | `{"enabled":false,"name":""}` | User provided postgres credentials formatted as JSON string  this secret will be autogenerated from values or postgresSecret, however, autogeneration requires a lookup for an existing secret, in case where that is not possible, such as apply with `helm template` use this setting to pass an existing secret with the correct format must contain `postgresIngestDsn` key containing a JSON list like: ["postgres://postgres:postgres@logfire-postgres:5432/ingest"] |
| postgresJSONSecret.enabled | bool | `false` | Whether to use an existing secret |
| postgresJSONSecret.name | string | `""` | Secret name |
| postgresSecret | object | `{"enabled":false,"name":""}` | User provided postgres credentials containing `postgresDsn`, `postgresFFDsn`, `postgresIngestDsn` keys |
| postgresSecret.enabled | bool | `false` | Whether to use an existing secret |
| postgresSecret.name | string | `""` | Secret name |
| priorityClassName | string | `""` | Specify a priority class name to set [pod priority](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#pod-priority). |
| redisDsn | string | `"redis://logfire-redis:6379"` | The DSN for redis.  Change from default if you have an external redis instance |
| revisionHistoryLimit | int | `2` | Define the [count of deployment revisions](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#clean-up-policy) to be kept. May be set to 0 in case of GitOps deployment approach. |
| securityContext | object | `{}` | Container [security context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-container). See the [API reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context-1) for details. |
| serviceAccountName | string | `"default"` | the Kubernetes Service Account that is used by the pods |
| smtp.host | string | `nil` | Hostname of the SMTP server |
| smtp.password | string | `nil` | SMTP password |
| smtp.port | int | `25` | Port of the SMTP server |
| smtp.use_tls | bool | `false` | Whether to use TLS |
| smtp.username | string | `nil` | SMTP username |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
