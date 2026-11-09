{{/*
Identity, telemetry and in-cluster CA settings that every Python workload needs. Takes `ctx` and
`serviceName`.
*/}}
{{- define "logfire.pythonServiceEnv" -}}
{{- $ctx := .ctx -}}
- name: LOGFIRE_SERVICE_NAME
  value: {{ .serviceName }}
- name: LOGFIRE_SERVICE_VERSION
  value: {{ include "logfire.serviceVersion" (dict "root" $ctx "serviceName" .serviceName) | quote }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ include "logfire.otelResourceAttributes" (dict "root" $ctx "serviceName" .serviceName "codeWorkDir" "/app") | quote }}
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
  {{- $ratio = 0.05 -}}
{{- end -}}
- name: OTEL_TRACES_SAMPLER
  value: parentbased_traceidratio
- name: OTEL_TRACES_SAMPLER_ARG
  value: {{ $ratio | quote }}
{{- end -}}

{{/*
What a workload needs to handle App channels: the key that decrypts stored credentials and the
`integrations` settings. Takes `ctx` and `serviceName`.

An entry that the workload's own `env` already sets is left out. Customers could set these by hand
before the chart managed them, and a duplicate env name can fail an upgrade.
*/}}
{{- define "logfire.appChannelEnv" -}}
{{- $ctx := .ctx -}}
{{- $integrations := $ctx.Values.integrations | default dict -}}
{{- $entries := list -}}
{{- $secrets := dict "ENCRYPTION_KEY" "logfire-encryption-key" -}}
{{- with dig "slack" "clientId" "" $integrations -}}
  {{- $entries = append $entries (dict "name" "INTEGRATION_SLACK_CLIENT_ID" "value" .) -}}
  {{- $_ := set $secrets "INTEGRATION_SLACK_CLIENT_SECRET" "logfire-slack-client-secret" -}}
  {{- $_ := set $secrets "INTEGRATION_SLACK_SIGNING_SECRET" "logfire-slack-signing-secret" -}}
{{- end -}}
{{- if eq .serviceName "logfire-backend" -}}
  {{- with dig "pagerduty" "appId" "" $integrations -}}
    {{- $entries = append $entries (dict "name" "INTEGRATION_PAGERDUTY_APP_ID" "value" .) -}}
  {{- end -}}
{{- end -}}
{{- range $name, $key := $secrets -}}
  {{- $secretName := include "logfire.externalSecretName" (dict "external" $ctx.Values.existingSecret "secretName" $key) | trim -}}
  {{- $entries = append $entries (dict "name" $name "valueFrom" (dict "secretKeyRef" (dict "name" $secretName "key" $key))) -}}
{{- end -}}
{{- $own := get (get $ctx.Values .serviceName | default dict) "env" -}}
{{- $ownNames := list -}}
{{- if kindIs "map" $own -}}
  {{- $ownNames = keys $own -}}
{{- else -}}
  {{- range ($own | default list) -}}
    {{- $ownNames = append $ownNames .name -}}
  {{- end -}}
{{- end -}}
{{- $kept := list -}}
{{- range $entries -}}
  {{- if not (has .name $ownNames) -}}
    {{- $kept = append $kept . -}}
  {{- end -}}
{{- end -}}
{{- if $kept -}}
  {{- toYaml $kept -}}
{{- end -}}
{{- end -}}

{{- define "logfire.slackApp.enabled" -}}
{{- if dig "slack" "clientId" "" (.Values.integrations | default dict) -}}true{{- end -}}
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
