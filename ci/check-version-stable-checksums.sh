#!/usr/bin/env bash
set -euo pipefail
# PyYAML is available in chart-testing's Python environment.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

cp -R "$repo_root/charts/logfire" "$tmp_dir/base"
cp -R "$tmp_dir/base" "$tmp_dir/version-change"

sed -i.bak 's/^version:.*/version: 999.999.999/' "$tmp_dir/version-change/Chart.yaml"
rm "$tmp_dir/version-change/Chart.yaml.bak"

render() {
  local chart=$1
  shift
  helm template checksum-test "$chart" \
    --set-string adminEmail=test@example.com \
    --set-string objectStore.uri=s3://test-bucket \
    --set existingSecret.enabled=true \
    --set-string existingSecret.name=logfire-secrets \
    --set postgresSecret.enabled=true \
    --set-string postgresSecret.name=postgres-secrets \
    "$@"
}

checksums() {
  awk '/checksum\/(config|ff-config|service-config):/ { print }' | sort
}

render "$tmp_dir/base" >"$tmp_dir/base.yaml"
render "$tmp_dir/version-change" >"$tmp_dir/version-change.yaml"
checksums <"$tmp_dir/base.yaml" >"$tmp_dir/base-checksums"
checksums <"$tmp_dir/version-change.yaml" >"$tmp_dir/version-checksums"

if [[ ! -s "$tmp_dir/base-checksums" ]]; then
  echo "No configuration checksum annotations were rendered" >&2
  exit 1
fi

if ! diff -u "$tmp_dir/base-checksums" "$tmp_dir/version-checksums"; then
  echo "A chart-version-only change altered workload configuration checksums" >&2
  exit 1
fi

render "$tmp_dir/base" --set-string redisDsn=redis://changed:6379 | checksums >"$tmp_dir/config-change-checksums"

if cmp -s "$tmp_dir/base-checksums" "$tmp_dir/config-change-checksums"; then
  echo "A configuration change did not alter workload configuration checksums" >&2
  exit 1
fi

render "$tmp_dir/base" --set-string 'otel_collector.exporter.headers.helm\.sh/chart=before' | checksums >"$tmp_dir/header-before-checksums"
render "$tmp_dir/base" --set-string 'otel_collector.exporter.headers.helm\.sh/chart=after' | checksums >"$tmp_dir/header-after-checksums"

if cmp -s "$tmp_dir/header-before-checksums" "$tmp_dir/header-after-checksums"; then
  echo "A user configuration key named helm.sh/chart was excluded from workload configuration checksums" >&2
  exit 1
fi

for chart in base version-change; do
  render "$tmp_dir/$chart" \
    --set-json 'logfire-dex.config.staticClients=[{"id":"test-client","name":"Test","secret":"test","redirectURIs":["https://client.example.com/callback"]}]' \
    --set-json 'logfire-dex.config.connectors=[{"id":"test","type":"oidc","name":"Test","config":{"issuer":"https://idp.example.com"}}]' \
    >"$tmp_dir/$chart-custom.yaml"
done

python3 - "$tmp_dir" <<'PY'
import base64
import hashlib
from pathlib import Path
import sys
import yaml

for custom in (False, True):
    snapshots = []
    for chart in ("base", "version-change"):
        name = chart + ("-custom" if custom else "")
        resources = {}
        for raw in (Path(sys.argv[1]) / f"{name}.yaml").read_text().split("\n---\n"):
            resource = yaml.safe_load(raw)
            if resource:
                resources[resource["kind"], resource["metadata"]["name"]] = resource, raw
        deployment, _ = resources["Deployment", "logfire-dex"]
        pod = deployment["spec"]["template"]
        secret_name = next(volume["secret"]["secretName"] for volume in pod["spec"]["volumes"] if volume["name"] == "config")
        secret, raw = resources["Secret", secret_name]
        encoded = secret["data"]["config.yaml"]
        config = yaml.safe_load(base64.b64decode(encoded, validate=True))
        assert isinstance(config, dict) and config, f"{name}: Dex config is empty or invalid"
        backend, _ = resources["Deployment", "logfire-backend"]
        backend_client = next(env["value"] for env in backend["spec"]["template"]["spec"]["containers"][0]["env"] if env["name"] == "DEX_CLIENT_ID")
        assert backend_client, f"{name}: Backend Dex client ID is empty"
        assert [client["id"] for client in config["staticClients"]] == [backend_client] + (["test-client"] if custom else []), f"{name}: Dex clients were lost or duplicated"
        assert [connector["id"] for connector in config["connectors"]] == (["test"] if custom else []), f"{name}: Dex connectors were lost or duplicated"
        if custom:
            assert config["connectors"][0]["config"]["issuer"] == "https://idp.example.com"
        normalized = "\n".join(line for line in raw.rstrip("\n").splitlines() if not line.startswith(("# Source:", "---", "    helm.sh/chart:"))) + "\n"
        checksum = pod["metadata"]["annotations"]["checksum/config"]
        assert checksum == hashlib.sha256(normalized.encode()).hexdigest(), f"{name}: Dex checksum does not match its rendered Secret"
        snapshots.append((encoded, checksum))
    assert snapshots[0] == snapshots[1], "A chart-version-only change altered Dex configuration"
    if custom:
        assert snapshots[0][0] != default_snapshot[0], "Custom Dex settings did not change its configuration"
        assert snapshots[0][1] != default_snapshot[1], "Custom Dex settings did not change its checksum"
    else:
        default_snapshot = snapshots[0]
    print(f"PASS real Dex Secret, checksum, and version stability: {'custom' if custom else 'default'}")
PY
