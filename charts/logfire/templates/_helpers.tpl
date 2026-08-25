{{- define "logfire.hpa" }}
{{- $cpuAverage := dig "hpa" "cpuAverage" .cpuAverage . }}
{{- $memAverage := dig "hpa" "memAverage" .memAverage . }}
{{- $extraMetrics := dig "hpa" "extraMetrics" .extraMetrics . }}
{{- $behavior := dig "hpa" "behavior" nil . }}
{{- $hasMetrics := or $cpuAverage $memAverage $extraMetrics }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .serviceName }}
  labels:
    app.kubernetes.io/component: {{ .serviceName }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: {{ .kind }}
    name: {{ .serviceName }}
  minReplicas: {{ .minReplicas | default "1" }}
  maxReplicas: {{ .maxReplicas |  default "2" }}
  {{- if $hasMetrics }}
  metrics:
  {{- if $cpuAverage }}
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: {{ $cpuAverage | default "75" }}
  {{- end }}
  {{- if $memAverage }}
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: {{ $memAverage | default "75" }}
  {{- end }}
{{- if $extraMetrics }}
{{- toYaml $extraMetrics | nindent 2 }}
{{- end}}
  {{- end }}
{{- with $behavior }}
  behavior:
{{- toYaml . | nindent 4 }}
{{- end }}
{{- end}}

{{- define "logfire.keda" }}
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: {{ .serviceName }}
  labels:
    app.kubernetes.io/component: {{ .serviceName }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: {{ .kind }}
    name: {{ .serviceName }}
  minReplicaCount: {{ .minReplicas | default "1" }}
  maxReplicaCount: {{ .maxReplicas |  default "2" }}
  {{- with .keda.triggers }}
  triggers:
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end}}

{{/* Determine whether HPA is enabled, including the legacy metrics format. */}}
{{- define "logfire.hpa.enabled" -}}
{{- if hasKey . "hpa" -}}
  {{- .hpa.enabled -}}
{{- else if or .memAverage .cpuAverage .extraMetrics -}}
  {{- true -}}
{{- else -}}
  {{- false -}}
{{- end -}}
{{- end -}}

{{- define "logfire.redisDsnFor" -}}
{{- $root := required "logfire.redisDsnFor: need .root" .root -}}
{{- $valuesKey := required "logfire.redisDsnFor: need .valuesKey" .valuesKey -}}
{{- $redisValues := get $root.Values $valuesKey | default dict -}}
{{- get $redisValues "dsn" | default $root.Values.redisDsn -}}
{{- end -}}

{{- define "logfire.redisPrefixFor" -}}
{{- $root := required "logfire.redisPrefixFor: need .root" .root -}}
{{- $valuesKey := required "logfire.redisPrefixFor: need .valuesKey" .valuesKey -}}
{{- $redisValues := get $root.Values $valuesKey | default dict -}}
{{- get $redisValues "prefix" | default "" -}}
{{- end -}}

{{- define "logfire.keda.enabled" -}}
{{- if hasKey . "keda" -}}
  {{- .keda.enabled -}}
{{- else -}}
  {{- false -}}
{{- end -}}
{{- end -}}

{{/*
Resolve effective service values using preset sizing defaults plus explicit overrides.
Only sizing and portable availability keys are inherited from presets.
*/}}
{{- define "logfire.effectiveServiceValues" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceValues := get .Values $serviceName | default dict -}}
{{- $merged := dict -}}
{{- $presetName := .Values.sizingPreset | default "" -}}
{{- if $presetName -}}
  {{- $presets := .Values.sizingPresets | default dict -}}
  {{- if not (hasKey $presets $presetName) -}}
    {{- fail (printf "Unknown sizingPreset %q. Valid presets: %s" $presetName ((keys $presets | sortAlpha) | join ", ")) -}}
  {{- end -}}
  {{- $presetValues := get $presets $presetName | default dict -}}
  {{- if and (eq $presetName "large") (hasKey $presets "standard") -}}
    {{- $presetValues = mergeOverwrite (deepCopy (get $presets "standard")) (deepCopy $presetValues) -}}
  {{- end -}}
  {{- $presetServiceValues := get $presetValues $serviceName | default dict -}}
  {{- range $key := list "resources" "autoscaling" "pdb" "replicas" "maxQueryCostPerPod" "queryParallelism" "datafusionThreads" "datafusionTargetPartitions" "datafusionBatchSize" "ioThreads" "datafusionMemory" "maintenanceRecordBatchMemory" "spillToDiskQuota" "cacheDiskCapacity" "scratchVolume" "volumeClaimTemplates" "jobParallelism" "cpuConcurrency" "parquetSpoolThresholdBytes" "maxCompactionJobSizeBytes" "directFileBufferMaxBytes" "directFileSubmitConcurrency" "topologySpreadConstraints" -}}
    {{- if hasKey $presetServiceValues $key -}}
      {{- $_ := set $merged $key (deepCopy (get $presetServiceValues $key)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $merged = mergeOverwrite $merged (deepCopy $serviceValues) -}}
{{- $merged | toJson -}}
{{- end -}}

{{/*
Render spec.replicas only when autoscaling is not configured for the workload.
*/}}
{{- define "logfire.replicas" -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- if not (hasKey $serviceValues "autoscaling") -}}
replicas: {{ dig "replicas" "1" $serviceValues }}
{{- end -}}
{{- end -}}

{{- define "logfire.autoscaler" }}
{{- include "logfire.validate.autoscaling" (dict "Values" .Values "serviceName" .serviceName) -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" (dict "Values" .Values "serviceName" .serviceName) | fromJson -}}
{{- if index $serviceValues "autoscaling" }}
{{- $kind := (not (eq .serviceName "logfire-ff-ingest") | ternary "Deployment" "StatefulSet" ) }}
{{- with index $serviceValues "autoscaling" }}
  {{- $ctx := deepCopy . -}}
  {{- $_ := set $ctx "serviceName" $.serviceName -}}
  {{- $_ := set $ctx "kind" $kind -}}
  {{- if include "logfire.hpa.enabled" . | eq "true" }}
    {{- template "logfire.hpa" $ctx }}
  {{- end }}
  {{- if include "logfire.keda.enabled" . | eq "true" }}
    {{- template "logfire.keda" $ctx }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "logfire.pdb" }}
{{- $root := .root -}}
{{- $serviceName := .serviceName -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" (dict "Values" $root.Values "serviceName" $serviceName) | fromJson -}}
{{- $pdb := index $serviceValues "pdb" -}}
{{- if hasKey . "pdb" -}}
  {{- $pdb = .pdb -}}
{{- end -}}
{{- if and (hasKey ($pdb | default dict) "minAvailable") (hasKey ($pdb | default dict) "maxUnavailable") -}}
  {{- fail (printf "pdb.minAvailable and pdb.maxUnavailable are mutually exclusive for '%s'. Specify only one." $serviceName) -}}
{{- end -}}
{{- if $pdb }}
{{- with $pdb }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $serviceName }}
  labels:
    {{- include "logfire.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $serviceName }}
spec:
  {{- if hasKey . "maxUnavailable" }}
  maxUnavailable: {{ .maxUnavailable }}
  {{- end }}
  {{- if hasKey . "minAvailable" }}
  minAvailable: {{ .minAvailable }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "logfire.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ $serviceName }}
{{- end }}
{{- end }}
{{- end }}

{{- define "logfire.resources" -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $resources := index $serviceValues "resources" | default dict -}}
{{- if $resources -}}
{{- if hasKey $resources "ephemeralStorageRequest" -}}
{{- fail (printf "resources.ephemeralStorageRequest is not supported for '%s'. Use resources.ephemeralStorage instead." .serviceName) -}}
{{- end -}}
{{- if hasKey $resources "ephemeralStorageLimit" -}}
{{- fail (printf "resources.ephemeralStorageLimit is not supported for '%s'. Use resources.ephemeralStorage instead." .serviceName) -}}
{{- end -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $limits := get $resources "limits" | default dict -}}
{{- $usesFlatResources := or (hasKey $resources "cpu") (hasKey $resources "memory") (hasKey $resources "ephemeralStorage") (hasKey $resources "ephemeral-storage") -}}
{{- $renderLimits := or $usesFlatResources (not (empty $limits)) -}}
{{- $cpuRequest := get $effectiveResources "cpuRequest" -}}
{{- $memoryRequest := get $effectiveResources "memoryRequest" -}}
{{- $ephemeralStorageRequest := get $effectiveResources "ephemeralStorageRequest" -}}
{{- $cpuLimit := get $effectiveResources "cpuLimit" -}}
{{- $memoryLimit := get $effectiveResources "memoryLimit" -}}
{{- $ephemeralStorageLimit := get $effectiveResources "ephemeralStorageLimit" -}}
resources:
  requests:
    memory: {{ $memoryRequest }}
    cpu: {{ $cpuRequest }}
    {{- if $ephemeralStorageRequest }}
    ephemeral-storage: {{ $ephemeralStorageRequest }}
    {{- end }}
  {{- if $renderLimits }}
  limits:
    {{- if or $usesFlatResources (hasKey $limits "memory") }}
    memory: {{ $memoryLimit }}
    {{- end }}
    {{- if or $usesFlatResources (hasKey $limits "cpu") }}
    cpu: {{ $cpuLimit }}
    {{- end }}
    {{- if or (and $usesFlatResources $ephemeralStorageLimit) (hasKey $limits "ephemeral-storage") (hasKey $limits "ephemeralStorage") }}
    ephemeral-storage: {{ $ephemeralStorageLimit }}
    {{- end }}
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Get effective hostnames - prefers explicit gateway.hostnames, falls back to ingress.hostnames
Returns a wrapped object {"hosts": [...]} to work around fromJson limitation with top-level arrays.
*/}}
{{- define "logfire.effective_hostnames" -}}
{{- $hosts := list -}}
{{- if .Values.gateway.hostnames -}}
  {{- $hosts = .Values.gateway.hostnames -}}
{{- else if .Values.ingress.hostnames -}}
  {{- $hosts = .Values.ingress.hostnames -}}
{{- else if .Values.ingress.hostname -}}
  {{- $hosts = list .Values.ingress.hostname -}}
{{- end -}}
{{- dict "hosts" $hosts | toJson -}}
{{- end -}}

{{/*
Get effective TLS setting - prefers explicit gateway.tls, falls back to ingress.tls
*/}}
{{- define "logfire.effective_tls" -}}
{{- if not (kindIs "invalid" .Values.gateway.tls) -}}
  {{- .Values.gateway.tls -}}
{{- else -}}
  {{- .Values.ingress.tls | default false -}}
{{- end -}}
{{- end -}}

{{/*
Get effective TLS secret name - prefers gateway.tlsSecretName when gateway is enabled and set, falls back to ingress.secretName
*/}}
{{- define "logfire.effective_tls_secret" -}}
{{- if and .Values.gateway.enabled .Values.gateway.tlsSecretName -}}
  {{- .Values.gateway.tlsSecretName -}}
{{- else -}}
  {{- .Values.ingress.secretName | default "logfire-frontend-cert" -}}
{{- end -}}
{{- end -}}

{{/*
Primary logfire host for the app. Selects the first item from effective hostnames list
*/}}
{{- define "logfire.primary_hostname" -}}
{{- $result := include "logfire.effective_hostnames" . | fromJson -}}
{{- $hosts := $result.hosts -}}
{{- if $hosts -}}
{{- first $hosts -}}
{{- end -}}
{{- end -}}

{{/*
Full list of logfire hostnames, primary and alternative domains.
*/}}
{{- define "logfire.all_hostnames_string" -}}
{{- $result := include "logfire.effective_hostnames" . | fromJson -}}
{{- $hosts := $result.hosts -}}
{{- if $hosts -}}
{{- join " " $hosts -}}
{{- end -}}
{{- end -}}

{{/*
Primary logfire host with protocol scheme.
*/}}
{{- define "logfire.url" -}}
{{- $primaryHostname := include "logfire.primary_hostname" . | trim -}}
{{- $tls := include "logfire.effective_tls" . -}}
{{- if $primaryHostname -}}
{{ eq $tls "true" | ternary "https" "http" }}://{{ $primaryHostname }}
{{- end -}}
{{- end -}}

{{/*
Public OTLP intake resource URL (RFC 8707 audience).
*/}}
{{- define "logfire.intakeOauthResourceUrl" -}}
{{- if .Values.intakeOauth.resourceUrl -}}
{{- .Values.intakeOauth.resourceUrl -}}
{{- else -}}
{{- printf "%s/v1" (include "logfire.url" . | trim) -}}
{{- end -}}
{{- end -}}

{{/*
Public AI gateway resource URL (RFC 8707 audience). Defaults to the main Logfire URL + /proxy.
*/}}
{{- define "logfire.gatewayOauthResourceUrl" -}}
{{- if .Values.aiGatewayOauth.resourceUrl -}}
{{- .Values.aiGatewayOauth.resourceUrl -}}
{{- else if (index .Values "logfire-ai-gateway" "enabled") -}}
{{- printf "%s/proxy" (include "logfire.url" . | trim) -}}
{{- end -}}
{{- end -}}

{{/*
OAuth issuer for AI gateway tokens. Defaults to the main Logfire URL.
*/}}
{{- define "logfire.gatewayOauthIssuer" -}}
{{- if .Values.aiGatewayOauth.issuer -}}
{{- .Values.aiGatewayOauth.issuer -}}
{{- else if (index .Values "logfire-ai-gateway" "enabled") -}}
{{- include "logfire.url" . | trim -}}
{{- end -}}
{{- end -}}

{{/*
Public host used by the frontend CSP for AI gateway requests.
*/}}
{{- define "logfire.publicGatewayHost" -}}
{{- $resourceUrl := include "logfire.gatewayOauthResourceUrl" . | trim -}}
{{- if $resourceUrl -}}
{{- (urlParse $resourceUrl).host -}}
{{- end -}}
{{- end -}}

{{/*
Full list of logfire urls, primary and alternative domains with scheme.
*/}}
{{- define "logfire.all_urls" -}}
{{- $result := include "logfire.effective_hostnames" . | fromJson -}}
{{- $hosts := $result.hosts -}}
{{- $tls := include "logfire.effective_tls" . -}}

{{- if $hosts -}}
  {{- $scheme := eq $tls "true" | ternary "https" "http" -}}
  {{- $urls := list -}}
  {{- range $host := $hosts -}}
    {{- $fullUrl := printf "%s://%s" $scheme $host -}}
    {{- $urls = append $urls $fullUrl -}}
  {{- end -}}
  {{- join " " $urls -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "logfire.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Expand the name of the chart.
*/}}
{{- define "logfire.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "logfire.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "logfire.labels" -}}
helm.sh/chart: {{ include "logfire.chart" . }}
{{ include "logfire.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Hash rendered configuration without the chart-version label. The label is
resource metadata and must not restart workloads during a version-only chart
promotion.
*/}}
{{- define "logfire.configChecksum" -}}
{{- regexReplaceAll `(?m)(^metadata:\n(?:^[ \t]+[^\n]*\n)*?^[ \t]+labels:\n)[ \t]+helm[.]sh/chart:[^\n]*\n` . `${1}` | sha256sum -}}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "logfire.selectorLabels" -}}
app.kubernetes.io/name: {{ include "logfire.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use.
Supports both new serviceAccount.name and deprecated serviceAccountName for backward compatibility.
*/}}
{{- define "logfire.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
  {{- default (include "logfire.fullname" .) .Values.serviceAccount.name }}
{{- else }}
  {{- if .Values.serviceAccount.name }}
    {{- .Values.serviceAccount.name }}
  {{- else if .Values.serviceAccountName }}
    {{- .Values.serviceAccountName }}
  {{- else }}
    {{- "default" }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
ServiceAccount to use for Helm hooks. On first install with create=true,
the ServiceAccount isn't created yet, so fall back to default.
*/}}
{{- define "logfire.hookServiceAccountName" -}}
{{- if and .Release.IsInstall .Values.serviceAccount.create }}
  {{- "default" }}
{{- else }}
  {{- include "logfire.serviceAccountName" . }}
{{- end }}
{{- end }}

{{/*
Get service-specific image tag, falling back to global tag
Usage: {{ include "logfire.serviceTag" (dict "Values" .Values "serviceName" "logfire-backend" "Chart" .Chart) }}
*/}}
{{- define "logfire.serviceTag" -}}
{{- $serviceValues := index .Values .serviceName | default dict -}}
{{- $serviceImage := $serviceValues.image | default dict -}}
{{- $serviceTag := $serviceImage.tag -}}
{{- if $serviceTag -}}
{{- $serviceTag -}}
{{- else -}}
{{- default .Chart.AppVersion .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Get the runtime version for a service, matching the selected image tag.
Usage: {{ include "logfire.serviceVersion" (dict "root" . "serviceName" "logfire-backend") }}
*/}}
{{- define "logfire.serviceVersion" -}}
{{- include "logfire.serviceTag" (dict "Values" .root.Values "serviceName" .serviceName "Chart" .root.Chart) -}}
{{- end -}}

{{/*
Build OTEL resource attributes for a service using the runtime image tag.
Usage: {{ include "logfire.otelResourceAttributes" (dict "root" . "serviceName" "logfire-backend" "codeWorkDir" "/app") }}
*/}}
{{- define "logfire.otelResourceAttributes" -}}
{{- $version := include "logfire.serviceVersion" . -}}
{{- $attrs := dict
  "vcs.repository.url.full" "https://github.com/pydantic/platform"
  "vcs.repository.ref.revision" $version
  "service.version" $version
-}}
{{- with .codeWorkDir }}
  {{- $_ := set $attrs "logfire.code.work_dir" . -}}
{{- end }}
{{- $attrs = mergeOverwrite $attrs ((get .root.Values "otelResourceAttributes") | default dict) -}}
{{- include "logfire.renderOtelResourceAttributes" $attrs -}}
{{- end -}}

{{/*
Render OTEL resource attributes from a map into OTEL_RESOURCE_ATTRIBUTES format.
Usage: {{ include "logfire.renderOtelResourceAttributes" (dict "service.name" "my-service") }}
*/}}
{{- define "logfire.renderOtelResourceAttributes" -}}
{{- $resourceAttributes := . | default dict -}}
{{- $pairs := list -}}
{{- range $key := keys $resourceAttributes | sortAlpha }}
  {{- $pairs = append $pairs (printf "%s=%v" $key (get $resourceAttributes $key)) -}}
{{- end -}}
{{- join "," $pairs -}}
{{- end -}}

{{/*
Render AI model environment variables shared across workloads.
*/}}
{{- define "logfire.aiModelEnv" -}}
{{- $ai := .root.Values.ai | default dict -}}
{{- $roles := .roles | default list -}}
{{- with (get $ai "model") }}
- name: AI_MODEL_DEFAULT
  value: {{ . }}
{{- end }}
{{- if has "chat" $roles }}
{{- with (get $ai "chatModel") }}
- name: AI_MODEL_CHAT
  value: {{ . }}
{{- end }}
{{- end }}
{{- if has "reasoning" $roles }}
{{- with ((get $ai "reasoningModel") | default (get $ai "model")) }}
- name: AI_MODEL_REASONING
  value: {{ . }}
{{- end }}
{{- end }}
{{- with (get $ai "llmJudgeModel") }}
- name: AI_MODEL_LLM_JUDGE
  value: {{ . }}
{{- end }}
{{- end -}}

{{- define "logfire.envValue" -}}
{{- $value := .value -}}
{{- $quote := .quote | default false -}}
{{- $allowValueKey := .allowValueKey | default false -}}
{{- if kindIs "map" $value -}}
{{- $lines := list -}}
{{- if and $allowValueKey (hasKey $value "value") -}}
  {{- if kindIs "invalid" $value.value -}}
    {{- $lines = append $lines "value:" -}}
  {{- else -}}
  {{- $renderedValue := ternary ($value.value | toString | quote) ($value.value | toString) $quote -}}
  {{- $lines = append $lines (printf "value: %s" $renderedValue) -}}
  {{- end -}}
{{- end -}}
{{- if hasKey $value "valueFrom" -}}
  {{- $lines = append $lines (printf "valueFrom:\n%s" (toYaml $value.valueFrom | indent 2 | trimSuffix "\n")) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- else }}
{{- if kindIs "invalid" $value -}}
{{- printf "value:" -}}
{{- else -}}
{{- $renderedValue := ternary ($value | toString | quote) ($value | toString) $quote -}}
{{- printf "value: %s" $renderedValue -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Render shared AI provider environment variables for workloads that construct AI clients.
*/}}
{{- define "logfire.aiProviderEnv" -}}
{{- $ai := .Values.ai | default dict -}}
{{- $openAi := get $ai "openAi" | default dict -}}
{{- $vertexAi := get $ai "vertexAi" | default dict -}}
{{- $azureOpenAi := get $ai "azureOpenAi" | default dict -}}
{{- with (get $openAi "apiKey") }}
- name: OPENAI_API_KEY
{{ include "logfire.envValue" (dict "value" .) | indent 2 }}
{{- end }}
{{- with (get $openAi "baseUrl") }}
- name: OPENAI_BASE_URL
{{ include "logfire.envValue" (dict "value" .) | indent 2 }}
{{- end }}
{{- with (get $vertexAi "region") }}
- name: GOOGLE_CLOUD_LOCATION
  value: {{ . }}
{{- if (get $vertexAi "anthropicProjectId") }}
- name: CLOUD_ML_REGION
  value: {{ . }}
{{- end }}
{{- end }}
{{- with (get $vertexAi "multiRegionLocation") }}
- name: GOOGLE_CLOUD_MULTI_REGION_LOCATION
  value: {{ . }}
{{- end }}
{{- with (get $vertexAi "anthropicProjectId") }}
- name: ANTHROPIC_VERTEX_PROJECT_ID
  value: {{ . }}
{{- end }}
{{- with (get $vertexAi "anthropicBaseUrl") }}
- name: ANTHROPIC_VERTEX_BASE_URL
  value: {{ . }}
{{- end }}
{{- with (get $azureOpenAi "endpoint") }}
- name: AZURE_OPENAI_ENDPOINT
  value: {{ . }}
{{- end }}
{{- with (get $azureOpenAi "apiKey") }}
- name: AZURE_OPENAI_API_KEY
{{ include "logfire.envValue" (dict "value" .) | indent 2 }}
{{- end }}
{{- with (get $azureOpenAi "apiVersion") }}
- name: OPENAI_API_VERSION
  value: {{ . }}
{{- end }}
{{- end -}}

{{/*
Create dex config secret name
*/}}
{{- define "logfire.dexSecretName" -}}
{{- printf "%s-dex-config" (include "logfire.fullname" .) }}
{{- end -}}

{{- define "logfire.hooksAnnotations" -}}
{{- with .Values.hooksAnnotations }}
{{- range $key, $value := . }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "logfire.hooksAnnotationsWithoutArgoDeletePolicy" -}}
{{- with .Values.hooksAnnotations }}
{{- range $key, $value := . }}
{{- if ne $key "argocd.argoproj.io/hook-delete-policy" }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Create Postgres secret name
*/}}
{{- define "logfire.postgresSecretName" -}}
{{- if .Values.postgresSecret.enabled }}
{{- .Values.postgresSecret.name }}
{{- else }}
{{- include "logfire.fullname" . }}-pg
{{- end }}
{{- end -}}

{{/* Use an external Secret name when configured, otherwise the managed name. */}}
{{- define "logfire.externalSecretName" -}}
{{- $external := .external | default dict -}}
{{- if and (get $external "enabled") (get $external "name") -}}
{{- get $external "name" -}}
{{- else }}
{{- .secretName }}
{{- end }}
{{- end -}}

{{- define "logfire.objectStoreEnv" -}}
- name: FF_OBJECT_STORE_URI
  value: {{ .Values.objectStore.uri }}
{{- with .Values.objectStore.sseCKeyB64 }}
- name: FF_S3_SSE_C_KEY_B64
{{ include "logfire.envValue" (dict "value" . "quote" true) | indent 2 }}
{{- end }}
{{- range $key, $value := .Values.objectStore.env }}
- name: {{ $key }}
{{ include "logfire.envValue" (dict "value" $value "quote" (not (kindIs "map" $value)) "allowValueKey" true) | indent 2 }}
{{- end }}
{{- end -}}

{{- define "logfire.objectStoreVolumeMounts" -}}
{{- if .Values.objectStore.volumeMounts }}
{{- .Values.objectStore.volumeMounts | toYaml }}
{{- end }}
{{- end -}}

{{- define "logfire.objectStoreVolumes" -}}
{{- if .Values.objectStore.volumes }}
{{- .Values.objectStore.volumes | toYaml }}
{{- end }}
{{- end -}}

{{/*
Create dex config secret name
*/}}
{{- define "logfire.dexClientId" -}}
{{- printf "logfire-backend" }}
{{- end -}}

{{/*
Create dex configuration secret, merging backend static clients with user provided storage and oauth connectors.
*/}}
{{- define "logfire.dexConfig" -}}
{{- $dexConfig := dig "config" dict (index .Values "logfire-dex" | default dict) -}}
{{- $staticClients := list -}}
{{- $logfireFrontend := (include "logfire.url" .) -}}
{{- $logfireUrls := include "logfire.all_urls" . | splitList " " }}
{{- $dexCallback := printf "%s/auth-api/callback" $logfireFrontend -}}

{{- $frontend := dict -}}
{{- $extraVars := dict "logfire_frontend_host" (printf "%s" $logfireFrontend) -}}
{{- $_ := set $frontend "extra" $extraVars -}}

{{- $oauth2 := dict "skipApprovalScreen" true "passwordConnector" "local" -}}

{{- $web := dict "http" "0.0.0.0:5556" -}}
{{- if (include "logfire.inClusterTls.enabled" . | eq "true") -}}
  {{- $_ := set $web "https" (printf "0.0.0.0:%v" .Values.inClusterTls.httpsPort) -}}
  {{- $_ := set $web "tlsCert" "/etc/dex/tls/tls.crt" -}}
  {{- $_ := set $web "tlsKey" "/etc/dex/tls/tls.key" -}}
{{- end -}}
{{- $grpc := dict "addr" "0.0.0.0:5557" -}}
{{- if (include "logfire.inClusterTls.enabled" . | eq "true") -}}
  {{- $_ := set $grpc "tlsCert" "/etc/dex/tls/tls.crt" -}}
  {{- $_ := set $grpc "tlsKey" "/etc/dex/tls/tls.key" -}}
{{- end -}}

{{- $client := dict -}}
{{- $_ := set $client "id" (include "logfire.dexClientId" .) -}}
{{- $_ := set $client "name" "Logfire Backend" -}}
{{- $_ := set $client "secretEnv" "LOGFIRE_CLIENT_SECRET" -}}
{{- $redirects := list -}}
{{- range $url := $logfireUrls -}}
  {{- $redirects = append $redirects (printf "%s/auth/code-callback" $url) -}}
  {{- $redirects = append $redirects (printf "%s/auth/link-provider-code-callback" $url) -}}
  {{- $redirects = append $redirects (printf "%s/auth/authorize-device-token-sso-callback" $url) -}}
{{- end -}}
{{- $_ := set $client "redirectURIs" $redirects -}}
{{- $_ := set $client "public" false -}}
{{- $_ := set $client "scopes"  (list "openid" "email" "profile") -}}
{{- $staticClients = append $staticClients $client -}}

{{- if and (hasKey $dexConfig "staticClients") $dexConfig.staticClients -}}
  {{- range $client := $dexConfig.staticClients -}}
    {{- $staticClients = append $staticClients $client -}}
  {{- end -}}
{{- end -}}

{{- $connectors := list -}}

{{- with $dexConfig.connectors -}}
  {{- range $connector := . -}}
    {{- if and (hasKey $connector "config") $connector.config -}}
      {{- if not (hasKey $connector.config "redirectURI") -}}
        {{- $_ := set $connector.config "redirectURI" $dexCallback  -}}
      {{- end -}}
    {{- end -}}
    {{- $connectors = append $connectors $connector -}}
  {{- end -}}
{{- end -}}

{{- $_ := set $dexConfig "issuer" (printf "%s/auth-api" $logfireFrontend) -}}
{{- $_ := set $dexConfig "staticClients" $staticClients -}}
{{- $_ := set $dexConfig "frontend" $frontend -}}
{{- $_ := set $dexConfig "oauth2" $oauth2 -}}
{{- $_ := set $dexConfig "web" $web -}}
{{- $_ := set $dexConfig "grpc" $grpc -}}
{{- if not (hasKey $dexConfig "enablePasswordDB") -}}
  {{- $_ := set $dexConfig "enablePasswordDB" true -}}
{{- end -}}
{{- $_ := set $dexConfig "connectors" $connectors -}}

{{ toYaml $dexConfig | b64enc | quote }}
{{- end -}}

{{- define "isPrometheusExporterEnabled" -}}
{{- with .Values.otel_collector }}
  {{- with .prometheus }}
    {{- if eq .enabled true }}true{{- else }}false{{- end }}
  {{- else }}
    false
  {{- end }}
{{- else }}
  false
{{- end }}
{{- end }}

{{/*
Render a fully-qualified container image reference using chart defaults when
overrides are not provided.
*/}}
{{- define "logfire.imageRef" -}}
{{- $image := .image | default dict -}}
{{- $repository := $image.repository | default .defaultRepository -}}
{{- $tag := $image.tag -}}
{{- $hasTag := hasKey $image "tag" -}}
{{- if not $hasTag }}
  {{- $tag = .defaultTag -}}
{{- end }}
{{- if and $hasTag (eq $tag "") }}
  {{- printf "%s" $repository -}}
{{- else if $tag }}
  {{- printf "%s:%s" $repository $tag -}}
{{- else }}
  {{- printf "%s" $repository -}}
{{- end }}
{{- end }}

{{- define "logfire.otlpExporterEnv" }}
{{- $serviceName := .serviceName -}}
{{- $root := .root -}}
- name: "OTEL_EXPORTER_OTLP_PROTOCOL"
  value: "grpc"
- name: "COLLECTOR_OTLP_GRPC_HOST"
  value: http://logfire-otel-collector:4317
- name: LOGFIRE_SERVICE_NAME
  value: {{ $serviceName }}
- name: LOGFIRE_SERVICE_VERSION
  value: {{ include "logfire.serviceVersion" (dict "root" $root "serviceName" $serviceName) | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ $serviceName }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ include "logfire.otelResourceAttributes" (dict "root" $root "serviceName" $serviceName "codeWorkDir" .codeWorkDir) | quote }}
{{- end }}

{{- define "logfire.scratchVolumeName" -}}
scratch-data
{{- end -}}

{{/*
Render storageClassName for chart-managed PVCs.
Non-empty component values win. Otherwise, defaultStorageClassName is used.
A value of "-" renders storageClassName: "" to disable dynamic provisioning.
*/}}
{{- define "logfire.storageClassName" -}}
{{- $root := .root -}}
{{- $values := .values | default dict -}}
{{- $storageClassName := "" -}}
{{- $componentStorageClassName := default "" (get $values "storageClassName") -}}
{{- if $componentStorageClassName -}}
  {{- $storageClassName = $componentStorageClassName -}}
{{- else if $root.Values.defaultStorageClassName -}}
  {{- $storageClassName = $root.Values.defaultStorageClassName -}}
{{- end -}}
{{- $storageClassName = toString $storageClassName -}}
{{- if eq $storageClassName "-" -}}
storageClassName: ""
{{- else if $storageClassName -}}
storageClassName: {{ $storageClassName | quote }}
{{- end -}}
{{- end -}}

{{- define "logfire.scratchVolume" -}}
{{- $root := .root -}}
{{- $scratchVolume := .scratchVolume | default dict -}}
{{- if $scratchVolume -}}
- name: {{ include "logfire.scratchVolumeName" . }}
  ephemeral:
    volumeClaimTemplate:
      {{- if $scratchVolume.labels }}
      metadata:
        labels:
          {{- $scratchVolume.labels | toYaml | nindent 10 }}
      {{- end }}
      spec:
        accessModes: [ "ReadWriteOnce" ]
        {{- include "logfire.storageClassName" (dict "root" $root "values" $scratchVolume) | nindent 8 }}
        resources:
          requests:
            storage: {{ $scratchVolume.storage }}
{{- else -}}
- name: {{ include "logfire.scratchVolumeName" . }}
  emptyDir: {}
{{- end -}}
{{- end -}}

{{- define "logfire.ingestVolumeName" -}}
ingest-data
{{- end -}}

{{- define "logfire.ingestVolume" -}}
{{- $root := .root -}}
{{- $ingestVolume := .ingestVolume | default dict -}}
- metadata:
    name: {{ include "logfire.ingestVolumeName" . }}
  spec:
    accessModes: [ "ReadWriteOnce" ]
    {{- include "logfire.storageClassName" (dict "root" $root "values" $ingestVolume) | nindent 4 }}
    resources:
      requests:
        storage: {{ $ingestVolume.storage }}
{{- end -}}

{{/*
Render workload annotations. Secret annotations are included only for sources
used by the workload, and workload-specific values take precedence.
*/}}
{{- define "logfire.workloadAnnotations" -}}
{{- $values := .Values -}}
{{- $serviceName := .serviceName -}}
{{- $secretSources := .secretSources | default list -}}
{{- $merged := dict -}}
{{- range $source := $secretSources }}
  {{- if eq $source "postgres" -}}
    {{- if and $values.postgresSecret.enabled (not (empty $values.postgresSecret.annotations)) -}}
      {{- $merged = mergeOverwrite $merged $values.postgresSecret.annotations -}}
    {{- end -}}
  {{- else if eq $source "existing" -}}
    {{- $secret := get $values "existingSecret" | default dict -}}
    {{- if and (get $secret "enabled") (not (empty (get $secret "annotations"))) -}}
      {{- $merged = mergeOverwrite $merged (get $secret "annotations") -}}
    {{- end -}}
  {{- else if eq $source "gateway" -}}
    {{- $secret := get $values "existingGatewaySecret" | default dict -}}
    {{- if and (index $values "logfire-ai-gateway" "enabled") (get $secret "enabled") (not (empty (get $secret "annotations"))) -}}
      {{- $merged = mergeOverwrite $merged (get $secret "annotations") -}}
    {{- end -}}
  {{- else if eq $source "admin" -}}
    {{- $secret := get $values "adminSecret" | default dict -}}
    {{- if and (get $secret "enabled") (not (empty (get $secret "annotations"))) -}}
      {{- $merged = mergeOverwrite $merged (get $secret "annotations") -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $serviceValues := index $values $serviceName | default dict -}}
{{- if $serviceValues.annotations -}}
  {{- $merged = mergeOverwrite $merged $serviceValues.annotations -}}
{{- end -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end -}}

{{/*
Render workload-specific pod annotations.
*/}}
{{- define "logfire.podAnnotations" -}}
{{- $serviceValues := index .Values .serviceName | default dict -}}
{{- if $serviceValues.podAnnotations -}}
{{- toYaml $serviceValues.podAnnotations -}}
{{- end -}}
{{- end -}}

{{/*
Custom labels for workloads
*/}}
{{- define "logfire.workloadLabels" -}}
{{- $serviceValues := index .Values .serviceName -}}
{{- if and $serviceValues $serviceValues.labels -}}
{{- toYaml $serviceValues.labels -}}
{{- end -}}
{{- end -}}

{{/*
Custom labels for workloads pods
*/}}
{{- define "logfire.podLabels" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceValues := index .Values $serviceName | default dict -}}
{{- $servicePodLabels := $serviceValues.podLabels | default dict -}}
{{- $merged := deepCopy $servicePodLabels -}}
{{- if dig "disableSidecarOnKnownWorkloads" false (.Values.istio | default dict) -}}
  {{- $knownWorkloads := list
    "logfire-service"
    "logfire-ff-proxy-cache-byte"
    "logfire-backend-migrations"
    "logfire-ff-migrations"
    "logfire-redis"
    "logfire-otel-collector"
    -}}
  {{- if and (has $serviceName $knownWorkloads) (not (hasKey $merged "sidecar.istio.io/inject")) -}}
    {{- $_ := set $merged "sidecar.istio.io/inject" "false" -}}
  {{- end -}}
{{- end -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end -}}

{{/*
Custom annotations for workloads services
*/}}
{{- define "logfire.serviceAnnotations" -}}
{{- $serviceValues := index .Values .serviceName -}}
{{- if and $serviceValues $serviceValues.service $serviceValues.service.annotations -}}
{{- toYaml $serviceValues.service.annotations -}}
{{- end -}}
{{- end -}}

{{/*
Initial checksum for autogenerated secrets
*/}}
{{- define "utils.secretChecksum" -}}
{{- $ctx  := required "secretChecksum: need .ctx"  .ctx  -}}
{{- $name := required "secretChecksum: need .name" .name -}}
{{- $key  := required "secretChecksum: need .key"  .key  -}}

{{- $secret := lookup "v1" "Secret" $ctx.Release.Namespace $name -}}

{{- if and $secret (hasKey $secret.data $key) -}}
{{ index $secret.data $key | sha256sum }}
{{- else -}}
default-checksum
{{- end -}}
{{- end -}}

{{- define "logfire.secretChecksumAnnotation" -}}
{{- $ctx := required "logfire.secretChecksumAnnotation: need .ctx" .ctx -}}
{{- $name := required "logfire.secretChecksumAnnotation: need .name" .name -}}
{{- $key := required "logfire.secretChecksumAnnotation: need .key" .key -}}
{{- $annotationKey := .annotationKey | default (printf "checksum/%s" $key) -}}
{{- printf "%s: %s" $annotationKey (include "utils.secretChecksum" (dict "ctx" $ctx "name" $name "key" $key) | trim) -}}
{{- end -}}

{{- define "logfire.postgresSecretChecksumAnnotation" -}}
{{- $ctx := required "logfire.postgresSecretChecksumAnnotation: need .ctx" .ctx -}}
{{- $key := .key | default "postgresDsn" -}}
{{- $annotationKey := .annotationKey | default (eq $key "postgresFFDsn" | ternary "checksum/logfire-postgres-ff-dsn" "checksum/logfire-postgres-dsn") -}}
{{- include "logfire.secretChecksumAnnotation" (dict "ctx" $ctx "annotationKey" $annotationKey "name" (include "logfire.postgresSecretName" $ctx) "key" $key) -}}
{{- end -}}

{{- define "logfire.logfireSecretChecksumAnnotations" -}}
{{- $ctx := required "logfire.logfireSecretChecksumAnnotations: need .ctx" .ctx -}}
{{- $lines := list -}}
{{- range $secretName := required "logfire.logfireSecretChecksumAnnotations: need .secrets" .secrets }}
  {{- $name := include "logfire.externalSecretName" (dict "external" $ctx.Values.existingSecret "secretName" $secretName) | trim -}}
  {{- $lines = append $lines (include "logfire.secretChecksumAnnotation" (dict "ctx" $ctx "name" $name "key" $secretName)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{- define "logfire.gatewaySecretChecksumAnnotations" -}}
{{- $ctx := required "logfire.gatewaySecretChecksumAnnotations: need .ctx" .ctx -}}
{{- list
  (include "logfire.secretChecksumAnnotation" (dict "ctx" $ctx "annotationKey" "checksum/gateway-encryption" "name" (include "logfire.externalSecretName" (dict "external" $ctx.Values.existingGatewaySecret "secretName" "gateway-encryption") | trim) "key" "key"))
  (include "logfire.secretChecksumAnnotation" (dict "ctx" $ctx "annotationKey" "checksum/gateway-internal-secret" "name" (include "logfire.externalSecretName" (dict "external" $ctx.Values.existingGatewaySecret "secretName" "gateway-internal-secret") | trim) "key" "internalSecret"))
  | join "\n" -}}
{{- end -}}

{{- define "logfire.adminSecretChecksumAnnotations" -}}
{{- $ctx := required "logfire.adminSecretChecksumAnnotations: need .ctx" .ctx -}}
{{- $lines := list -}}
{{- range $secretName := list "logfire-admin-password" "logfire-admin-totp-secret" "logfire-admin-totp-recovery-codes" }}
  {{- $name := include "logfire.externalSecretName" (dict "external" $ctx.Values.adminSecret "secretName" $secretName) | trim -}}
  {{- $lines = append $lines (include "logfire.secretChecksumAnnotation" (dict "ctx" $ctx "name" $name "key" $secretName)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{- define "logfire.migrationJobName" -}}
{{- $name := required "logfire.migrationJobName: need .name" .name -}}
{{- $ctx := required "logfire.migrationJobName: need .ctx" .ctx -}}
{{- if $ctx.Values.dev.deployPostgres -}}
{{- printf "%s-%d" $name $ctx.Release.Revision | quote -}}
{{- else -}}
{{- $name | quote -}}
{{- end -}}
{{- end -}}

{{/*
Render global and service-level pod scheduling. Optional default topology spread
constraints are appended only when the merged user/preset list does not already
contain the same topologyKey.
*/}}
{{- define "logfire.podScheduling" -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $nodeSelector := merge (deepCopy ($serviceValues.nodeSelector | default dict)) (.Values.nodeSelector | default dict) -}}
{{- $affinity := merge (deepCopy ($serviceValues.affinity | default dict)) (.Values.affinity | default dict) -}}
{{- $tolerations := concat ($serviceValues.tolerations | default list) (.Values.tolerations | default list) -}}
{{- $topologySpreadConstraints := concat ($serviceValues.topologySpreadConstraints | default list) (.Values.topologySpreadConstraints | default list) -}}
{{- range (.defaultTopologySpreadConstraints | default list) -}}
  {{- $defaultConstraint := . -}}
  {{- $topologyKey := get $defaultConstraint "topologyKey" -}}
  {{- $hasTopologyKey := false -}}
  {{- range $topologySpreadConstraints -}}
    {{- if eq (get . "topologyKey") $topologyKey -}}
      {{- $hasTopologyKey = true -}}
    {{- end -}}
  {{- end -}}
  {{- if not $hasTopologyKey -}}
    {{- $topologySpreadConstraints = append $topologySpreadConstraints $defaultConstraint -}}
  {{- end -}}
{{- end -}}
{{- $blocks := list -}}
{{- if $nodeSelector -}}
{{- $blocks = append $blocks (printf "nodeSelector:%s" (toYaml $nodeSelector | nindent 2 | trimSuffix "\n")) -}}
{{- end -}}
{{- if $affinity -}}
{{- $blocks = append $blocks (printf "affinity:%s" (toYaml $affinity | nindent 2 | trimSuffix "\n")) -}}
{{- end -}}
{{- if $tolerations -}}
{{- $blocks = append $blocks (printf "tolerations:%s" (toYaml $tolerations | nindent 2 | trimSuffix "\n")) -}}
{{- end -}}
{{- if $topologySpreadConstraints -}}
{{- $blocks = append $blocks (printf "topologySpreadConstraints:%s" (toYaml $topologySpreadConstraints | nindent 2 | trimSuffix "\n")) -}}
{{- end -}}
{{- join "\n" $blocks -}}
{{- end -}}

{{- define "logfire.securityContext" -}}
{{- with . -}}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end -}}
{{- end -}}

{{- define "logfire.standardPodSpecFields" -}}
{{- $ctx := required "logfire.standardPodSpecFields: need .ctx" .ctx -}}
{{- $serviceName := required "logfire.standardPodSpecFields: need .serviceName" .serviceName -}}
{{- $lines := list -}}
{{- with ($ctx.Values.priorityClassName | default "") -}}
  {{- $lines = append $lines (printf "priorityClassName: %s" .) -}}
{{- end -}}
{{- $lines = append $lines (printf "serviceAccountName: %s" (include "logfire.serviceAccountName" $ctx | trim)) -}}
{{- with $ctx.Values.imagePullSecrets -}}
  {{- $imagePullSecretLines := list "imagePullSecrets:" -}}
  {{- range . -}}
    {{- $imagePullSecretLines = append $imagePullSecretLines (printf "  - name: %s" (. | quote)) -}}
  {{- end -}}
  {{- $lines = append $lines (join "\n" $imagePullSecretLines) -}}
{{- end -}}
{{- $initContainers := include "logfire.initContainers" (dict "ctx" $ctx "serviceName" $serviceName) | trim -}}
{{- if $initContainers -}}
  {{- $lines = append $lines $initContainers -}}
{{- end -}}
{{- with $ctx.Values.podSecurityContext -}}
  {{- $lines = append $lines (include "logfire.securityContext" . | trim) -}}
{{- end -}}
{{- $podScheduling := include "logfire.podScheduling" (dict "Values" $ctx.Values "serviceName" $serviceName) | trim -}}
{{- if $podScheduling -}}
  {{- $lines = append $lines $podScheduling -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{- define "logfire.groupOrganizationMapping" -}}
{{- if .Values.groupOrganizationMapping -}}
{{- $mappings := list -}}
{{- range $idx, $group := .Values.groupOrganizationMapping -}}
  {{- if not $group.group_id -}}
    {{- fail (printf "groupOrganizationMapping[%d]: 'group_id' is required" $idx) -}}
  {{- end -}}

  {{- if not $group.organization_roles -}}
    {{- fail (printf "groupOrganizationMapping[%d]: 'organization_roles' is required for group_id '%s'" $idx $group.group_id) -}}
  {{- end -}}

  {{- if not (kindIs "slice" $group.organization_roles) -}}
    {{- fail (printf "groupOrganizationMapping[%d]: 'organization_roles' must be a list for group_id '%s'" $idx $group.group_id) -}}
  {{- end -}}

  {{- $orgRoles := list -}}
  {{- range $orgIdx, $org := $group.organization_roles -}}
    {{- if not $org.organization_name -}}
      {{- fail (printf "groupOrganizationMapping[%d].organization_roles[%d]: 'organization_name' is required" $idx $orgIdx) -}}
    {{- end -}}

    {{- if not $org.role -}}
      {{- fail (printf "groupOrganizationMapping[%d].organization_roles[%d]: 'role' is required for organization '%s'" $idx $orgIdx $org.organization_name) -}}
    {{- end -}}

    {{- $projectRoles := list -}}
    {{- if $org.project_roles -}}
      {{- if not (kindIs "slice" $org.project_roles) -}}
        {{- fail (printf "groupOrganizationMapping[%d].organization_roles[%d]: 'project_roles' must be a list for organization '%s'" $idx $orgIdx $org.organization_name) -}}
      {{- end -}}

      {{- range $projIdx, $proj := $org.project_roles -}}
        {{- if not $proj.project_name -}}
          {{- fail (printf "groupOrganizationMapping[%d].organization_roles[%d].project_roles[%d]: 'project_name' is required" $idx $orgIdx $projIdx) -}}
        {{- end -}}

        {{- if not $proj.role -}}
          {{- fail (printf "groupOrganizationMapping[%d].organization_roles[%d].project_roles[%d]: 'role' is required for project '%s'" $idx $orgIdx $projIdx $proj.project_name) -}}
        {{- end -}}

        {{- $projectRoles = append $projectRoles (dict "project_name" $proj.project_name "role" $proj.role) -}}
      {{- end -}}
    {{- end -}}

    {{- if $projectRoles -}}
      {{- $orgRoles = append $orgRoles (dict "organization_name" $org.organization_name "role" $org.role "project_roles" $projectRoles) -}}
    {{- else -}}
      {{- $orgRoles = append $orgRoles (dict "organization_name" $org.organization_name "role" $org.role) -}}
    {{- end -}}
  {{- end -}}

  {{- $mappings = append $mappings (dict "group_id" $group.group_id "organization_roles" $orgRoles) -}}
{{- end -}}

- name: GROUP_ORGANIZATION_MAPPING
  value: {{ $mappings | toJson | quote }}
{{- end -}}
{{- end -}}

{{- define "logfire.rateLimits" -}}
{{- with .Values.rateLimits -}}
{{- $queries := get . "queries" | default dict -}}
- name: ENTERPRISE_CLOUD_RATE_LIMITS__SDK_V1_QUERY__PER_MINUTE
  value: {{ (get $queries "perMinute" | default 99999) | quote }}
- name: ENTERPRISE_CLOUD_RATE_LIMITS__SDK_V1_QUERY__PER_HOUR
  value: {{ (get $queries "perHour" | default 99999) | quote }}
{{- end -}}
{{- end -}}

{{/*
================================================================================
In-cluster TLS helpers
================================================================================
*/}}

{{- define "logfire.inClusterTls.enabled" -}}
{{- .Values.inClusterTls.enabled | default false -}}
{{- end -}}

{{/*
Render an HAProxy server line, including in-cluster TLS when enabled.
*/}}
{{- define "logfire.inClusterTls.haproxyUpstream" -}}
{{- $ctx := required "logfire.inClusterTls.haproxyUpstream: need .ctx" .ctx -}}
{{- $name := required "logfire.inClusterTls.haproxyUpstream: need .name" .name -}}
{{- $serviceName := required "logfire.inClusterTls.haproxyUpstream: need .serviceName" .serviceName -}}
{{- $cleartextPort := required "logfire.inClusterTls.haproxyUpstream: need .cleartextPort" .cleartextPort -}}
{{- $certificateServiceName := .certificateServiceName | default $serviceName -}}
{{- $clusterDomain := $ctx.Values.clusterDomain | default "cluster.local" -}}
{{- $host := printf "%s.%s.svc.%s" $serviceName $ctx.Release.Namespace $clusterDomain -}}
{{- $certificateHost := printf "%s.%s.svc.%s" $certificateServiceName $ctx.Release.Namespace $clusterDomain -}}
{{- $checkSsl := true -}}
{{- if hasKey . "checkSsl" -}}{{- $checkSsl = .checkSsl -}}{{- end -}}
{{- if .replicas -}}server-template {{ $name }} 1-{{ .replicas }}{{- else -}}server {{ $name }}{{- end }} {{ $host }}.:{{ ternary $ctx.Values.inClusterTls.httpsPort $cleartextPort (include "logfire.inClusterTls.enabled" $ctx | eq "true") }}{{ with .options }} {{ . }}{{ end }}{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") }} ssl verify required ca-file /usr/local/etc/haproxy/ca/ca.crt sni str({{ $certificateHost }}) verifyhost {{ $certificateHost }}{{ if $checkSsl }} check-ssl{{ end }}{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.secretName" -}}
{{- $prefix := .ctx.Values.inClusterTls.secretNamePrefix | default .ctx.Release.Name -}}
{{- printf "%s-%s-tls" $prefix .serviceName -}}
{{- end -}}

{{- define "logfire.inClusterTls.certs.mode" -}}
{{- dig "certs" "mode" "existingSecrets" .Values.inClusterTls -}}
{{- end -}}

{{- define "logfire.inClusterTls.certs.isCertManager" -}}
{{- eq (include "logfire.inClusterTls.certs.mode" .) "certManager" -}}
{{- end -}}

{{- define "logfire.inClusterTls.certs.certManager.issuerRef.kind" -}}
{{- dig "certs" "certManager" "issuerRef" "kind" "Issuer" .Values.inClusterTls -}}
{{- end -}}

{{- define "logfire.inClusterTls.certs.certManager.issuerRef.name" -}}
{{- dig "certs" "certManager" "issuerRef" "name" "" .Values.inClusterTls -}}
{{- end -}}

{{- define "logfire.inClusterTls.certs.certManager.issuerRef.group" -}}
{{- dig "certs" "certManager" "issuerRef" "group" "cert-manager.io" .Values.inClusterTls -}}
{{- end -}}

{{- define "logfire.inClusterTls.certs.certManager.autoIssuer" -}}
{{- and (include "logfire.inClusterTls.certs.isCertManager" . | eq "true") (not (include "logfire.inClusterTls.certs.certManager.issuerRef.name" .)) -}}
{{- end -}}

{{- define "logfire.inClusterTls.certs.certManager.autoCaSecretName" -}}
{{- printf "%s-incluster-ca" .Release.Name -}}
{{- end -}}

{{- define "logfire.inClusterTls.https.servicePort" -}}
{{- $ctx := .ctx -}}
{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") -}}
- name: {{ .name | default "https" }}
  port: {{ $ctx.Values.inClusterTls.httpsPort }}
  targetPort: {{ .targetPort | default "https" }}
  appProtocol: HTTPS
  protocol: TCP
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.https.containerPort" -}}
{{- $ctx := .ctx -}}
{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") -}}
- name: {{ .name | default "https" }}
  containerPort: {{ $ctx.Values.inClusterTls.httpsPort }}
  protocol: TCP
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.server.checksumAnnotation" -}}
{{- $ctx := .ctx -}}
{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") -}}
{{- $serviceName := required "inClusterTls.server.checksumAnnotation: serviceName is required" .serviceName -}}
{{- $annotationKey := .annotationKey | default "checksum/incluster-tls-cert" -}}
{{- $secretKey := .secretKey | default "tls.crt" -}}
{{- $secretName := include "logfire.inClusterTls.secretName" (dict "ctx" $ctx "serviceName" $serviceName) -}}
{{ $annotationKey }}: {{ include "utils.secretChecksum" (dict "ctx" $ctx "name" $secretName "key" $secretKey) }}
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.server.volumeMount" -}}
{{- $ctx := .ctx -}}
{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") -}}
- name: {{ .volumeName | default "logfire-incluster-tls" }}
  mountPath: {{ .mountPath | default "/etc/tls" }}
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.server.volume" -}}
{{- $ctx := .ctx -}}
{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") -}}
{{- $serviceName := required "inClusterTls.server.volume: serviceName is required" .serviceName -}}
{{- $volumeName := .volumeName | default "logfire-incluster-tls" -}}
{{- $secretName := include "logfire.inClusterTls.secretName" (dict "ctx" $ctx "serviceName" $serviceName) -}}
- name: {{ $volumeName }}
  secret:
    secretName: {{ $secretName }}
    items:
      - key: tls.crt
        path: {{ .crtPath | default "tls.crt" }}
      - key: tls.key
        path: {{ .keyPath | default "tls.key" }}
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.caBundle.volumeMount" -}}
{{- $ctx := .ctx -}}
{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") -}}
- name: {{ .volumeName | default "logfire-incluster-ca-bundle" }}
  mountPath: {{ required "inClusterTls.caBundle.volumeMount: mountPath is required" .mountPath }}
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.caBundle.volume" -}}
{{- $ctx := .ctx -}}
{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") -}}
{{- $volumeName := .volumeName | default "logfire-incluster-ca-bundle" -}}
{{- $caBundleSecretName := dig "existingSecret" "name" "" $ctx.Values.inClusterTls.caBundle -}}
{{- $autoIssuer := include "logfire.inClusterTls.certs.certManager.autoIssuer" $ctx | eq "true" -}}
- name: {{ $volumeName }}
  {{- if $ctx.Values.inClusterTls.caBundle.existingConfigMap.name }}
  configMap:
    name: {{ $ctx.Values.inClusterTls.caBundle.existingConfigMap.name }}
    items:
      - key: {{ $ctx.Values.inClusterTls.caBundle.existingConfigMap.key | default "ca.crt" }}
        path: ca.crt
  {{- else if $caBundleSecretName }}
  secret:
    secretName: {{ $caBundleSecretName }}
    items:
      - key: {{ dig "existingSecret" "key" "ca.crt" $ctx.Values.inClusterTls.caBundle }}
        path: ca.crt
  {{- else if $autoIssuer }}
  secret:
    secretName: {{ include "logfire.inClusterTls.certs.certManager.autoCaSecretName" $ctx }}
    items:
      - key: tls.crt
        path: ca.crt
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Get the scheme (http/https) based on in-cluster TLS setting.
Usage: {{ include "logfire.scheme" . }}
*/}}
{{- define "logfire.scheme" -}}
{{- if and .Values.inClusterTls .Values.inClusterTls.enabled -}}
https
{{- else -}}
http
{{- end -}}
{{- end -}}

{{/*
Get the port based on in-cluster TLS setting.
Usage: {{ include "logfire.port" (dict "port" 9001 "root" .) }}
*/}}
{{- define "logfire.port" -}}
{{- $port := .port -}}
{{- $root := .root -}}
{{- if and $root.Values.inClusterTls $root.Values.inClusterTls.enabled -}}
{{- $root.Values.inClusterTls.httpsPort -}}
{{- else -}}
{{- $port -}}
{{- end -}}
{{- end -}}

{{/*
================================================================================
Dev Postgres helpers
================================================================================
*/}}

{{- define "logfire.dev.waitForPostgres.initContainers" -}}
{{- $ctx := .ctx -}}
{{- $serviceName := .serviceName -}}
{{- if and $ctx.Values.dev.deployPostgres (has $serviceName (list
  "logfire-backend"
  "logfire-backend-auth"
  "logfire-worker"
  "logfire-dex"
  "logfire-backend-migrations"
  "logfire-ff-migrations"
  "logfire-ff-crud-api"
  "logfire-ff-maintenance-scheduler"
  "logfire-ff-maintenance-worker"
  "logfire-ff-compaction-worker"
  "logfire-ff-query-api"
  "logfire-ff-query-worker"
  "logfire-ff-ingest"
  "logfire-ff-ingest-processor"
  "logfire-ai-gateway"
  "logfire-remote-mcp"
)) -}}
- name: check-db-ready
  image: postgres:17
  command:
    - sh
    - -c
    - >-
      until pg_isready -h {{ $ctx.Values.postgresql.fullnameOverride | default "logfire-postgres" }} -p 5432; do echo "Waiting for postgres..."; sleep 2; done
  {{- include "logfire.securityContext" $ctx.Values.securityContext | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
Merge initContainers from values with dev Postgres wait initContainer.
*/}}
{{- define "logfire.initContainers" -}}
{{- $ctx := .ctx -}}
{{- $serviceName := required "logfire.initContainers: serviceName is required" .serviceName -}}
{{- $userInit := (index $ctx.Values $serviceName | default dict).initContainers -}}
{{- $devInit := include "logfire.dev.waitForPostgres.initContainers" (dict "ctx" $ctx "serviceName" $serviceName) | trim -}}
{{- $userHasCheckDbReady := dict "value" false -}}
{{- range $userInit }}
  {{- if eq .name "check-db-ready" }}
    {{- $_ := set $userHasCheckDbReady "value" true -}}
  {{- end -}}
{{- end -}}
{{- $includeDevInit := and $devInit (not $userHasCheckDbReady.value) -}}
{{- if or $includeDevInit $userInit -}}
initContainers:
{{- if $includeDevInit }}
{{ $devInit | nindent 2 }}
{{- end }}
{{- with $userInit }}
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
{{- end -}}
