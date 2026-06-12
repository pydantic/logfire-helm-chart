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
Resolve FF execution values. No-preset installs borrow tiny's FF-specific
baseline when a workload has no resources, without rendering tiny's resources,
autoscaling, PDBs, or scheduling rules.
*/}}
{{- define "logfire.ffDerivedServiceValues" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $derived := deepCopy $effectiveServiceValues -}}
{{- if and (not (.Values.sizingPreset | default "")) (not (get $effectiveServiceValues "resources")) -}}
  {{- $tinyPreset := get (.Values.sizingPresets | default dict) "tiny" | default dict -}}
  {{- $tinyServiceValues := get $tinyPreset .serviceName | default dict -}}
  {{- range $key := list "queryParallelism" "datafusionMemory" "maintenanceRecordBatchMemory" "spillToDiskQuota" "jobParallelism" "cpuConcurrency" "parquetSpoolThresholdBytes" "maxCompactionJobSizeBytes" "directFileBufferMaxBytes" "directFileSubmitConcurrency" -}}
    {{- if and (not (hasKey $derived $key)) (hasKey $tinyServiceValues $key) -}}
      {{- $_ := set $derived $key (deepCopy (get $tinyServiceValues $key)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $derived | toJson -}}
{{- end -}}

{{- define "logfire.ffMaxCompactionJobSizeBytesDefault" -}}
{{- $compactionWorker := dict "Values" .Values "serviceName" "logfire-ff-compaction-worker" -}}
{{- $effectiveResources := include "logfire.effectiveResources" $compactionWorker | fromJson -}}
{{- $memory := get $effectiveResources "memoryRequest" -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
{{- $jobSizeMi := min 512 (max 32 (div $memoryMi 16)) -}}
{{- printf "%dMB" $jobSizeMi -}}
{{- end -}}

{{- define "logfire.ffMaxCompactionJobSizeBytes" -}}
{{- $maintenanceServiceValues := include "logfire.ffDerivedServiceValues" (dict "Values" .Values "serviceName" "logfire-ff-maintenance-worker") | fromJson -}}
{{- $compactionServiceValues := include "logfire.ffDerivedServiceValues" (dict "Values" .Values "serviceName" "logfire-ff-compaction-worker") | fromJson -}}
{{- coalesce (get $compactionServiceValues "maxCompactionJobSizeBytes") (get $maintenanceServiceValues "maxCompactionJobSizeBytes") (include "logfire.ffMaxCompactionJobSizeBytesDefault" .) -}}
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
{{- $effectiveServiceValues := include "logfire.ffDerivedServiceValues" . | fromJson -}}
{{- $defaultQueryParallelism := include "logfire.ffQueryParallelismDefault" . -}}
{{- get $effectiveServiceValues "queryParallelism" | default $defaultQueryParallelism -}}
{{- end -}}

{{/*
Default ingest direct-file buffering.
Sizes batch files from the pod memory request, then caps replay/submit
concurrency from both memory and CPU so sub-core ingest pods do not overwhelm
the downstream ingest-processor during disk replay.
*/}}
{{- define "logfire.ffIngestDirectFileSettingsDefault" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $cpu := get $effectiveResources "cpuRequest" -}}
{{- $memory := get $effectiveResources "memoryRequest" -}}
{{- $cpuMilli := int (include "logfire.cpuMilli" $cpu) -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
{{- $bufferMi := min 8 (max 1 (div $memoryMi 256)) -}}
{{- $memoryConcurrency := max 4 (div $memoryMi 64) -}}
{{- $cpuConcurrency := max 4 (div (add $cpuMilli 31) 32) -}}
{{- $submitConcurrency := min 128 (max 1 (min $cpuConcurrency $memoryConcurrency)) -}}
{{- dict "bufferMaxBytes" (printf "%dMB" $bufferMi) "submitConcurrency" $submitConcurrency | toJson -}}
{{- end -}}

{{/*
Resolve ingest direct-file buffering from explicit service values, falling back
to computed defaults.
*/}}
{{- define "logfire.ffIngestDirectFileSettings" -}}
{{- $effectiveServiceValues := include "logfire.ffDerivedServiceValues" . | fromJson -}}
{{- $defaults := include "logfire.ffIngestDirectFileSettingsDefault" . | fromJson -}}
{{- $bufferMaxBytes := get $effectiveServiceValues "directFileBufferMaxBytes" | default (get $defaults "bufferMaxBytes") -}}
{{- $submitConcurrency := get $effectiveServiceValues "directFileSubmitConcurrency" | default (get $defaults "submitConcurrency") -}}
{{- dict "bufferMaxBytes" $bufferMaxBytes "submitConcurrency" $submitConcurrency | toJson -}}
{{- end -}}

{{/*
Resolve query-api parallelism. When dedicated query-workers are enabled,
default from query-worker sizing because query-api schedules work onto workers.
*/}}
{{- define "logfire.ffQueryApiParallelism" -}}
{{- $effectiveServiceValues := include "logfire.ffDerivedServiceValues" . | fromJson -}}
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
{{- $datafusionMemoryMi := max 256 (div $memoryMi 2) -}}
{{- printf "%dMB" $datafusionMemoryMi -}}
{{- end -}}

{{/*
Default DataFusion memory cap for background maintenance/compaction workers.
Larger workers use the pod memory limit so burstable workers can use their
configured headroom. Sub-core workers use a smaller fraction to leave room for
the process runtime, object store clients, decompression, and parquet writers.
*/}}
{{- define "logfire.ffBackgroundDatafusionMemoryDefault" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $cpu := get $effectiveResources "cpuRequest" -}}
{{- $memory := get $effectiveResources "memoryLimit" -}}
{{- $cpuMilli := int (include "logfire.cpuMilli" $cpu) -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
{{- $datafusionMemoryMi := 0 -}}
{{- if lt $cpuMilli 1000 -}}
  {{- if le $memoryMi 1024 -}}
    {{- $datafusionMemoryMi = max 128 (div $memoryMi 2) -}}
  {{- else -}}
    {{- $datafusionMemoryMi = max 512 (div $memoryMi 8) -}}
  {{- end -}}
{{- else -}}
{{- $datafusionMemoryMi = max 512 (div (mul $memoryMi 3) 8) -}}
{{- end -}}
{{- printf "%dMB" $datafusionMemoryMi -}}
{{- end -}}

{{/*
Default DataFusion memory cap for the maintenance scheduler.
The scheduler scans metadata rather than running compaction jobs, so it follows
the pod memory request directly with a cap matching the previous chart default.
*/}}
{{- define "logfire.ffMaintenanceSchedulerDatafusionMemoryDefault" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $memory := get $effectiveResources "memoryRequest" -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
{{- $datafusionMemoryMi := min 512 (max 128 $memoryMi) -}}
{{- printf "%dMB" $datafusionMemoryMi -}}
{{- end -}}

{{/*
Default background maintenance/compaction job concurrency.
Sub-core workers stay conservative. Larger workers get enough queue parallelism
to keep CPU-heavy phases fed while CPU concurrency still gates active compute.
*/}}
{{- define "logfire.ffBackgroundJobParallelismDefault" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $threadSettings := include "logfire.ffThreadSettings" . | fromJson -}}
{{- $cpu := get $effectiveResources "cpuRequest" -}}
{{- $cpuMilli := int (include "logfire.cpuMilli" $cpu) -}}
{{- $cpuCores := int (get $threadSettings "cpuCores") -}}
{{- if lt $cpuMilli 1000 -}}
1
{{- else -}}
{{- min 10 (max 4 (mul $cpuCores 4)) -}}
{{- end -}}
{{- end -}}

{{/*
Resolve background maintenance/compaction job concurrency from explicit service values,
falling back to the computed default.
*/}}
{{- define "logfire.ffBackgroundJobParallelism" -}}
{{- $effectiveServiceValues := include "logfire.ffDerivedServiceValues" . | fromJson -}}
{{- $defaultJobParallelism := include "logfire.ffBackgroundJobParallelismDefault" . -}}
{{- get $effectiveServiceValues "jobParallelism" | default $defaultJobParallelism -}}
{{- end -}}

{{/*
Default number of CPU-heavy maintenance phases to run concurrently.
Uses roughly 75% of the effective CPU request, rounded to cores, with a
minimum of one so sub-core workers can still make progress.
*/}}
{{- define "logfire.ffBackgroundCpuConcurrencyDefault" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $cpu := get $effectiveResources "cpuRequest" -}}
{{- $cpuMilli := int (include "logfire.cpuMilli" $cpu) -}}
{{- max 1 (div (add (mul $cpuMilli 3) 2000) 4000) -}}
{{- end -}}

{{/*
Resolve CPU-heavy maintenance concurrency from explicit service values, falling
back to the computed default.
*/}}
{{- define "logfire.ffBackgroundCpuConcurrency" -}}
{{- $effectiveServiceValues := include "logfire.ffDerivedServiceValues" . | fromJson -}}
{{- $defaultCpuConcurrency := include "logfire.ffBackgroundCpuConcurrencyDefault" . -}}
{{- get $effectiveServiceValues "cpuConcurrency" | default $defaultCpuConcurrency -}}
{{- end -}}

{{/*
Common execution env for background maintenance/compaction workers.
*/}}
{{- define "logfire.ffBackgroundWorkerExecutionEnv" -}}
{{- $effectiveServiceValues := include "logfire.ffDerivedServiceValues" . | fromJson -}}
{{- $threadSettings := include "logfire.ffThreadSettings" . | fromJson -}}
{{- $defaultDatafusionMemory := include "logfire.ffBackgroundDatafusionMemoryDefault" . -}}
{{- $datafusionMemory := get $effectiveServiceValues "datafusionMemory" | default $defaultDatafusionMemory -}}
{{- $recordBatchMemory := get $effectiveServiceValues "maintenanceRecordBatchMemory" | default $datafusionMemory -}}
{{- $jobParallelism := include "logfire.ffBackgroundJobParallelism" . -}}
{{- $cpuConcurrency := include "logfire.ffBackgroundCpuConcurrency" . -}}
{{- $cpuCores := int (get $threadSettings "cpuCores") -}}
{{- $dataFusionThreads := int (get $threadSettings "dataFusionThreads") -}}
- name: FF_IO_THREADS
  value: {{ $cpuCores | quote }}
- name: FF_DATAFUSION_THREADS
  value: {{ $dataFusionThreads | quote }}
- name: FF_DATAFUSION_MEMORY_LIMIT
  value: {{ $datafusionMemory | quote }}
- name: FF_MAINTENANCE_MAX_RECORD_BATCH_MEMORY
  value: {{ $recordBatchMemory | quote }}
- name: FF_ENABLE_SPILL_TO_DISK
  value: "true"
- name: FF_TEMP_DIR
  value: /scratch/fusionfire
{{- with (get $effectiveServiceValues "spillToDiskQuota") }}
- name: FF_SPILL_TO_DISK_QUOTA
  value: {{ . | quote }}
{{- end }}
- name: FF_MAINTENANCE_CPU_CONCURRENCY
  value: {{ $cpuConcurrency | quote }}
- name: FF_PARQUET_SPOOL_THRESHOLD_BYTES
  value: {{ (get $effectiveServiceValues "parquetSpoolThresholdBytes" | default "1MB" | quote) }}
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

{{/*
Container command that sweeps stale FF_TEMP_DIR contents before starting fusionfire.

The scratch volume (ephemeral PVC or emptyDir) is fresh when the pod is created but
survives *container* restarts (e.g. OOM kills), and a SIGKILL skips tempfile's Drop
cleanup - so a restarted container inherits orphaned scratch data that stays until
the pod is deleted. Init containers only run at pod creation, so the sweep must run
in the container command itself; keeping it in the chart (not the image entrypoint)
means running the binary outside Kubernetes never deletes anything.

The swept path comes from FF_TEMP_DIR at runtime so the script and the binary always
agree on the location; workloads without FF_TEMP_DIR (e.g. the byte cache, whose
/scratch mount holds reusable cache data) skip the sweep. `find` rather than a shell
glob because tempfile names everything `.tmp*` and sh globs skip dotfiles.

Emits the `command:` list entries; the fusionfire subcommand and flags stay in `args:`.
*/}}
{{- define "logfire.ffCommandWithTempDirCleanup" -}}
- sh
- -c
- 'if [ -n "$FF_TEMP_DIR" ]; then find "$FF_TEMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true; fi; exec fusionfire "$@"'
- fusionfire
{{- end -}}
