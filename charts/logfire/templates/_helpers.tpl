{{- define "logfire.redisPrefixFor" -}}
{{- get (get .root.Values .valuesKey | default dict) "prefix" | default "" -}}
{{- end -}}

{{/*
The user's Secret when `redisSecret.enabled` is true, otherwise the Secret the
chart creates from `redisDsn`, `tokenRedis.dsn` and `usageRedis.dsn`.
*/}}
{{- define "logfire.redisSecretName" -}}
{{- $redisSecret := .Values.redisSecret | default dict -}}
{{- if get $redisSecret "enabled" -}}
{{- get $redisSecret "name" -}}
{{- else -}}
{{- printf "%s-redis-dsns" (include "logfire.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
The live-tail role shares `redisDsn` with the shared role, as it does everywhere
else in the values.
*/}}
{{- define "logfire.redisDsnValue" -}}
{{- $values := .root.Values -}}
{{- $valuesKey := get (dict "tokenDsn" "tokenRedis" "usageDsn" "usageRedis") .key -}}
{{- if $valuesKey -}}
{{- get (get $values $valuesKey | default dict) "dsn" | default $values.redisDsn -}}
{{- else -}}
{{- $values.redisDsn -}}
{{- end -}}
{{- end -}}

{{/* The Redis DSNs never appear in a ConfigMap or a plain env value. */}}
{{- define "logfire.redisDsnValueFrom" -}}
valueFrom:
  secretKeyRef:
    name: {{ include "logfire.redisSecretName" .root }}
    key: {{ .key }}
{{- end -}}

{{- define "logfire.ffRedisEnv" -}}
- name: FF_SHARED_REDIS_DSN
{{ include "logfire.redisDsnValueFrom" (dict "root" . "key" "sharedDsn") | indent 2 }}
- name: FF_TOKEN_REDIS_DSN
{{ include "logfire.redisDsnValueFrom" (dict "root" . "key" "tokenDsn") | indent 2 }}
- name: FF_USAGE_REDIS_DSN
{{ include "logfire.redisDsnValueFrom" (dict "root" . "key" "usageDsn") | indent 2 }}
{{- end -}}

{{- define "logfire.ffRedisTailEnv" -}}
- name: FF_REDIS_TAIL_DSN
{{ include "logfire.redisDsnValueFrom" (dict "root" . "key" "tailDsn") | indent 2 }}
{{- end -}}

{{/*
Only sizing and portable availability keys are inherited from presets.
*/}}
{{- define "logfire.effectiveServiceValues" -}}
{{- $serviceName := .serviceName -}}
{{- $serviceValues := get .Values $serviceName | default dict | deepCopy -}}
{{- $resources := get $serviceValues "resources" -}}
{{- if and (kindIs "map" $resources) (or (hasKey $resources "cpu") (hasKey $resources "memory")) -}}
  {{- $limitsSpecified := hasKey $resources "limits" -}}
  {{- $requests := get $resources "requests" | default dict -}}
  {{- $limits := get $resources "limits" | default dict -}}
  {{- range $key := list "cpu" "memory" -}}
    {{- if hasKey $resources $key -}}
      {{- $value := get $resources $key -}}
      {{- $_ := unset $resources $key -}}
      {{- if not (hasKey $requests $key) -}}
        {{- $_ := set $requests $key $value -}}
      {{- end -}}
      {{- if not $limitsSpecified -}}
        {{- $_ := set $limits $key $value -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $resources "requests" $requests -}}
  {{- $_ := set $resources "limits" $limits -}}
{{- end -}}
{{- $merged := dict -}}
{{- with .Values.sizingPreset -}}
  {{- $presets := $.Values.sizingPresets | default dict -}}
  {{- if not (hasKey $presets .) -}}
    {{- fail (printf "Unknown sizingPreset %q. Valid presets: %s" .
        ((keys $presets | sortAlpha) | join ", ")) -}}
  {{- end -}}
  {{- $presetValues := get $presets . | default dict -}}
  {{- if and (eq . "large") (hasKey $presets "standard") -}}
    {{- $presetValues = mergeOverwrite (deepCopy (get $presets "standard"))
        (deepCopy $presetValues) -}}
  {{- end -}}
  {{- $presetServiceValues := get $presetValues $serviceName | default dict -}}
  {{- $presetHpaBehavior := get $presetValues "hpaBehavior" | default dict -}}
  {{- if and $presetHpaBehavior (hasKey $presetServiceValues "autoscaling") -}}
    {{- $presetServiceValues = deepCopy $presetServiceValues -}}
    {{- $autoscaling := get $presetServiceValues "autoscaling" | default dict -}}
    {{- $hpa := get $autoscaling "hpa" | default dict -}}
    {{- if and $hpa (not (hasKey $hpa "behavior")) -}}
      {{- $_ := set $hpa "behavior" (deepCopy $presetHpaBehavior) -}}
      {{- $_ := set $autoscaling "hpa" $hpa -}}
      {{- $_ := set $presetServiceValues "autoscaling" $autoscaling -}}
    {{- end -}}
  {{- end -}}
  {{- range $key := list "resources" "autoscaling" "pdb" "replicas" "maxQueryCostPerPod"
      "queryParallelism" "datafusionThreads" "datafusionTargetPartitions"
      "datafusionBatchSize" "ioThreads" "datafusionMemory" "maintenanceRecordBatchMemory"
      "spillToDiskQuota" "scratchVolume" "disk" "volumeClaimTemplates" "jobParallelism"
      "cpuConcurrency" "parquetSpoolThresholdBytes" "maxCompactionJobSizeBytes"
      "directFileBufferMaxBytes" "directFileSubmitConcurrency" "topologySpreadConstraints"
      "spreadAcrossZones" "sendingQueueBytes" "maxColdCompactionJobs" -}}
    {{- if hasKey $presetServiceValues $key -}}
      {{- $_ := set $merged $key (deepCopy (get $presetServiceValues $key)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $merged = mergeOverwrite $merged (deepCopy $serviceValues) -}}
{{- $merged | toJson -}}
{{- end -}}

{{/* Render spec.replicas only when no autoscaler is enabled for the workload. */}}
{{- define "logfire.replicas" -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $autoscaling := get $serviceValues "autoscaling" | default dict -}}
{{- if not (or (dig "hpa" "enabled" false $autoscaling | toString | eq "true")
    (dig "keda" "enabled" false $autoscaling | toString | eq "true")) -}}
replicas: {{ dig "replicas" "1" $serviceValues }}
{{- end -}}
{{- end -}}

{{- define "logfire.autoscaler" }}
{{- $serviceName := .serviceName }}
{{- $serviceValues := include "logfire.effectiveServiceValues"
    (dict "Values" .root.Values "serviceName" $serviceName) | fromJson }}
{{- with $serviceValues.autoscaling }}
{{- $hpa := .hpa | default dict }}
{{- $hpaEnabled := dig "hpa" "enabled" false . | toString | eq "true" }}
{{- $kedaEnabled := dig "keda" "enabled" false . | toString | eq "true" }}
{{- range $key := list "cpuAverage" "memAverage" "extraMetrics" }}
  {{- if hasKey $serviceValues.autoscaling $key }}
    {{- fail
        (printf "%s.autoscaling.%s was removed in chart 0.15.0. Move it to %s.autoscaling.hpa.%s and set autoscaling.hpa.enabled=true."
        $serviceName $key $serviceName $key) }}
  {{- end }}
{{- end }}
{{- if and $hpaEnabled $kedaEnabled }}
  {{- fail
      (printf "Both HPA and KEDA are enabled for '%s'. Only one autoscaler should be enabled at a time to avoid conflicts."
      $serviceName) }}
{{- end }}
{{- $hasMetrics := or $hpa.cpuAverage $hpa.memAverage $hpa.extraMetrics }}
{{- if and $hpaEnabled (not $hasMetrics) }}
  {{- fail
      (printf "HPA is enabled for '%s', but no metrics are configured. Set autoscaling.hpa.cpuAverage, autoscaling.hpa.memAverage, or autoscaling.hpa.extraMetrics."
      $serviceName) }}
{{- end }}
{{- if and .minReplicas .maxReplicas (gt (int .minReplicas) (int .maxReplicas)) }}
  {{- fail
      (printf "autoscaling.minReplicas (%d) cannot be greater than autoscaling.maxReplicas (%d) for '%s'."
      (int .minReplicas) (int .maxReplicas) $serviceName) }}
{{- end }}
{{- $kind := has $serviceName (list "logfire-ff-ingest" "logfire-ff-bcache")
    | ternary "StatefulSet" "Deployment" }}
{{- if $hpaEnabled }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ $serviceName }}
  labels:
    app.kubernetes.io/component: {{ $serviceName }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: {{ $kind }}
    name: {{ $serviceName }}
  minReplicas: {{ .minReplicas | default "1" }}
  maxReplicas: {{ .maxReplicas | default "2" }}
  {{- if $hasMetrics }}
  metrics:
  {{- range $name, $average := dict "cpu" $hpa.cpuAverage "memory" $hpa.memAverage }}
  {{- if $average }}
  - type: Resource
    resource:
      name: {{ $name }}
      target:
        type: Utilization
        averageUtilization: {{ $average }}
  {{- end }}
  {{- end }}
  {{- with $hpa.extraMetrics }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- end }}
  {{- with $hpa.behavior }}
  behavior:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- else if $kedaEnabled }}
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: {{ $serviceName }}
  labels:
    app.kubernetes.io/component: {{ $serviceName }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: {{ $kind }}
    name: {{ $serviceName }}
  minReplicaCount: {{ .minReplicas | default "1" }}
  maxReplicaCount: {{ .maxReplicas | default "2" }}
  {{- with .keda.triggers }}
  triggers:
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- end }}
{{- template "logfire.pdb" . }}
{{- end }}

{{- define "logfire.pdb" }}
{{- $root := .root }}
{{- $serviceName := .serviceName }}
{{- $serviceValues := include "logfire.effectiveServiceValues"
    (dict "Values" $root.Values "serviceName" $serviceName) | fromJson }}
{{- $pdb := hasKey . "pdb" | ternary .pdb $serviceValues.pdb | default dict }}
{{- if and (hasKey $pdb "minAvailable") (hasKey $pdb "maxUnavailable") }}
  {{- fail
      (printf "pdb.minAvailable and pdb.maxUnavailable are mutually exclusive for '%s'. Specify only one."
      $serviceName) }}
{{- end }}
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

{{- define "logfire.resources" -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $resources := index $serviceValues "resources" | default dict -}}
{{- if $resources -}}
{{- if hasKey $resources "ephemeralStorageRequest" -}}
{{- fail
    (printf "resources.ephemeralStorageRequest is not supported for '%s'. Use resources.ephemeralStorage instead."
    .serviceName) -}}
{{- end -}}
{{- if hasKey $resources "ephemeralStorageLimit" -}}
{{- fail
    (printf "resources.ephemeralStorageLimit is not supported for '%s'. Use resources.ephemeralStorage instead."
    .serviceName) -}}
{{- end -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $limits := get $resources "limits" | default dict -}}
{{- $usesFlatResources := or (hasKey $resources "cpu") (hasKey $resources "memory")
    (hasKey $resources "ephemeralStorage") (hasKey $resources "ephemeral-storage") -}}
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
    {{- if or (and $usesFlatResources $ephemeralStorageLimit) (hasKey $limits "ephemeral-storage")
        (hasKey $limits "ephemeralStorage") }}
    ephemeral-storage: {{ $ephemeralStorageLimit }}
    {{- end }}
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Prefers gateway.hostnames over ingress.hostnames. Wrapped as {"hosts": [...]} because fromJson
cannot return a top-level array.
*/}}
{{- define "logfire.effective_hostnames" -}}
{{- dict "hosts" (.Values.gateway.hostnames | default .Values.ingress.hostnames | default list)
    | toJson -}}
{{- end -}}

{{- define "logfire.effective_tls" -}}
{{- if not (kindIs "invalid" .Values.gateway.tls) -}}
  {{- .Values.gateway.tls -}}
{{- else -}}
  {{- .Values.ingress.tls | default false -}}
{{- end -}}
{{- end -}}

{{- define "logfire.primary_hostname" -}}
{{- with (include "logfire.effective_hostnames" . | fromJson).hosts -}}
{{- first . -}}
{{- end -}}
{{- end -}}

{{- define "logfire.all_hostnames_string" -}}
{{- join " " (include "logfire.effective_hostnames" . | fromJson).hosts -}}
{{- end -}}

{{- define "logfire.url" -}}
{{- with include "logfire.primary_hostname" . | trim -}}
{{ include "logfire.effective_tls" $ | eq "true" | ternary "https" "http" }}://{{ . }}
{{- end -}}
{{- end -}}

{{/* Public OTLP intake resource URL (RFC 8707 audience). */}}
{{- define "logfire.intakeOauthResourceUrl" -}}
{{- .Values.intakeOauth.resourceUrl | default (printf "%s/v1" (include "logfire.url" . | trim)) -}}
{{- end -}}

{{/* Public AI gateway resource URL (RFC 8707 audience). */}}
{{- define "logfire.gatewayOauthResourceUrl" -}}
{{- if .Values.aiGatewayOauth.resourceUrl -}}
{{- .Values.aiGatewayOauth.resourceUrl -}}
{{- else if (index .Values "logfire-ai-gateway" "enabled") -}}
{{- printf "%s/proxy" (include "logfire.url" . | trim) -}}
{{- end -}}
{{- end -}}

{{- define "logfire.all_urls" -}}
{{- $scheme := include "logfire.effective_tls" . | eq "true" | ternary "https" "http" -}}
{{- $urls := list -}}
{{- range (include "logfire.effective_hostnames" . | fromJson).hosts -}}
  {{- $urls = append $urls (printf "%s://%s" $scheme .) -}}
{{- end -}}
{{- join " " $urls -}}
{{- end -}}

{{/*
Truncated at 63 chars for DNS-limited name fields. A release name that contains the chart name is
used as the full name.
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

{{- define "logfire.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63
    | trimSuffix "-" }}
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
{{- regexReplaceAll
    `(?m)(^metadata:\n(?:^[ \t]+[^\n]*\n)*?^[ \t]+labels:\n)[ \t]+helm[.]sh/chart:[^\n]*\n` . `${1}`
    | sha256sum -}}
{{- end }}

{{- define "logfire.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "logfire.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
  {{- default (include "logfire.fullname" .) .Values.serviceAccount.name }}
{{- else }}
  {{- .Values.serviceAccount.name | default "default" }}
{{- end }}
{{- end }}

{{/*
On first install with create=true, the ServiceAccount isn't created yet when hooks run, so hooks
fall back to default.
*/}}
{{- define "logfire.hookServiceAccountName" -}}
{{- if and .Release.IsInstall .Values.serviceAccount.create }}
  {{- "default" }}
{{- else }}
  {{- include "logfire.serviceAccountName" . }}
{{- end }}
{{- end }}

{{- define "logfire.serviceTag" -}}
{{- $image := (index .Values .serviceName | default dict).image | default dict -}}
{{- $image.tag | default (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{- define "logfire.serviceVersion" -}}
{{- include "logfire.serviceTag" (dict "Values" .root.Values "serviceName" .serviceName
    "Chart" .root.Chart) -}}
{{- end -}}

{{- define "logfire.otelResourceAttributes" -}}
{{- $version := include "logfire.serviceVersion" . -}}
{{- $attrs := dict
    "vcs.repository.url.full" "https://github.com/pydantic/platform"
    "vcs.repository.ref.revision" $version
    "service.version" $version -}}
{{- with .codeWorkDir }}
  {{- $_ := set $attrs "logfire.code.work_dir" . -}}
{{- end }}
{{- $attrs = mergeOverwrite $attrs ((get .root.Values "otelResourceAttributes") | default dict) -}}
{{- include "logfire.renderOtelResourceAttributes" $attrs -}}
{{- end -}}

{{/* Renders a map in OTEL_RESOURCE_ATTRIBUTES format. */}}
{{- define "logfire.renderOtelResourceAttributes" -}}
{{- $pairs := list -}}
{{- range $key, $value := . }}
  {{- $pairs = append $pairs (printf "%s=%v" $key $value) -}}
{{- end -}}
{{- join "," $pairs -}}
{{- end -}}

{{- define "logfire.aiModelEnv" -}}
{{- $ai := .root.Values.ai | default dict -}}
{{- $roles := .roles | default list -}}
{{- with (get $ai "model") }}
- name: AI_MODEL_DEFAULT
  value: {{ . }}
{{- end }}
{{- with and (has "chat" $roles) (get $ai "chatModel") }}
- name: AI_MODEL_CHAT
  value: {{ . }}
{{- end }}
{{- with and (has "reasoning" $roles) ((get $ai "reasoningModel") | default (get $ai "model")) }}
- name: AI_MODEL_REASONING
  value: {{ . }}
{{- end }}
{{- with (get $ai "llmJudgeModel") }}
- name: AI_MODEL_LLM_JUDGE
  value: {{ . }}
{{- end }}
{{- end -}}

{{/*
The valueFrom of a credential set as {valueFrom: ...}, as JSON, or "" for a plain value. Any other
map fails, so a reference never ends up stored as the credential itself. Call with
(dict "value" $value "path" "integrations.slack.clientSecret").
*/}}
{{- define "logfire.credentialValueFrom" -}}
{{- $value := .value -}}
{{- if kindIs "map" $value -}}
  {{- if or (ne (len $value) 1) (not (kindIs "map" $value.valueFrom))
      (ne (len ($value.valueFrom | default dict)) 1) -}}
    {{- fail (printf "%s: set a string, or only valueFrom with exactly one source such as secretKeyRef."
        .path) -}}
  {{- end -}}
  {{- $value.valueFrom | toJson -}}
{{- end -}}
{{- end -}}

{{- define "logfire.envValue" -}}
{{- $value := .value -}}
{{- $quote := .quote | default false -}}
{{- if kindIs "map" $value -}}
{{- $lines := list -}}
{{- if and .allowValueKey (hasKey $value "value") -}}
  {{- if kindIs "invalid" $value.value -}}
    {{- $lines = append $lines "value:" -}}
  {{- else -}}
    {{- $lines = append $lines (printf "value: %s" (ternary ($value.value | toString | quote)
        ($value.value | toString) $quote)) -}}
  {{- end -}}
{{- end -}}
{{- if hasKey $value "valueFrom" -}}
  {{- $lines = append $lines (printf "valueFrom:\n%s" (toYaml $value.valueFrom | indent 2
      | trimSuffix "\n")) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- else if kindIs "invalid" $value -}}
value:
{{- else -}}
value: {{ ternary ($value | toString | quote) ($value | toString) $quote }}
{{- end -}}
{{- end -}}

{{/*
A service's extra environment as a YAML list, or "" when it has none. `<service>.env` is either a
list of EnvVar entries or a map from name to a scalar or to an EnvVar body (`value` or
`valueFrom`). Helm merges maps across values files but replaces lists, so only the map form lets a
layered file add one variable. Map entries render sorted by name and a null entry is dropped.
An empty default stays `null` in values.yaml, because Helm warns when a user value's shape differs
from a non-null default. Call with `(dict "Values" .Values "serviceName" $serviceName)`.
*/}}
{{- define "logfire.serviceEnv" -}}
{{- $env := get (get .Values .serviceName | default dict) "env" -}}
{{- if kindIs "map" $env -}}
  {{- $entries := list -}}
  {{- range $name, $value := $env -}}
    {{- if kindIs "map" $value -}}
      {{- $entry := merge (dict "name" $name) (deepCopy $value) -}}
      {{- if hasKey $entry "value" -}}
        {{- $_ := set $entry "value" (include "logfire.envString" $entry.value) -}}
      {{- end -}}
      {{- $entries = append $entries $entry -}}
    {{- else if not (kindIs "invalid" $value) -}}
      {{- $entries = append $entries (dict "name" $name "value"
          (include "logfire.envString" $value)) -}}
    {{- end -}}
  {{- end -}}
  {{- $env = $entries -}}
{{- end -}}
{{- with $env }}
  {{- toYaml . }}
{{- end -}}
{{- end -}}

{{/*
Whether users may sign in with an email address and a password, as "true" or "false". The Logfire
sign-in page and Dex's password database both follow it. `logfire-dex.config.enablePasswordDB:
false` predates `auth.passwordLogin` and still turns password sign-in off.
*/}}
{{- define "logfire.passwordLoginEnabled" -}}
{{- $dexPasswordDB := dig "config" "enablePasswordDB" true
    (index .Values "logfire-dex" | default dict) -}}
{{- and (dig "passwordLogin" true (.Values.auth | default dict)) $dexPasswordDB | toString -}}
{{- end -}}

{{/*
Values files load numbers as float64, so print whole numbers without an exponent.
*/}}
{{- define "logfire.envString" -}}
{{- if and (kindIs "float64" .) (eq . (floor .)) -}}
{{- printf "%.0f" . -}}
{{- else -}}
{{- toString . -}}
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
{{- range $key, $value := .Values.hooksAnnotations | default dict }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end -}}

{{- define "logfire.postgresSecretName" -}}
{{- if .Values.postgresSecret.enabled }}
{{- .Values.postgresSecret.name }}
{{- else }}
{{- include "logfire.fullname" . }}-pg
{{- end }}
{{- end -}}

{{/*
The Secret key that holds the session DSN of a database, given its runtime key:
`postgresDsn` gives `postgresSessionDsn`, and `postgresFFDsn` gives `postgresFFSessionDsn`.
*/}}
{{- define "logfire.postgresSessionDsnKey" -}}
{{- printf "%sSessionDsn" (trimSuffix "Dsn" .) -}}
{{- end -}}

{{/*
Renders "true" when the database of the runtime key `.key` has a session DSN.
The chart cannot read an existing Secret, so with `postgresSecret` a flag declares the key.
*/}}
{{- define "logfire.postgresHasSessionDsn" -}}
{{- $ctx := .ctx -}}
{{- $key := .key -}}
{{- $secret := $ctx.Values.postgresSecret | default dict -}}
{{- if get $secret "enabled" -}}
{{- if get $secret (eq $key "postgresFFDsn" | ternary "ffSessionDsn"
    "sessionDsn") -}}true{{- end -}}
{{- else if get $ctx.Values (include "logfire.postgresSessionDsnKey" $key) -}}true
{{- end -}}
{{- end -}}

{{/*
The Secret key that a migration Job reads: the session DSN when the database has
one, otherwise the runtime DSN.
*/}}
{{- define "logfire.postgresMigrationKey" -}}
{{- if include "logfire.postgresHasSessionDsn" . -}}
{{- include "logfire.postgresSessionDsnKey" .key -}}
{{- else -}}
{{- .key -}}
{{- end -}}
{{- end -}}

{{/*
With a session DSN for `crud`, `CRUD_PG_DSN` is a transaction-mode pool.
The platform names that topology `pgbouncer`, whatever the pooler is.
*/}}
{{- define "logfire.crudPgTopologyEnv" -}}
{{- if include "logfire.postgresHasSessionDsn" (dict "ctx" . "key" "postgresDsn") -}}
- name: CRUD_PG_TOPOLOGY
  value: "pgbouncer"
{{- end -}}
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

{{/*
Bucket the in-cluster object store creates at startup. When `objectStore.uri` is an `s3://`
URI its bucket is authoritative, so RustFS creates the bucket the workloads actually read.
*/}}
{{- define "logfire.inClusterObjectStoreBucket" -}}
{{- $uri := include "logfire.objectStoreUriValue" . | trim -}}
{{- $bucket := "" -}}
{{- if hasPrefix "s3://" $uri -}}
{{- $bucket = splitList "/" (trimPrefix "s3://" $uri) | first | trim -}}
{{- end -}}
{{- if not $bucket -}}
  {{- $bucket = .Values.rustfs.bucket | trim -}}
{{- end -}}
{{- $bucket | default "logfire" -}}
{{- end -}}

{{/* Render objectStore.uri as configured, before in-cluster defaults. */}}
{{- define "logfire.objectStoreUriValue" -}}
{{- tpl (.Values.objectStore.uri | default "") . -}}
{{- end -}}

{{- define "logfire.objectStoreUri" -}}
{{- $uri := include "logfire.objectStoreUriValue" . -}}
{{- if and (not (trim $uri)) .Values.dev.deployRustfs -}}
{{- $uri = printf "s3://%s" (include "logfire.inClusterObjectStoreBucket" .) -}}
{{- end -}}
{{- $uri -}}
{{- end -}}

{{- define "logfire.objectStoreEnv" -}}
- name: FF_OBJECT_STORE_URI
  value: {{ include "logfire.objectStoreUri" . | quote }}
{{- with .Values.objectStore.sseCKeyB64 }}
- name: FF_S3_SSE_C_KEY_B64
{{ include "logfire.envValue" (dict "value" . "quote" true) | indent 2 }}
{{- end }}
{{- include "logfire.objectStoreProviderEnv" . }}
{{- end -}}

{{/*
The provider environment for the configured object store: the endpoint, the credentials and the
entries the deployment added under `objectStore.env`. FusionFire and the Python services read the
same variable names, so one map configures both. FusionFire reads `AWS_ENDPOINT`; the Python S3
client reads it as the alias of `AWS_ENDPOINT_URL` (see `logfire_services/object_store.py`).
*/}}
{{- define "logfire.objectStoreProviderEnv" -}}
{{- $objectStoreEnv := .Values.objectStore.env | default dict -}}
{{- if .Values.dev.deployRustfs }}
{{- range list
    (dict "name" "AWS_ENDPOINT" "value" "http://logfire-rustfs:9000")
    (dict "name" "AWS_ACCESS_KEY_ID" "key" "accessKey")
    (dict "name" "AWS_SECRET_ACCESS_KEY" "key" "secretKey")
    (dict "name" "AWS_ALLOW_HTTP" "value" "true") }}
{{- if not (hasKey $objectStoreEnv .name) }}
- name: {{ .name }}
{{- if .key }}
  valueFrom:
    secretKeyRef:
      name: logfire-rustfs
      key: {{ .key }}
{{- else }}
  value: {{ .value | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- range $key, $value := $objectStoreEnv }}
{{- if kindIs "string" $value }}
{{- $value = tpl $value $ }}
{{- end }}
- name: {{ $key }}
{{ include "logfire.envValue" (dict "value" $value "quote" (not (kindIs "map" $value))
    "allowValueKey" true) | indent 2 }}
{{- end }}
{{- end -}}

{{/*
Rolls a workload that reads the RustFS root credentials from the logfire-rustfs Secret when they
change, together with RustFS itself.
*/}}
{{- define "logfire.rustfsChecksumAnnotation" -}}
{{- if .Values.dev.deployRustfs -}}
checksum/rustfs-credentials: {{ printf "%s:%s" .Values.rustfs.auth.accessKey
    .Values.rustfs.auth.secretKey | sha256sum }}
{{- end -}}
{{- end -}}

{{/*
A feature's blob store inside the configured bucket, or "" when no object store is configured.

The Python services keep session replay and visual-test blobs under their own prefixes of the
bucket, so the two never share one path and the replay objects do not sit among the Fusionfire
parquet objects. `value` names the optional `objectStore` key that overrides the derived URI for a
deployment that keeps one feature in its own bucket or container. Call with
`(dict "root" . "value" "sessionReplayUri" "suffix" "session-replays")`.
*/}}
{{- define "logfire.featureObjectStoreUri" -}}
{{- $override := get (.root.Values.objectStore | default dict) .value | default "" | toString
    | trim -}}
{{- if $override -}}
{{- tpl $override .root -}}
{{- else -}}
{{- $base := include "logfire.objectStoreUri" .root | trim -}}
{{- if $base -}}
{{- printf "%s/%s" (trimSuffix "/" $base) .suffix -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The object-store environment for the Python services (backend, worker): the two feature URIs the
platform reads plus the provider settings. Emitted only when a store is configured, because the
platform falls back to its own local directory otherwise.
*/}}
{{- define "logfire.pythonObjectStoreEnv" -}}
{{- $replay := include "logfire.featureObjectStoreUri" (dict "root" . "value" "sessionReplayUri"
    "suffix" "session-replays") -}}
{{- $visual := include "logfire.featureObjectStoreUri" (dict "root" . "value" "visualTestsUri"
    "suffix" "visual-tests") -}}
{{- if or $replay $visual }}
- name: SESSION_REPLAY_OBJECT_STORE_URI
  value: {{ $replay | quote }}
- name: VISUAL_TESTS_OBJECT_STORE_URI
  value: {{ $visual | quote }}
{{- include "logfire.objectStoreProviderEnv" . }}
{{- end }}
{{- end -}}

{{- define "logfire.objectStoreVolumeMounts" -}}
{{- with .Values.objectStore.volumeMounts }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{- define "logfire.objectStoreVolumes" -}}
{{- with .Values.objectStore.volumes }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{- define "isPrometheusExporterEnabled" -}}
{{- with (.Values.otel_collector | default dict).prometheus -}}
  {{- dig "enabled" false . | eq true -}}
{{- else -}}
  false
{{- end -}}
{{- end }}

{{/*
Falls back to `image.backendImage` when the per-service key is unset. An install created before
these keys existed upgrades with `--reuse-values`, which carries `image.backendImage` forward and
knows nothing of the newer keys. Without the fallback such an upgrade would move three workloads
onto per-service images that the install never asked for. Setting the per-service key, or taking
the chart's own defaults on a fresh install, opts in.

Charts before 0.15.0 set `backendImage` and `workerImage` to `python-prod`, and `--reuse-values`
carries that value forward. The platform no longer publishes `python-prod`, so the chart replaces
that name with the image of the workload. Otherwise the upgrade pulls a tag that does not exist.
*/}}
{{- define "logfire.pythonImage" -}}
{{- $image := .Values.image -}}
{{- $key := .key -}}
{{- $name := index $image $key -}}
{{- if and (not $name) (has $key (list "authImage" "taskRunnerImage" "remoteMcpImage")) -}}
  {{- $name = $image.backendImage -}}
{{- end -}}
{{- if eq $name "python-prod" -}}
  {{- $name = get (dict
      "backendImage" "logfire-backend-prod"
      "workerImage" "logfire-worker-prod"
      "authImage" "logfire-auth-prod"
      "taskRunnerImage" "logfire-task-runner-prod"
      "remoteMcpImage" "logfire-remote-mcp-prod") $key -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{- define "logfire.imageRef" -}}
{{- $image := .image | default dict -}}
{{- $repository := $image.repository | default .defaultRepository -}}
{{- $tag := hasKey $image "tag" | ternary $image.tag .defaultTag -}}
{{- if $tag }}
  {{- printf "%s:%s" $repository $tag -}}
{{- else }}
  {{- $repository -}}
{{- end }}
{{- end }}

{{- define "logfire.otlpExporterEnv" }}
{{- $serviceName := .serviceName -}}
- name: "OTEL_EXPORTER_OTLP_PROTOCOL"
  value: "grpc"
- name: "COLLECTOR_OTLP_GRPC_HOST"
  value: http://logfire-otel-collector:4317
- name: LOGFIRE_SERVICE_NAME
  value: {{ $serviceName }}
- name: LOGFIRE_SERVICE_VERSION
  value: {{ include "logfire.serviceVersion" . | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ $serviceName }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ include "logfire.otelResourceAttributes" . | quote }}
{{- end }}

{{/*
Component values win over defaultStorageClassName. A value of "-" renders storageClassName: "" to
disable dynamic provisioning.
*/}}
{{- define "logfire.storageClassName" -}}
{{- $storageClassName := get (.values | default dict) "storageClassName"
    | default .root.Values.defaultStorageClassName | default "" | toString -}}
{{- if eq $storageClassName "-" -}}
storageClassName: ""
{{- else if $storageClassName -}}
storageClassName: {{ $storageClassName | quote }}
{{- end -}}
{{- end -}}

{{- define "logfire.scratchVolume" -}}
{{- $root := .root -}}
- name: scratch-data
{{- with .scratchVolume }}
  ephemeral:
    volumeClaimTemplate:
      {{- with .labels }}
      metadata:
        labels:
          {{- toYaml . | nindent 10 }}
      {{- end }}
      spec:
        accessModes: [ "ReadWriteOnce" ]
        {{- include "logfire.storageClassName" (dict "root" $root "values" .) | nindent 8 }}
        resources:
          requests:
            storage: {{ .storage }}
{{- else }}
  emptyDir: {}
{{- end -}}
{{- end -}}

{{/*
Secret annotations are copied for external secret reload controllers. Later sources win, and
per-workload annotations have final precedence.
*/}}
{{- define "logfire.workloadAnnotations" -}}
{{- $values := .Values -}}
{{- $merged := dict -}}
{{- $valuesKeys := dict
    "postgres" "postgresSecret"
    "existing" "existingSecret"
    "gateway" "existingGatewaySecret"
    "admin" "adminSecret"
    "redis" "redisSecret" -}}
{{- range .secretSources | default list }}
  {{- $secret := get $values (get $valuesKeys .) | default dict -}}
  {{- $gatewayOff := and (eq . "gateway") (not (index $values "logfire-ai-gateway" "enabled")) -}}
  {{- if and (get $secret "enabled") (get $secret "annotations") (not $gatewayOff) -}}
    {{- $merged = mergeOverwrite $merged (get $secret "annotations") -}}
  {{- end -}}
{{- end -}}
{{- with (index $values .serviceName | default dict).annotations -}}
  {{- $merged = mergeOverwrite $merged . -}}
{{- end -}}
{{- with $merged -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{- define "logfire.podAnnotations" -}}
{{- with dig "podAnnotations" dict (index .Values .serviceName | default dict) -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{- define "logfire.workloadLabels" -}}
{{- with dig "labels" dict (index .Values .serviceName | default dict) -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{- define "logfire.podLabels" -}}
{{- with dig "podLabels" dict (index .Values .serviceName | default dict) -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{- define "logfire.serviceAnnotations" -}}
{{- with ((index .Values .serviceName | default dict).service | default dict).annotations -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/* The checksum of one key of a live Secret, or a placeholder before the Secret exists. */}}
{{- define "utils.secretChecksum" -}}
{{- $secret := lookup "v1" "Secret" .ctx.Release.Namespace .name -}}
{{- if and $secret (hasKey $secret.data .key) -}}
{{ index $secret.data .key | sha256sum }}
{{- else -}}
default-checksum
{{- end -}}
{{- end -}}

{{- define "logfire.secretChecksumAnnotation" -}}
{{- printf "%s: %s" (.annotationKey | default (printf "checksum/%s" .key))
    (include "utils.secretChecksum" . | trim) -}}
{{- end -}}

{{- define "logfire.postgresSecretChecksumAnnotation" -}}
{{- $ctx := .ctx -}}
{{- $key := .key | default "postgresDsn" -}}
{{- $annotationKey := .annotationKey | default (eq $key "postgresFFDsn"
    | ternary "checksum/logfire-postgres-ff-dsn" "checksum/logfire-postgres-dsn") -}}
{{- if $ctx.Values.postgresSecret.enabled -}}
{{- /* Without a name there is no Secret to checksum. Stay silent so logfire.validate.postgres
       reports the missing postgresSecret.name. */ -}}
{{- with include "logfire.postgresSecretName" $ctx | trim -}}
{{- include "logfire.secretChecksumAnnotation" (dict "ctx" $ctx "annotationKey" $annotationKey
    "name" . "key" $key) -}}
{{- end -}}
{{- else -}}
{{- /* Each Secret key has a value of the same name. */ -}}
{{- printf "%s: %s" $annotationKey (get $ctx.Values $key | default "" | b64enc | sha256sum) -}}
{{- end -}}
{{- end -}}

{{/*
Roll the Redis consumers when a DSN changes. Emits nothing when an external
Secret has reload annotations, because those roll the workloads instead. The
roles are read together by the workloads that consume them, and a DSN change is
deliberate and rare, so one annotation covers the whole Secret instead of one
per role.

An upgrade from a release whose values predate `redisSecret` leaves the value
unset, so every read here tolerates a missing key.
*/}}
{{- define "logfire.redisSecretChecksumAnnotation" -}}
{{- $ctx := .ctx -}}
{{- $redisSecret := $ctx.Values.redisSecret | default dict -}}
{{- $external := get $redisSecret "enabled" -}}
{{- $keys := list "sharedDsn" "tailDsn" "tokenDsn" "usageDsn" -}}
{{- $parts := list -}}
{{- if not $external -}}
{{- range $key := $keys -}}
  {{- $parts = append $parts (include "logfire.redisDsnValue" (dict "root" $ctx "key" $key)
      | trim) -}}
{{- end -}}
{{- printf "checksum/logfire-redis-dsns: %s" (join "|" $parts | b64enc | sha256sum) -}}
{{- else if not (get $redisSecret "annotations") -}}
{{- /* Without a name there is no Secret to checksum. Stay silent so logfire.validate.redis
       reports the missing redisSecret.name. */ -}}
{{- with include "logfire.redisSecretName" $ctx | trim -}}
{{- $name := . -}}
{{- range $key := $keys -}}
  {{- $parts = append $parts (include "utils.secretChecksum"
      (dict "ctx" $ctx "name" $name "key" $key) | trim) -}}
{{- end -}}
{{- printf "checksum/logfire-redis-dsns: %s" (join "|" $parts | sha256sum) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* `.external` defaults to `existingSecret`. */}}
{{- define "logfire.logfireSecretChecksumAnnotations" -}}
{{- $ctx := .ctx -}}
{{- $external := hasKey . "external" | ternary .external $ctx.Values.existingSecret -}}
{{- $lines := list -}}
{{- range $secretName := .secrets }}
  {{- $name := include "logfire.externalSecretName" (dict "external" $external
      "secretName" $secretName) | trim -}}
  {{- $lines = append $lines (include "logfire.secretChecksumAnnotation"
      (dict "ctx" $ctx "name" $name "key" $secretName)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{- define "logfire.gatewaySecretChecksumAnnotations" -}}
{{- $ctx := .ctx -}}
{{- $lines := list -}}
{{- range $secretName, $key := dict "gateway-encryption" "key" "gateway-internal-secret"
    "internalSecret" -}}
  {{- $name := include "logfire.externalSecretName" (dict
      "external" $ctx.Values.existingGatewaySecret "secretName" $secretName) | trim -}}
  {{- $lines = append $lines (include "logfire.secretChecksumAnnotation"
      (dict "ctx" $ctx "annotationKey" (printf "checksum/%s" $secretName) "name" $name
      "key" $key)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{- define "logfire.migrationJobName" -}}
{{- if .ctx.Values.dev.deployPostgres -}}
{{- printf "%s-%d" .name .ctx.Release.Revision | quote -}}
{{- else -}}
{{- .name | quote -}}
{{- end -}}
{{- end -}}

{{/*
Optional preset and default topology spread constraints are appended only when the merged
user/preset list does not already contain the same topologyKey.
*/}}
{{- define "logfire.podScheduling" -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $nodeSelector := merge (deepCopy ($serviceValues.nodeSelector | default dict))
    (.Values.nodeSelector | default dict) -}}
{{- $affinity := merge (deepCopy ($serviceValues.affinity | default dict))
    (.Values.affinity | default dict) -}}
{{- $tolerations := concat ($serviceValues.tolerations | default list)
    (.Values.tolerations | default list) -}}
{{- $constraints := concat ($serviceValues.topologySpreadConstraints | default list)
    (.Values.topologySpreadConstraints | default list) -}}
{{- $extra := list -}}
{{- if get $serviceValues "spreadAcrossZones" -}}
  {{- $selector := dict "matchLabels" (dict "app.kubernetes.io/component" .serviceName) -}}
  {{- range list "topology.kubernetes.io/zone" "kubernetes.io/hostname" -}}
    {{- $extra = append $extra (dict "maxSkew" 1 "topologyKey" . "whenUnsatisfiable"
        "ScheduleAnyway" "labelSelector" $selector) -}}
  {{- end -}}
{{- end -}}
{{- range concat $extra (.defaultTopologySpreadConstraints | default list) -}}
  {{- $topologyKey := get . "topologyKey" -}}
  {{- $hasTopologyKey := false -}}
  {{- range $constraints -}}
    {{- if eq (get . "topologyKey") $topologyKey -}}
      {{- $hasTopologyKey = true -}}
    {{- end -}}
  {{- end -}}
  {{- if not $hasTopologyKey -}}
    {{- $constraints = append $constraints . -}}
  {{- end -}}
{{- end -}}
{{- $blocks := list -}}
{{- range list
    (list "nodeSelector" $nodeSelector)
    (list "affinity" $affinity)
    (list "tolerations" $tolerations)
    (list "topologySpreadConstraints" $constraints) -}}
  {{- if index . 1 -}}
    {{- $blocks = append $blocks (printf "%s:%s" (index . 0)
        (toYaml (index . 1) | nindent 2 | trimSuffix "\n")) -}}
  {{- end -}}
{{- end -}}
{{- join "\n" $blocks -}}
{{- end -}}

{{- define "logfire.securityContext" -}}
{{- with . -}}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
Merge the container SecurityContext layers with later layers winning:
1. the provided chart defaults;
2. the chart-wide `.Values.securityContext`;
3. the service's own `<service>.securityContext` value.

A layer value of `null` removes the field from the result, so a user can clear `runAsUser` or
`runAsGroup` for OpenShift or a policy-managed cluster, and can set `readOnlyRootFilesystem`
back to false. Returns JSON so callers can parse it with `fromJson`.
*/}}
{{- define "logfire.mergeSecurityContext" -}}
{{- $values := .ctx.Values -}}
{{- $merged := .defaults | default dict -}}
{{- range $layer := list ($values.securityContext | default dict)
    ((get $values .serviceName | default dict).securityContext | default dict) -}}
  {{- $merged = mergeOverwrite $merged (deepCopy $layer) -}}
  {{- range $key, $value := $layer -}}
    {{- if kindIs "invalid" $value -}}
      {{- $_ := unset $merged $key -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $merged | toJson -}}
{{- end -}}

{{/*
Chart-owned container SecurityContext. The defaults stay in the chart rather than in values, so an
upgrade that carries no service `securityContext` key still applies them.

The kubelet verifies `runAsNonRoot` against `runAsUser`, and a named image user cannot be
verified, so the chart pins each image's numeric identity. The Python, Fusionfire, bcache, and
gateway images run as uid/gid 1000; the frontend nginx image runs as uid/gid 33. The platform
contract tests keep the image `USER` and these numbers in step.
*/}}
{{- define "logfire.containerSecurityContext" -}}
{{- $serviceName := .serviceName -}}
{{- $id := 1000 -}}
{{- if eq $serviceName "logfire-frontend-service" -}}
  {{- $id = 33 -}}
{{- else if not (has $serviceName (list
    "logfire-backend" "logfire-backend-auth" "logfire-backend-migrations"
    "logfire-backend-post-deploy-migrations" "logfire-worker" "logfire-task-runner"
    "logfire-alert-runner" "logfire-remote-mcp" "logfire-ai-gateway" "logfire-ff-ingest"
    "logfire-ff-ingest-processor" "logfire-ff-query-api" "logfire-ff-query-worker"
    "logfire-ff-crud-api" "logfire-ff-maintenance-scheduler" "logfire-ff-maintenance-worker"
    "logfire-ff-compaction-worker" "logfire-ff-bcache" "logfire-ff-migrations")) -}}
  {{- fail
      (printf "logfire.containerImageIdentity: unknown chart-owned service %q; add its verified image identity"
      $serviceName) -}}
{{- end -}}
{{- $defaults := dict
    "runAsNonRoot" true
    "runAsUser" $id
    "runAsGroup" $id
    "allowPrivilegeEscalation" false
    "capabilities" (dict "drop" (list "ALL"))
    "seccompProfile" (dict "type" "RuntimeDefault")
    "readOnlyRootFilesystem" true -}}
{{- include "logfire.mergeSecurityContext" (dict "ctx" .ctx "serviceName" $serviceName
    "defaults" $defaults) -}}
{{- end -}}

{{/*
Bundled third-party container SecurityContext. `readOnlyRootFilesystem` stays off unless the
caller sets `.readOnlyRootFilesystem`, because an image may write outside its data volume. The
`.identity` names the image; the optional `.serviceName` selects the per-service
`<serviceName>.securityContext` override and defaults to the identity.

Each uid/gid was verified by running the image and reading its `USER` or its user database:
`redis` in `redis:7.2`, the Dex image `USER`, `rustfs` in `rustfs/rustfs:1.0.0`, `node` in
`maildev/maildev:3.0.0`, the collector image `USER`, `postgres` in `postgres:17`, and `curl_user`
in `curlimages/curl:8.12.1`.
*/}}
{{- define "logfire.thirdPartyContainerSecurityContext" -}}
{{- $identities := dict
    "logfire-redis" (list 999 999)
    "logfire-dex" (list 1001 1001)
    "rustfs" (list 10001 10001)
    "maildev" (list 1000 1000)
    "otel_collector" (list 10001 10001)
    "postgres" (list 999 999)
    "tls-wait" (list 101 102) -}}
{{- if not (hasKey $identities .identity) -}}
  {{- fail
      (printf "logfire.thirdPartyImageIdentity: unknown third-party image %q; add its verified image identity"
      .identity) -}}
{{- end -}}
{{- $identity := get $identities .identity -}}
{{- $defaults := dict
    "runAsNonRoot" true
    "runAsUser" (index $identity 0)
    "runAsGroup" (index $identity 1)
    "allowPrivilegeEscalation" false
    "capabilities" (dict "drop" (list "ALL"))
    "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- if .readOnlyRootFilesystem -}}
  {{- $_ := set $defaults "readOnlyRootFilesystem" true -}}
{{- end -}}
{{- include "logfire.mergeSecurityContext"
    (dict "ctx" .ctx "serviceName" (.serviceName | default .identity) "defaults" $defaults) -}}
{{- end -}}

{{/*
The writable `/tmp` mount every chart-owned container gets. The production images keep a
writable `HOME` or write scratch data under `/tmp`, so a read-only image root needs this
emptyDir. List the mount before any mount nested under `/tmp`, because the kubelet applies
container mounts in spec order and a later `/tmp` mount shadows the nested path.
*/}}
{{- define "logfire.tmpVolumeMounts" -}}
- name: tmp
  mountPath: /tmp
{{- end -}}

{{- define "logfire.tmpVolume" -}}
- name: tmp
  emptyDir: {}
{{- end -}}

{{/*
Self-hosted deployments default the session-replay and visual-test stores to
`file:///var/lib/logfire`, so the backend and the worker need the directory writable under a
read-only image root.
*/}}
{{- define "logfire.logfireDataVolumeMounts" -}}
- name: logfire-data
  mountPath: /var/lib/logfire
{{- end -}}

{{- define "logfire.logfireDataVolume" -}}
- name: logfire-data
  emptyDir: {}
{{- end -}}

{{- define "logfire.standardPodSpecFields" -}}
{{- $ctx := .ctx -}}
{{- $lines := list -}}
{{- with $ctx.Values.priorityClassName -}}
  {{- $lines = append $lines (printf "priorityClassName: %s" .) -}}
{{- end -}}
{{- $lines = append $lines (printf "serviceAccountName: %s"
    (include "logfire.serviceAccountName" $ctx | trim)) -}}
{{- with $ctx.Values.imagePullSecrets -}}
  {{- $pullSecretLines := list "imagePullSecrets:" -}}
  {{- range . -}}
    {{- $pullSecretLines = append $pullSecretLines (printf "  - name: %s" (. | quote)) -}}
  {{- end -}}
  {{- $lines = append $lines (join "\n" $pullSecretLines) -}}
{{- end -}}
{{- with include "logfire.initContainers" . | trim -}}
  {{- $lines = append $lines . -}}
{{- end -}}
{{- with .podSecurityContext | default (include "logfire.podSecurityContext" $ctx | fromJson) -}}
  {{- $lines = append $lines (include "logfire.securityContext" . | trim) -}}
{{- end -}}
{{- with include "logfire.podScheduling" (dict "Values" $ctx.Values "serviceName" .serviceName)
    | trim -}}
  {{- $lines = append $lines . -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/*
The VAPID application-server identity every Web Push request is signed with, for the
workloads that register a device or send to one. Emits nothing while webPush is disabled,
where the backend reports push unavailable and the settings panel says so.
*/}}
{{- define "logfire.webPushEnv" -}}
{{- if .Values.webPush.enabled -}}
- name: WEB_PUSH_VAPID_SUBJECT
  value: {{ .Values.webPush.subject | default (printf "mailto:%s" .Values.adminEmail) | quote }}
- name: WEB_PUSH_VAPID_PRIVATE_KEY
{{- with include "logfire.credentialValueFrom" (dict "value" .Values.webPush.privateKey
    "path" "webPush.privateKey") }}
  valueFrom:
    {{- fromJson . | toYaml | nindent 4 }}
{{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ include "logfire.externalSecretName" (dict "external" .Values.existingSecret
          "secretName" "logfire-web-push-vapid-key") }}
      key: logfire-web-push-vapid-key
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Rolls the workloads that hold the VAPID key when it changes, so a rotation cannot leave one pod
signing with the old key while another signs with the new one. Emits nothing while webPush is
disabled.

A key supplied in the values is hashed from there rather than from the live Secret, which still
holds the pre-upgrade key while the templates render: hashing that would leave the pod template
unchanged on the very upgrade that rotates the key, so a pod would pick the new one up only at
some later unrelated restart. The hash is taken over the base64 value the Secret stores, which is
what the lookup path hashes once the new key is applied, so a subsequent no-op upgrade does not
roll the workloads a second time. The generated and existingSecret cases keep reading the
cluster, since that is where their key lives. A key read through `valueFrom` lives in a Secret the
chart does not manage, so a reload controller restarts the workloads, as for `existingSecret`.
*/}}
{{- define "logfire.webPushChecksumAnnotation" -}}
{{- if .Values.webPush.enabled -}}
{{- if include "logfire.credentialValueFrom" (dict "value" .Values.webPush.privateKey
    "path" "webPush.privateKey") -}}
{{- else if and .Values.webPush.privateKey (not .Values.existingSecret.enabled) -}}
{{- printf "checksum/logfire-web-push-vapid-key: %s" (.Values.webPush.privateKey | b64enc
    | sha256sum) -}}
{{- else -}}
{{- include "logfire.logfireSecretChecksumAnnotations" (dict "ctx" . "secrets"
    (list "logfire-web-push-vapid-key")) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Whether this deployment has an SMTP server behind it, which is what decides if the producers
queue transactional email at all. Derived from the SMTP configuration rather than a separate
switch, so the two cannot disagree: a configured server that no producer knows about sends
nothing, and `emails_enabled` without a reachable server queues mail that can only fail at
delivery. This gates the producers only. `logfire-task-runner` drains the Absurd queues and is
deployed unconditionally, so queued email always has something behind it.
*/}}
{{- define "logfire.emailsEnabled" -}}
{{- if or .Values.dev.deployMaildev .Values.smtp.host -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
A self-hosted install (`ON_PREM`) with an SMTP server refuses to start without
`EMAIL_FROM_ADDRESS`, because the platform does not send email as `pydantic.dev` from a
self-hosted install. The bundled maildev accepts any sender, so it gets a placeholder on the
reserved `.localhost` domain.
*/}}
{{- define "logfire.emailSenderEnv" -}}
{{- $smtp := .Values.smtp | default dict -}}
{{- with get $smtp "fromAddress" | default (ternary "no-reply@logfire.localhost" ""
    (.Values.dev.deployMaildev | default false)) }}
- name: EMAIL_FROM_ADDRESS
  value: {{ . | quote }}
{{- end }}
{{- with get $smtp "fromName" }}
- name: EMAIL_FROM_NAME
  value: {{ . | quote }}
{{- end }}
{{- end -}}

{{/*
The CA bundle that verifies the SMTP server certificate, for relays signed by an internal CA.
Not used with the bundled maildev, which replaces smtp.host.
*/}}
{{- define "logfire.smtp.caBundle.source" -}}
{{- $caBundle := (.Values.smtp | default dict).caBundle | default dict -}}
{{- if and (not .Values.dev.deployMaildev)
    (or (dig "existingConfigMap" "name" "" $caBundle) (dig "existingSecret" "name"
    "" $caBundle)) -}}
true
{{- end -}}
{{- end -}}

{{/* The SMTP CA bundle reaches the client through `logfire.trustedCa.env`. */}}
{{- define "logfire.smtp.tlsEnv" -}}
{{- $validateCerts := (.Values.smtp | default dict).validate_certs -}}
{{- if and (not .Values.dev.deployMaildev) (not (kindIs "invalid" $validateCerts)) }}
- name: SMTP_VALIDATE_CERTS
  value: {{ $validateCerts | toString | quote }}
{{- end }}
{{- end -}}

{{/*
Trusted CA bundle: extra CA certificates for outbound TLS, such as a `rediss://` Redis or an
SMTP relay signed by a private CA. `trustedCaBundle` reaches every service in the list below.
`smtp.caBundle` reaches only the two services that send email.

The `trusted-ca-bundle` init container joins the certificates into one file in an emptyDir.
Python (OpenSSL, httpx) and Rust (`rustls-native-certs`) read it through `SSL_CERT_FILE`, which
replaces their default trust store. So the file starts with the system bundle of the image, and
public endpoints such as object storage and model providers stay trusted.

The AI gateway runs on Node, which ignores `SSL_CERT_FILE`. It reads the file through
`NODE_EXTRA_CA_CERTS`, which adds to the built-in roots of Node. That variable takes one file, so
the file also holds the in-cluster CA when in-cluster TLS is enabled.

The other in-cluster TLS clients are unaffected. They trust `LOGFIRE_CA_PATH` explicitly.
*/}}
{{- define "logfire.trustedCa.sources" -}}
{{- $ctx := .ctx -}}
{{- $sources := list -}}
{{- $trusted := $ctx.Values.trustedCaBundle | default dict -}}
{{- if and (has .serviceName (list
    "logfire-backend" "logfire-backend-auth" "logfire-worker" "logfire-task-runner"
    "logfire-alert-runner" "logfire-remote-mcp" "logfire-ai-gateway" "logfire-ff-ingest"
    "logfire-ff-ingest-processor" "logfire-ff-query-api" "logfire-ff-query-worker"
    "logfire-ff-crud-api" "logfire-ff-maintenance-scheduler" "logfire-ff-maintenance-worker"
    "logfire-ff-compaction-worker"))
    (or (dig "existingConfigMap" "name" "" $trusted) (dig "existingSecret" "name" "" $trusted)) -}}
  {{- $sources = append $sources (dict "bundle" $trusted "path" "trusted-ca.crt") -}}
{{- end -}}
{{- if and (has .serviceName (list "logfire-task-runner" "logfire-worker"))
    (include "logfire.smtp.caBundle.source" $ctx) -}}
  {{- $sources = append $sources (dict "bundle" $ctx.Values.smtp.caBundle "path" "smtp-ca.crt") -}}
{{- end -}}
{{- dict "sources" $sources | toJson -}}
{{- end -}}

{{/* "true" when the service trusts extra CA certificates. Pass (dict "ctx" . "serviceName"
    $serviceName). */}}
{{- define "logfire.trustedCa.enabled" -}}
{{- if (include "logfire.trustedCa.sources" . | fromJson).sources -}}
true
{{- end -}}
{{- end -}}

{{- define "logfire.trustedCa.env" -}}
{{- if include "logfire.trustedCa.enabled" . -}}
- name: {{ ternary "NODE_EXTRA_CA_CERTS" "SSL_CERT_FILE" (eq .serviceName "logfire-ai-gateway") }}
  value: /etc/logfire/trusted-ca/ca-bundle.crt
{{- end -}}
{{- end -}}

{{- define "logfire.trustedCa.volumeMount" -}}
{{- if include "logfire.trustedCa.enabled" . -}}
- name: logfire-trusted-ca
  mountPath: /etc/logfire/trusted-ca
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "logfire.trustedCa.volumes" -}}
{{- with (include "logfire.trustedCa.sources" . | fromJson).sources -}}
- name: logfire-trusted-ca-sources
  projected:
    sources:
      {{- range . }}
      {{- $fromConfigMap := dig "existingConfigMap" "name" "" .bundle | empty | not }}
      {{- $kind := ternary "configMap" "secret" $fromConfigMap }}
      {{- $source := get .bundle (ternary "existingConfigMap" "existingSecret" $fromConfigMap) }}
      - {{ $kind }}:
          name: {{ $source.name }}
          items:
            - key: {{ dig "key" "ca.crt" $source }}
              path: {{ .path }}
      {{- end }}
- name: logfire-trusted-ca
  emptyDir:
    sizeLimit: 16Mi
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.enabled" -}}
{{- .Values.inClusterTls.enabled | default false -}}
{{- end -}}

{{- define "logfire.serviceHost" -}}
{{- printf "%s.%s.svc.%s" .serviceName .ctx.Release.Namespace
    (.ctx.Values.clusterDomain | default "cluster.local") -}}
{{- end -}}

{{/* An HAProxy server line, with in-cluster TLS when enabled. */}}
{{- define "logfire.inClusterTls.haproxyUpstream" -}}
{{- $ctx := .ctx -}}
{{- $tls := include "logfire.inClusterTls.enabled" $ctx | eq "true" -}}
{{- $host := include "logfire.serviceHost" . -}}
{{- $certificateHost := include "logfire.serviceHost"
    (dict "ctx" $ctx "serviceName" (.certificateServiceName | default .serviceName)) -}}
{{- if .replicas -}}
server-template {{ .name }} 1-{{ .replicas }}
{{- else -}}
server {{ .name }}
{{- end }} {{ $host }}.:{{ ternary $ctx.Values.inClusterTls.httpsPort .cleartextPort $tls }}
{{- with .options }} {{ . }}{{ end }}
{{- if
    $tls }} ssl verify required ca-file /usr/local/etc/haproxy/ca/ca.crt sni str({{ $certificateHost }}) verifyhost {{ $certificateHost }}
{{- if hasKey . "checkSsl" | ternary .checkSsl true }} check-ssl{{ end }}
{{- end -}}
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

{{- define "logfire.inClusterTls.certs.certManager.autoIssuer" -}}
{{- and (include "logfire.inClusterTls.certs.isCertManager" . | eq "true")
    (not (include "logfire.inClusterTls.certs.certManager.issuerRef.name" .)) -}}
{{- end -}}

{{- define "logfire.inClusterTls.certs.certManager.autoCaSecretName" -}}
{{- printf "%s-incluster-ca" .Release.Name -}}
{{- end -}}

{{- define "logfire.inClusterTls.https.servicePort" -}}
{{- if include "logfire.inClusterTls.enabled" .ctx | eq "true" -}}
- name: {{ .name | default "https" }}
  port: {{ .ctx.Values.inClusterTls.httpsPort }}
  targetPort: {{ .targetPort | default "https" }}
  appProtocol: HTTPS
  protocol: TCP
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.https.containerPort" -}}
{{- if include "logfire.inClusterTls.enabled" .ctx | eq "true" -}}
- name: {{ .name | default "https" }}
  containerPort: {{ .ctx.Values.inClusterTls.httpsPort }}
  protocol: TCP
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.server.checksumAnnotation" -}}
{{- $ctx := .ctx -}}
{{- if include "logfire.inClusterTls.enabled" $ctx | eq "true" -}}
{{- $secretName := include "logfire.inClusterTls.secretName" . -}}
{{ .annotationKey | default "checksum/incluster-tls-cert" }}: {{ include "utils.secretChecksum"
    (dict "ctx" $ctx "name" $secretName "key" (.secretKey | default "tls.crt")) }}
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.server.volumeMount" -}}
{{- if include "logfire.inClusterTls.enabled" .ctx | eq "true" -}}
- name: {{ .volumeName | default "logfire-incluster-tls" }}
  mountPath: {{ .mountPath | default "/etc/tls" }}
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.server.volume" -}}
{{- if include "logfire.inClusterTls.enabled" .ctx | eq "true" -}}
- name: {{ .volumeName | default "logfire-incluster-tls" }}
  secret:
    secretName: {{ include "logfire.inClusterTls.secretName" . }}
    items:
      - key: tls.crt
        path: {{ .crtPath | default "tls.crt" }}
      - key: tls.key
        path: {{ .keyPath | default "tls.key" }}
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.caBundle.volumeMount" -}}
{{- if include "logfire.inClusterTls.enabled" .ctx | eq "true" -}}
- name: {{ .volumeName | default "logfire-incluster-ca-bundle" }}
  mountPath: {{ .mountPath }}
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.caBundle.volume" -}}
{{- $ctx := .ctx -}}
{{- if include "logfire.inClusterTls.enabled" $ctx | eq "true" -}}
{{- $caBundle := $ctx.Values.inClusterTls.caBundle -}}
{{- $caBundleSecretName := dig "existingSecret" "name" "" $caBundle -}}
- name: {{ .volumeName | default "logfire-incluster-ca-bundle" }}
  {{- if $caBundle.existingConfigMap.name }}
  configMap:
    name: {{ $caBundle.existingConfigMap.name }}
    items:
      - key: {{ $caBundle.existingConfigMap.key | default "ca.crt" }}
        path: ca.crt
  {{- else if $caBundleSecretName }}
  secret:
    secretName: {{ $caBundleSecretName }}
    items:
      - key: {{ dig "existingSecret" "key" "ca.crt" $caBundle }}
        path: ca.crt
  {{- else if include "logfire.inClusterTls.certs.certManager.autoIssuer" $ctx | eq "true" }}
  secret:
    secretName: {{ include "logfire.inClusterTls.certs.certManager.autoCaSecretName" $ctx }}
    items:
      - key: tls.crt
        path: ca.crt
  {{- end }}
{{- end -}}
{{- end -}}

{{- define "logfire.scheme" -}}
{{- if .Values.inClusterTls.enabled -}}
https
{{- else -}}
http
{{- end -}}
{{- end -}}

{{/* `.port`, or the in-cluster HTTPS port when in-cluster TLS is enabled. */}}
{{- define "logfire.port" -}}
{{- if .root.Values.inClusterTls.enabled -}}
{{- .root.Values.inClusterTls.httpsPort -}}
{{- else -}}
{{- .port -}}
{{- end -}}
{{- end -}}

{{/*
The `devPostgres` values, JSON encoded. A `--reuse-values` upgrade from a chart before 0.15.0
renders with the old release's values in place of this chart's defaults, so the block is
missing, or holds only the keys the user set. Every reader goes through here, so that upgrade
fails with this message wherever the render stops first.
*/}}
{{- define "logfire.devPostgres.values" -}}
{{- $devPostgres := .Values.devPostgres | default dict -}}
{{- range $key := list "fullnameOverride" "image" "auth" "initdb" "persistence" "podSecurityContext"
    "resources" -}}
  {{- if not (hasKey $devPostgres $key) -}}
    {{- fail
        (printf "dev.deployPostgres needs devPostgres.%s, a chart 0.15.0 default that a --reuse-values upgrade from an older chart does not carry. Upgrade with --reset-then-reuse-values, or pass your values file with -f."
        $key) -}}
  {{- end -}}
{{- end -}}
{{- $devPostgres | toJson -}}
{{- end -}}

{{/* The database wait init container runs the same image, so a mirrored image reaches both. */}}
{{- define "logfire.devPostgres.image" -}}
{{- include "logfire.imageRef" (dict "image" (include "logfire.devPostgres.values" .
    | fromJson).image) -}}
{{- end -}}

{{/*
The chart-wide pod security context over a pod-level `RuntimeDefault` seccomp profile, so containers
the chart does not render, such as injected mesh sidecars, pass the `restricted` Pod Security level.
The bundled Redis reads `podSecurityContext` directly, so its pod template stays unchanged.
*/}}
{{- define "logfire.podSecurityContext" -}}
{{- mergeOverwrite (dict "seccompProfile" (dict "type" "RuntimeDefault"))
    (deepCopy (.Values.podSecurityContext | default dict)) | toJson -}}
{{- end -}}

{{/*
Chart-owned init containers come first, then the service's own `initContainers`. A user init
container with the same name replaces `check-db-ready` or `wait-for-absurd-schema`.

`logfire-task-runner` drains the `default` Absurd queue and exits 1 at startup when that queue is
missing. Only `absurd.create_queue` creates the per-queue tables, and `logfire-backend-migrations`
calls it through `ensure_queues` right after it installs the `absurd` schema (see
`logfire_db.migrations.main`). Migrations are a Helm hook only when the bundled Postgres is off
(see the annotations on that Job), so nothing otherwise orders the two. Waiting for the runner's
queue makes the dependency explicit rather than leaving it to scheduling order.

The post-deploy migrations Job name hashes this output, so keep its whitespace stable.
*/}}
{{- define "logfire.initContainers" -}}
{{- $ctx := .ctx -}}
{{- $serviceName := .serviceName -}}
{{- $userInit := (index $ctx.Values $serviceName | default dict).initContainers -}}
{{- $userNames := list -}}
{{- range $userInit -}}
  {{- $userNames = append $userNames .name -}}
{{- end -}}
{{- $trustedCa := include "logfire.trustedCa.enabled" (dict "ctx" $ctx "serviceName" $serviceName) -}}
{{- $devInit := and $ctx.Values.dev.deployPostgres (not (has "check-db-ready" $userNames))
    (has $serviceName (list "logfire-backend" "logfire-backend-auth" "logfire-worker"
        "logfire-task-runner" "logfire-alert-runner" "logfire-dex" "logfire-backend-migrations"
        "logfire-backend-post-deploy-migrations" "logfire-ff-migrations" "logfire-ff-crud-api"
        "logfire-ff-maintenance-scheduler" "logfire-ff-maintenance-worker"
        "logfire-ff-compaction-worker" "logfire-ff-query-api" "logfire-ff-query-worker"
        "logfire-ff-ingest" "logfire-ff-ingest-processor" "logfire-ai-gateway"
        "logfire-remote-mcp")) -}}
{{- $absurdInit := and (eq $serviceName "logfire-task-runner")
    (not (has "wait-for-absurd-schema" $userNames)) -}}
{{- if or $trustedCa $devInit $userInit $absurdInit -}}
initContainers:
{{- if $trustedCa }}
{{- $containerSecurityContext := include "logfire.containerSecurityContext"
    (dict "ctx" $ctx "serviceName" $serviceName) | fromJson }}
{{- $gateway := eq $serviceName "logfire-ai-gateway" }}
{{- $inClusterCa := and $gateway (include "logfire.inClusterTls.enabled" $ctx | eq "true") }}
{{- $repository := $ctx.Values.image.repository | default "" }}
{{- $image := include "logfire.pythonImage" (dict "Values" $ctx.Values "key" "backendImage") }}
{{- $baseFile := "/etc/ssl/certs/ca-certificates.crt" }}
{{- if $gateway }}
  {{- $repository = $ctx.Values.image.gatewayRepository | default "" }}
  {{- $image = $ctx.Values.image.gatewayImage }}
  {{- $baseFile = ternary "/etc/logfire/incluster-ca/ca.crt" "" $inClusterCa }}
{{- else if hasPrefix "logfire-ff-" $serviceName }}
  {{- $image = $ctx.Values.image.fusionfireImage }}
{{- else if eq $serviceName "logfire-worker" }}
  {{- $image = include "logfire.pythonImage" (dict "Values" $ctx.Values "key" "workerImage") }}
{{- else if eq $serviceName "logfire-alert-runner" }}
  {{- $image = $ctx.Values.image.alertRunnerImage | default "logfire-alert-runner-prod" }}
{{- end }}

  - name: trusted-ca-bundle
    image: '{{ $repository }}{{ $image }}:{{ include "logfire.serviceTag"
        (dict "Values" $ctx.Values "serviceName" $serviceName "Chart" $ctx.Chart) }}'
    imagePullPolicy: "{{ $ctx.Values.image.pullPolicy }}"
    command:
      - sh
      - -c
      - |
        set -eu
        for f in {{ with $baseFile }}{{ . }} {{ end }}/etc/logfire/trusted-ca-sources/*.crt; do
          cat "$f"
          echo
        done > /etc/logfire/trusted-ca/ca-bundle.crt
    {{- include "logfire.resources" (dict "Values" $ctx.Values "serviceName" $serviceName)
        | nindent 4 }}
    {{- include "logfire.securityContext" $containerSecurityContext | nindent 4 }}
    volumeMounts:
      - name: logfire-trusted-ca-sources
        mountPath: /etc/logfire/trusted-ca-sources
        readOnly: true
      - name: logfire-trusted-ca
        mountPath: /etc/logfire/trusted-ca
      {{- if $inClusterCa }}
      {{- include "logfire.inClusterTls.caBundle.volumeMount"
          (dict "ctx" $ctx "mountPath" "/etc/logfire/incluster-ca") | nindent 6 }}
      {{- end }}
{{- end }}
{{- if $devInit }}

  - name: check-db-ready
    image: {{ include "logfire.devPostgres.image" $ctx }}
    command:
      - sh
      - -c
      - >-
        until pg_isready -h {{ (include "logfire.devPostgres.values" $ctx
            | fromJson).fullnameOverride }} -p 5432 -U postgres; do echo "Waiting for postgres..."; sleep 2; done
    {{- $waitSecurityContext := include "logfire.thirdPartyContainerSecurityContext"
        (dict "ctx" $ctx "identity" "postgres" "serviceName" "postgres-wait"
        "readOnlyRootFilesystem" true) | fromJson }}
    {{- include "logfire.securityContext" $waitSecurityContext | nindent 4 }}
{{- end }}
{{- if $absurdInit }}
{{- $containerSecurityContext := include "logfire.containerSecurityContext"
    (dict "ctx" $ctx "serviceName" $serviceName) | fromJson }}

  - name: wait-for-absurd-schema
    image: '{{ $ctx.Values.image.repository | default "" }}{{ include "logfire.pythonImage"
        (dict "Values" $ctx.Values "key" "taskRunnerImage") }}:{{ include "logfire.serviceTag"
        (dict "Values" $ctx.Values "serviceName" $serviceName "Chart" $ctx.Chart) }}'
    imagePullPolicy: "{{ $ctx.Values.image.pullPolicy }}"
    command:
      - python
      - -c
      - |
        import os, time, psycopg

        dsn = os.environ["CRUD_PG_DSN"]
        while True:
            try:
                with psycopg.connect(dsn) as conn:
                    (queue_ready,) = conn.execute("SELECT to_regclass('absurd.t_default')").fetchone()
                if queue_ready:
                    break
                print("Waiting for the 'default' Absurd queue...", flush=True)
            except psycopg.OperationalError as exc:
                print(f"Waiting for postgres: {exc}", flush=True)
            time.sleep(2)
    env:
      - name: CRUD_PG_DSN
        valueFrom:
          secretKeyRef:
            name: {{ include "logfire.postgresSecretName" $ctx }}
            key: postgresDsn
    {{- include "logfire.securityContext" $containerSecurityContext | nindent 4 }}
    volumeMounts:
      {{- include "logfire.tmpVolumeMounts" $ctx | nindent 6 }}
{{- end }}
{{- with $userInit }}
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
{{- end -}}
