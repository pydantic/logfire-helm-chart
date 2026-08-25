{{/*
================================================================================
Fusionfire Helpers
================================================================================
Helpers specific to Fusionfire workloads and configuration.
*/}}

{{/*
Configure query workloads to discover byte-cache pods directly. Keep these
defaults before service-specific env so operators can explicitly override them.
*/}}
{{- define "logfire.ffByteCacheClientRoutingEnv" -}}
{{- $routing := get (get .Values "logfire-ff-cache-byte" | default dict) "clientSideRouting" | default dict -}}
{{- if get $routing "enabled" }}
- name: FF_BYTE_CACHE_K8S_SERVICE
  value: logfire-ff-cache-byte-internal
- name: FF_BYTE_CACHE_K8S_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: FF_BYTE_CACHE_K8S_PORT_NAME
  value: {{ ternary "https" "http" .Values.inClusterTls.enabled }}
{{- if get $routing "zoneAware" }}
- name: FF_NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
{{- end }}
{{- end }}
{{- end -}}

{{/*
Give Fusionfire processes enough time to initialize on constrained nodes before
liveness checks can restart them. The health endpoint is checked immediately so
fast starts are not delayed by a fixed initial delay.
*/}}
{{- define "logfire.ffStartupProbe" -}}
httpGet:
  path: /health
  port: {{ .port }}
periodSeconds: 10
timeoutSeconds: 5
failureThreshold: 30
{{- end -}}

{{/*
Readiness can be checked immediately because failures do not restart the
container. Use /ready so traffic only reaches a fully initialized process.
*/}}
{{- define "logfire.ffReadinessProbe" -}}
httpGet:
  path: /ready
  port: {{ .port }}
periodSeconds: 5
timeoutSeconds: 5
failureThreshold: 5
{{- end -}}

{{- define "logfire.ffMaxCompactionJobSizeBytes" -}}
{{- $maintenanceServiceValues := include "logfire.effectiveServiceValues" (dict "Values" .Values "serviceName" "logfire-ff-maintenance-worker") | fromJson -}}
{{- $compactionServiceValues := include "logfire.effectiveServiceValues" (dict "Values" .Values "serviceName" "logfire-ff-compaction-worker") | fromJson -}}
{{- $effectiveResources := include "logfire.effectiveResources" (dict "Values" .Values "serviceName" "logfire-ff-compaction-worker") | fromJson -}}
{{- $memoryMi := int (include "logfire.memoryToMi" (get $effectiveResources "memoryRequest")) -}}
{{- $default := printf "%dMB" (min 512 (max 32 (div $memoryMi 16))) -}}
{{- coalesce (get $compactionServiceValues "maxCompactionJobSizeBytes") (get $maintenanceServiceValues "maxCompactionJobSizeBytes") $default -}}
{{- end -}}

{{/*
Convert storage quantities used by scratchVolume.storage to whole MiB via the
shared Kubernetes quantity parser (case-sensitive: decimal suffixes like G are
powers of 1000, binary suffixes like Gi are powers of 1024), rounding down so
derived sizes never exceed the volume. Quantities below 1Mi fail rather than
rounding to zero.
*/}}
{{- define "logfire.storageQuantityToMi" -}}
{{- $quantity := required "logfire.storageQuantityToMi: storage quantity is required" . | toString | trim -}}
{{- $miInt := int (include "logfire.memoryToMi" $quantity) -}}
{{- if lt $miInt 1 -}}
{{- fail (printf "scratchVolume.storage %q is below the 1Mi minimum" $quantity) -}}
{{- end -}}
{{- $miInt -}}
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
{{- $storageMi := int (include "logfire.storageQuantityToMi" .) -}}
{{- printf "%dMB" (max 1 (div $storageMi 2)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Byte-cache disk capacity. Explicit cacheDiskCapacity wins; otherwise 80% of
the scratch volume size. Sized from the declared volume, not the filesystem:
network filesystems can report effectively unlimited free space, and
free-space sizing then OOMs the pod at startup. Not derived for emptyDir.
*/}}
{{- define "logfire.ffCacheDiskCapacity" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- with (get $effectiveServiceValues "cacheDiskCapacity") -}}
{{- . -}}
{{- else -}}
{{- $scratchVolume := get $effectiveServiceValues "scratchVolume" | default dict -}}
{{- with (get $scratchVolume "storage") -}}
{{- $storageMi := int (include "logfire.storageQuantityToMi" .) -}}
{{- printf "%dMB" (max 1 (div (mul $storageMi 4) 5)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Expose effective Kubernetes resources to FusionFire so its auto-config formulas
use the same resources Kubernetes enforces. Effective resources fall back to
the tiny preset for internal calculations when no preset/resources are set,
without rendering Kubernetes resources.
*/}}
{{- define "logfire.ffResourceEnv" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $cpu := get $effectiveResources "cpuLimit" -}}
{{- $memory := get $effectiveResources "memoryLimit" -}}
{{- $cpuMilli := int (include "logfire.cpuMilli" $cpu) -}}
{{- $memoryMi := int (include "logfire.memoryToMi" $memory) -}}
- name: FF_RESOURCE_CPU_CORES
  value: {{ printf "%.3f" (divf (float64 $cpuMilli) 1000.0) | quote }}
- name: FF_RESOURCE_MEMORY_BYTES
  value: {{ mul $memoryMi 1048576 | quote }}
{{- end -}}

{{/*
Resolve worker query capacity consistently for the combined query-api deployment
and optional remote query workers. An explicit query-api override wins.
Otherwise, derive capacity from the execution worker's effective CPU limit (or
request when no limit is configured), rounded up to whole cores.
*/}}
{{- define "logfire.ffMaxCostPerWorker" -}}
{{- $queryApiValues := include "logfire.effectiveServiceValues" (dict "Values" .Values "serviceName" "logfire-ff-query-api") | fromJson -}}
{{- $queryWorkerEnabled := get (get .Values "logfire-ff-query-worker" | default dict) "enabled" | default false -}}
{{- $executionServiceName := ternary "logfire-ff-query-worker" "logfire-ff-query-api" $queryWorkerEnabled -}}
{{- if hasKey $queryApiValues "maxQueryCostPerPod" -}}
  {{- $override := toString (get $queryApiValues "maxQueryCostPerPod") -}}
  {{- if not (regexMatch "^[1-9][0-9]*$" $override) -}}
    {{- fail "logfire-ff-query-api.maxQueryCostPerPod must be a positive integer" -}}
  {{- end -}}
  {{- $override -}}
{{- else -}}
  {{- $effectiveResources := include "logfire.effectiveResources" (dict "Values" .Values "serviceName" $executionServiceName) | fromJson -}}
  {{- $cpuMilli := int (include "logfire.cpuMilli" (get $effectiveResources "cpuLimit")) -}}
  {{- max 1 (div (add $cpuMilli 999) 1000) -}}
{{- end -}}
{{- end -}}

{{/*
Render the FusionFire query environment for an intake, worker, or combined role.
*/}}
{{- define "logfire.ffQueryExecutionEnv" -}}
{{- $serviceName := required "logfire.ffQueryExecutionEnv: need .serviceName" .serviceName -}}
{{- $role := required "logfire.ffQueryExecutionEnv: need .role" .role -}}
{{- if not (has $role (list "combined" "intake" "worker")) -}}
  {{- fail (printf "logfire.ffQueryExecutionEnv: unknown role %q" $role) -}}
{{- end -}}
{{- $executesQueries := ne $role "intake" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $queryParallelism := get $effectiveServiceValues "queryParallelism" | default "auto" -}}
{{- $maxCostPerWorker := include "logfire.ffMaxCostPerWorker" (dict "Values" .Values) -}}
- name: FF_ENABLE_SPILL_TO_DISK
  value: "true"
- name: FF_TEMP_DIR
  value: /scratch/fusionfire
- name: FF_QUERY_PARALLELISM
  value: {{ $queryParallelism | quote }}
- name: FF_MAX_COST_PER_WORKER
  value: {{ $maxCostPerWorker | quote }}
{{ include "logfire.ffResourceEnv" . }}
{{- if eq $role "worker" }}
- name: FF_PG_POOL_MAX_CONNECTIONS
  value: "4"
{{- end }}
{{- if $executesQueries }}
- name: FF_IO_THREADS
  value: {{ get $effectiveServiceValues "ioThreads" | default "auto" | quote }}
- name: FF_DATAFUSION_THREADS
  value: {{ get $effectiveServiceValues "datafusionThreads" | default "auto" | quote }}
- name: FF_DATAFUSION_MEMORY_LIMIT
  value: {{ get $effectiveServiceValues "datafusionMemory" | default "auto" | quote }}
{{- if and (eq $role "combined") (hasKey $effectiveServiceValues "datafusionTargetPartitions") }}
- name: FF_DATAFUSION_TARGET_PARTITIONS
  value: {{ get $effectiveServiceValues "datafusionTargetPartitions" | quote }}
{{- end }}
{{- if and (eq $role "combined") (hasKey $effectiveServiceValues "datafusionBatchSize") }}
- name: FF_DATAFUSION_BATCH_SIZE
  value: {{ get $effectiveServiceValues "datafusionBatchSize" | quote }}
{{- end }}
{{- if eq $role "worker" }}
- name: FF_DATAFUSION_THREAD_STACK_SIZE
  value: "8MB"
{{- end }}
- name: FF_IO_THREAD_STACK_SIZE
  value: "8MB"
{{- end }}
{{- if ne $role "worker" }}
- name: FF_DATAFUSION_THREAD_STACK_SIZE
  value: "8MB"
{{- end }}
{{- end -}}

{{/*
Resolve ingest direct-file buffering from explicit values or pod resources.
*/}}
{{- define "logfire.ffIngestDirectFileSettings" -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $cpuMilli := int (include "logfire.cpuMilli" (get $effectiveResources "cpuRequest")) -}}
{{- $memoryMi := int (include "logfire.memoryToMi" (get $effectiveResources "memoryRequest")) -}}
{{- $defaultBuffer := printf "%dMB" (min 8 (max 1 (div $memoryMi 256))) -}}
{{- $memoryConcurrency := max 4 (div $memoryMi 64) -}}
{{- $cpuConcurrency := max 4 (div (add $cpuMilli 31) 32) -}}
{{- $defaultConcurrency := min 128 (max 1 (min $cpuConcurrency $memoryConcurrency)) -}}
{{- $bufferMaxBytes := get $effectiveServiceValues "directFileBufferMaxBytes" | default $defaultBuffer -}}
{{- $submitConcurrency := get $effectiveServiceValues "directFileSubmitConcurrency" | default $defaultConcurrency -}}
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
{{- $ioThreads := get $effectiveServiceValues "ioThreads" | default "auto" -}}
{{- $datafusionThreads := get $effectiveServiceValues "datafusionThreads" | default "auto" -}}
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
