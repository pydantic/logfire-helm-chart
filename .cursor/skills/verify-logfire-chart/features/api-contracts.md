# Public API contracts

Clients authenticate, send telemetry, query stored records, and use remote MCP
through the installed chart's public service.

## Sub-features

- `auth-mail` covers token and email flows against the real backend and Maildev.
- `ingest-query` covers SDK and OTLP ingestion, exact query results, metrics, and errors.
- `mcp` ingests a unique OTLP span, authenticates, discovers tools, and queries that exact span through MCP.
- `frontend-http` checks build identity, editor/worker/frame headers, and setup Markdown.

## How to get to it (user POV)

- Send requests to the installed public `/v1`, `/v2`, and `/ui-api` routes.
- Connect an MCP client to `/mcp` using a project-scoped API key with `project:read`.
- Open the frontend and project setup documents through the same public service.

## Driving it with pytest and public HTTP

For local checks, complete Launch through the public service forward and run
Doctor. Run only the selected blocks below. All use this credential setup:

```bash
export LOGFIRE_PUBLIC_HOST="localhost:$VERIFY_PORT"
export LOGFIRE_PUBLIC_URL="$LOGFIRE_BASE_URL"
META_FRONTEND_TOKEN="$(kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted \
  get secret logfire-tokens -o jsonpath='{.data.logfire-meta-frontend-token}' \
  | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.buffer.read()).decode())')"
export META_FRONTEND_TOKEN
```

For a frontend route or CSP change:

```bash
uv run --directory tests/integration pytest -v --tb=short test_frontend_contracts.py \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/frontend-http.log"
test "${PIPESTATUS[0]}" -eq 0
```

For API routing or authentication changes, select these existing cases as relevant:

```bash
uv run --directory tests/integration pytest -v --tb=short \
  test_routes.py test_auth.py::test_oidc_discovery test_auth.py::test_dex_jwks \
  test_auth.py::test_token_endpoint_rejects_bad_credentials \
  test_auth.py::test_device_flow_mints_a_working_user_token \
  test_mcp.py::test_mcp_requires_bearer_auth \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/auth-routes.log"
test "${PIPESTATUS[0]}" -eq 0
```

For ingest and query changes, select `test_ingest.py`, `test_query.py`, or
`test_sdk_roundtrip.py` as relevant. `test_release_contracts.py` covers SQL formats,
problem responses, immediate SSE, and metric storage.

### Stored telemetry through MCP

Run the existing case through this installation's `/mcp` endpoint. It needs no Maildev:

```bash
uv run --directory tests/integration pytest -v -s --tb=short \
  test_mcp.py::test_mcp_authenticated_query \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/mcp-telemetry.log"
test "${PIPESTATUS[0]}" -eq 0
```

The case creates a project, ingests a unique OTLP span, and mints an API key with
`project:read`. An SDK read token does not authenticate MCP. The client initializes
MCP, discovers `query_run`, and queries the generated trace ID with `LIMIT 2`.
Its UTC window covers five minutes before and after ingestion.
Require exactly one row with the generated trace and span IDs, service `helm-it-mcp`,
and span name `integration-span`. Empty rows retry for at most 90 seconds.
Tool errors and unexpected rows fail immediately. The `-s` option preserves the
endpoint, public host, project, SQL, time window, exact rows, and case result in the log.

### Authentication and transport boundaries

CI checks Dex discovery and JWKS, rejection of bad credentials, project tokens, and
MCP bearer authentication. Its device flow uses a meta session token for approval
and exercises the resulting SDK token. Maildev checks invitation delivery and
enumeration-safe login-code requests. These tests do not complete Dex password,
email-code, or external SSO login. The [browser recipe](setup.md) uses the
self-hosted token entrypoint.

CI sends HTTP requests through a port-forward to `logfire-service`. It renders
an Ingress but installs no ingress controller. Its `gateway.tls=true` checks
generated HTTPS public URLs. Because `ingress.tls=false` and `inClusterTls.enabled=false`,
this run does not prove a TLS handshake or certificate verification.

Choose additional runtime proof only for a changed boundary:

- For Dex or SSO changes, use a disposable identity through the actual login and
  callback. Verify the resulting session can read its project, then sign out.
  Metadata and a meta-token session cannot replace that login flow.
- For ingress or Gateway changes, install the selected controller in the owned
  test cluster and use its actual hostname and listener. Exercise the changed
  frontend, auth callback, ingest, query, or MCP route through that entry point.
- For public TLS changes, use the HTTPS listener with a trusted certificate or
  an explicit test CA. Require the handshake, correct hostname, and affected
  authenticated route to work. Do not bypass verification with `curl -k`.
- For in-cluster TLS changes, follow [In-cluster HTTPS](../../../../charts/logfire/README.md#in-cluster-https)
  with the selected certificate mode. Prove the affected service call accepts
  its trusted certificate and rejects an untrusted one. Unit tests for service
  addresses and secret names do not establish this runtime behavior.

### Focused mail checks

For mail cases, also forward Maildev:

```bash
kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted \
  port-forward --address 127.0.0.1 svc/logfire-maildev :1080 \
  > "$VERIFY_RUNTIME/maildev-port-forward.log" 2>&1 &
VERIFY_MAILDEV_PID=$!
for attempt in {1..30}; do
  maildev_port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+).*$/\1/p' \
    "$VERIFY_RUNTIME/maildev-port-forward.log" | head -n 1)
  [[ -n "$maildev_port" ]] && break
  kill -0 "$VERIFY_MAILDEV_PID" || exit 1
  sleep 2
done
test -n "$maildev_port" || exit 1
export MAILDEV_BASE_URL="http://127.0.0.1:$maildev_port"
uv run --directory tests/integration pytest -v --tb=short test_mail.py \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/mail-tests.log"
test "${PIPESTATUS[0]}" -eq 0
```

Run `unset META_FRONTEND_TOKEN` after the selected cases. The skill's
[cleanup](../SKILL.md#cleanup) stops both owned forwards.

## Gotchas

- Public hostname and URL assertions must match the installed gateway values.
- The OAuth client metadata case expects CI's fixed public hostname. Use its
  matching values rather than the browser loopback overrides.
- The current metric fixture uses numeric JSON `asInt`. String-valued OTLP JSON
  int64 points are a known pinned-image compatibility gap; do not claim both forms pass.
