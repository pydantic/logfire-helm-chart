{{/*
================================================================================
Resource Quantity Helpers
================================================================================
Helpers for parsing/deriving CPU and memory quantities used by FF workloads.
*/}}

{{/*
Convert Kubernetes CPU quantity to millicores.
Accepts values like 1, 0.5, 750m.
*/}}
{{- define "logfire.cpuMilli" -}}
{{- $cpu := trim (toString .) -}}
{{- $numberPattern := "^[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$" -}}
{{- $cpuMilli := 0 -}}
{{- if hasSuffix "m" $cpu -}}
  {{- $milli := trimSuffix "m" $cpu -}}
  {{- if not (regexMatch $numberPattern $milli) -}}
    {{- fail (printf "Invalid CPU format '%s'. Use Kubernetes quantity format (e.g., '1', '0.5', '750m')." $cpu) -}}
  {{- end -}}
  {{- $cpuMilli = int (floor (float64 $milli)) -}}
{{- else -}}
  {{- if not (regexMatch $numberPattern $cpu) -}}
    {{- fail (printf "Invalid CPU format '%s'. Use Kubernetes quantity format (e.g., '1', '0.5', '750m')." $cpu) -}}
  {{- end -}}
  {{- $cpuMilli = int (floor (mulf (float64 $cpu) 1000.0)) -}}
{{- end -}}
{{- if lt $cpuMilli 1 -}}
  {{- fail (printf "Invalid CPU format '%s': effective millicores must be >= 1m." $cpu) -}}
{{- end -}}
{{- $cpuMilli -}}
{{- end -}}

{{/*
Convert Kubernetes CPU quantity to integer cores using ceil, with minimum 1.
*/}}
{{- define "logfire.cpuCores" -}}
{{- $cpuMilli := int (include "logfire.cpuMilli" .) -}}
{{- max 1 (div (add $cpuMilli 999) 1000) -}}
{{- end -}}

{{/*
Convert Kubernetes memory quantity to mebibytes (Mi).
Supports common binary and decimal suffixes plus plain bytes.
*/}}
{{- define "logfire.memoryToMi" -}}
{{- $memory := trim (toString .) -}}
{{- $pattern := "^[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?([EPTGMK]i?|[numkKMGTEP])?$" -}}
{{- if not (regexMatch $pattern $memory) -}}
  {{- fail (printf "Invalid memory format '%s'. Use Kubernetes quantity format (e.g., '1536Mi', '1.5Gi', '2G')." $memory) -}}
{{- end -}}
{{- $number := regexFind "^[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?" $memory -}}
{{- $unit := regexReplaceAll "^[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?" $memory "" -}}
{{- $value := float64 $number -}}
{{- $mi := 0.0 -}}
{{- if eq $unit "" -}}
  {{- $mi = divf $value 1048576.0 -}}
{{- else if eq $unit "Ki" -}}
  {{- $mi = divf $value 1024.0 -}}
{{- else if eq $unit "Mi" -}}
  {{- $mi = $value -}}
{{- else if eq $unit "Gi" -}}
  {{- $mi = mulf $value 1024.0 -}}
{{- else if eq $unit "Ti" -}}
  {{- $mi = mulf $value 1048576.0 -}}
{{- else if eq $unit "Pi" -}}
  {{- $mi = mulf $value 1073741824.0 -}}
{{- else if eq $unit "Ei" -}}
  {{- $mi = mulf $value 1099511627776.0 -}}
{{- else if eq $unit "n" -}}
  {{- $mi = divf $value 1048576000000000.0 -}}
{{- else if eq $unit "u" -}}
  {{- $mi = divf $value 1048576000000.0 -}}
{{- else if eq $unit "m" -}}
  {{- $mi = divf $value 1048576000.0 -}}
{{- else if or (eq $unit "k") (eq $unit "K") -}}
  {{- $mi = divf (mulf $value 1000.0) 1048576.0 -}}
{{- else if eq $unit "M" -}}
  {{- $mi = divf (mulf $value 1000000.0) 1048576.0 -}}
{{- else if eq $unit "G" -}}
  {{- $mi = divf (mulf $value 1000000000.0) 1048576.0 -}}
{{- else if eq $unit "T" -}}
  {{- $mi = divf (mulf $value 1000000000000.0) 1048576.0 -}}
{{- else if eq $unit "P" -}}
  {{- $mi = divf (mulf $value 1000000000000000.0) 1048576.0 -}}
{{- else if eq $unit "E" -}}
  {{- $mi = divf (mulf $value 1000000000000000000.0) 1048576.0 -}}
{{- else -}}
  {{- fail (printf "Invalid memory format '%s'." $memory) -}}
{{- end -}}
{{- int (floor $mi) -}}
{{- end -}}

{{/*
Calculate memory assignments based on service memory request.
*/}}
{{- define "logfire.calculateMemory" -}}
{{-   $dot := . -}}
{{-   $values := get $dot "Values"  -}}
{{-   $serviceName := get $dot "serviceName" -}}
{{-   $percentage := get $dot "percentage" -}}
{{-   $defaultMemory := get $dot "defaultMemory" | default "1Gi" -}}

{{-   $serviceValues := get $values $serviceName | default dict -}}
{{-   $resources := get $serviceValues "resources" | default dict -}}
{{-   $memory := get $resources "memory" | default $defaultMemory -}}

{{-   $memoryMi := int (include "logfire.memoryToMi" $memory) -}}

{{-   $calculatedMemory := div (mul $memoryMi (int $percentage)) 100 -}}

{{-   $calculatedMemory | int -}}
{{- end -}}
