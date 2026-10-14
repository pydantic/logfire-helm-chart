---
name: verify-logfire-chart
description: Verify Logfire Helm chart installs, stable upgrades, public APIs, and browser flows against the pinned platform images in an isolated local Kind cluster. Use for chart configuration, image, migration, routing, CSP, or topology changes.
---

# Verify the Logfire chart

Read the [feature map](features/README.md) and select the entries affected by the
change. Reuse `ci/run-kind-tests.sh` and `tests/integration/`; do not replace
deployment proof with rendered-template assertions. Documentation changes need
link and command checks. Run a real instance when a changed recipe needs proof.

## Launch

Run commands from the chart repository in Bash. Check dependencies before startup:

```bash
set -o pipefail
for tool in docker kind kubectl helm uv python3 curl; do
  command -v "$tool" || exit 1
done
docker info >/dev/null
helm version --short
python3 --version
```

Use Helm `4.2.0`, the version in `.github/workflows/pr.yaml`. Version `4.2.1`
hangs in Kind uninstall waits. Python must be at least `3.12`. The helpers declare
their dependencies through `uv` script metadata. A browser tool must already be
available for browser checks; use its accessibility snapshots and console/network
inspection. Do not install a browser tool to hide an unavailable capability.

Create a private runtime directory outside the repository:

```bash
umask 077
export CHART_ROOT="$(git rev-parse --show-toplevel)"
export VERIFY_SKILL="$CHART_ROOT/.cursor/skills/verify-logfire-chart"
export VERIFY_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/logfire-chart-verify.XXXXXX")"
export KUBECONFIG="$VERIFY_RUNTIME/kubeconfig"
mkdir "$VERIFY_RUNTIME/evidence"
git rev-parse HEAD > "$VERIFY_RUNTIME/evidence/source.txt"
git status --short >> "$VERIFY_RUNTIME/evidence/source.txt"
```

The cluster needs pull access to the platform registry for the current and
baseline images. Supply a private Docker `config.json` with inline registry
authentication. A host credential-helper reference cannot run inside the Kind
node. If you already have a configured `gcloud` identity with pull access, create
the file without printing its token:

```bash
command -v gcloud || exit 1
python3 - <<'PY'
import base64
import json
import os
from pathlib import Path
import subprocess

token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
if not token:
    raise SystemExit("gcloud returned no token")
auth = base64.b64encode(f"oauth2accesstoken:{token}".encode()).decode()
path = Path(os.environ["VERIFY_RUNTIME"]) / "pull-config.json"
path.write_text(json.dumps({"auths": {"us-docker.pkg.dev": {"auth": auth}}}))
path.chmod(0o600)
PY
```

For another existing authentication method, place its Docker config at
`$VERIFY_RUNTIME/pull-config.json`. Do not change the user's active cloud identity.

Prepare a fresh cluster and the four CI Secrets:

```bash
local_values=()
if [[ -f charts/logfire/values.local.yaml ]]; then
  local_values=(--values "$CHART_ROOT/charts/logfire/values.local.yaml")
fi
uv run --script "$VERIFY_SKILL/scripts/prepare-kind.py" prepare \
  --runtime "$VERIFY_RUNTIME" \
  --registry-config "$VERIFY_RUNTIME/pull-config.json" "${local_values[@]}"
export VERIFY_CONTEXT="$(python3 -c \
  'import json,os; print(json.load(open(os.environ["VERIFY_RUNTIME"]+"/ownership.json"))["context"])')"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add jetstack https://charts.jetstack.io
helm dependency build charts/logfire
uv sync --directory tests/integration
```

The helper creates a unique cluster and a dedicated kubeconfig. It matches CI's
namespace labels, `enforce=baseline` and `warn=restricted`.
It applies the optional lighter `values.local.yaml` after `fixtures/values.kind.yaml`.
It then forces two query API replicas for the disabled-autoscaler integration contract.
It records overlay hashes without
copying values into the evidence directory. Never commit the local overlay.

For install, image, startup, migration, or topology changes, run the canonical suite
from [Deployment and upgrade](features/deployment.md). It installs chart `0.14.0`
before the current chart and leaves the current installation ready for inspection.
Always use a fresh cluster for that suite. An older binary must not reuse an
already upgraded database.

For a focused browser or HTTP recipe, install the current chart directly:

```bash
helm upgrade --install lf charts/logfire \
  --kube-context "$VERIFY_CONTEXT" --namespace logfire-restricted \
  -f charts/logfire/ci/ci-values.yaml -f "$VERIFY_RUNTIME/values.yaml" \
  --wait --wait-for-jobs --timeout 10m \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/install.log"
test "${PIPESTATUS[0]}" -eq 0
```

For browser checks, configure a free loopback port and match the API origin:

```bash
export VERIFY_PORT=8080
python3 - <<'PY'
import os
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", int(os.environ["VERIFY_PORT"])))
PY
helm upgrade lf charts/logfire \
  --kube-context "$VERIFY_CONTEXT" --namespace logfire-restricted \
  -f charts/logfire/ci/ci-values.yaml -f "$VERIFY_RUNTIME/values.yaml" \
  --set ingress.enabled=false --set gateway.tls=false \
  --set "gateway.hostnames[0]=localhost:$VERIFY_PORT" \
  --wait --wait-for-jobs --timeout 10m \
  2>&1 | tee "$VERIFY_RUNTIME/evidence/browser-upgrade.log"
test "${PIPESTATUS[0]}" -eq 0
kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted \
  port-forward --address 127.0.0.1 svc/logfire-service "$VERIFY_PORT:8080" \
  > "$VERIFY_RUNTIME/port-forward.log" 2>&1 &
VERIFY_FORWARD_PID=$!
export LOGFIRE_BASE_URL="http://localhost:$VERIFY_PORT"
curl --fail --silent --show-error --retry 30 --retry-delay 2 --retry-connrefused \
  "$LOGFIRE_BASE_URL/ui-api/platform-config/" \
  > "$VERIFY_RUNTIME/evidence/platform-config.json"
```

Keep this shell's port-forward PID for cleanup. The pinned frontend uses
`appConfig.apiHost` to construct API URLs. A page on a different port does not
correct a mismatched `gateway.hostnames[0]`.

## Doctor

Run this read-only check before driving a feature, and whenever the target looks
wrong. It must identify this run's context and the current installed chart:

```bash
test "$(kubectl config current-context)" = "$VERIFY_CONTEXT"
kubectl --context "$VERIFY_CONTEXT" get nodes
helm list --kube-context "$VERIFY_CONTEXT" -n logfire-restricted -o json \
  | tee "$VERIFY_RUNTIME/evidence/releases.json"
kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted get deploy,sts,pods -o wide \
  | tee "$VERIFY_RUNTIME/evidence/workloads.txt"
kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted get pods -o json \
  > "$VERIFY_RUNTIME/evidence/pods.json"
if [[ -n "${LOGFIRE_BASE_URL:-}" ]]; then
  curl --fail --silent --show-error -D "$VERIFY_RUNTIME/evidence/version-headers.txt" \
    "$LOGFIRE_BASE_URL/version.json" > "$VERIFY_RUNTIME/evidence/version.json"
  curl --fail --silent --show-error "$LOGFIRE_BASE_URL/config.1.js" \
    > "$VERIFY_RUNTIME/evidence/frontend-config.js"
fi
```

Require Ready nodes and current application workloads, a `deployed` release,
the current `Chart.yaml` version and `appVersion`, and two ready query API replicas.
Completed migration Jobs do not need a Ready pod condition. Compare each running
platform image and its image ID with the chart pin and any declared image override.
Investigate Pending pods, failed Jobs, restart loops, or mismatched images before
continuing. When an owned public forward is active, require `/version.json` to
return `200` and `Cache-Control: no-store`. The canonical runner removes its own
forwards, so complete the browser launch step before the HTTP part of Doctor.
For browser work, require `selfHosted: true` and the configured local `apiHost` in
`config.1.js`. Do not archive Secrets or token-bearing responses.

## Drive

Follow the selected [feature recipes](features/README.md). For browser fixtures,
read the configured disposable meta token into a private file without printing it:

```bash
kubectl --context "$VERIFY_CONTEXT" -n logfire-restricted get secret logfire-tokens \
  -o jsonpath='{.data.logfire-meta-frontend-token}' \
  | python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))' \
  > "$VERIFY_RUNTIME/meta-token"
uv run --script "$VERIFY_SKILL/scripts/seed-browser.py" \
  --base-url "$LOGFIRE_BASE_URL" --browser-origin "$LOGFIRE_BASE_URL" \
  --token-file "$VERIFY_RUNTIME/meta-token" \
  --output "$VERIFY_RUNTIME/browser.json"
cp "$VERIFY_RUNTIME/browser-evidence.json" "$VERIFY_RUNTIME/evidence/"
```

The seeder creates an isolated project through real APIs and ingests one synthetic
OTLP chat span. It queries the exact trace and span before saving a custom panel
and enhanced view. It makes no model request. Use the private receipt's
`first_login_url` through the normal self-hosted entrypoint. Never print that URL
or copy it into an evidence file. Capture screenshots only after the app removes
the token fragment. Use `browser-evidence.json` for shareable fixture identity.

## Evidence

Store proof in `$VERIFY_RUNTIME/evidence`. Capture the user action and resulting
state, including screenshots, accessibility snapshots, relevant network/console
events, command exit codes, and the exact ingested record. Inspect screenshots
before declaring success. Do not use internal setters, fabricated browser storage,
mocked service responses, or a successful HTTP header check as proof of a browser
flow. A production API may create fixtures; the browser must still exercise the
feature being verified.

Record the selected feature IDs, chart commit and dirty state, chart/image versions,
overlay hashes, observed results, artifact paths, and skipped checks with reasons.
Distinguish an intended negative security error from an unrelated application error.
Keep private login and token files outside the evidence directory. Redact any token
in copied commands, browser URLs, response bodies, or network exports.

## Cleanup

Run cleanup after successful and failed attempts. Save diagnostics before teardown.
Close only the browser tabs or isolated browser session this run opened. Stop the
port-forward PID this shell started; never kill by process name:

```bash
if [[ -n "${VERIFY_FORWARD_PID:-}" ]]; then
  kill "$VERIFY_FORWARD_PID" 2>/dev/null || true
  wait "$VERIFY_FORWARD_PID" 2>/dev/null || true
fi
uv run --script "$VERIFY_SKILL/scripts/prepare-kind.py" cleanup --runtime "$VERIFY_RUNTIME"
rm -f "$VERIFY_RUNTIME/meta-token" "$VERIFY_RUNTIME/browser.json" "$VERIFY_RUNTIME/pull-config.json"
unset META_FRONTEND_TOKEN KUBECONFIG LOGFIRE_BASE_URL
test -s "$VERIFY_RUNTIME/evidence/source.txt"
find "$VERIFY_RUNTIME/evidence" -type f
```

If the shell state is lost, identify the owned port-forward by its exact context,
namespace, and port before stopping it. The helper deletes only the cluster named
in this run's ownership receipt and its private configuration. It preserves the
receipt and proof artifacts. Confirm the cluster is absent with `kind get clusters`
and that the recorded evidence still exists. Do not remove the whole runtime
directory or prune shared Docker images, containers, volumes, or caches.

## Helpers

- `uv run --script "$VERIFY_SKILL/scripts/prepare-kind.py" prepare ...` prepares the isolated Kind
  cluster, CI Secrets, and merged local values as shown above.
- `uv run --script "$VERIFY_SKILL/scripts/prepare-kind.py" cleanup --runtime ...` tears down that
  cluster and private configuration.
- `uv run --script "$VERIFY_SKILL/scripts/seed-browser.py" --base-url ... --browser-origin ... --token-file ... --output ...`
  prepares the bounded real browser fixture as shown above.
- `fixtures/` contains source to paste into the real panel and enhanced-view editors.
  Follow [Renderers](features/renderers.md) for positive and negative checks.

When the chart or platform images change, update the affected feature recipes and
re-run them. The pstack `maintain-verification-skill` skill can audit this map
against the source and a running installation.
