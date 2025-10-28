{{- define "logfire.hpa" }}
{{- $cpuAverage := dig "hpa" "cpuAverage" .cpuAverage . }}
{{- $memAverage := dig "hpa" "memAverage" .memAverage . }}
{{- $extraMetrics := dig "hpa" "extraMetrics" .extraMetrics . }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .serviceName }}
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
Primary logfire host for the app. Selects the first item from .Values.ingress.hostnames list
*/}}
{{- define "logfire.primary_hostname" -}}
{{- if .Values.ingress.hostnames -}}
{{- first .Values.ingress.hostnames -}}
{{- else -}}
{{- .Values.ingress.hostname -}}
{{- end -}}
{{- end -}}

{{/*
Full list of logfire hostnames, primary and alternative domains for ingress.
*/}}
{{- define "logfire.all_hostnames_string" -}}
{{- $hosts := .Values.ingress.hostnames -}}
{{- if not $hosts -}}
  {{- if .Values.ingress.hostname -}}
    {{- $hosts = list .Values.ingress.hostname -}}
  {{- end -}}
{{- end -}}
{{- join " " $hosts -}}
{{- end -}}

{{/*
Primary logfire host with protocol scheme.
*/}}
{{- define "logfire.url" -}}
{{- $primaryHostname := include "logfire.primary_hostname" . | trim -}}
{{- if $primaryHostname -}}
{{ .Values.ingress.tls | default false | ternary "https" "http" }}://{{ $primaryHostname }}
{{- end -}}
{{- end -}}

{{/*
Full list of logfire urls, primary and alternative domains with scheme.
*/}}
{{- define "logfire.all_urls" -}}
{{- $hosts := .Values.ingress.hostnames -}}
{{- if not $hosts -}}
  {{- if .Values.ingress.hostname -}}
    {{- $hosts = list .Values.ingress.hostname -}}
  {{- end -}}
{{- end -}}

{{- if $hosts -}}
  {{- $scheme := .Values.ingress.tls | default false | ternary "https" "http" -}}
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
Create default tag 
*/}}
{{- define "logfire.defaultTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
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
{{- $ctx := required "logfire.SecretName: need .ctx" .ctx -}}
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
{{- $grpc := dict "addr" "0.0.0.0:5557" -}}

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
      metadata:
        labels:
          {{ $scratchVolume.labels | toYaml }}
      spec:
        accessModes: [ "ReadWriteOnce" ]
        storageClassName: {{ $scratchVolume.storageClassName }}
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
    storageClassName: {{ $ingestVolume.storageClassName }}
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
"default-checksum"
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
