{{/*
Merge the Fusionfire volume-ownership defaults under the chart-wide and per-service
pod security contexts. The uid 1000 Fusionfire and bcache images need `fsGroup: 1000`
to write chart-managed scratch and ingest volumes.

`fsGroupChangePolicy: OnRootMismatch` skips the recursive ownership pass when the
volume root already carries the fsGroup. That skip is safe for scratch volumes,
which are fresh when the pod starts. It is not safe for the retained ingest spool.
A release that ran as root leaves bucket directories owned by root with mode 0755
below a volume root that already matches `fsGroup: 1000`. The root check then skips
the repair, and every disk write fails with EACCES. `logfire-ff-ingest` therefore
defaults to `Always`, which walks the spool at each pod start and adds group write
to those directories. The pass changes ownership and permissions only. It never
touches file contents.

Later layers win, and the defaults apply even when an upgrade with `--reuse-values`
carries no `podSecurityContext` key. Returns JSON so callers can parse it with
`fromJson`, matching `logfire.effectiveServiceValues`.
*/}}
{{- define "logfire.fusionfirePodSecurityContext" -}}
{{- $policy := eq .serviceName "logfire-ff-ingest" | ternary "Always" "OnRootMismatch" -}}
{{- mergeOverwrite (dict "fsGroup" 1000 "fsGroupChangePolicy" $policy)
    (include "logfire.podSecurityContext" .ctx | fromJson)
    (get (get .ctx.Values .serviceName | default dict) "podSecurityContext" | default dict
    | deepCopy)
    | toJson -}}
{{- end -}}

{{/*
Resolved topology settings for the bcache readers, shared by the reader env and the RBAC that
the zone lookup needs.

`FF_ZONE` resolves the pod's zone directly, so it needs no node read. `FF_NODE_NAME` makes the
reader read `topology.kubernetes.io/zone` off its own node at startup, which needs a read-only
`nodes` `get` ClusterRole. With neither, the reader runs zoneless and routes on one global ring,
which is right for a single-zone cluster.
*/}}
{{- define "logfire.bcacheTopology" -}}
{{- $topology := get (get .Values "logfire-ff-bcache" | default dict) "topology" | default dict -}}
{{- $zone := get $topology "zone" | default "" -}}
{{- $zoneAware := get $topology "zoneAware" | default false -}}
{{- dict "zone" $zone "zoneAware" $zoneAware "needsNodeRead" (and $zoneAware (not $zone))
    | toJson -}}
{{- end -}}

{{/*
Point a Fusionfire reader at bcache. The reader lists the headless
service's EndpointSlices, so each request reaches a pod IP. Keep these defaults
before service-specific env so operators can override them. A read-once reader,
such as maintenance, sets `noWarm` so its reads do not displace query data.
*/}}
{{- define "logfire.ffBcacheReaderEnv" -}}
{{- $root := .root -}}
{{- $topology := include "logfire.bcacheTopology" $root | fromJson -}}
- name: FF_BCACHE_URI
  value: "{{ include "logfire.scheme" $root }}://logfire-ff-bcache-internal:9443"
- name: FF_BCACHE_K8S_SERVICE
  value: logfire-ff-bcache-internal
- name: FF_BCACHE_K8S_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: FF_BCACHE_K8S_PORT_NAME
  value: {{ ternary "https" "http" ($root.Values.inClusterTls.enabled | default false) }}
- name: FF_BCACHE_HTTP_VERSION
  value: http1
{{- with $topology.zone }}
- name: FF_ZONE
  value: {{ . | quote }}
{{- end }}
{{- if $topology.zoneAware }}
- name: FF_NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
{{- end }}
{{- if .noWarm }}
- name: FF_READ_NO_WARM
  value: "true"
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

{{/*
Convert storage quantities used by scratchVolume.storage to whole MiB via the
shared Kubernetes quantity parser (case-sensitive: decimal suffixes like G are
powers of 1000, binary suffixes like Gi are powers of 1024), rounding down so
derived sizes never exceed the volume. Quantities below 1Mi fail rather than
rounding to zero.
*/}}
{{- define "logfire.storageQuantityToMi" -}}
{{- $quantity := required "logfire.storageQuantityToMi: storage quantity is required" . | toString
    | trim -}}
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
Scratch env for a FusionFire workload that spills into its `/tmp` emptyDir: crud-api and the
maintenance scheduler. The binary roots its DataFusion `DiskManager` at `FF_TEMP_DIR` and empties
`{FF_TEMP_DIR}/fusionfire` at startup. Without a quota, DataFusion allows 100GiB of spill files,
and the emptyDir has no size limit, so a large query could fill the node disk.
*/}}
{{- define "logfire.ffTmpSpillEnv" -}}
- name: FF_TEMP_DIR
  value: /tmp
- name: FF_SPILL_TO_DISK_QUOTA
  value: {{ include "logfire.ffSpillToDiskQuota" . | default "512MB" | quote }}
{{- end -}}

{{/*
Expose effective Kubernetes resources to FusionFire so its auto-config formulas
use the same resources Kubernetes enforces. Effective resources fall back to
the tiny preset for internal calculations when no preset/resources are set,
without rendering Kubernetes resources.
*/}}
{{- define "logfire.ffResourceEnv" -}}
{{- $effectiveResources := include "logfire.effectiveResources" . | fromJson -}}
{{- $cpuMilli := include "logfire.cpuMilli" $effectiveResources.cpuLimit | int -}}
{{- $memoryMi := include "logfire.memoryToMi" $effectiveResources.memoryLimit | int -}}
- name: FF_RESOURCE_CPU_CORES
  value: {{ printf "%.3f" (divf (float64 $cpuMilli) 1000.0) | quote }}
- name: FF_RESOURCE_MEMORY_BYTES
  value: {{ mul $memoryMi 1048576 | quote }}
{{- end -}}

{{/*
The shutdown budget of a Fusionfire role. The pod has the default grace period of 30 seconds.
The preStop sleep uses the first part of it, so the process gets the rest. Fusionfire stops its
tasks at SIGTERM, so it takes no lame duck.

Pass (dict "preStopSeconds" N). Omit `preStopSeconds` for a role without a preStop hook.
*/}}
{{- define "logfire.ffShutdownEnv" -}}
- name: SHUTDOWN_GRACE_SECONDS
  value: {{ sub 30 (.preStopSeconds | default 0) | quote }}
- name: SHUTDOWN_LAME_DUCK_SECONDS
  value: "0"
{{- end -}}

{{/*
Render the FusionFire query environment for an intake, worker, or combined role.

`FF_MAX_COST_PER_WORKER` is the same for the combined query-api deployment and the optional
remote query workers. An explicit query-api override wins. Otherwise it is the execution
worker's effective CPU limit (or request when no limit is configured), rounded up to whole cores.
*/}}
{{- define "logfire.ffQueryExecutionEnv" -}}
{{- $role := .role -}}
{{- $effectiveServiceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $queryApiValues := include "logfire.effectiveServiceValues"
    (dict "Values" .Values "serviceName" "logfire-ff-query-api") | fromJson -}}
{{- $maxCostPerWorker := toString (get $queryApiValues "maxQueryCostPerPod") -}}
{{- if hasKey $queryApiValues "maxQueryCostPerPod" -}}
  {{- if not (regexMatch "^[1-9][0-9]*$" $maxCostPerWorker) -}}
    {{- fail "logfire-ff-query-api.maxQueryCostPerPod must be a positive integer" -}}
  {{- end -}}
{{- else -}}
  {{- $queryWorkerEnabled := get (get .Values "logfire-ff-query-worker" | default dict) "enabled"
      | default false -}}
  {{- $executionServiceName := ternary "logfire-ff-query-worker" "logfire-ff-query-api"
      $queryWorkerEnabled -}}
  {{- $cpuLimit := (include "logfire.effectiveResources"
      (dict "Values" .Values "serviceName" $executionServiceName) | fromJson).cpuLimit -}}
  {{- $maxCostPerWorker = max 1 (div (add (include "logfire.cpuMilli" $cpuLimit | int) 999)
      1000) -}}
{{- end -}}
- name: FF_TEMP_DIR
  value: /scratch/fusionfire
- name: FF_QUERY_PARALLELISM
  value: {{ get $effectiveServiceValues "queryParallelism" | default "auto" | quote }}
- name: FF_MAX_COST_PER_WORKER
  value: {{ $maxCostPerWorker | quote }}
{{ include "logfire.ffResourceEnv" . }}
{{- if eq $role "worker" }}
- name: FF_PG_POOL_MAX_CONNECTIONS
  value: "4"
{{- end }}
{{- if ne $role "intake" }}
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
Common execution env for background maintenance/compaction workers.
*/}}
{{- define "logfire.ffBackgroundWorkerExecutionEnv" -}}
{{- $values := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $datafusionMemory := get $values "datafusionMemory" | default "auto" -}}
{{- $spillToDiskQuota := include "logfire.ffSpillToDiskQuota" . -}}
{{- include "logfire.ffResourceEnv" . }}
- name: FF_IO_THREADS
  value: {{ get $values "ioThreads" | default "auto" | quote }}
- name: FF_DATAFUSION_THREADS
  value: {{ get $values "datafusionThreads" | default "auto" | quote }}
- name: FF_DATAFUSION_MEMORY_LIMIT
  value: {{ $datafusionMemory | quote }}
- name: FF_MAINTENANCE_MAX_RECORD_BATCH_MEMORY
  value: {{ get $values "maintenanceRecordBatchMemory" | default $datafusionMemory | quote }}
- name: FF_TEMP_DIR
  value: /scratch/fusionfire
{{- with $spillToDiskQuota }}
- name: FF_SPILL_TO_DISK_QUOTA
  value: {{ . | quote }}
{{- end }}
- name: FF_MAINTENANCE_CPU_CONCURRENCY
  value: {{ get $values "cpuConcurrency" | default "auto" | quote }}
- name: FF_PARQUET_SPOOL_THRESHOLD_BYTES
  value: {{ get $values "parquetSpoolThresholdBytes" | default "1MB" | quote }}
- name: FF_COMPACTION_JOB_PARALLELISM
  value: {{ get $values "jobParallelism" | default "auto" | quote }}
{{- include "logfire.ffMaintenanceRetryEnv" (dict "Values" .Values "serviceName" .serviceName "ladder" true) }}
{{- end -}}

{{/*
Retry env for maintenance jobs. A job that fails on memory retries in the same process with
fewer lanes and smaller batches (the resource ladder). The scheduler deletes a job when it
reaches the maximum attempts, so the workers and the scheduler must use the same maximum.

The service `env` overrides these defaults. A name that it sets is left out here, so the pod
spec has no duplicate entry. A map entry set to null removes the name from `env`, so the
default applies. Args: Values, serviceName, ladder (true for the workers).
*/}}
{{- define "logfire.ffMaintenanceRetryEnv" -}}
{{- $env := get (get .Values .serviceName | default dict) "env" | default list -}}
{{- $names := list -}}
{{- if kindIs "map" $env -}}
  {{- range $name, $value := $env -}}
    {{- if not (kindIs "invalid" $value) -}}
      {{- $names = append $names $name -}}
    {{- end -}}
  {{- end -}}
{{- else -}}
  {{- range $env }}{{ $names = append $names .name }}{{ end -}}
{{- end -}}
{{- if and .ladder (not (has "FF_MAINTENANCE_RESOURCE_LADDER" $names)) }}
- name: FF_MAINTENANCE_RESOURCE_LADDER
  value: "true"
{{- end }}
{{- if not (has "FF_MAINTENANCE_JOB_MAX_ATTEMPTS" $names) }}
- name: FF_MAINTENANCE_JOB_MAX_ATTEMPTS
  value: "5"
{{- end }}
{{- end -}}
