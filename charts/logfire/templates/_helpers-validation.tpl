{{/*
================================================================================
Configuration Validation Helpers
================================================================================
These helpers validate chart configuration and fail with clear error messages
when required values are missing or incorrectly configured.
*/}}

{{/*
Validate that objectStore.uri resolves to a nonblank value (required for production)
*/}}
{{- define "logfire.validate.objectStore" -}}
{{- if not (or .Values.dev.deployRustfs .Values.dev.deployMinio) -}}
  {{- if not (include "logfire.objectStoreUri" . | trim) -}}
    {{- fail "objectStore.uri is required. Set objectStore.uri to your S3/Azure/GCS bucket URI (e.g., 's3://bucket-name' or 'az://container-name'). For local development, you can set dev.deployRustfs=true instead." -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate that objectStore.volumes and objectStore.volumeMounts entries do not collide with the
volumes and mount paths the chart adds to the same Fusionfire pods. Kubernetes rejects a pod that
lists the same volume name or mount path twice, so the chart reserves its generated names and
paths here. The in-cluster TLS volumes are reserved only when that TLS mode is enabled.
*/}}
{{- define "logfire.validate.objectStoreVolumes" -}}
{{- $reservedNames := list "tmp" "scratch-data" "ingest-data" -}}
{{- $reservedMountPaths := list "/tmp" "/scratch" "/fusionfire/ingest-data" -}}
{{- if (include "logfire.inClusterTls.enabled" . | eq "true") -}}
{{- $reservedNames = concat $reservedNames (list "logfire-incluster-tls" "logfire-incluster-ca-bundle") -}}
{{- $reservedMountPaths = concat $reservedMountPaths (list "/etc/tls" "/etc/logfire/incluster-ca") -}}
{{- end -}}
{{- $objectStore := .Values.objectStore | default dict -}}
{{- range $index, $volume := (get $objectStore "volumes" | default list) -}}
  {{- $name := get $volume "name" -}}
  {{- if has $name $reservedNames -}}
    {{- fail (printf "objectStore.volumes[%d].name '%s' is reserved by the chart. Rename the volume, because chart-owned containers mount a volume with that name. Reserved names: %s." $index $name ($reservedNames | join ", ")) -}}
  {{- end -}}
{{- end -}}
{{- range $index, $mount := (get $objectStore "volumeMounts" | default list) -}}
  {{- $mountPath := get $mount "mountPath" -}}
  {{- if has $mountPath $reservedMountPaths -}}
    {{- fail (printf "objectStore.volumeMounts[%d].mountPath '%s' is reserved by the chart. Use another mount path, because chart-owned containers mount a writable volume at that path. Reserved paths: %s." $index $mountPath ($reservedMountPaths | join ", ")) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate public hostnames configuration
*/}}
{{- define "logfire.validate.ingress" -}}
{{- $result := include "logfire.effective_hostnames" . | fromJson -}}
{{- $hosts := default (list) $result.hosts -}}
{{- if eq (len $hosts) 0 -}}
  {{- fail "At least one hostname is required for Logfire. Set gateway.hostnames, ingress.hostnames, or ingress.hostname so the chart can generate public URLs and CORS settings." -}}
{{- end -}}
{{- end -}}

{{/*
Validate postgres configuration - either external secret or DSN must be provided
*/}}
{{- define "logfire.validate.postgres" -}}
{{- if not .Values.dev.deployPostgres -}}
  {{- if .Values.postgresSecret.enabled -}}
    {{- if not .Values.postgresSecret.name -}}
      {{- fail "postgresSecret.name is required when postgresSecret.enabled is true. Provide the name of your Kubernetes Secret containing 'postgresDsn' and 'postgresFFDsn' keys." -}}
    {{- end -}}
  {{- else -}}
    {{- if not .Values.postgresDsn -}}
      {{- fail "postgresDsn is required when not using dev.deployPostgres or postgresSecret. Provide a PostgreSQL DSN for the crud database." -}}
    {{- end -}}
    {{- if not .Values.postgresFFDsn -}}
      {{- fail "postgresFFDsn is required when not using dev.deployPostgres or postgresSecret. Provide a PostgreSQL DSN for the ff database." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate dex storage configuration when using external postgres
*/}}
{{- define "logfire.validate.dexStorage" -}}
{{- $dexConfig := dig "config" dict (index .Values "logfire-dex" | default dict) -}}
{{- $storage := dig "storage" dict $dexConfig -}}
{{- $storageType := dig "type" "" $storage -}}
{{- if and (not .Values.dev.deployPostgres) (eq $storageType "postgres") -}}
  {{- $storageConfig := dig "config" dict $storage -}}
  {{- if not $storageConfig.host -}}
    {{- fail "logfire-dex.config.storage.config.host is required when using postgres storage type. Configure the Dex storage to point to your PostgreSQL instance." -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate AI configuration consistency - if model is set, required provider config must exist
*/}}
{{- define "logfire.validate.ai" -}}
{{- $ai := .Values.ai | default dict -}}
{{- $openAi := get $ai "openAi" | default dict -}}
{{- $vertexAi := get $ai "vertexAi" | default dict -}}
{{- $azureOpenAi := get $ai "azureOpenAi" | default dict -}}
{{- $multiRegionLocation := get $vertexAi "multiRegionLocation" -}}
{{- if and $multiRegionLocation (not (has $multiRegionLocation (list "us" "eu"))) -}}
  {{- fail (printf "ai.vertexAi.multiRegionLocation must be exactly 'us' or 'eu', got '%s'. Do not use 'global' as a data-residency workaround." $multiRegionLocation) -}}
{{- end -}}
{{- $models := list
  (dict "name" "ai.model" "value" (get $ai "model"))
  (dict "name" "ai.chatModel" "value" (get $ai "chatModel"))
  (dict "name" "ai.reasoningModel" "value" (get $ai "reasoningModel"))
  (dict "name" "ai.llmJudgeModel" "value" (get $ai "llmJudgeModel"))
-}}
{{- range $models -}}
{{- if .value -}}
  {{- $model := .value -}}
  {{- $name := .name -}}
  {{- range $fallback := splitList "," $model -}}
    {{- $fallback = trim $fallback -}}
    {{- if hasPrefix "google-cloud:" $fallback -}}
      {{- if eq $fallback "google-cloud:gemini-3.5-flash" -}}
        {{- if not $multiRegionLocation -}}
          {{- fail (printf "ai.vertexAi.multiRegionLocation is required when %s contains Google Cloud model '%s'. Set it to 'us' or 'eu'." $name $fallback) -}}
        {{- end -}}
      {{- else if not (get $vertexAi "region") -}}
        {{- fail (printf "ai.vertexAi.region is required when %s contains regional Google Cloud model '%s'." $name $fallback) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if or (hasPrefix "openai:" $model) (hasPrefix "openai-chat:" $model) (hasPrefix "openai-responses:" $model) -}}
    {{- if not (get $openAi "apiKey") -}}
      {{- fail (printf "ai.openAi.apiKey is required when %s uses OpenAI model '%s'. Provide your OpenAI API key." $name $model) -}}
    {{- end -}}
  {{- else if hasPrefix "azure:" $model -}}
    {{- if not (get $azureOpenAi "endpoint") -}}
      {{- fail (printf "ai.azureOpenAi.endpoint is required when %s uses Azure OpenAI model '%s'." $name $model) -}}
    {{- end -}}
    {{- if not (get $azureOpenAi "apiKey") -}}
      {{- fail (printf "ai.azureOpenAi.apiKey is required when %s uses Azure OpenAI model '%s'." $name $model) -}}
    {{- end -}}
  {{- else if hasPrefix "google-vertex:" $model -}}
    {{- if not (get $vertexAi "region") -}}
      {{- fail (printf "ai.vertexAi.region is required when %s uses Google Vertex AI model '%s'." $name $model) -}}
    {{- end -}}
  {{- else if hasPrefix "anthropic-vertex:" $model -}}
    {{- if not (get $vertexAi "region") -}}
      {{- fail (printf "ai.vertexAi.region is required when %s uses Anthropic Vertex model '%s'." $name $model) -}}
    {{- end -}}
    {{- if not (get $vertexAi "anthropicProjectId") -}}
      {{- fail (printf "ai.vertexAi.anthropicProjectId is required when %s uses Anthropic Vertex model '%s'." $name $model) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate existing secret configuration
*/}}
{{- define "logfire.validate.existingSecret" -}}
{{- if .Values.existingSecret.enabled -}}
  {{- if not .Values.existingSecret.name -}}
    {{- $msg := "existingSecret.name is required when existingSecret.enabled is true. Provide the name of your Kubernetes Secret containing logfire-dex-client-secret, logfire-encryption-key, logfire-meta-write-token, logfire-meta-frontend-token, logfire-jwt-secret and logfire-unsubscribe-secret keys." -}}
    {{- if .Values.webPush.enabled -}}
      {{- $msg = printf "%s It must also hold a logfire-web-push-vapid-key key when webPush.enabled." $msg -}}
    {{- end -}}
    {{- fail $msg -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate admin secret configuration
*/}}
{{- define "logfire.validate.adminSecret" -}}
{{- if .Values.adminSecret.enabled -}}
  {{- if not .Values.adminSecret.name -}}
    {{- fail "adminSecret.name is required when adminSecret.enabled is true. Provide the name of your Kubernetes Secret containing logfire-admin-password, logfire-admin-totp-secret, and logfire-admin-totp-recovery-codes keys." -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate gateway secret configuration
*/}}
{{- define "logfire.validate.existingGatewaySecret" -}}
{{- if (index .Values "logfire-ai-gateway" "enabled") -}}
{{- $ex := get .Values "existingGatewaySecret" | default dict -}}
{{- if get $ex "enabled" -}}
  {{- if not (get $ex "name") -}}
    {{- fail "existingGatewaySecret.name is required when existingGatewaySecret.enabled is true. Provide the name of your Kubernetes Secret containing 'key' (gateway encryption key) and 'internalSecret' (gateway internal secret) keys." -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/*
Validate scratch volume configuration.
*/}}
{{- define "logfire.validate.scratchVolumes" -}}
{{- range $serviceName := list "logfire-ff-cache-byte" "logfire-ff-compaction-worker" "logfire-ff-maintenance-worker" "logfire-ff-query-api" "logfire-ff-query-worker" -}}
  {{- $serviceValues := include "logfire.effectiveServiceValues" (dict "Values" $.Values "serviceName" $serviceName) | fromJson -}}
  {{- $scratchVolume := get $serviceValues "scratchVolume" | default dict -}}
  {{- if and $scratchVolume (not (get $scratchVolume "storage")) -}}
    {{- fail (printf "%s.scratchVolume.storage is required when scratchVolume is configured. Omit %s.scratchVolume to use emptyDir scratch storage, or set scratchVolume.storage for an ephemeral PVC." $serviceName $serviceName) -}}
  {{- end -}}
{{- end -}}
{{- end -}}


{{/*
Validate autoscaling configuration - warn if both HPA and KEDA are enabled
*/}}
{{- define "logfire.validate.sizingPreset" -}}
{{- $presetName := .Values.sizingPreset | default "" -}}
{{- if $presetName -}}
  {{- $presets := .Values.sizingPresets | default dict -}}
  {{- if not (hasKey $presets $presetName) -}}
    {{- fail (printf "Unknown sizingPreset %q. Valid presets: %s" $presetName ((keys $presets | sortAlpha) | join ", ")) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate autoscaling configuration - warn if both HPA and KEDA are enabled
*/}}
{{- define "logfire.validate.autoscaling" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" (dict "Values" .Values "serviceName" $serviceName) | fromJson -}}
{{- $autoscaling := $serviceValues.autoscaling | default dict -}}
{{- if $autoscaling -}}
  {{- $hpaEnabled := include "logfire.hpa.enabled" $autoscaling | eq "true" -}}
  {{- $kedaEnabled := include "logfire.keda.enabled" $autoscaling | eq "true" -}}
  {{- $cpuAverage := dig "hpa" "cpuAverage" $autoscaling.cpuAverage $autoscaling -}}
  {{- $memAverage := dig "hpa" "memAverage" $autoscaling.memAverage $autoscaling -}}
  {{- $extraMetrics := dig "hpa" "extraMetrics" $autoscaling.extraMetrics $autoscaling -}}
  {{- if and $hpaEnabled $kedaEnabled -}}
    {{- fail (printf "Both HPA and KEDA are enabled for '%s'. Only one autoscaler should be enabled at a time to avoid conflicts." $serviceName) -}}
  {{- end -}}
  {{- if and $hpaEnabled (not (or $cpuAverage $memAverage $extraMetrics)) -}}
    {{- fail (printf "HPA is enabled for '%s', but no metrics are configured. Set autoscaling.hpa.cpuAverage, autoscaling.hpa.memAverage, or autoscaling.hpa.extraMetrics (or the backward-compatible top-level equivalents)." $serviceName) -}}
  {{- end -}}
  {{- if $autoscaling.minReplicas -}}
    {{- if $autoscaling.maxReplicas -}}
      {{- if gt (int $autoscaling.minReplicas) (int $autoscaling.maxReplicas) -}}
        {{- fail (printf "autoscaling.minReplicas (%d) cannot be greater than autoscaling.maxReplicas (%d) for '%s'." (int $autoscaling.minReplicas) (int $autoscaling.maxReplicas) $serviceName) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate email/admin configuration
*/}}
{{- define "logfire.validate.admin" -}}
{{- if not .Values.adminEmail -}}
  {{- fail "adminEmail is required. Provide an email address for the initial admin user." -}}
{{- end -}}
{{- $emailRegex := "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$" -}}
{{- if not (regexMatch $emailRegex .Values.adminEmail) -}}
  {{- fail (printf "adminEmail '%s' does not appear to be a valid email address." .Values.adminEmail) -}}
{{- end -}}
{{- end -}}

{{/*
Validate in-cluster TLS configuration
*/}}
{{- define "logfire.validate.inClusterTls" -}}
{{- if (include "logfire.inClusterTls.enabled" . | eq "true") -}}
  {{- $mode := include "logfire.inClusterTls.certs.mode" . -}}
  {{- if not (or (eq $mode "existingSecrets") (eq $mode "certManager")) -}}
    {{- fail (printf "inClusterTls.certs.mode must be one of 'existingSecrets' or 'certManager' (got %q)" $mode) -}}
  {{- end -}}

  {{- $cm := .Values.inClusterTls.caBundle.existingConfigMap.name -}}
  {{- $secret := dig "existingSecret" "name" "" .Values.inClusterTls.caBundle -}}
  {{- if and $cm $secret -}}
    {{- fail "inClusterTls.caBundle: specify only one of existingConfigMap.name or existingSecret.name" -}}
  {{- end -}}

  {{- if eq $mode "certManager" -}}
    {{- $issuerKind := include "logfire.inClusterTls.certs.certManager.issuerRef.kind" . -}}
    {{- $issuerName := include "logfire.inClusterTls.certs.certManager.issuerRef.name" . -}}
    {{- if not (or (eq $issuerKind "Issuer") (eq $issuerKind "ClusterIssuer")) -}}
      {{- fail (printf "inClusterTls.certs.certManager.issuerRef.kind must be 'Issuer' or 'ClusterIssuer' (got %q)" $issuerKind) -}}
    {{- end -}}

    {{- /* Auto-Issuer only supports creating a namespaced Issuer */ -}}
    {{- if and (not $issuerName) (ne $issuerKind "Issuer") -}}
      {{- fail "inClusterTls.certs.mode=certManager with an empty issuerRef.name uses the chart-managed *namespaced* Issuer. Set issuerRef.kind=Issuer, or provide a non-empty issuerRef.name (Issuer/ClusterIssuer)." -}}
    {{- end -}}

    {{- $autoIssuer := include "logfire.inClusterTls.certs.certManager.autoIssuer" . | eq "true" -}}
    {{- if and (not $cm) (not $secret) (not $autoIssuer) -}}
      {{- fail "inClusterTls.enabled is true and certs.mode=certManager, but no CA bundle was provided. Set inClusterTls.caBundle.existingConfigMap.name (recommended) or inClusterTls.caBundle.existingSecret.name, or leave issuerRef.name empty to use the chart-managed CA." -}}
    {{- end -}}

    {{- if and (not (dig "deployCertManager" false .Values.dev)) (not (.Capabilities.APIVersions.Has "cert-manager.io/v1")) -}}
      {{- fail "inClusterTls.certs.mode=certManager requires cert-manager CRDs (cert-manager.io/v1). Either install cert-manager separately, or set dev.deployCertManager=true for Kind/dev." -}}
    {{- end -}}

  {{- else -}}
    {{- /* existingSecrets */ -}}
    {{- if and (not $cm) (not $secret) -}}
      {{- fail "inClusterTls.enabled is true and certs.mode=existingSecrets, but no CA bundle was provided. Set inClusterTls.caBundle.existingConfigMap.name (recommended) or inClusterTls.caBundle.existingSecret.name." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate Redis configuration
*/}}
{{- define "logfire.validate.redis" -}}
{{- $redisEnabled := dig "enabled" true (index .Values "logfire-redis" | default dict) -}}
{{- if not $redisEnabled -}}
  {{- if not .Values.redisDsn -}}
    {{- fail "redisDsn is required when logfire-redis.enabled is false. Provide a Redis DSN for your external Redis instance." -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate Gateway API configuration
*/}}
{{- define "logfire.validate.gateway" -}}
{{- if .Values.gateway.enabled -}}
  {{- if .Values.gateway.create -}}
    {{- if not .Values.gateway.gatewayClassName -}}
      {{- fail "gateway.gatewayClassName is required when gateway.create is true. Specify the GatewayClass name (e.g., 'istio', 'cilium', 'nginx', 'envoy-gateway')." -}}
    {{- end -}}
  {{- else -}}
    {{- if not .Values.gateway.name -}}
      {{- fail "gateway.name is required when gateway.enabled is true and gateway.create is false. Provide the name of the existing Gateway resource to attach the HTTPRoute to." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate that both Ingress and Gateway are not enabled simultaneously
*/}}
{{- define "logfire.validate.ingressGatewayConflict" -}}
{{- if and .Values.ingress.enabled .Values.gateway.enabled -}}
  {{- fail "Both ingress.enabled and gateway.enabled are true. Enable only one of Ingress or Gateway API to avoid routing conflicts. Set ingress.enabled=false to use Gateway API, or gateway.enabled=false to use Ingress." -}}
{{- end -}}
{{- end -}}

{{/*
Validate that an install with an SMTP server names its own email sender.
The platform does not send email as pydantic.dev from a self-hosted install, and the task
runner and the worker refuse to start without EMAIL_FROM_ADDRESS. This check stops the
install or upgrade before any workload rolls out. With dev.deployMaildev, the workloads send
through maildev instead of smtp.host and get a placeholder sender.
*/}}
{{- define "logfire.validate.smtp" -}}
{{- $smtp := .Values.smtp | default dict -}}
{{- if and (get $smtp "host") (not (get $smtp "fromAddress")) (not (.Values.dev).deployMaildev) -}}
  {{- fail "smtp.fromAddress is required when smtp.host is set. Set it to the sender address of Logfire email, such as logfire@example.com, on a domain that your SMTP server may send for. Logfire does not send email as pydantic.dev from a self-hosted install." -}}
{{- end -}}
{{- $domain := (get $smtp "fromAddress" | default "" | toString | splitList "@" | last | trim | trimSuffix "." | lower) -}}
{{- if or (eq $domain "pydantic.dev") (hasSuffix ".pydantic.dev" $domain) -}}
  {{- fail "smtp.fromAddress must not be a pydantic.dev address. Set it to an address on a domain that your SMTP server may send for." -}}
{{- end -}}
{{- end -}}

{{/*
Master validation template - runs all validations
Call this from templates that need to ensure configuration is valid.
*/}}
{{- define "logfire.validateConfig" -}}
{{- $root := . -}}
{{- $validators := list
  "logfire.validate.sizingPreset"
  "logfire.validate.objectStore"
  "logfire.validate.objectStoreVolumes"
  "logfire.validate.ingress"
  "logfire.validate.gateway"
  "logfire.validate.ingressGatewayConflict"
  "logfire.validate.postgres"
  "logfire.validate.dexStorage"
  "logfire.validate.ai"
  "logfire.validate.existingSecret"
  "logfire.validate.existingGatewaySecret"
  "logfire.validate.adminSecret"
  "logfire.validate.admin"
  "logfire.validate.redis"
  "logfire.validate.smtp"
  "logfire.validate.inClusterTls"
  "logfire.validate.scratchVolumes"
  -}}
{{- range $validator := $validators -}}
{{- include $validator $root -}}
{{- end -}}
{{- end -}}

{{/* Each of the three signal databases needs room for its compaction copy. */}}
{{- define "logfire.validate.otelQueueStorage" -}}
{{- $storage := .Values.otel_collector.queueStorage -}}
{{- if $storage.enabled -}}
{{- $maximum := $storage.maxSizeBytes | int64 -}}
{{- if lt $maximum 1048576 -}}
{{- fail "otel_collector.queueStorage.maxSizeBytes must be at least 1048576 (1MiB)." -}}
{{- end -}}
{{- $volumeMi := include "logfire.memoryToMi" $storage.sizeLimit | int64 -}}
{{- if lt (mul $volumeMi 1048576) (mul $maximum 6) -}}
{{- fail "otel_collector.queueStorage.sizeLimit must allow at least 6x maxSizeBytes for three databases and their compaction copies." -}}
{{- end -}}
{{- $resources := include "logfire.otelCollectorResources" . | fromYaml -}}
{{- $limitMiPrecise := include "logfire.memoryToMiFloat" (dig "resources" "limits" "ephemeral-storage" "0" $resources) | float64 -}}
{{- $volumeMiPrecise := include "logfire.memoryToMiFloat" $storage.sizeLimit | float64 -}}
{{- if lt $limitMiPrecise $volumeMiPrecise -}}
{{- fail "The collector ephemeral-storage limit must be at least otel_collector.queueStorage.sizeLimit; allow extra space for container logs." -}}
{{- end -}}
{{- $collector := include "logfire.effectiveServiceValues" (dict "Values" .Values "serviceName" "logfire-otel-collector") | fromJson -}}
{{- $queueBytes := $collector.sendingQueueBytes | default .Values.otel_collector.sendingQueueBytes | default 67108864 -}}
{{- $queue := .Values.otel_collector.exporter.sending_queue | default dict -}}
{{- if hasKey $queue "queue_size" -}}
{{- $queueBytes = $queue.queue_size -}}
{{- end -}}
{{- if and (eq ($queue.sizer | default "bytes") "bytes") (ne (dig "enabled" true $queue) false) -}}
{{/* Small requests need bbolt page/index headroom; this minimum is not a storage-loss guarantee. */}}
{{- if lt $maximum (mul ($queueBytes | int64) 4) -}}
{{- fail "otel_collector.queueStorage.maxSizeBytes must allow at least 4x the effective byte queue_size for database overhead; increase the disk budgets when increasing the queue." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The collector's self-metrics and the application Prometheus exporter each bind a port, so they
must differ or the collector cannot start. */}}
{{- define "logfire.validate.otelSelfMetricsPort" -}}
{{- if include "isPrometheusExporterEnabled" . | trim | eq "true" -}}
{{- $selfPort := .Values.otel_collector.selfMetricsPort | default 8888 -}}
{{- $promPort := (get (.Values.otel_collector.prometheus | default dict) "port") | default 9090 -}}
{{- if eq (int $selfPort) (int $promPort) -}}
{{- fail (printf "otel_collector.selfMetricsPort (%d) must differ from otel_collector.prometheus.port (%d); the collector binds both and cannot start when they match." (int $selfPort) (int $promPort)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
