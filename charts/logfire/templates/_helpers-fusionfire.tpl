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
Default query parallelism follows the computed FF IO thread count.
*/}}
{{- define "logfire.ffQueryParallelismDefault" -}}
{{- $threadSettings := include "logfire.ffThreadSettings" . | fromJson -}}
{{- $cpuCores := int (get $threadSettings "cpuCores") -}}
{{- mul $cpuCores 2 -}}
{{- end -}}

{{/*
Resolve query parallelism from explicit service values, falling back to the computed default.
*/}}
{{- define "logfire.ffQueryParallelism" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $defaultQueryParallelism := include "logfire.ffQueryParallelismDefault" . -}}
{{- get $effectiveServiceValues "queryParallelism" | default $defaultQueryParallelism -}}
{{- end -}}

{{/*
Resolve query-api parallelism. When dedicated query-workers are enabled,
default from query-worker sizing because query-api schedules work onto workers.
*/}}
{{- define "logfire.ffQueryApiParallelism" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $queryParallelismDefaultServiceName := .serviceName -}}
{{- if (get (get .Values "logfire-ff-query-worker" | default  dict) "enabled") -}}
{{- $queryParallelismDefaultServiceName = "logfire-ff-query-worker" -}}
{{- end -}}
{{- $queryParallelismDefault := include "logfire.ffQueryParallelismDefault" (dict "Values" .Values "serviceName" $queryParallelismDefaultServiceName) -}}
{{- get $effectiveServiceValues "queryParallelism" | default $queryParallelismDefault -}}
{{- end -}}

{{/*
Default DataFusion memory limit for query execution.
Uses half the pod memory request, leaving headroom for the HTTP process/runtime.
*/}}
{{- define "logfire.ffQueryDatafusionMemoryDefault" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $memory := get $effectiveResources "memoryRequest" -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
{{- $datafusionMemoryMi := max 512 (div $memoryMi 2) -}}
{{- printf "%dMB" $datafusionMemoryMi -}}
{{- end -}}

{{/*
Default DataFusion memory cap for background maintenance/compaction workers.
Uses the pod memory limit so burstable workers can use their configured headroom.
*/}}
{{- define "logfire.ffBackgroundDatafusionMemoryDefault" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $memory := get $effectiveResources "memoryLimit" -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
{{- $datafusionMemoryMi := max 512 (div (mul $memoryMi 3) 8) -}}
{{- printf "%dMB" $datafusionMemoryMi -}}
{{- end -}}

{{/*
Default background maintenance/compaction job concurrency.
The runner gates CPU-heavy work to roughly half this value, so cpu+1 keeps
small pods conservative while allowing larger workers to make progress.
*/}}
{{- define "logfire.ffBackgroundJobParallelismDefault" -}}
{{- $threadSettings := include "logfire.ffThreadSettings" . | fromJson -}}
{{- $cpuCores := int (get $threadSettings "cpuCores") -}}
{{- min 10 (max 3 (add $cpuCores 1)) -}}
{{- end -}}

{{/*
Resolve background maintenance/compaction job concurrency from explicit service values,
falling back to the computed default.
*/}}
{{- define "logfire.ffBackgroundJobParallelism" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $defaultJobParallelism := include "logfire.ffBackgroundJobParallelismDefault" . -}}
{{- get $effectiveServiceValues "jobParallelism" | default $defaultJobParallelism -}}
{{- end -}}

{{/*
Common execution env for background maintenance/compaction workers.
*/}}
{{- define "logfire.ffBackgroundWorkerExecutionEnv" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $threadSettings := include "logfire.ffThreadSettings" . | fromJson -}}
{{- $defaultDatafusionMemory := include "logfire.ffBackgroundDatafusionMemoryDefault" . -}}
{{- $jobParallelism := include "logfire.ffBackgroundJobParallelism" . -}}
{{- $cpuCores := int (get $threadSettings "cpuCores") -}}
{{- $dataFusionThreads := int (get $threadSettings "dataFusionThreads") -}}
- name: FF_IO_THREADS
  value: {{ $cpuCores | quote }}
- name: FF_DATAFUSION_THREADS
  value: {{ $dataFusionThreads | quote }}
- name: FF_DATAFUSION_MEMORY_LIMIT
  value: {{ (get $effectiveServiceValues "datafusionMemory" | default $defaultDatafusionMemory | quote) }}
- name: FF_ENABLE_SPILL_TO_DISK
  value: "true"
- name: FF_TEMP_DIR
  value: /scratch/fusionfire
{{- with (get $effectiveServiceValues "spillToDiskQuota") }}
- name: FF_SPILL_TO_DISK_QUOTA
  value: {{ . | quote }}
{{- end }}
- name: FF_COMPACTION_DOWNLOAD_PARALLELISM
  value: {{ (get $effectiveServiceValues "downloadParallelism" | default "10" | quote) }}
- name: FF_COMPACTION_JOB_PARALLELISM
  value: {{ $jobParallelism | quote }}
{{- end -}}

{{- define "logfire.ffMigrations.name" -}}
{{- if .Values.dev.deployPostgres -}}
"logfire-ff-migrations-{{ .Release.Revision }}"
{{- else -}}
"logfire-ff-migrations"
{{- end -}}
{{- end -}}
