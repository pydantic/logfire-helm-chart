{{/*
Identity, telemetry and in-cluster CA settings that every Python workload needs. A workload uses
this helper, so a new Python workload cannot miss one of these settings.
Takes `ctx`, `serviceName`, and optionally `codeWorkDir`.
*/}}
{{- define "logfire.pythonServiceEnv" -}}
{{- $ctx := .ctx -}}
{{- $attributes := dict "root" $ctx "serviceName" .serviceName -}}
{{- if .codeWorkDir -}}
  {{- $_ := set $attributes "codeWorkDir" .codeWorkDir -}}
{{- end -}}
- name: LOGFIRE_SERVICE_NAME
  value: {{ .serviceName }}
- name: LOGFIRE_SERVICE_VERSION
  value: {{ include "logfire.serviceVersion" (dict "root" $ctx "serviceName" .serviceName) | quote }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ include "logfire.otelResourceAttributes" $attributes | quote }}
- name: COLLECTOR_OTLP_GRPC_HOST
  value: http://logfire-otel-collector:4317
- name: ON_PREM
  value: "true"
- name: LOGFIRE_REGION
  value: {{ $ctx.Values.logfireRegion | default "local" }}
{{- if (include "logfire.inClusterTls.enabled" $ctx | eq "true") }}
- name: LOGFIRE_CA_PATH
  value: /etc/logfire/incluster-ca/ca.crt
{{- end }}
{{- end -}}

{{/*
Trace sampling for high-volume workloads. Spans of a sampled parent stay sampled, so the query
services that these workloads call follow the same decision.
*/}}
{{- define "logfire.otelSamplerEnv" -}}
{{- $ratio := .Values.otelTraceSampleRatio -}}
{{- if kindIs "invalid" $ratio -}}
  {{- $ratio = "0.05" -}}
{{- end -}}
- name: OTEL_TRACES_SAMPLER
  value: parentbased_traceidratio
- name: OTEL_TRACES_SAMPLER_ARG
  value: {{ $ratio | toString | quote }}
{{- end -}}

{{/*
Whether a workload's own `env` already sets `name`. A chart default for a credential that customers
could set by hand before the chart managed it checks this first, because a duplicate env name can
fail an upgrade. Takes `Values`, `serviceName` and `name`.
*/}}
{{- define "logfire.serviceEnvHas" -}}
{{- $env := get (get .Values .serviceName | default dict) "env" -}}
{{- $name := .name -}}
{{- if kindIs "map" $env -}}
  {{- if hasKey $env $name -}}true{{- end -}}
{{- else -}}
  {{- range ($env | default list) -}}
    {{- if eq .name $name -}}true{{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
The key that decrypts stored App channel credentials, for the workloads that deliver alerts.
Takes `ctx` and `serviceName`.
*/}}
{{- define "logfire.encryptionKeyEnv" -}}
{{- if not (include "logfire.serviceEnvHas" (dict "Values" .ctx.Values "serviceName" .serviceName "name" "ENCRYPTION_KEY")) -}}
- name: ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "logfire.externalSecretName" (dict "external" .ctx.Values.existingSecret "secretName" "logfire-encryption-key") }}
      key: logfire-encryption-key
{{- end -}}
{{- end -}}

{{- define "logfire.slackApp.enabled" -}}
{{- if dig "slack" "enabled" false (.Values.integrations | default dict) -}}true{{- end -}}
{{- end -}}

{{/*
The Slack App credentials, for `logfire-backend` and the workloads that deliver alerts.
Takes `ctx` and `serviceName`.
*/}}
{{- define "logfire.slackAppEnv" -}}
{{- if include "logfire.slackApp.enabled" .ctx -}}
{{- $ctx := .ctx -}}
{{- $serviceName := .serviceName -}}
{{- $slack := $ctx.Values.integrations.slack -}}
{{- $lines := list -}}
{{- if not (include "logfire.serviceEnvHas" (dict "Values" $ctx.Values "serviceName" $serviceName "name" "INTEGRATION_SLACK_CLIENT_ID")) -}}
  {{- $lines = append $lines (printf "- name: INTEGRATION_SLACK_CLIENT_ID\n  value: %s" ($slack.clientId | quote)) -}}
{{- end -}}
{{- range $envName, $key := dict "INTEGRATION_SLACK_CLIENT_SECRET" "logfire-slack-client-secret" "INTEGRATION_SLACK_SIGNING_SECRET" "logfire-slack-signing-secret" -}}
  {{- if not (include "logfire.serviceEnvHas" (dict "Values" $ctx.Values "serviceName" $serviceName "name" $envName)) -}}
    {{- $secretName := include "logfire.externalSecretName" (dict "external" $ctx.Values.existingSecret "secretName" $key) -}}
    {{- $lines = append $lines (printf "- name: %s\n  valueFrom:\n    secretKeyRef:\n      name: %s\n      key: %s" $envName $secretName $key) -}}
  {{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}
{{- end -}}

{{/*
Rolls the workloads that hold the Slack App credentials when they change.
*/}}
{{- define "logfire.slackAppChecksumAnnotation" -}}
{{- if include "logfire.slackApp.enabled" . -}}
{{- if .Values.existingSecret.enabled -}}
{{- include "logfire.logfireSecretChecksumAnnotations" (dict "ctx" . "secrets" (list "logfire-slack-client-secret" "logfire-slack-signing-secret")) -}}
{{- else -}}
{{- $slack := .Values.integrations.slack -}}
{{- printf "checksum/logfire-slack-app: %s" (printf "%s\x00%s\x00%s" $slack.clientId $slack.clientSecret $slack.signingSecret | sha256sum) -}}
{{- end -}}
{{- end -}}
{{- end -}}
