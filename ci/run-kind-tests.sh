#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
namespace=${LOGFIRE_TEST_NAMESPACE:-logfire-restricted}
release=lf

for command in kubectl helm curl uv python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is missing: $command" >&2
    exit 1
  fi
done

context=$(kubectl config current-context)
case "$context" in
  kind-*) ;;
  *) echo "Refusing to run upgrade tests outside Kind: $context" >&2; exit 1 ;;
esac
if [[ ! "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [[ ${#namespace} -gt 63 ]]; then
  echo "LOGFIRE_TEST_NAMESPACE must be a valid namespace name" >&2
  exit 1
fi
kubectl --context "$context" get namespace "$namespace" >/dev/null

values=(-f "$repo_root/charts/logfire/ci/ci-values.yaml")
if [[ -n "${LOGFIRE_TEST_VALUES:-}" ]]; then
  if [[ ! -f "$LOGFIRE_TEST_VALUES" ]]; then
    echo "LOGFIRE_TEST_VALUES must name a values file" >&2
    exit 1
  fi
  values+=(-f "$LOGFIRE_TEST_VALUES")
fi

rc_values=("${values[@]}")
if [[ -n "${LOGFIRE_TEST_RC_VALUES:-}" ]]; then
  if [[ ! -f "$LOGFIRE_TEST_RC_VALUES" ]]; then
    echo "LOGFIRE_TEST_RC_VALUES must name a values file" >&2
    exit 1
  fi
  rc_values+=(-f "$LOGFIRE_TEST_RC_VALUES")
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/logfire-kind-tests.XXXXXX")
state_file="$tmp_dir/upgrade-state.json"
forward_pids=()
restore_combined=false

stop_forwards() {
  local pid
  for pid in ${forward_pids[@]+"${forward_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  forward_pids=()
}

upgrade_current() {
  local split=$1
  helm upgrade "$release" "$repo_root/charts/logfire" \
    --kube-context "$context" --namespace "$namespace" \
    --reset-values "${rc_values[@]}" \
    --set "logfire-ff-query-worker.enabled=$split" \
    --wait --wait-for-jobs --timeout 10m
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  stop_forwards
  if [[ "$restore_combined" == true ]]; then
    echo "Restoring combined query mode after the interrupted split-worker test"
    upgrade_current false
    if [[ $? -ne 0 ]]; then
      echo "Failed to restore combined query mode" >&2
      status=1
    fi
  fi
  unset META_FRONTEND_TOKEN
  rm -rf "$tmp_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

baseline_chart=${LOGFIRE_TEST_BASELINE_CHART:-}
if [[ -n "$baseline_chart" ]]; then
  if [[ ! -f "$baseline_chart" || "$baseline_chart" != *.tgz ]]; then
    echo "LOGFIRE_TEST_BASELINE_CHART must name a local chart archive" >&2
    exit 1
  fi
else
  helm repo add pydantic https://charts.pydantic.dev/ --force-update
  helm repo update pydantic
  helm pull pydantic/logfire --version 0.14.0 --destination "$tmp_dir"
  baseline_chart="$tmp_dir/logfire-0.14.0.tgz"
fi
baseline_version=$(helm show chart "$baseline_chart" | awk '/^version:/ { gsub(/"/, "", $2); print $2; exit }')
if [[ "$baseline_version" != 0.14.0 ]]; then
  echo "The baseline archive must contain chart version 0.14.0" >&2
  exit 1
fi

start_forward() {
  local service=$1
  local remote_port=$2
  local log_file="$tmp_dir/$service-port-forward.log"
  local pid deadline port
  kubectl --context "$context" --namespace "$namespace" \
    port-forward --address 127.0.0.1 "svc/$service" ":$remote_port" >"$log_file" 2>&1 &
  pid=$!
  forward_pids+=("$pid")
  deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$log_file" >&2
      echo "Port-forward exited for $service" >&2
      return 1
    fi
    port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+).*$/\1/p' "$log_file" | head -n 1)
    if [[ -n "$port" ]]; then
      forwarded_port=$port
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for the $service port-forward" >&2
  return 1
}

restart_forwards() {
  stop_forwards
  start_forward logfire-service 8080
  export LOGFIRE_BASE_URL="http://127.0.0.1:$forwarded_port"
  start_forward logfire-maildev 1080
  export MAILDEV_BASE_URL="http://127.0.0.1:$forwarded_port"
  curl --fail --silent --show-error --output /dev/null \
    --connect-timeout 2 --max-time 5 --retry 300 --retry-delay 2 \
    --retry-max-time 600 --retry-all-errors "$LOGFIRE_BASE_URL/ui-api/platform-config/"
  curl --fail --silent --show-error --output /dev/null \
    --connect-timeout 2 --max-time 5 --retry 300 --retry-delay 2 \
    --retry-max-time 600 --retry-all-errors "$MAILDEV_BASE_URL/api/email"
}

export LOGFIRE_TEST_NAMESPACE="$namespace"
export LOGFIRE_TEST_KUBE_CONTEXT="$context"
META_FRONTEND_TOKEN=$(kubectl --context "$context" --namespace "$namespace" \
  get secret logfire-tokens -o jsonpath='{.data.logfire-meta-frontend-token}' \
  | python3 -c 'import base64, sys; sys.stdout.write(base64.b64decode(sys.stdin.buffer.read()).decode())')
if [[ -z "$META_FRONTEND_TOKEN" ]]; then
  echo "The prepared logfire-tokens secret has no frontend token" >&2
  exit 1
fi
export META_FRONTEND_TOKEN

echo "Installing the 0.14.0 baseline in $context/$namespace"
helm upgrade --install "$release" "$baseline_chart" \
  --kube-context "$context" --namespace "$namespace" \
  --reset-values "${values[@]}" --set logfire-ff-query-worker.enabled=false \
  --wait --wait-for-jobs --timeout 10m
restart_forwards
uv run --directory "$repo_root/tests/integration" python upgrade_probe.py seed "$state_file"

echo "Upgrading to the current chart in combined query mode"
stop_forwards
upgrade_current false
restart_forwards
uv run --directory "$repo_root/tests/integration" python upgrade_probe.py check "$state_file"
uv run --directory "$repo_root/tests/integration" pytest -v --tb=short

echo "Testing the optional split query worker"
stop_forwards
restore_combined=true
upgrade_current true
restart_forwards
uv run --directory "$repo_root/tests/integration" python upgrade_probe.py check "$state_file"
uv run --directory "$repo_root/tests/integration" pytest -v --tb=short \
  test_query.py test_release_contracts.py test_features.py -k "query or sql_format"

echo "Restoring combined query mode"
stop_forwards
upgrade_current false
restore_combined=false
restart_forwards
uv run --directory "$repo_root/tests/integration" python upgrade_probe.py check "$state_file"
echo "Kind upgrade and integration tests passed"
