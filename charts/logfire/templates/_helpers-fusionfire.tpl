{{/*
================================================================================
Fusionfire Helpers
================================================================================
Helpers specific to Fusionfire workloads and configuration.
*/}}

{{/*
No-preset installs without workload resources still need a synthetic resource
baseline for FusionFire auto-config, because no Kubernetes resources are
rendered for the workload.
*/}}
{{- define "logfire.ffUseNoPresetResourceFallback" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- if and (not (.Values.sizingPreset | default "")) (not (get $effectiveServiceValues "resources")) -}}
true
{{- end -}}
{{- end -}}

{{/*
Conservative resource hints for no-preset/no-resource installs. Keep these
independent from the sizing presets so preset resource changes do not silently
increase FusionFire auto-config on installs that render no Kubernetes resources.
*/}}
{{- define "logfire.ffNoPresetResourceFallback" -}}
{{- $fallbacks := dict
  "logfire-ff-cache-byte" (dict "cpu" "250m" "memory" "384Mi")
  "logfire-ff-compaction-worker" (dict "cpu" "1" "memory" "2Gi")
  "logfire-ff-crud-api" (dict "cpu" "100m" "memory" "192Mi")
  "logfire-ff-ingest" (dict "cpu" "250m" "memory" "512Mi")
  "logfire-ff-ingest-processor" (dict "cpu" "350m" "memory" "512Mi")
  "logfire-ff-maintenance-scheduler" (dict "cpu" "100m" "memory" "192Mi")
  "logfire-ff-maintenance-worker" (dict "cpu" "1" "memory" "512Mi")
  "logfire-ff-query-api" (dict "cpu" "500m" "memory" "768Mi")
  "logfire-ff-query-worker" (dict "cpu" "500m" "memory" "768Mi")
-}}
{{- get $fallbacks .serviceName | default (dict "cpu" "500m" "memory" "1Gi") | toJson -}}
{{- end -}}

{{- define "logfire.ffCompactionTiersValue" -}}
{{- $maintenanceWorker := dict "Values" .Values "serviceName" "logfire-ff-maintenance-worker" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" $maintenanceWorker | fromJson -}}
{{- if (get $effectiveServiceValues "compactionTiers") -}}
{{- get $effectiveServiceValues "compactionTiers" | toJson -}}
{{- end -}}
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
{{- $maintenanceServiceValues := include "logfire.effectiveServiceValues" (dict "Values" .Values "serviceName" "logfire-ff-maintenance-worker") | fromJson -}}
{{- $compactionServiceValues := include "logfire.effectiveServiceValues" (dict "Values" .Values "serviceName" "logfire-ff-compaction-worker") | fromJson -}}
{{- coalesce (get $compactionServiceValues "maxCompactionJobSizeBytes") (get $maintenanceServiceValues "maxCompactionJobSizeBytes") (include "logfire.ffMaxCompactionJobSizeBytesDefault" .) -}}
{{- end -}}

{{/*
Convert storage quantities used by scratchVolume.storage to whole GiB.
*/}}
{{- define "logfire.storageQuantityToGi" -}}
{{- $quantity := required "logfire.storageQuantityToGi: storage quantity is required" . | toString | trim -}}
{{- $unit := regexFind "[a-zA-Z]+$" $quantity | lower -}}
{{- $valueText := regexReplaceAll "[a-zA-Z]+$" $quantity "" | trim -}}
{{- $value := int $valueText -}}
{{- if or (eq $unit "gi") (eq $unit "g") (eq $unit "gb") -}}
{{- $value -}}
{{- else if or (eq $unit "ti") (eq $unit "t") (eq $unit "tb") -}}
{{- mul $value 1024 -}}
{{- else if or (eq $unit "mi") (eq $unit "m") (eq $unit "mb") -}}
{{- max 1 (div (add $value 1023) 1024) -}}
{{- else -}}
{{- fail (printf "unsupported scratchVolume.storage quantity %q; use Mi, Gi, or Ti" $quantity) -}}
{{- end -}}
{{- end -}}

{{/*
Resolve DataFusion disk-spill quota for background workers.
Explicit spillToDiskQuota wins. Otherwise derive half of the scratch PVC size,
leaving headroom for local scratch files, index merge scratch, and filesystem
overhead. No quota is derived for emptyDir scratch storage.
*/}}
{{- define "logfire.ffSpillToDiskQuota" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- with (get $effectiveServiceValues "spillToDiskQuota") -}}
{{- . -}}
{{- else -}}
{{- $scratchVolume := get $effectiveServiceValues "scratchVolume" | default dict -}}
{{- with (get $scratchVolume "storage") -}}
{{- $storageGi := int (include "logfire.storageQuantityToGi" .) -}}
{{- printf "%dGB" (max 1 (div $storageGi 2)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Expose effective Kubernetes resources to FusionFire so its auto-config formulas
use the same resources Kubernetes enforces. When no preset/resources are set,
the chart does not render Kubernetes resources, so use conservative synthetic
inputs instead.
*/}}
{{- define "logfire.ffResourceEnv" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $useFallback := include "logfire.ffUseNoPresetResourceFallback" . -}}
{{- $fallbackResources := include "logfire.ffNoPresetResourceFallback" . | fromJson -}}
{{- $cpu := ternary (get $fallbackResources "cpu") (get $effectiveResources "cpuLimit") (not (empty $useFallback)) -}}
{{- $memory := ternary (get $fallbackResources "memory") (get $effectiveResources "memoryLimit") (not (empty $useFallback)) -}}
{{- $cpuMilli := int (include "logfire.cpuMilli" $cpu) -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
- name: FF_RESOURCE_CPU_CORES
  value: {{ printf "%.3f" (divf (float64 $cpuMilli) 1000.0) | quote }}
- name: FF_RESOURCE_MEMORY_BYTES
  value: {{ mul $memoryMi 1048576 | quote }}
{{- end -}}

{{- define "logfire.ffIoThreads" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- get $effectiveServiceValues "ioThreads" | default "auto" -}}
{{- end -}}

{{- define "logfire.ffDatafusionThreads" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- get $effectiveServiceValues "datafusionThreads" | default "auto" -}}
{{- end -}}

{{/*
Resolve query parallelism from explicit service values, falling back to FusionFire auto-config.
*/}}
{{- define "logfire.ffQueryParallelism" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- get $effectiveServiceValues "queryParallelism" | default "auto" -}}
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
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $defaults := include "logfire.ffIngestDirectFileSettingsDefault" . | fromJson -}}
{{- $bufferMaxBytes := get $effectiveServiceValues "directFileBufferMaxBytes" | default (get $defaults "bufferMaxBytes") -}}
{{- $submitConcurrency := get $effectiveServiceValues "directFileSubmitConcurrency" | default (get $defaults "submitConcurrency") -}}
{{- dict "bufferMaxBytes" $bufferMaxBytes "submitConcurrency" $submitConcurrency | toJson -}}
{{- end -}}

{{/*
Common execution env for background maintenance/compaction workers.
*/}}
{{- define "logfire.ffBackgroundWorkerExecutionEnv" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $datafusionMemory := get $effectiveServiceValues "datafusionMemory" | default "auto" -}}
{{- $recordBatchMemory := get $effectiveServiceValues "maintenanceRecordBatchMemory" | default $datafusionMemory -}}
{{- $jobParallelism := get $effectiveServiceValues "jobParallelism" | default "auto" -}}
{{- $cpuConcurrency := get $effectiveServiceValues "cpuConcurrency" | default "auto" -}}
{{- $ioThreads := include "logfire.ffIoThreads" . -}}
{{- $datafusionThreads := include "logfire.ffDatafusionThreads" . -}}
{{- $spillToDiskQuota := include "logfire.ffSpillToDiskQuota" . -}}
{{- include "logfire.ffResourceEnv" . }}
- name: FF_IO_THREADS
  value: {{ $ioThreads | quote }}
- name: FF_DATAFUSION_THREADS
  value: {{ $datafusionThreads | quote }}
- name: FF_DATAFUSION_MEMORY_LIMIT
  value: {{ $datafusionMemory | quote }}
- name: FF_MAINTENANCE_MAX_RECORD_BATCH_MEMORY
  value: {{ $recordBatchMemory | quote }}
- name: FF_ENABLE_SPILL_TO_DISK
  value: "true"
- name: FF_TEMP_DIR
  value: /scratch/fusionfire
{{- with $spillToDiskQuota }}
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
