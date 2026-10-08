{{- define "logfire.scheduledQueryResultsUri" -}}
{{- tpl .Values.scheduledQueryResults.uri . | trim | default "file:///var/lib/logfire/scheduled-query-results" -}}
{{- end -}}

{{- define "logfire.scheduledQueryResultsClaim" -}}
{{- .Values.scheduledQueryResults.persistence.existingClaim | default (printf "%s-scheduled-query-results" .Release.Name) -}}
{{- end -}}

{{- define "logfire.scheduledQueryResultsPodSecurityContext" -}}
{{- $defaults := dict -}}
{{- if not (tpl .Values.scheduledQueryResults.uri . | trim) -}}
{{- $defaults = dict "fsGroup" 1000 -}}
{{- end -}}
{{- mergeOverwrite $defaults (deepCopy .Values.podSecurityContext) | toJson -}}
{{- end -}}

{{- define "logfire.scheduledQueryResultsEnv" -}}
- name: SCHEDULED_QUERY_RESULTS_OBJECT_STORE_URI
  value: {{ include "logfire.scheduledQueryResultsUri" . | quote }}
{{- range $key, $value := .Values.scheduledQueryResults.env }}
- name: {{ $key }}
{{ include "logfire.envValue" (dict "value" $value "quote" (not (kindIs "map" $value)) "allowValueKey" true) | indent 2 }}
{{- end }}
{{- end -}}

{{- define "logfire.scheduledQueryResultsVolumeMounts" -}}
{{- if not (tpl .Values.scheduledQueryResults.uri . | trim) }}
- name: scheduled-query-results
  mountPath: /var/lib/logfire/scheduled-query-results
{{- end }}
{{- with .Values.scheduledQueryResults.volumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "logfire.scheduledQueryResultsVolumes" -}}
{{- if not (tpl .Values.scheduledQueryResults.uri . | trim) }}
- name: scheduled-query-results
  persistentVolumeClaim:
    claimName: {{ include "logfire.scheduledQueryResultsClaim" . }}
{{- end }}
{{- with .Values.scheduledQueryResults.volumes }}
{{ toYaml . }}
{{- end }}
{{- end -}}
