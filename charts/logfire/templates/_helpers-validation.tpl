{{/*
================================================================================
Configuration Validation Helpers
================================================================================
These helpers validate chart configuration and fail with clear error messages
when required values are missing or incorrectly configured.
*/}}

{{/*
Validate that objectStore.uri is configured (required for production)
*/}}
{{- define "logfire.validate.objectStore" -}}
{{- if not .Values.dev.deployMinio -}}
  {{- if not .Values.objectStore.uri -}}
    {{- fail "objectStore.uri is required. Set objectStore.uri to your S3/Azure/GCS bucket URI (e.g., 's3://bucket-name' or 'az://container-name'). For local development, you can set dev.deployMinio=true instead." -}}
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
{{- if .Values.ai.model -}}
  {{- $model := .Values.ai.model -}}
  {{- if hasPrefix "openai:" $model -}}
    {{- if not .Values.ai.openAi.apiKey -}}
      {{- fail (printf "ai.openAi.apiKey is required when using OpenAI model '%s'. Provide your OpenAI API key." $model) -}}
    {{- end -}}
  {{- else if hasPrefix "azure:" $model -}}
    {{- if not .Values.ai.azureOpenAi.endpoint -}}
      {{- fail (printf "ai.azureOpenAi.endpoint is required when using Azure OpenAI model '%s'." $model) -}}
    {{- end -}}
    {{- if not .Values.ai.azureOpenAi.apiKey -}}
      {{- fail (printf "ai.azureOpenAi.apiKey is required when using Azure OpenAI model '%s'." $model) -}}
    {{- end -}}
  {{- else if hasPrefix "google-vertex:" $model -}}
    {{- if not .Values.ai.vertexAi.region -}}
      {{- fail (printf "ai.vertexAi.region is required when using Google Vertex AI model '%s'." $model) -}}
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
    {{- fail "existingSecret.name is required when existingSecret.enabled is true. Provide the name of your Kubernetes Secret containing logfire-dex-client-secret, logfire-encryption-key, logfire-meta-write-token, logfire-meta-frontend-token, logfire-jwt-secret and logfire-unsubscribe-secret keys." -}}
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
Validate autoscaling configuration - warn if both HPA and KEDA are enabled
*/}}
{{- define "logfire.validate.autoscaling" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceValues := index .Values $serviceName | default dict -}}
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
Validate PDB configuration - minAvailable and maxUnavailable are mutually exclusive
*/}}
{{- define "logfire.validate.pdb" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceValues := index .Values $serviceName | default dict -}}
{{- $pdb := $serviceValues.pdb | default dict -}}
{{- if and $pdb.minAvailable $pdb.maxUnavailable -}}
  {{- fail (printf "pdb.minAvailable and pdb.maxUnavailable are mutually exclusive for '%s'. Specify only one." $serviceName) -}}
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
Master validation template - runs all validations
Call this from templates that need to ensure configuration is valid.
*/}}
{{- define "logfire.validateConfig" -}}
{{- $root := . -}}
{{- $validators := list
  "logfire.validate.objectStore"
  "logfire.validate.ingress"
  "logfire.validate.gateway"
  "logfire.validate.ingressGatewayConflict"
  "logfire.validate.postgres"
  "logfire.validate.dexStorage"
  "logfire.validate.ai"
  "logfire.validate.existingSecret"
  "logfire.validate.adminSecret"
  "logfire.validate.admin"
  "logfire.validate.redis"
  "logfire.validate.inClusterTls"
  -}}
{{- range $validator := $validators -}}
{{- include $validator $root -}}
{{- end -}}
{{- end -}}
