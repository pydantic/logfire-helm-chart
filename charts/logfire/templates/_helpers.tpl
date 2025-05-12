{{- define "logfire.hpa" }}
{{- if index (index .Values .serviceName | default dict) "autoscaling" }}
{{- with index .Values .serviceName "autoscaling" }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ $.serviceName }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ $.serviceName }}
  minReplicas: {{ .minReplicas | default "1" }}
  maxReplicas: {{ .maxReplicas |  default "2" }}
  metrics:
  {{- if .cpuAverage }}
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: {{ .cpuAverage | default "75" }}
  {{- end }}
  {{- if .memAverage }}
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: {{ .memAverage | default "75" }}
  {{- end }}
{{- if .extraMetrics }}
{{- toYaml .extraMetrics | nindent 2 }}
{{- end}}
{{- end}}
{{- end}}
{{- end}}

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

{{- define "logfire.url" -}}
{{ .Values.ingress.tls | default false | ternary "https" "http" }}://{{ .Values.ingress.hostname }}
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

{{- define "logfire.objectStoreEnv" -}}
- name: FF_OBJECT_STORE_URI
  value: {{ .Values.objectStore.uri }}
- name: FF_FAILOVER_OBJECT_STORE_URI
  value: {{ .Values.objectStore.uri }}/_ingest_failover
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
{{- $_ := set $client "redirectURIs" (list (printf "%s/auth/code-callback" $logfireFrontend) (printf "%s/auth/link-provider-code-callback" $logfireFrontend)) -}}
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
{{- $_ := set $dexConfig "enablePasswordDB" true -}}
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
