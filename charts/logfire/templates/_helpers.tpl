{{- define "logfire.hpa" }}
{{- $cpuAverage := dig "hpa" "cpuAverage" .cpuAverage . }}
{{- $memAverage := dig "hpa" "memAverage" .memAverage . }}
{{- $extraMetrics := dig "hpa" "extraMetrics" .extraMetrics . }}
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

{{/*
Determine if HPA is enabled maintaining backward compatibility with old values format
*/}}
{{- define "logfire.hpa.enabled" -}}
{{- if hasKey . "hpa" -}}
  {{- .hpa.enabled  -}}
{{- else if or .memAverage .cpuAverage .extraMetrics -}}
  {{- true -}}
{{- else -}}
  {{- false -}}
{{- end -}}
{{- end -}}

{{- define "logfire.keda.enabled" -}}
{{- if hasKey . "keda" -}}
  {{- .keda.enabled  -}}
{{- else -}}
  {{- false -}}
{{- end -}}
{{- end -}}

{{- define "logfire.autoscaler" }}
{{- if index (index .Values .serviceName | default dict) "autoscaling" }}
{{- $kind := (not (eq .serviceName "logfire-ff-ingest") | ternary "Deployment" "StatefulSet" ) }}
{{- with index .Values .serviceName "autoscaling" }}
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
{{- if hasKey $root.Values $serviceName }}
{{- if index (index $root.Values $serviceName | default dict) "pdb" }}
{{- with index $root.Values $serviceName "pdb" }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $serviceName }}
  labels:
    {{- include "logfire.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $serviceName }}
spec:
  {{- with .maxUnavailable }}
  maxUnavailable: {{ . }}
  {{- end }}
  {{- with .minAvailable }}
  minAvailable: {{ . }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "logfire.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ $serviceName }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "logfire.ffCompactionTiers" -}}
{{- if (get (get .Values "logfire-ff-maintenance-worker" | default  dict) "compactionTiers") -}}
{{- with (get (get .Values "logfire-ff-maintenance-worker" | default  dict) "compactionTiers") -}}
- name: FF_COMPACTION_TIERS
  value: {{ . | toJson | squote }}
{{- end -}}
{{- else -}}
- name: FF_COMPACTION_TIERS
  value: '[{"count_threshold":10,"size_threshold_bytes":"1KB"},{"count_threshold":10,"size_threshold_bytes":"10KB"},{"count_threshold":10,"size_threshold_bytes":"100KB"},{"count_threshold":10,"size_threshold_bytes":"1MB"},{"count_threshold":10,"size_threshold_bytes":"10MB"},{"count_threshold":10,"size_threshold_bytes":"100MB"}]'
{{- end -}}
{{- end -}}

{{- define "logfire.resources"}}
{{- if index (index .Values .serviceName | default dict) "resources" }}
{{- with index .Values .serviceName "resources" }}
resources:
  requests:
    memory: {{ .memory | default "1Gi" }}
    cpu: {{ .cpu | default "1" }}
  limits:
    memory: {{ .memory | default "1Gi" }}
    cpu: {{ .cpu | default "1" }}
{{- end}}
{{- end}}
{{- end}}

{{/*
Get effective hostnames - prefers gateway.hostnames when gateway is enabled, falls back to ingress.hostnames
Returns a wrapped object {"hosts": [...]} to work around fromJson limitation with top-level arrays.
*/}}
{{- define "logfire.effective_hostnames" -}}
{{- $hosts := list -}}
{{- if and .Values.gateway.enabled .Values.gateway.hostnames -}}
  {{- $hosts = .Values.gateway.hostnames -}}
{{- else if .Values.ingress.hostnames -}}
  {{- $hosts = .Values.ingress.hostnames -}}
{{- else if .Values.ingress.hostname -}}
  {{- $hosts = list .Values.ingress.hostname -}}
{{- end -}}
{{- dict "hosts" $hosts | toJson -}}
{{- end -}}

{{/*
Get effective TLS setting - prefers gateway.tls when gateway is enabled and set, falls back to ingress.tls
*/}}
{{- define "logfire.effective_tls" -}}
{{- if and .Values.gateway.enabled (not (kindIs "invalid" .Values.gateway.tls)) -}}
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

{{/*
Logfire secret name
*/}}
{{- define "logfire.secretName" -}}
{{- $ctx := required "logfire.secretName: need .ctx" .ctx -}}
{{- $ex := get $ctx.Values "existingSecret" | default dict -}}
{{- if and (get $ex "enabled") (get $ex "name") -}}
    {{ get $ex "name" }}
{{- else }}
{{- .secretName }}
{{- end }}
{{- end -}}

{{/*
Logfire secret name
*/}}
{{- define "logfire.adminSecretName" -}}
{{- $ctx := required "logfire.adminSecretName: need .ctx" .ctx -}}
{{- $ex := get $ctx.Values "adminSecret" | default dict -}}
{{- if and (get $ex "enabled") (get $ex "name") -}}
    {{ get $ex "name" }}
{{- else }}
{{- .secretName }}
{{- end }}
{{- end -}}

{{- define "logfire.objectStoreEnv" -}}
- name: FF_OBJECT_STORE_URI
  value: {{ .Values.objectStore.uri }}
{{- range $key, $value := .Values.objectStore.env }}
{{- if kindIs "map" $value }}
- name: {{ $key }}
  {{- if hasKey $value "value" }}
  value: {{ $value.value }}
  {{- end }}
  {{- if hasKey $value "valueFrom" }}
  valueFrom:
    {{- toYaml $value.valueFrom | nindent 4 }}
  {{- end }}
{{- else }}
- name: {{ $key }}
  value: {{ $value | toString | quote }}
{{- end }}
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
- name: "OTEL_EXPORTER_OTLP_PROTOCOL"
  value: "grpc"
- name: "COLLECTOR_OTLP_GRPC_HOST"
  value: http://logfire-otel-collector:4317
- name: LOGFIRE_SERVICE_NAME
  value: {{ . }}
- name: OTEL_SERVICE_NAME
  value: {{ . }}
{{- end }}

{{- define "logfire.scratchVolumeName" -}}
scratch-data
{{- end -}}

{{- define "logfire.scratchVolume" -}}
{{- $scratchVolume := . -}}
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
        {{- if $scratchVolume.storageClassName }}
        storageClassName: {{ $scratchVolume.storageClassName }}
        {{- end }}
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
{{- $ingestVolume := . -}}
- metadata:
    name: {{ include "logfire.ingestVolumeName" . }}
  spec:
    accessModes: [ "ReadWriteOnce" ]
    {{- if $ingestVolume.storageClassName }}
    storageClassName: {{ $ingestVolume.storageClassName }}
    {{- end }}
    resources:
      requests:
        storage: {{ $ingestVolume.storage }}
{{- end -}}

{{/*
Annotations to allow existing logfire secrets reloading
*/}}
{{- define "logfire.existingSecret.annotations" -}}
{{- if and .Values.existingSecret.enabled (not (empty .Values.existingSecret.annotations)) -}}
{{- toYaml .Values.existingSecret.annotations -}}
{{- end }}
{{- end }}

{{/*
Annotations to allow existing postgres secret reloading
*/}}
{{- define "logfire.postgresSecret.annotations" -}}
{{- if and .Values.postgresSecret.enabled (not (empty .Values.postgresSecret.annotations)) -}}
{{- toYaml .Values.postgresSecret.annotations -}}
{{- end -}}
{{- end }}

{{/* 
Annotations to allow both postgres and existing secrets reloading
*/}}
{{- define "logfire.secretAnnotations" -}}
{{- $postgresAnns := .Values.postgresSecret.annotations -}}
{{- $existingAnns := .Values.existingSecret.annotations -}}

{{- $merged := dict -}}

{{- if and .Values.postgresSecret.enabled $postgresAnns -}}
  {{- $merged = merge $merged $postgresAnns -}}
{{- end -}}

{{- /* Merge in the second set, overwriting any duplicate keys */ -}}
{{- if and .Values.existingSecret.enabled $existingAnns -}}
  {{- $merged = merge $merged $existingAnns -}}
{{- end -}}

{{- if $merged -}}
{{-   toYaml $merged -}}
{{- end -}}
{{- end -}}

{{/*
Custom annotations for workloads
*/}}
{{- define "logfire.annotations" -}}
{{- $serviceValues := index .Values .serviceName -}}
{{- if and $serviceValues $serviceValues.annotations -}}
{{- toYaml $serviceValues.annotations -}}
{{- end -}}
{{- end -}}

{{/*
Custom annotations for workloads pods
*/}}
{{- define "logfire.podAnnotations" -}}
{{- $serviceValues := index .Values .serviceName -}}
{{- if and $serviceValues $serviceValues.podAnnotations -}}
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
{{- $serviceValues := index .Values .serviceName -}}
{{- if and $serviceValues $serviceValues.podLabels -}}
{{- toYaml $serviceValues.podLabels -}}
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

{{/*
Calculate memory assignments based on servicememory request
*/}}
{{- define "logfire.calculateMemory" -}}
{{-   $dot := . -}}
{{-   $values := get $dot "Values"  -}}
{{-   $serviceName := get $dot "serviceName" -}}
{{-   $percentage := get $dot "percentage" -}}
{{-   $defaultMemory := get $dot "defaultMemory" | default "1Gi" -}}

{{-   $serviceValues := get $values $serviceName | default dict -}}
{{-   $resources := get $serviceValues "resources" | default dict -}}
{{-   $memory := get $resources "memory" | default $defaultMemory -}}

{{-   $memoryMi := 0 -}}
{{-   if hasSuffix "Gi" $memory -}}
{{-     $memoryMi = mul (int (trimSuffix "Gi" $memory)) 1024 -}}
{{-   else if hasSuffix "Mi" $memory -}}
{{-     $memoryMi = int (trimSuffix "Mi" $memory) -}}
{{-   else -}}
      {{- fail (printf "Invalid memory format for service '%s': '%s'. Must end in 'Gi' or 'Mi'." $serviceName $memory) -}}
{{-   end -}}

{{-   $calculatedMemory := div (mul $memoryMi (int $percentage)) 100 -}}

{{-   $calculatedMemory | int -}}
{{- end -}}

{{- define "logfire.backendMigrations.name" -}}
{{- if .Values.dev.deployPostgres -}}
"logfire-backend-migrations-{{ .Release.Revision }}"
{{- else -}}
"logfire-backend-migrations"
{{- end -}}
{{- end -}}

{{- define "logfire.ffMigrations.name" -}}
{{- if .Values.dev.deployPostgres -}}
"logfire-ff-migrations-{{ .Release.Revision }}"
{{- else -}}
"logfire-ff-migrations"
{{- end -}}
{{- end -}}

{{- define "logfire.nodeSelector" -}}
{{- $serviceValues := index .Values .serviceName | default dict -}}
{{- $serviceSelector := $serviceValues.nodeSelector | default dict -}}
{{- $merged := merge $serviceSelector (.Values.nodeSelector | default dict) -}}
{{- if $merged -}}
nodeSelector:
{{- toYaml $merged | nindent 2 }}
{{- end -}}
{{- end -}}

{{- define "logfire.affinity" -}}
{{- $serviceValues := index .Values .serviceName | default dict -}}
{{- $serviceAffinity := $serviceValues.affinity | default dict -}}
{{- $merged := merge $serviceAffinity (.Values.affinity | default dict) -}}
{{- if $merged -}}
affinity:
{{- toYaml $merged | nindent 2 }}
{{- end -}}
{{- end -}}

{{- define "logfire.tolerations" -}}
{{- $serviceValues := index .Values .serviceName | default dict -}}
{{- $serviceTolerations := $serviceValues.tolerations | default list -}}
{{- $merged := concat $serviceTolerations (.Values.tolerations | default list) -}}
{{- if $merged -}}
tolerations:
{{- toYaml $merged | nindent 2 }}
{{- end -}}
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
{{- if .Values.rateLimits -}}
- name: SDK_V1_QUERY_RATE_LIMIT__PER_MINUTE
  value: {{ (get (get .Values.rateLimits "queries"| default dict) "perMinute" | default 99999) | quote }}
- name: SDK_V1_QUERY_RATE_LIMIT__PER_HOUR
  value: {{ (get (get .Values.rateLimits "queries"| default dict) "perHour" | default 99999) | quote }}
{{- else -}}
- name: SDK_V1_QUERY_RATE_LIMIT__PER_MINUTE
  value: "99999"
- name: SDK_V1_QUERY_RATE_LIMIT__PER_HOUR
  value: "99999"
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

{{- define "logfire.inClusterTls.secretNamePrefix" -}}
{{- if .Values.inClusterTls.secretNamePrefix -}}
{{- .Values.inClusterTls.secretNamePrefix -}}
{{- else -}}
{{- .Release.Name -}}
{{- end -}}
{{- end -}}

{{- define "logfire.inClusterTls.secretName" -}}
{{- $prefix := include "logfire.inClusterTls.secretNamePrefix" .ctx -}}
{{- printf "%s-%s-tls" $prefix .serviceName -}}
{{- end -}}

{{- define "logfire.inClusterTls.caBundle.isConfigMap" -}}
{{- and (include "logfire.inClusterTls.enabled" . | eq "true") (.Values.inClusterTls.caBundle.existingConfigMap.name) -}}
{{- end -}}

{{- define "logfire.inClusterTls.caBundle.isSecret" -}}
{{- and (include "logfire.inClusterTls.enabled" . | eq "true") (dig "existingSecret" "name" "" .Values.inClusterTls.caBundle) -}}
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
  {{- if (include "logfire.inClusterTls.caBundle.isConfigMap" $ctx | eq "true") }}
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
================================================================================
Dev Postgres helpers
================================================================================
*/}}

{{- define "logfire.dev.waitForPostgres.initContainers" -}}
{{- $ctx := .ctx -}}
{{- $serviceName := .serviceName -}}
{{- if and $ctx.Values.dev.deployPostgres (has $serviceName (list
  "logfire-backend"
  "logfire-worker"
  "logfire-dex"
  "logfire-backend-migrations"
  "logfire-ff-migrations"
  "logfire-ff-crud-api"
  "logfire-ff-maintenance-scheduler"
  "logfire-ff-maintenance-worker"
  "logfire-ff-query-api"
  "logfire-ff-query-worker"
  "logfire-ff-ingest"
  "logfire-ff-ingest-processor"
)) -}}
- name: check-db-ready
  image: postgres:17
  command:
    - sh
    - -c
    - >-
      until pg_isready -h {{ $ctx.Values.postgresql.fullnameOverride | default "logfire-postgres" }} -p 5432; do echo "Waiting for postgres..."; sleep 2; done
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
Validate ingress hostnames configuration
*/}}
{{- define "logfire.validate.ingress" -}}
{{- $hasHostnames := and .Values.ingress.hostnames (gt (len .Values.ingress.hostnames) 0) -}}
{{- $hasHostname := .Values.ingress.hostname -}}
{{- if not (or $hasHostnames $hasHostname) -}}
  {{- fail "ingress.hostnames (or ingress.hostname) is required. Specify at least one hostname for Logfire (e.g., hostnames: ['logfire.example.com']). This is needed for CORS and URL generation even if ingress.enabled is false." -}}
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
  {{- if and $hpaEnabled $kedaEnabled -}}
    {{- fail (printf "Both HPA and KEDA are enabled for '%s'. Only one autoscaler should be enabled at a time to avoid conflicts." $serviceName) -}}
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
{{- include "logfire.validate.objectStore" . -}}
{{- include "logfire.validate.ingress" . -}}
{{- include "logfire.validate.gateway" . -}}
{{- include "logfire.validate.ingressGatewayConflict" . -}}
{{- include "logfire.validate.postgres" . -}}
{{- include "logfire.validate.dexStorage" . -}}
{{- include "logfire.validate.ai" . -}}
{{- include "logfire.validate.existingSecret" . -}}
{{- include "logfire.validate.adminSecret" . -}}
{{- include "logfire.validate.admin" . -}}
{{- include "logfire.validate.redis" . -}}
{{- include "logfire.validate.inClusterTls" . -}}
{{- end -}}
