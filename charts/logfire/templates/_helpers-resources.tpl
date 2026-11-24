{{/*
Convert Kubernetes CPU quantity to millicores.
Accepts values like 1, 0.5, 750m.
*/}}
{{- define "logfire.cpuMilli" -}}
{{- $cpu := trim (toString .) -}}
{{- $number := trimSuffix "m" $cpu -}}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$" $number) -}}
  {{- fail (printf
      "Invalid CPU format '%s'. Use Kubernetes quantity format (e.g., '1', '0.5', '750m')."
      $cpu) -}}
{{- end -}}
{{- $cpuMilli := hasSuffix "m" $cpu | ternary (float64 $number) (mulf (float64 $number) 1000.0)
    | floor | int -}}
{{- if lt $cpuMilli 1 -}}
  {{- fail (printf "Invalid CPU format '%s': effective millicores must be >= 1m." $cpu) -}}
{{- end -}}
{{- $cpuMilli -}}
{{- end -}}

{{/*
Resolve effective resource requests/limits for a workload.
Supports both legacy flat keys and nested requests/limits.
When resources are omitted entirely, use the tiny preset's resources as the
internal FusionFire baseline. These defaults do not render Kubernetes resources.
*/}}
{{- define "logfire.effectiveResources" -}}
{{- $serviceValues := include "logfire.effectiveServiceValues" . | fromJson -}}
{{- $resources := get $serviceValues "resources" | default dict -}}
{{- if not $resources -}}
  {{- $tinyPreset := get (.Values.sizingPresets | default dict) "tiny" | default dict -}}
  {{- $tinyServiceValues := get $tinyPreset .serviceName | default dict -}}
  {{- $resources = get $tinyServiceValues "resources" | default dict -}}
{{- end -}}
{{- $requests := get $resources "requests" | default dict -}}
{{- $limits := get $resources "limits" | default dict -}}
{{- $cpuRequest := coalesce (get $requests "cpu") (get $resources "cpu") (get $limits "cpu")
    "500m" -}}
{{- $memoryRequest := coalesce (get $requests "memory") (get $resources "memory")
    (get $limits "memory") "1Gi" -}}
{{- $ephemeralStorageRequest := coalesce (get $requests "ephemeral-storage")
    (get $requests "ephemeralStorage") (get $resources "ephemeralStorage")
    (get $limits "ephemeral-storage") (get $limits "ephemeralStorage") -}}
{{- $cpuLimit := coalesce (get $limits "cpu") $cpuRequest -}}
{{- $memoryLimit := coalesce (get $limits "memory") $memoryRequest -}}
{{- $ephemeralStorageLimit := coalesce (get $limits "ephemeral-storage")
    (get $limits "ephemeralStorage") $ephemeralStorageRequest -}}
{{- dict "cpuRequest" $cpuRequest "memoryRequest" $memoryRequest
    "ephemeralStorageRequest" $ephemeralStorageRequest "cpuLimit" $cpuLimit
    "memoryLimit" $memoryLimit "ephemeralStorageLimit" $ephemeralStorageLimit | toJson -}}
{{- end -}}

{{/*
Convert Kubernetes memory quantity to mebibytes (Mi).
Supports common binary and decimal suffixes plus plain bytes.
*/}}
{{- define "logfire.memoryToMiFloat" -}}
{{- $memory := trim (toString .) -}}
{{- $pattern :=
    "^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?([EPTGMK]i?|[numkKMGTEP])?$" -}}
{{- if not (regexMatch $pattern $memory) -}}
  {{- fail
      (printf "Invalid quantity format '%s'. Use Kubernetes quantity format (e.g., '1536Mi', '1.5Gi', '2G')."
      $memory) -}}
{{- end -}}
{{- $number := regexFind "^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?" $memory -}}
{{- $unit := regexReplaceAll "^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?" $memory "" -}}
{{/* Each unit maps to a multiplier and a divisor. Dividing by 1 would round the decimal. */}}
{{- $factors := get (dict
    "" (list 1.0 1048576.0) "Ki" (list 1.0 1024.0) "Mi" (list 1.0 1.0)
    "Gi" (list 1024.0 1.0) "Ti" (list 1048576.0 1.0) "Pi" (list 1073741824.0 1.0)
    "Ei" (list 1099511627776.0 1.0) "n" (list 1.0 1048576000000000.0)
    "u" (list 1.0 1048576000000.0) "m" (list 1.0 1048576000.0) "k" (list 1000.0 1048576.0)
    "K" (list 1000.0 1048576.0) "M" (list 1000000.0 1048576.0)
    "G" (list 1000000000.0 1048576.0) "T" (list 1000000000000.0 1048576.0)
    "P" (list 1000000000000000.0 1048576.0) "E" (list 1000000000000000000.0 1048576.0)
    ) $unit -}}
{{- $mi := mulf (float64 $number) (first $factors) -}}
{{- if ne (last $factors) 1.0 -}}
  {{- $mi = divf $mi (last $factors) -}}
{{- end -}}
{{- $mi -}}
{{- end -}}

{{/* Whole-MiB floor of a Kubernetes memory quantity. Use `logfire.memoryToMiFloat` when a
comparison must keep sub-MiB precision. */}}
{{- define "logfire.memoryToMi" -}}
{{- int (floor (float64 (include "logfire.memoryToMiFloat" .))) -}}
{{- end -}}

{{/* Use the actual rendered collector limit, including legacy resource normalization. */}}
{{- define "logfire.otelCollectorMemoryLimitMi" -}}
{{- $resources := include "logfire.resources" (dict "Values" .Values "serviceName"
    "logfire-otel-collector") | fromYaml -}}
{{- $limit := dig "resources" "limits" "memory" "" $resources -}}
{{- if $limit -}}
{{- include "logfire.memoryToMi" $limit -}}
{{- end -}}
{{- end -}}

{{/* Add disk queue storage budgets without inventing CPU/memory requests when none are set. */}}
{{- define "logfire.otelCollectorResources" -}}
{{- $rendered := include "logfire.resources" (dict "Values" .Values "serviceName"
    "logfire-otel-collector") | fromYaml -}}
{{- $resources := get $rendered "resources" | default dict -}}
{{- $storage := .Values.otel_collector.queueStorage -}}
{{- if $storage.enabled -}}
{{- range $entry := list (dict "kind" "requests" "value" $storage.ephemeralStorageRequest)
    (dict "kind" "limits" "value" $storage.ephemeralStorageLimit) -}}
{{- $target := get $resources $entry.kind | default dict -}}
{{- if not (hasKey $target "ephemeral-storage") -}}
{{- $_ := set $target "ephemeral-storage" $entry.value -}}
{{- end -}}
{{- $_ := set $resources $entry.kind $target -}}
{{- end -}}
{{- end -}}
{{- if $resources -}}
resources:
  {{- $resources | toYaml | nindent 2 -}}
{{- end -}}
{{- end -}}
