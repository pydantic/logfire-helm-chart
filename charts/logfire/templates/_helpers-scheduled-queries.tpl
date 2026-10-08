{{- define "logfire.scheduledQueryResultsUri" -}}
{{- if eq (include "logfire.scheduledQueryResultsUsesPersistence" .) "true" -}}
file:///var/lib/logfire/scheduled-query-results
{{- else -}}
{{- tpl .Values.scheduledQueryResults.uri . | trim | default (include "logfire.objectStoreUri" .) -}}
{{- end -}}
{{- end -}}

{{- define "logfire.scheduledQueryResultsUsesPersistence" -}}
{{- or .Values.scheduledQueryResults.persistence.enabled (not (empty .Values.scheduledQueryResults.persistence.existingClaim)) -}}
{{- end -}}

{{- define "logfire.scheduledQueryResultsReusesObjectStore" -}}
{{- and (not (tpl .Values.scheduledQueryResults.uri . | trim)) (eq (include "logfire.scheduledQueryResultsUsesPersistence" .) "false") -}}
{{- end -}}

{{- define "logfire.scheduledQueryResultsClaim" -}}
{{- .Values.scheduledQueryResults.persistence.existingClaim | default (printf "%s-scheduled-query-results" .Release.Name) -}}
{{- end -}}

{{- define "logfire.scheduledQueryResultsPodSecurityContext" -}}
{{- $defaults := dict -}}
{{- if eq (include "logfire.scheduledQueryResultsUsesPersistence" .) "true" -}}
{{- $defaults = dict "fsGroup" 1000 -}}
{{- end -}}
{{- mergeOverwrite $defaults (deepCopy .Values.podSecurityContext) | toJson -}}
{{- end -}}

{{- define "logfire.scheduledQueryResultsEnv" -}}
- name: SCHEDULED_QUERY_RESULTS_OBJECT_STORE_URI
  value: {{ include "logfire.scheduledQueryResultsUri" . | quote }}
{{- if eq (include "logfire.scheduledQueryResultsReusesObjectStore" .) "true" }}
{{- $ctx := deepCopy . }}
{{- $env := mergeOverwrite (deepCopy .Values.objectStore.env) .Values.scheduledQueryResults.env }}
{{- with .Values.objectStore.sseCKeyB64 }}
{{- $_ := set $env "AWS_SERVER_SIDE_ENCRYPTION" "sse-c" }}
{{- $_ := set $env "AWS_SSE_CUSTOMER_KEY_BASE64" . }}
{{- end }}
{{- $_ := set $ctx.Values.objectStore "env" $env }}
{{ include "logfire.objectStoreCredentialsEnv" $ctx }}
{{- else }}
{{- range $key, $value := .Values.scheduledQueryResults.env }}
- name: {{ $key }}
{{ include "logfire.envValue" (dict "value" $value "quote" (not (kindIs "map" $value)) "allowValueKey" true) | indent 2 }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "logfire.scheduledQueryResultsVolumeMounts" -}}
{{- if eq (include "logfire.scheduledQueryResultsUsesPersistence" .) "true" }}
- name: scheduled-query-results
  mountPath: /var/lib/logfire/scheduled-query-results
{{- end }}
{{- if eq (include "logfire.scheduledQueryResultsReusesObjectStore" .) "true" }}
{{ include "logfire.objectStoreVolumeMounts" . }}
{{- end }}
{{- with .Values.scheduledQueryResults.volumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "logfire.scheduledQueryResultsVolumes" -}}
{{- if eq (include "logfire.scheduledQueryResultsUsesPersistence" .) "true" }}
- name: scheduled-query-results
  persistentVolumeClaim:
    claimName: {{ include "logfire.scheduledQueryResultsClaim" . }}
{{- end }}
{{- if eq (include "logfire.scheduledQueryResultsReusesObjectStore" .) "true" }}
{{ include "logfire.objectStoreVolumes" . }}
{{- end }}
{{- with .Values.scheduledQueryResults.volumes }}
{{ toYaml . }}
{{- end }}
{{- end -}}
