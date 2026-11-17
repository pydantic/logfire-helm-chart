{{/*
Public gRPC routes, as a JSON list of {path, backend}. Each path is an exact gRPC
method path, and backend names the HAProxy backend that serves it. Features add
their routes here, and every route shares the gRPC listener on logfire-service.
*/}}
{{- define "logfire.grpc.routes" -}}
{{- $routes := list -}}
{{- if (.Values.agentSandboxes | default dict).enabled -}}
{{- $routes = append $routes (dict "path" "/monty.v1.MontySession/Session" "backend" "monty-relay") -}}
{{- end -}}
{{- toJson $routes -}}
{{- end -}}

{{/*
Port of the gRPC listener on logfire-service. gRPC needs HTTP/2 end to end, and
load balancers usually select one protocol per Service port, so gRPC gets its own
port instead of promoting all web traffic on the HTTP port to HTTP/2.
*/}}
{{- define "logfire.grpc.port" -}}8444{{- end -}}

{{/*
appProtocol of the gRPC Service port, which controllers read to speak HTTP/2 to the
backend: `kubernetes.io/h2c` for cleartext, `HTTP2` for HTTP/2 over in-cluster TLS.
*/}}
{{- define "logfire.grpc.appProtocol" -}}
{{- ternary "HTTP2" "kubernetes.io/h2c" (include "logfire.inClusterTls.enabled" . | eq "true") -}}
{{- end -}}

{{/*
Validate that the gRPC listener does not collide with the in-cluster HTTPS port.
*/}}
{{- define "logfire.validate.grpc" -}}
{{- if and (include "logfire.grpc.routes" . | fromJsonArray) (include "logfire.inClusterTls.enabled" . | eq "true") (eq (int .Values.inClusterTls.httpsPort) (int (include "logfire.grpc.port" .))) -}}
{{- fail (printf "inClusterTls.httpsPort must not be %s while a gRPC route is enabled: logfire-service serves gRPC on that port." (include "logfire.grpc.port" .)) -}}
{{- end -}}
{{- end -}}
