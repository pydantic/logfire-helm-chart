#!/usr/bin/env bash
set -euo pipefail

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

render "$tmp_dir/base" | checksums >"$tmp_dir/base-checksums"
render "$tmp_dir/version-change" | checksums >"$tmp_dir/version-checksums"

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
