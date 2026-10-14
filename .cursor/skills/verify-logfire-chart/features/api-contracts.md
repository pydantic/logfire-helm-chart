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

Preconditions:

- The canonical CI runner covers the HTTP suite in combined query mode.
  Use its passing result for the exact PR revision when it covers the changed path.
- For focused HTTP checks, the current chart is installed and Doctor passes.
- Use this run's loopback public service port-forward from Launch.

Select the affected cases rather than the whole suite. Set the matching public
URL and disposable token for the cases that need them:

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

For MCP, ingest, query, image, or release changes, require the stored-telemetry
case. CI on the exact PR revision supplies this proof. When local MCP proof is
needed, use this run's public service forward. This command does not need Maildev:

```bash
export LOGFIRE_PUBLIC_HOST="localhost:$VERIFY_PORT"
export LOGFIRE_PUBLIC_URL="$LOGFIRE_BASE_URL"
META_FRONTEND_TOKEN="$(kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted \
  get secret logfire-tokens -o jsonpath='{.data.logfire-meta-frontend-token}' \
  | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.buffer.read()).decode())')"
export META_FRONTEND_TOKEN
uv run --directory tests/integration pytest -v -s --tb=short \
  test_mcp.py::test_mcp_authenticated_query \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/mcp-telemetry.log"
test "${PIPESTATUS[0]}" -eq 0
unset META_FRONTEND_TOKEN
```

The case creates its own project and a project-scoped API key with `project:read`.
It sends one unique span through `/v1/traces`, then initializes MCP and discovers
`query_run` through the same public installation's `/mcp` endpoint.
The SQL filters on the exact generated trace ID and uses `LIMIT 2`.
The explicit UTC time window covers five minutes before and after ingestion.
Require exactly one row with the generated trace ID and span ID, service
`helm-it-mcp`, and span name `integration-span`. An empty result retries for at
most 90 seconds. A tool error or an unexpected nonempty result fails immediately.
The command records the endpoint, project, SQL, time window, exact rows, and case result.
Keep the Doctor image/source receipt with that log. Never record tokens or auth headers.
The canonical runner repeats this case in split mode and after it restores combined mode.

Require the expected cases to be collected and pass. `test_mcp.py` proves the
authenticated MCP lifecycle and stored telemetry. `test_release_contracts.py`
covers SQL formats, problem responses, immediate SSE, and metric storage.
Record case names and results; a healthy pod alone does not prove these contracts.
Unset `META_FRONTEND_TOKEN` after the selected cases.

### Authentication and transport boundaries

CI uses the real Dex discovery, JWKS, and token endpoints. It checks discovery
metadata and rejection of bad credentials. Its device flow approves a backend
device code with the configured meta session token and uses the resulting SDK
token. It also exercises project tokens and MCP bearer authentication. Maildev
checks invitation delivery and enumeration-safe login-code requests. These checks
do not complete a Dex password login, email-code login, or external SSO connector.
The browser [login recipe](setup.md) uses the self-hosted token entrypoint.

CI sends HTTP requests through a port-forward to `logfire-service`. It renders
an Ingress but installs no ingress controller. Its `gateway.tls=true` checks
generated HTTPS public URLs; `ingress.tls=false` and `inClusterTls.enabled=false`
mean that this run does not prove a TLS handshake or certificate verification.
The OAuth client metadata case also expects CI's fixed public hostname. Run that
case with its matching values, rather than with the browser loopback overrides.

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

The bundled dependencies suffice for ordinary checks. A changed external Postgres,
Redis, or object-store connection needs focused proof of its endpoint, credentials,
and applicable TLS/IAM behavior. The CI dependency configuration does not prove
these customer-specific connections. Record an unavailable path as unverified.

### Focused mail checks

CI runs the full HTTP suite. For a changed mail path, forward Maildev as well as
the application and set the disposable token for the selected cases:

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
META_FRONTEND_TOKEN="$(kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted \
  get secret logfire-tokens -o jsonpath='{.data.logfire-meta-frontend-token}' \
  | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.buffer.read()).decode())')"
export META_FRONTEND_TOKEN
uv run --directory tests/integration pytest -v --tb=short test_mail.py \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/mail-tests.log"
test "${PIPESTATUS[0]}" -eq 0
unset META_FRONTEND_TOKEN
```

Stop `VERIFY_MAILDEV_PID` during cleanup, using the same owned-PID rules as Launch.
Use the [canonical runner](deployment.md) when a full local investigation is needed.

## Gotchas

- The suite uses real services and mutates its own disposable projects and records.
  It must not target a shared or hosted installation.
- Public hostname and URL assertions must match the installed gateway values.
- A `200` MCP health response does not prove tool authentication or query behavior.
- Header tests complement browser checks. They do not prove editor or renderer behavior.
- The current metric fixture uses numeric JSON `asInt`. String-valued OTLP JSON
  int64 points are a known pinned-image compatibility gap; do not claim both forms pass.
