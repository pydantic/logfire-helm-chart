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
- Connect an MCP client to `/mcp` using a project read token.
- Open the frontend and project setup documents through the same public service.

## Driving it with pytest and public HTTP

Preconditions:

- The canonical runner already covers this recipe in combined query mode.
- For focused HTTP checks, the current chart is installed and Doctor passes.
- Use this run's loopback public service port-forward from Launch.

Forward Maildev for the full HTTP suite and obtain the disposable configured token:

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
```

Use the port reported by this owned forward. Set the matching public URL and token:

```bash
export LOGFIRE_PUBLIC_HOST="localhost:$VERIFY_PORT"
export LOGFIRE_PUBLIC_URL="$LOGFIRE_BASE_URL"
META_FRONTEND_TOKEN="$(kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted \
  get secret logfire-tokens -o jsonpath='{.data.logfire-meta-frontend-token}' \
  | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.buffer.read()).decode())')"
export META_FRONTEND_TOKEN
uv run --directory tests/integration pytest -v --tb=short \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/http-tests.log"
test "${PIPESTATUS[0]}" -eq 0
unset META_FRONTEND_TOKEN
```

For a narrow route or CSP change, select the relevant existing file instead of
claiming the entire suite ran. For example:

```bash
uv run --directory tests/integration pytest -v --tb=short test_frontend_contracts.py \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/frontend-http.log"
test "${PIPESTATUS[0]}" -eq 0
```

For MCP, ingest, query, image, or release changes, run the stored-telemetry check.
Use this run's public service forward. This command does not need Maildev:

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
Stop `VERIFY_MAILDEV_PID` during cleanup, using the same owned-PID rules as Launch.

## Gotchas

- The suite uses real services and mutates its own disposable projects and records.
  It must not target a shared or hosted installation.
- Public hostname and URL assertions must match the installed gateway values.
- A `200` MCP health response does not prove tool authentication or query behavior.
- Header tests complement browser checks. They do not prove editor or renderer behavior.
- The current metric fixture uses numeric JSON `asInt`. String-valued OTLP JSON
  int64 points are a known pinned-image compatibility gap; do not claim both forms pass.
