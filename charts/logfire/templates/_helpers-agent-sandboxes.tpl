{{- define "logfire.agentSandboxes.namespace" -}}
{{- default (printf "%s-sandboxes" .Release.Namespace) .Values.agentSandboxes.workerNamespace -}}
{{- end -}}
{{- define "logfire.agentSandboxes.secret" -}}
{{- default (printf "%s-agent-sandboxes" .Release.Name) .Values.agentSandboxes.existingSecret -}}
{{- end -}}
{{- define "logfire.agentSandboxes.url" -}}
{{- printf "%s://%s.%s.svc.%s:%v%s" .scheme .service .root.Release.Namespace .root.Values.clusterDomain .port (.path | default "") -}}
{{- end -}}
{{- define "logfire.agentSandboxes.controlUrl" -}}
{{- include "logfire.agentSandboxes.url" (dict "root" .root "scheme" (include "logfire.scheme" .root) "service" .service "port" (include "logfire.port" (dict "root" .root "port" .port)) "path" (.path | default "")) -}}
{{- end -}}
{{- define "logfire.agentSandboxes.tokenEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "logfire.agentSandboxes.secret" .root }}
      key: {{ .key }}
{{- end -}}
{{- define "logfire.agentSandboxes.snapshotUri" -}}
{{- default (printf "%s/monty-snapshots" (include "logfire.objectStoreUri" . | trimSuffix "/")) .Values.agentSandboxes.snapshotUri -}}
{{- end -}}
{{- define "logfire.agentSandboxes.storesEnv" -}}
{{- include "logfire.agentSandboxes.validate" .root -}}
{{- $a := .root.Values.agentSandboxes -}}
- name: MONTY_STORE_MODE
  value: dedicated
- name: MONTY_PG_DSN
  valueFrom:
    secretKeyRef:
      name: {{ $a.stores.postgresSecret.name }}
      key: {{ if eq .service "logfire-backend-auth" }}{{ $a.stores.postgresSecret.authKey }}{{ else }}{{ $a.stores.postgresSecret.runtimeKey }}{{ end }}
- name: MONTY_PG_TOPOLOGY
  value: {{ $a.stores.postgresTopology | quote }}
- name: MONTY_PG_POOL_MAX_CONNECTIONS
  value: "8"
- name: MONTY_PG_POOL_MIN_CONNECTIONS
  value: "0"
- name: MONTY_REDIS_DSN
  valueFrom:
    secretKeyRef:
      name: {{ $a.stores.redisSecret.name }}
      key: {{ $a.stores.redisSecret.key }}
{{- end -}}
{{- define "logfire.agentSandboxes.storesChecksum" -}}
{{- include "logfire.agentSandboxes.validate" . -}}
{{- $root := . -}}
{{- $stores := .Values.agentSandboxes.stores -}}
{{- $hashes := list -}}
{{- range $key := list $stores.postgresSecret.runtimeKey $stores.postgresSecret.authKey -}}
{{- $hashes = append $hashes (include "utils.secretChecksum" (dict "ctx" $root "name" $stores.postgresSecret.name "key" $key)) -}}
{{- end -}}
{{- $hashes = append $hashes (include "utils.secretChecksum" (dict "ctx" . "name" $stores.redisSecret.name "key" $stores.redisSecret.key)) -}}
{{- join "" $hashes | sha256sum -}}
{{- end -}}
{{- define "logfire.agentSandboxes.env" -}}
{{- if (.root.Values.agentSandboxes | default dict).enabled }}
{{- $root := .root -}}
{{ include "logfire.agentSandboxes.storesEnv" . }}
- name: MONTY_MANAGED_ENABLED
  value: "true"
- name: MONTY_PROFILES_ENABLED
  value: {{ $root.Values.agentSandboxes.profilesEnabled | quote }}
{{- if has .service (list "logfire-backend" "logfire-remote-mcp") }}
- name: MONTY_WORKBENCH_ENABLED
  value: "true"
- name: MONTY_ALLOWED_ORGANIZATIONS
  value: {{ $root.Values.agentSandboxes.allowedOrganizations | toJson | quote }}
- name: MONTY_VOLUMES_ENABLED
  value: {{ $root.Values.agentSandboxes.volumesEnabled | quote }}
- name: MONTY_CONTROL_URL
  value: {{ include "logfire.agentSandboxes.controlUrl" (dict "root" $root "service" "monty-admission" "port" 8080) | quote }}
{{ include "logfire.agentSandboxes.tokenEnv" (dict "root" $root "name" "MONTY_CONTROL_TOKEN" "key" "management") }}
- name: MONTY_WORKBENCH_RELAY_URL
  value: {{ include "logfire.agentSandboxes.url" (dict "root" $root "scheme" "http" "service" "monty-relay" "port" 8000 "path" "/") | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "logfire.agentSandboxes.validate" -}}
{{- $a := .Values.agentSandboxes | default dict -}}
{{- if $a.enabled -}}
{{- if not (semverCompare ">=1.25.0-0" .Capabilities.KubeVersion.Version) -}}
{{- fail "agentSandboxes requires Kubernetes 1.25 or later with CRD CEL validation enabled; Kubernetes 1.29 or later is recommended" -}}
{{- end -}}
{{- if and (include "logfire.inClusterTls.enabled" . | eq "true") (eq (int .Values.inClusterTls.httpsPort) 8082) -}}
{{- fail "agentSandboxes reserves port 8082 for gRPC; choose a different inClusterTls.httpsPort" -}}
{{- end -}}
{{- if not .Values.agentSandboxes.imageTag -}}
{{- fail "agentSandboxes requires an explicit compatible agentSandboxes.imageTag for the Platform and Monty images" -}}
{{- end -}}
{{- if not (regexMatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" ($a.capacityOwnerId | default "" | toString)) -}}
{{- fail "agentSandboxes.capacityOwnerId must be a stable installation UUID shared by admission replicas" -}}
{{- end -}}
{{- if not (regexMatch "^(s3|gs|az)://[^/]+/.+" (include "logfire.agentSandboxes.snapshotUri" .)) -}}
{{- fail "agentSandboxes.snapshotUri must name an S3, GCS or Azure object-store prefix" -}}
{{- end -}}
{{- if or (lt (int $a.relay.replicas) 1) (lt (int $a.relay.maxSessions) 1) -}}
{{- fail "agentSandboxes relay replicas and maxSessions must be positive" -}}
{{- end -}}
{{- if not $a.allowedOrganizations -}}
{{- fail "agentSandboxes.allowedOrganizations must contain at least one organization UUID" -}}
{{- end -}}
{{- range $a.allowedOrganizations -}}
{{- if not (regexMatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" .) -}}
{{- fail "agentSandboxes.allowedOrganizations must contain organization UUIDs" -}}
{{- end -}}
{{- end -}}
{{- $namespace := include "logfire.agentSandboxes.namespace" . -}}
{{- if or (eq $namespace .Release.Namespace) (gt (len $namespace) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $namespace)) -}}
{{- fail "agentSandboxes.workerNamespace must be a separate valid namespace of at most 63 characters" -}}
{{- end -}}
{{- if not $a.workers.runtimeClassName -}}
{{- fail "agentSandboxes.workers.runtimeClassName must name an installed isolated runtime" -}}
{{- end -}}
{{- if and (hasKey $a.workers "dnsEgress") (not (kindIs "slice" $a.workers.dnsEgress)) -}}
{{- fail "agentSandboxes.workers.dnsEgress must be a list of NetworkPolicy egress rules; use [] to omit the DNS exception" -}}
{{- end -}}
{{- if and (hasKey $a.workers "extraEgress") (not (kindIs "slice" $a.workers.extraEgress)) -}}
{{- fail "agentSandboxes.workers.extraEgress must be a list of NetworkPolicy egress rules" -}}
{{- end -}}
{{- if or (lt (int $a.workers.warmReplicas) 1) (le (int $a.workers.ceiling) (int $a.workers.warmReplicas)) (gt (int $a.workers.ceiling) 128) -}}
{{- fail "agentSandboxes workers require 1 <= warmReplicas < ceiling <= 128" -}}
{{- end -}}
{{- if not (has $a.workers.updateStrategy (list "Recreate" "OnReplenish")) -}}
{{- fail "agentSandboxes.workers.updateStrategy must be Recreate or OnReplenish" -}}
{{- end -}}
{{- if or (lt (int $a.workers.memoryMiB) 512) (lt (int $a.workers.cpuRequestMillicores) 250) (lt (int $a.workers.cpuLimitMillicores) (int $a.workers.cpuRequestMillicores)) (gt (int $a.workers.cpuLimitMillicores) 1000) -}}
{{- fail "agentSandboxes workers require memoryMiB >= 512 and 250 <= cpuRequestMillicores <= cpuLimitMillicores <= 1000" -}}
{{- end -}}
{{- if or (lt (int64 $a.snapshotQuota.bytes) 67108864) (lt (int64 $a.snapshotQuota.objects) 1) (lt (int $a.snapshotQuota.retentionSeconds) 1) (gt (int $a.snapshotQuota.retentionSeconds) 604800) -}}
{{- fail "agentSandboxes.snapshotQuota requires bytes >= 67108864, objects >= 1 and retentionSeconds between 1 and 604800" -}}
{{- end -}}
{{- if and $a.volumesEnabled (not $a.profilesEnabled) -}}
{{- fail "agentSandboxes.volumesEnabled requires profilesEnabled" -}}
{{- end -}}
{{- range $service := list "logfire-backend" "logfire-backend-auth" "logfire-backend-migrations" "logfire-worker" "logfire-task-runner" "logfire-frontend-service" "logfire-remote-mcp" -}}
{{- if ne (include "logfire.serviceTag" (dict "Values" $.Values "Chart" $.Chart "serviceName" $service)) $.Values.agentSandboxes.imageTag -}}
{{- fail "agentSandboxes requires matching Python and frontend image tags" -}}
{{- end -}}
{{- end -}}
{{- $stores := $a.stores | default dict -}}
{{- if or (not (($stores.postgresSecret | default dict).name)) (not (($stores.redisSecret | default dict).name)) -}}
{{- fail "agentSandboxes requires stores.postgresSecret.name and stores.redisSecret.name for its independent runtime stores" -}}
{{- end -}}
{{- if or (empty $stores.postgresSecret.runtimeKey) (empty $stores.postgresSecret.authKey) (empty $stores.postgresSecret.migrationKey) (empty $stores.redisSecret.key) -}}
{{- fail "agentSandboxes stores require nonempty runtimeKey, authKey, migrationKey and Redis key" -}}
{{- end -}}
{{- if or (eq $stores.postgresSecret.runtimeKey $stores.postgresSecret.authKey) (eq $stores.postgresSecret.runtimeKey $stores.postgresSecret.migrationKey) (eq $stores.postgresSecret.authKey $stores.postgresSecret.migrationKey) -}}
{{- fail "agentSandboxes stores require distinct runtime, auth and migration Secret keys" -}}
{{- end -}}
{{- if not (has ($stores.postgresTopology | default "direct") (list "direct" "pgbouncer")) -}}
{{- fail "agentSandboxes.stores.postgresTopology must be direct or pgbouncer" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "logfire.agentSandboxes.pythonEnv" -}}
- name: APP_PORT
  value: "8080"
{{- if (include "logfire.inClusterTls.enabled" .root | eq "true") }}
- name: HTTPS_PORT
  value: {{ .root.Values.inClusterTls.httpsPort | quote }}
- name: TLS_CERT_PATH
  value: /etc/tls/tls.crt
- name: TLS_KEY_PATH
  value: /etc/tls/tls.key
- name: LOGFIRE_CA_PATH
  value: /etc/logfire/incluster-ca/ca.crt
{{- end }}
- name: ON_PREM
  value: "true"
- name: LOGFIRE_REGION
  value: {{ .root.Values.logfireRegion | default "local" | quote }}
- name: LOGFIRE_SERVICE_NAME
  value: {{ .service }}
- name: LOGFIRE_SERVICE_VERSION
  value: {{ .root.Values.agentSandboxes.imageTag | quote }}
- name: FRONTEND_HOST
  value: {{ include "logfire.url" .root | quote }}
- name: COLLECTOR_OTLP_GRPC_HOST
  value: http://logfire-otel-collector:4317
{{- end -}}
{{- define "logfire.agentSandboxes.controllerEnv" -}}
{{- $root := . -}}
- name: MONTY_CONTROLLER_STATE_URL
  value: {{ include "logfire.agentSandboxes.controlUrl" (dict "root" . "service" "monty-admission" "port" 8080 "path" "/state") | quote }}
- name: MONTY_CONTROLLER_AUTH_URL
  value: {{ include "logfire.agentSandboxes.controlUrl" (dict "root" . "service" "logfire-backend-auth" "port" 8000 "path" "/internal/monty/get-state") | quote }}
{{- range $item := list (dict "name" "MONTY_CONTROLLER_TOKEN" "key" "controller") (dict "name" "MONTY_CONTROLLER_STATE_TOKEN" "key" "state") (dict "name" "MONTY_CONTROLLER_RELAY_TOKEN" "key" "relay") (dict "name" "MONTY_WORKER_TELEMETRY_TOKEN" "key" "telemetry") }}
{{ include "logfire.agentSandboxes.tokenEnv" (dict "root" $root "name" $item.name "key" $item.key) }}
{{- end }}
- name: MONTY_WORKER_INTAKE_URL
  value: {{ include "logfire.agentSandboxes.controlUrl" (dict "root" . "service" "logfire-service" "port" 8080) | quote }}
- name: MONTY_PUBLIC_GRPC_URL
  value: {{ include "logfire.url" . | quote }}
- name: MONTY_NAMESPACE
  value: {{ include "logfire.agentSandboxes.namespace" . | quote }}
- name: MONTY_KUBERNETES_CLUSTER_DOMAIN
  value: {{ .Values.clusterDomain | quote }}
- name: MONTY_WARM_POOL
  value: monty-workers
- name: MONTY_ALLOWED_ORGANIZATIONS
  value: {{ .Values.agentSandboxes.allowedOrganizations | toJson | quote }}
- name: MONTY_WORKER_MEMORY_LIMIT_MIB
  value: {{ .Values.agentSandboxes.workers.memoryMiB | quote }}
- name: MONTY_WORKER_CPU_LIMIT_MILLICORES
  value: {{ .Values.agentSandboxes.workers.cpuLimitMillicores | quote }}
- name: MONTY_PRESSURE_ENABLED
  value: {{ .Values.agentSandboxes.pressureEnabled | default false | quote }}
{{- end -}}

{{- define "logfire.agentSandboxes.checksum" -}}
{{- $root := . -}}
{{- $hashes := list -}}
{{- $hashes = append $hashes (include "logfire.agentSandboxes.storesChecksum" .) -}}
{{- range $key := list "management" "controller" "state" "relay" "snapshot" "snapshot-admin" "volume" "volume-admin" "telemetry" -}}
{{- $hashes = append $hashes (include "utils.secretChecksum" (dict "ctx" $root "name" (include "logfire.agentSandboxes.secret" $root) "key" $key)) -}}
{{- end -}}
{{- join "" $hashes | sha256sum -}}
{{- end -}}
