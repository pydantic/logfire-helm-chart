{{/*
================================================================================
Fusionfire Helpers
================================================================================
Helpers specific to Fusionfire workloads and configuration.
*/}}

{{- define "logfire.ffCompactionTiersValue" -}}
{{- if (get (get .Values "logfire-ff-maintenance-worker" | default  dict) "compactionTiers") -}}
{{- with (get (get .Values "logfire-ff-maintenance-worker" | default  dict) "compactionTiers") -}}
{{ . | toJson }}
{{- end -}}
{{- else -}}
[{"count_threshold":10,"size_threshold_bytes":"1KB"},{"count_threshold":10,"size_threshold_bytes":"10KB"},{"count_threshold":10,"size_threshold_bytes":"100KB"},{"count_threshold":10,"size_threshold_bytes":"1MB"},{"count_threshold":10,"size_threshold_bytes":"10MB"},{"count_threshold":10,"size_threshold_bytes":"100MB"}]
{{- end -}}
{{- end -}}

{{/*
Derive FF service CPU core count and DataFusion thread count from the effective CPU request.
*/}}
{{- define "logfire.ffThreadSettings" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $cpu := get $effectiveResources "cpuRequest" -}}
{{- $cpuCores := int (include "logfire.cpuCores" $cpu) -}}
{{- $dataFusionThreads := max 1 (sub $cpuCores 1) -}}
{{- dict "cpuCores" $cpuCores "dataFusionThreads" $dataFusionThreads | toJson -}}
{{- end -}}

{{/*
Conservative default DataFusion memory cap for query-worker execution.
Leaves headroom for the HTTP process/runtime, scales up with queryParallelism,
and caps at 3Gi unless explicitly overridden.
*/}}
{{- define "logfire.ffQueryDatafusionMemoryDefault" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $memory := get $effectiveResources "memoryRequest" -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
{{- $queryParallelism := int (get $effectiveServiceValues "queryParallelism" | default "4") -}}
{{- $parallelismFloorMi := mul $queryParallelism 256 -}}
{{- $baselineMi := max 512 (max (div $memoryMi 2) $parallelismFloorMi) -}}
{{- $headroomMi := max 512 (div (mul $memoryMi 3) 4) -}}
{{- $datafusionMemoryMi := min 3072 (min $baselineMi $headroomMi) -}}
{{- printf "%dMB" $datafusionMemoryMi -}}
{{- end -}}

{{- define "logfire.ffMigrations.name" -}}
{{- if .Values.dev.deployPostgres -}}
"logfire-ff-migrations-{{ .Release.Revision }}"
{{- else -}}
"logfire-ff-migrations"
{{- end -}}
{{- end -}}
