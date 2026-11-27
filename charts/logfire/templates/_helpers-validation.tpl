{{/*
Fail with a clear message when required values are missing or inconsistent. The checks run in
order, so the first failing check names the error.
*/}}
{{- define "logfire.validateConfig" -}}
{{- $values := .Values -}}

{{- with $values.sizingPreset -}}
  {{- $presets := $values.sizingPresets | default dict -}}
  {{- if not (hasKey $presets .) -}}
    {{- fail (printf "Unknown sizingPreset %q. Valid presets: %s" .
        ((keys $presets | sortAlpha) | join ", ")) -}}
  {{- end -}}
{{- end -}}

{{- if and (not $values.dev.deployRustfs) (not (include "logfire.objectStoreUri" . | trim)) -}}
  {{- fail
      "objectStore.uri is required. Set objectStore.uri to your S3/Azure/GCS bucket URI (e.g., 's3://bucket-name' or 'az://container-name'). For local development, you can set dev.deployRustfs=true instead." -}}
{{- end -}}

{{- /* Kubernetes rejects a pod that lists the same volume name or mount path twice. The entries
reach FusionFire and the Python services (backend, worker), so a name or path any of them mounts
is reserved. The in-cluster TLS and trusted CA volumes are reserved only while enabled. */ -}}
{{- $reservedNames := list "tmp" "scratch-data" "ingest-data" "logfire-data" -}}
{{- $reservedMountPaths := list "/tmp" "/scratch" "/fusionfire/ingest-data" "/var/lib/logfire" -}}
{{- if include "logfire.inClusterTls.enabled" . | eq "true" -}}
  {{- $reservedNames = concat $reservedNames (list "logfire-incluster-tls"
      "logfire-incluster-ca-bundle") -}}
  {{- $reservedMountPaths = concat $reservedMountPaths (list "/etc/tls"
      "/etc/logfire/incluster-ca") -}}
{{- end -}}
{{- if include "logfire.trustedCa.enabled" (dict "ctx" . "serviceName" "logfire-worker") -}}
  {{- $reservedNames = concat $reservedNames (list "logfire-trusted-ca-sources"
      "logfire-trusted-ca") -}}
  {{- $reservedMountPaths = concat $reservedMountPaths (list "/etc/logfire/trusted-ca-sources"
      "/etc/logfire/trusted-ca") -}}
{{- end -}}
{{- $objectStore := $values.objectStore | default dict -}}
{{- range $index, $volume := get $objectStore "volumes" | default list -}}
  {{- if has (get $volume "name") $reservedNames -}}
    {{- fail
        (printf "objectStore.volumes[%d].name '%s' is reserved by the chart. Rename the volume, because chart-owned containers mount a volume with that name. Reserved names: %s."
        $index (get $volume "name") ($reservedNames | join ", ")) -}}
  {{- end -}}
{{- end -}}
{{- range $index, $mount := get $objectStore "volumeMounts" | default list -}}
  {{- if has (get $mount "mountPath") $reservedMountPaths -}}
    {{- fail
        (printf "objectStore.volumeMounts[%d].mountPath '%s' is reserved by the chart. Use another mount path, because chart-owned containers mount a writable volume at that path. Reserved paths: %s."
        $index (get $mount "mountPath") ($reservedMountPaths | join ", ")) -}}
  {{- end -}}
{{- end -}}

{{- if not (include "logfire.effective_hostnames" . | fromJson).hosts -}}
  {{- fail
      "At least one hostname is required for Logfire. Set gateway.hostnames or ingress.hostnames so the chart can generate public URLs and CORS settings." -}}
{{- end -}}

{{- if not (has ((($values.haproxy | default dict).corsOriginMatch) | default "exact") (list "exact" "prefix")) -}}
  {{- fail "haproxy.corsOriginMatch must be exact or prefix." -}}
{{- end -}}

{{- if and $values.gateway.enabled $values.gateway.create (not $values.gateway.gatewayClassName) -}}
  {{- fail
      "gateway.gatewayClassName is required when gateway.create is true. Specify the GatewayClass name (e.g., 'istio', 'cilium', 'nginx', 'envoy-gateway')." -}}
{{- end -}}
{{- $hostValidation := $values.hostValidation | default dict -}}
{{- if not (has ($hostValidation.mode | default "off") (list "off" "report" "enforce")) -}}
  {{- fail "hostValidation.mode must be off, report or enforce." -}}
{{- end -}}
{{- range $index, $host := $hostValidation.additionalHosts | default list -}}
  {{- if not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?$" (toString $host)) -}}
    {{- fail
        (printf "hostValidation.additionalHosts[%d] %q is not a hostname. List a bare hostname, with its port if it has one, such as localhost:8080." $index $host) -}}
  {{- end -}}
{{- end -}}

{{- if and $values.gateway.enabled (not $values.gateway.create) (not $values.gateway.name) -}}
  {{- fail
      "gateway.name is required when gateway.enabled is true and gateway.create is false. Provide the name of the existing Gateway resource to attach the HTTPRoute to." -}}
{{- end -}}
{{- if and $values.ingress.enabled $values.gateway.enabled -}}
  {{- fail
      "Both ingress.enabled and gateway.enabled are true. Enable only one of Ingress or Gateway API to avoid routing conflicts. Set ingress.enabled=false to use Gateway API, or gateway.enabled=false to use Ingress." -}}
{{- end -}}

{{- $frontendHosts := list -}}
{{- range (include "logfire.effective_hostnames" . | fromJson).hosts -}}
  {{- $frontendHosts = append $frontendHosts (lower (toString .)) -}}
{{- end -}}
{{- $intakeHosts := list -}}
{{- range $index, $host := (include "logfire.intake_hostnames" . | fromJson).hosts -}}
  {{- /* The entry becomes an Ingress rule host, an HTTPRoute hostname and a Gateway listener hostname.
  Kubernetes accepts only a lowercase RFC 1123 name there, at most 253 characters, so a port, an
  uppercase letter, an IP address or a longer name would pass the render and fail at apply. A label
  of more than 63 characters is not a DNS name that resolves, although Kubernetes accepts it. A
  number would render as a number in the Ingress, so only a string is a hostname. */ -}}
  {{- if not (kindIs "string" $host) -}}
    {{- fail
        (printf "intake.hostnames[%d] must be a string, such as ingest.example.com." $index) -}}
  {{- end -}}
  {{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$" (toString $host)) -}}
    {{- fail
        (printf "intake.hostnames[%d] %q is not a valid hostname. List a bare hostname in lowercase, such as ingest.example.com, without a scheme, a port or a path, with at most 63 characters in a label." $index $host) -}}
  {{- end -}}
  {{- if gt (len (toString $host)) 253 -}}
    {{- fail
        (printf "intake.hostnames[%d] %q is not a valid hostname. A hostname has at most 253 characters." $index $host) -}}
  {{- end -}}
  {{- if regexMatch "^[0-9]+(\\.[0-9]+){3}$" (toString $host) -}}
    {{- fail
        (printf "intake.hostnames[%d] %q is an IP address. An Ingress or Gateway hostname must be a DNS name." $index $host) -}}
  {{- end -}}
  {{- if has (lower (toString $host)) $frontendHosts -}}
    {{- fail
        (printf "intake.hostnames[%d] %q is also a frontend hostname. An ingest-only hostname serves no UI, so remove it from gateway.hostnames or ingress.hostnames, or from intake.hostnames." $index $host) -}}
  {{- end -}}
  {{- if has (lower (toString $host)) $intakeHosts -}}
    {{- fail (printf "intake.hostnames[%d] %q is listed twice." $index $host) -}}
  {{- end -}}
  {{- $intakeHosts = append $intakeHosts (lower (toString $host)) -}}
{{- end -}}

{{- if not $values.dev.deployPostgres -}}
  {{- if $values.postgresSecret.enabled -}}
    {{- if not $values.postgresSecret.name -}}
      {{- fail
          "postgresSecret.name is required when postgresSecret.enabled is true. Provide the name of your Kubernetes Secret containing 'postgresDsn' and 'postgresFFDsn' keys." -}}
    {{- end -}}
  {{- else if not $values.postgresDsn -}}
    {{- fail
        "postgresDsn is required when not using dev.deployPostgres or postgresSecret. Provide a PostgreSQL DSN for the crud database." -}}
  {{- else if not $values.postgresFFDsn -}}
    {{- fail
        "postgresFFDsn is required when not using dev.deployPostgres or postgresSecret. Provide a PostgreSQL DSN for the ff database." -}}
  {{- end -}}
  {{- $dexStorage := dig "config" "storage" dict (index $values "logfire-dex" | default dict) -}}
  {{- if and (eq (dig "type" "" $dexStorage) "postgres")
      (not (dig "config" dict $dexStorage).host) -}}
    {{- fail
        "logfire-dex.config.storage.config.host is required when using postgres storage type. Configure the Dex storage to point to your PostgreSQL instance." -}}
  {{- end -}}
{{- end -}}

{{- $ai := $values.ai | default dict -}}
{{- $openAi := get $ai "openAi" | default dict -}}
{{- $vertexAi := get $ai "vertexAi" | default dict -}}
{{- $azureOpenAi := get $ai "azureOpenAi" | default dict -}}
{{- $multiRegionLocation := get $vertexAi "multiRegionLocation" -}}
{{- if and $multiRegionLocation (not (has $multiRegionLocation (list "us" "eu"))) -}}
  {{- fail
      (printf "ai.vertexAi.multiRegionLocation must be exactly 'us' or 'eu', got '%s'. Do not use 'global' as a data-residency workaround."
      $multiRegionLocation) -}}
{{- end -}}
{{- range $name := list "ai.model" "ai.chatModel" "ai.reasoningModel" "ai.llmJudgeModel" -}}
  {{- range $fallback := get $ai (trimPrefix "ai." $name) | default "" | splitList "," -}}
    {{- $fallback = trim $fallback -}}
    {{- if eq $fallback "google-cloud:gemini-3.5-flash" -}}
      {{- if not $multiRegionLocation -}}
        {{- fail
            (printf "ai.vertexAi.multiRegionLocation is required when %s contains Google Cloud model '%s'. Set it to 'us' or 'eu'."
            $name $fallback) -}}
      {{- end -}}
    {{- else if and (hasPrefix "google-cloud:" $fallback) (not (get $vertexAi "region")) -}}
      {{- fail
          (printf "ai.vertexAi.region is required when %s contains regional Google Cloud model '%s'."
          $name $fallback) -}}
    {{- else if and (regexMatch "^openai(-chat|-responses)?:" $fallback)
        (not (get $openAi "apiKey")) -}}
      {{- fail
          (printf "ai.openAi.apiKey is required when %s uses OpenAI model '%s'. Provide your OpenAI API key."
          $name $fallback) -}}
    {{- else if hasPrefix "azure:" $fallback -}}
      {{- if not (get $azureOpenAi "endpoint") -}}
        {{- fail (printf "ai.azureOpenAi.endpoint is required when %s uses Azure OpenAI model '%s'."
            $name $fallback) -}}
      {{- end -}}
      {{- if not (get $azureOpenAi "apiKey") -}}
        {{- fail (printf "ai.azureOpenAi.apiKey is required when %s uses Azure OpenAI model '%s'."
            $name $fallback) -}}
      {{- end -}}
    {{- else if and (hasPrefix "google-vertex:" $fallback) (not (get $vertexAi "region")) -}}
      {{- fail (printf "ai.vertexAi.region is required when %s uses Google Vertex AI model '%s'."
          $name $fallback) -}}
    {{- else if hasPrefix "anthropic-vertex:" $fallback -}}
      {{- if not (get $vertexAi "region") -}}
        {{- fail (printf "ai.vertexAi.region is required when %s uses Anthropic Vertex model '%s'."
            $name $fallback) -}}
      {{- end -}}
      {{- if not (get $vertexAi "anthropicProjectId") -}}
        {{- fail
            (printf "ai.vertexAi.anthropicProjectId is required when %s uses Anthropic Vertex model '%s'."
            $name $fallback) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $slackApp := include "logfire.slackApp.enabled" . -}}
{{- if and $values.existingSecret.enabled (not $values.existingSecret.name) -}}
  {{- $msg :=
      "existingSecret.name is required when existingSecret.enabled is true. Provide the name of your Kubernetes Secret containing logfire-dex-client-secret, logfire-encryption-key, logfire-meta-write-token, logfire-meta-frontend-token, logfire-jwt-secret and logfire-unsubscribe-secret keys." -}}
  {{- if $values.webPush.enabled -}}
    {{- $msg = printf "%s It must also hold a logfire-web-push-vapid-key key when webPush.enabled, unless webPush.privateKey sets valueFrom."
        $msg -}}
  {{- end -}}
  {{- if $slackApp -}}
    {{- $msg = printf
        "%s It must also hold logfire-slack-client-secret and logfire-slack-signing-secret keys when integrations.slack.clientId is set, unless those values set valueFrom."
        $msg -}}
  {{- end -}}
  {{- fail $msg -}}
{{- end -}}
{{- $gatewaySecret := get $values "existingGatewaySecret" | default dict -}}
{{- if and (index $values "logfire-ai-gateway" "enabled") (get $gatewaySecret "enabled")
    (not (get $gatewaySecret "name")) -}}
  {{- fail
      "existingGatewaySecret.name is required when existingGatewaySecret.enabled is true. Provide the name of your Kubernetes Secret containing 'key' (gateway encryption key) and 'internalSecret' (gateway internal secret) keys." -}}
{{- end -}}
{{- if and $values.adminSecret.enabled (not $values.adminSecret.name) -}}
  {{- fail
      "adminSecret.name is required when adminSecret.enabled is true. Provide the name of your Kubernetes Secret containing logfire-admin-password, logfire-admin-totp-secret, and logfire-admin-totp-recovery-codes keys." -}}
{{- end -}}

{{- if not $values.adminEmail -}}
  {{- fail "adminEmail is required. Provide an email address for the initial admin user." -}}
{{- end -}}
{{- if not (regexMatch "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$" $values.adminEmail) -}}
  {{- fail (printf "adminEmail '%s' does not appear to be a valid email address."
      $values.adminEmail) -}}
{{- end -}}
{{- range $index, $apiKey := $values.adminApiKeys -}}
  {{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9 ._-]*$" (toString (default "" $apiKey.name))) -}}
    {{- fail
        (printf "adminApiKeys[%d].name is required and may contain only letters, digits, spaces, dots, underscores, and dashes."
        $index) -}}
  {{- end -}}
  {{- if or (not $apiKey.secretName) (not $apiKey.secretKey) -}}
    {{- fail
        (printf "adminApiKeys[%d] needs secretName and secretKey. Provide the Kubernetes Secret and the key that hold the token."
        $index) -}}
  {{- end -}}
  {{- $badScopes := or (not (kindIs "slice" $apiKey.scopes)) (not $apiKey.scopes) -}}
  {{- range kindIs "slice" $apiKey.scopes | ternary $apiKey.scopes (list) -}}
    {{- if not (regexMatch "^[a-z_]+:[a-z_]+$" (toString .)) -}}
      {{- $badScopes = true -}}
    {{- end -}}
  {{- end -}}
  {{- if $badScopes -}}
    {{- fail
        (printf "adminApiKeys[%d].scopes must list at least one scope, and each scope looks like instance:admin."
        $index) -}}
  {{- end -}}
{{- end -}}

{{- $redisSecret := $values.redisSecret | default dict -}}
{{- if and (get $redisSecret "enabled") (not (get $redisSecret "name")) -}}
  {{- fail
      "redisSecret.name is required when redisSecret.enabled is true. Set it to a Secret that holds the sharedDsn, tailDsn, tokenDsn and usageDsn keys." -}}
{{- end -}}
{{- if and (not (get $redisSecret "enabled")) (not (dig "enabled" true
    (index $values "logfire-redis" | default dict))) (not $values.redisDsn) -}}
  {{- fail
      "redisDsn is required when logfire-redis.enabled is false and redisSecret is not in use. Provide a Redis DSN for your external Redis instance, or set redisSecret.name to a Secret that holds the Redis DSNs." -}}
{{- end -}}

{{- /* The platform does not send email as pydantic.dev from a self-hosted install, and the task
runner and the worker refuse to start without EMAIL_FROM_ADDRESS, so this stops the install
before any workload rolls out. With dev.deployMaildev the workloads get a placeholder sender. */ -}}
{{- $smtp := $values.smtp | default dict -}}
{{- if and (get $smtp "host") (not (get $smtp "fromAddress")) (not $values.dev.deployMaildev) -}}
  {{- fail
      "smtp.fromAddress is required when smtp.host is set. Set it to the sender address of Logfire email, such as logfire@example.com, on a domain that your SMTP server may send for. Logfire does not send email as pydantic.dev from a self-hosted install." -}}
{{- end -}}
{{- $domain := get $smtp "fromAddress" | default "" | toString | splitList "@" | last | trim
    | trimSuffix "." | lower -}}
{{- if or (eq $domain "pydantic.dev") (hasSuffix ".pydantic.dev" $domain) -}}
  {{- fail
      "smtp.fromAddress must not be a pydantic.dev address. Set it to an address on a domain that your SMTP server may send for." -}}
{{- end -}}
{{- $smtpCaBundle := get $smtp "caBundle" | default dict -}}
{{- if and (dig "existingConfigMap" "name" "" $smtpCaBundle)
    (dig "existingSecret" "name" "" $smtpCaBundle) -}}
  {{- fail "smtp.caBundle: specify only one of existingConfigMap.name or existingSecret.name" -}}
{{- end -}}
{{- if and (include "logfire.smtp.caBundle.source" .) (eq (toString (get $smtp "validate_certs"))
    "false") -}}
  {{- fail
      "smtp.caBundle is set but smtp.validate_certs is false, so the bundle would never be used. Remove smtp.validate_certs to verify the SMTP server against the bundle." -}}
{{- end -}}
{{- $trustedCaBundle := $values.trustedCaBundle | default dict -}}
{{- if and (dig "existingConfigMap" "name" "" $trustedCaBundle)
    (dig "existingSecret" "name" "" $trustedCaBundle) -}}
  {{- fail "trustedCaBundle: specify only one of existingConfigMap.name or existingSecret.name" -}}
{{- end -}}

{{- if include "logfire.inClusterTls.enabled" . | eq "true" -}}
  {{- $mode := include "logfire.inClusterTls.certs.mode" . -}}
  {{- if not (has $mode (list "existingSecrets" "certManager")) -}}
    {{- fail
        (printf "inClusterTls.certs.mode must be one of 'existingSecrets' or 'certManager' (got %q)"
        $mode) -}}
  {{- end -}}
  {{- $caConfigMap := $values.inClusterTls.caBundle.existingConfigMap.name -}}
  {{- $caSecret := dig "existingSecret" "name" "" $values.inClusterTls.caBundle -}}
  {{- if and $caConfigMap $caSecret -}}
    {{- fail
        "inClusterTls.caBundle: specify only one of existingConfigMap.name or existingSecret.name" -}}
  {{- end -}}
  {{- if eq $mode "certManager" -}}
    {{- $issuerKind := include "logfire.inClusterTls.certs.certManager.issuerRef.kind" . -}}
    {{- if not (has $issuerKind (list "Issuer" "ClusterIssuer")) -}}
      {{- fail
          (printf "inClusterTls.certs.certManager.issuerRef.kind must be 'Issuer' or 'ClusterIssuer' (got %q)"
          $issuerKind) -}}
    {{- end -}}
    {{- /* The auto-Issuer can only be a namespaced Issuer. */ -}}
    {{- if and (not (include "logfire.inClusterTls.certs.certManager.issuerRef.name" .))
        (ne $issuerKind "Issuer") -}}
      {{- fail
          "inClusterTls.certs.mode=certManager with an empty issuerRef.name uses the chart-managed *namespaced* Issuer. Set issuerRef.kind=Issuer, or provide a non-empty issuerRef.name (Issuer/ClusterIssuer)." -}}
    {{- end -}}
    {{- if and (not $caConfigMap) (not $caSecret) (not (include
        "logfire.inClusterTls.certs.certManager.autoIssuer" . | eq "true")) -}}
      {{- fail
          "inClusterTls.enabled is true and certs.mode=certManager, but no CA bundle was provided. Set inClusterTls.caBundle.existingConfigMap.name (recommended) or inClusterTls.caBundle.existingSecret.name, or leave issuerRef.name empty to use the chart-managed CA." -}}
    {{- end -}}
    {{- if and (not (dig "deployCertManager" false $values.dev))
        (not (.Capabilities.APIVersions.Has "cert-manager.io/v1")) -}}
      {{- fail
          "inClusterTls.certs.mode=certManager requires cert-manager CRDs (cert-manager.io/v1). Either install cert-manager separately, or set dev.deployCertManager=true for Kind/dev." -}}
    {{- end -}}
  {{- else if and (not $caConfigMap) (not $caSecret) -}}
    {{- fail
        "inClusterTls.enabled is true and certs.mode=existingSecrets, but no CA bundle was provided. Set inClusterTls.caBundle.existingConfigMap.name (recommended) or inClusterTls.caBundle.existingSecret.name." -}}
  {{- end -}}
{{- end -}}

{{- range $serviceName := list "logfire-ff-compaction-worker" "logfire-ff-maintenance-worker"
    "logfire-ff-query-api" "logfire-ff-query-worker" -}}
  {{- $scratchVolume := include "logfire.effectiveServiceValues"
      (dict "Values" $values "serviceName" $serviceName) | fromJson | dig "scratchVolume" dict -}}
  {{- if and $scratchVolume (not (get $scratchVolume "storage")) -}}
    {{- fail
        (printf "%s.scratchVolume.storage is required when scratchVolume is configured. Omit %s.scratchVolume to use emptyDir scratch storage, or set scratchVolume.storage for an ephemeral PVC."
        $serviceName $serviceName) -}}
  {{- end -}}
{{- end -}}

{{- /* Removed values would otherwise be ignored without an error, so each guard names the move.
A check reads a value, not a key, when the 0.14.0 defaults carry the key, because
`--reuse-values` keeps those defaults. Ignoring the v1 byte cache block would turn zone routing
off, ignoring `dev.deployMinio` would drop the in-cluster object store, and ignoring
`serviceAccountName` would move the pods to another ServiceAccount and drop the cloud identity
bound to it. The 0.14.0 `serviceAccountName` default is `default`, so only another value
fails. */ -}}
{{- if $values.dev.deployMinio -}}
  {{- fail
      "dev.deployMinio was removed in chart 0.15.0. Set dev.deployRustfs=true and move minio.auth and minio.persistence to rustfs.auth and rustfs.persistence. Existing MinIO data does not carry over, and the object store Service is logfire-rustfs." -}}
{{- end -}}
{{- if and $values.serviceAccountName (ne (toString $values.serviceAccountName) "default") -}}
  {{- fail "serviceAccountName was removed in chart 0.15.0. Set serviceAccount.name instead." -}}
{{- end -}}
{{- if hasKey $values "logfire-ff-cache-byte" -}}
  {{- fail
      "logfire-ff-cache-byte is no longer a values block. Move its settings to logfire-ff-bcache: replica, resource, autoscaling and PDB settings keep their names, scratchVolume and cacheDiskCapacity become logfire-ff-bcache.disk.storage, and clientSideRouting.zoneAware becomes logfire-ff-bcache.topology.zoneAware." -}}
{{- end -}}

{{- /* The chart cannot generate the Slack App credentials. */ -}}
{{- if and $slackApp (not $values.existingSecret.enabled)
    (or (not $values.integrations.slack.clientSecret) (not
    $values.integrations.slack.signingSecret)) -}}
  {{- fail
      "integrations.slack.clientSecret and integrations.slack.signingSecret are required with integrations.slack.clientId, unless existingSecret holds logfire-slack-client-secret and logfire-slack-signing-secret." -}}
{{- end -}}

{{- /* nginx rejects other worker counts only when the frontend pod starts. */ -}}
{{- $workers := dig "nginx" "workerProcesses" "auto" (index $values "logfire-frontend-service"
    | default dict) | toString -}}
{{- if not (regexMatch "^(auto|[1-9][0-9]*)$" $workers) -}}
  {{- fail
      (printf "logfire-frontend-service.nginx.workerProcesses must be auto or a positive integer, got %q."
      $workers) -}}
{{- end -}}

{{- /* The chart serves this token to browsers. Only a public token is safe. */ -}}
{{- $token := $values.frontendApplicationToken | default "" -}}
{{- if and $token (not (regexMatch "^pylf_v1_[a-z]+_pub[a-zA-Z0-9]+$" $token)) -}}
  {{- fail
      (printf "frontendApplicationToken must match pylf_v1_<region>_pub<random>, got %q. The chart serves this token to browsers, so a private token would expose more than telemetry writes."
      $token) -}}
{{- end -}}
{{- end -}}
