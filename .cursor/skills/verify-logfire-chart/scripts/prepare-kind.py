#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["PyYAML>=6"]
# ///

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import yaml

NAMESPACE = "logfire-restricted"
PRIVATE_FILES = ("kubeconfig", "config.json", "kind.yaml", "values.yaml")


def run(*args: str, env: dict[str, str], capture: bool = False) -> str:
    result = subprocess.run(args, env=env, check=True, text=True, capture_output=capture)
    return result.stdout if capture else ""


def private_directory(path: str) -> Path:
    directory = Path(path).expanduser().resolve(strict=True)
    info = directory.stat()
    if not directory.is_dir() or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise SystemExit("The runtime directory must belong to you and have mode 0700.")
    return directory


def save_state(runtime: Path, state: dict[str, object]) -> None:
    (runtime / "ownership.json").write_text(json.dumps(state, indent=2) + "\n")


def merge_values(left: dict[str, object], right: dict[str, object]) -> dict[str, object]:
    result = copy.deepcopy(left)
    for key, value in right.items():
        previous = result.get(key)
        result[key] = merge_values(previous, value) if isinstance(previous, dict) and isinstance(value, dict) else value
    return result


def create_secret(name: str, values: dict[str, str], env: dict[str, str], context: str) -> None:
    manifest = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "namespace": NAMESPACE},
        "type": "Opaque",
        "data": {key: base64.b64encode(value.encode()).decode() for key, value in values.items()},
    }
    result = subprocess.run(
        ["kubectl", "--context", context, "create", "-f", "-"],
        env=env,
        input=json.dumps(manifest),
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise SystemExit(f"Could not create verification Secret {name}. The secret manifest is withheld.")
    print(f"Created verification Secret {name}", flush=True)


def prepare(runtime: Path, registry_config: str, values_path: str | None) -> None:
    for command in ("docker", "kind", "kubectl"):
        if shutil.which(command) is None:
            raise SystemExit(f"Required command is missing: {command}")
    if any((runtime / name).exists() for name in (*PRIVATE_FILES, "ownership.json")):
        raise SystemExit("The runtime directory contains preparation state. Use a new private directory.")

    registry = Path(registry_config).expanduser().resolve(strict=True)
    if stat.S_IMODE(registry.stat().st_mode) & 0o077:
        raise SystemExit("The registry config must be private. Set its mode to 0600.")
    registry_data = json.loads(registry.read_text())
    if not isinstance(registry_data, dict) or not isinstance(registry_data.get("auths"), dict):
        raise SystemExit("The registry config must be a Docker config with an auths object.")
    overlays = [Path(__file__).resolve().parent.parent / "fixtures" / "values.kind.yaml"]
    if values_path:
        overlays.append(Path(values_path).expanduser().resolve(strict=True))
    values: dict[str, object] = {"image": {"pullPolicy": "IfNotPresent"}}
    overlay_inputs = []
    for path in overlays:
        content = path.read_bytes()
        overlay = yaml.safe_load(content)
        if not isinstance(overlay, dict):
            raise SystemExit(f"The values file must contain a YAML mapping: {path}")
        values = merge_values(values, overlay)
        overlay_inputs.append({"path": str(path), "sha256": hashlib.sha256(content).hexdigest()})
    values = merge_values(values, {"logfire-ff-query-api": {"replicas": 2}})
    merged_values = yaml.safe_dump(values, sort_keys=False).encode()

    env = dict(os.environ, KUBECONFIG=str(runtime / "kubeconfig"))
    run("docker", "info", env=env, capture=True)
    cluster = f"logfire-verify-{secrets.token_hex(6)}"
    if cluster in run("kind", "get", "clusters", env=env, capture=True).splitlines():
        raise SystemExit("The generated cluster name already exists. Refusing to adopt it.")
    context = f"kind-{cluster}"
    state: dict[str, object] = {
        "runtime": str(runtime),
        "owner_uid": os.getuid(),
        "cluster_name": cluster,
        "context": context,
        "namespace": NAMESPACE,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "status": "creating",
        "overlay_inputs": overlay_inputs,
        "merged_values_sha256": hashlib.sha256(merged_values).hexdigest(),
    }
    save_state(runtime, state)
    (runtime / "config.json").write_text(json.dumps(registry_data) + "\n")
    (runtime / "config.json").chmod(0o600)
    (runtime / "values.yaml").write_bytes(merged_values)
    kind_config = {
        "kind": "Cluster",
        "apiVersion": "kind.x-k8s.io/v1alpha4",
        "nodes": [
            {
                "role": "control-plane",
                "extraMounts": [
                    {
                        "containerPath": "/var/lib/kubelet/config.json",
                        "hostPath": str(runtime / "config.json"),
                        "readOnly": True,
                    }
                ],
            }
        ],
    }
    (runtime / "kind.yaml").write_text(json.dumps(kind_config, indent=2) + "\n")
    print(f"Creating {cluster}. Cleanup receipt: {runtime / 'ownership.json'}", flush=True)
    run(
        "kind",
        "create",
        "cluster",
        "--name",
        cluster,
        "--config",
        str(runtime / "kind.yaml"),
        "--kubeconfig",
        env["KUBECONFIG"],
        "--wait",
        "5m",
        env=env,
    )
    if run("kubectl", "config", "current-context", env=env, capture=True).strip() != context:
        raise SystemExit("The isolated kubeconfig has an unexpected context.")
    run("kubectl", "--context", context, "wait", "--for=condition=Ready", "node", "--all", "--timeout=120s", env=env)
    run("kubectl", "--context", context, "create", "namespace", NAMESPACE, env=env)
    run(
        "kubectl",
        "--context",
        context,
        "label",
        "namespace",
        NAMESPACE,
        "pod-security.kubernetes.io/enforce=baseline",
        "pod-security.kubernetes.io/warn=restricted",
        env=env,
    )
    create_secret(
        "pg-dsns",
        {
            "postgresDsn": "postgres://postgres:postgres@logfire-postgres:5432/crud",
            "postgresFFDsn": "postgres://postgres:postgres@logfire-postgres:5432/ff",
        },
        env,
        context,
    )
    tokens = {
        key: secrets.token_hex(16)
        for key in (
            "logfire-dex-client-secret",
            "logfire-meta-write-token",
            "logfire-meta-frontend-token",
            "logfire-jwt-secret",
            "logfire-unsubscribe-secret",
            "logfire-mcp-oauth-client-secret",
        )
    }
    tokens["logfire-encryption-key"] = base64.b64encode(secrets.token_bytes(32)).decode()
    create_secret("logfire-tokens", tokens, env, context)
    create_secret(
        "logfire-admin",
        {
            "logfire-admin-password": secrets.token_hex(16),
            "logfire-admin-totp-secret": base64.b32encode(secrets.token_bytes(20)).decode().rstrip("="),
            "logfire-admin-totp-recovery-codes": json.dumps([secrets.token_hex(16)]),
            "logfire-jwt-secret": secrets.token_hex(16),
        },
        env,
        context,
    )
    create_secret(
        "logfire-gateway",
        {
            "key": base64.urlsafe_b64encode(secrets.token_bytes(32)).decode(),
            "internalSecret": secrets.token_hex(16),
        },
        env,
        context,
    )
    state["status"] = "ready"
    save_state(runtime, state)
    print(f"Prepared {context}/{NAMESPACE}. KUBECONFIG={env['KUBECONFIG']}", flush=True)


def cleanup(runtime: Path) -> None:
    state = json.loads((runtime / "ownership.json").read_text())
    cluster = state.get("cluster_name")
    if (
        state.get("runtime") != str(runtime)
        or state.get("owner_uid") != os.getuid()
        or not isinstance(cluster, str)
        or re.fullmatch(r"logfire-verify-[0-9a-f]{12}", cluster) is None
        or state.get("context") != f"kind-{cluster}"
        or state.get("namespace") != NAMESPACE
        or state.get("status") not in ("creating", "ready", "cleaned")
    ):
        raise SystemExit("The ownership receipt does not identify this verification runtime.")
    if state["status"] == "cleaned":
        for name in PRIVATE_FILES:
            (runtime / name).unlink(missing_ok=True)
        print("The owned cluster and credential files are already cleaned.")
        return
    env = dict(os.environ, KUBECONFIG=str(runtime / "kubeconfig"))
    if (runtime / "kubeconfig").exists():
        result = subprocess.run(
            ["kubectl", "config", "current-context"],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        context = result.stdout.strip()
        if context != state["context"] and (context or state["status"] == "ready"):
            raise SystemExit("The runtime kubeconfig has an unexpected context. Refusing cleanup.")
    elif state["status"] == "ready":
        raise SystemExit("The prepared runtime has lost its kubeconfig. Refusing cleanup.")
    run("kind", "delete", "cluster", "--name", cluster, "--kubeconfig", env["KUBECONFIG"], env=env)
    state["status"] = "cleaned"
    state["cleaned_at"] = datetime.now(timezone.utc).isoformat()
    save_state(runtime, state)
    for name in PRIVATE_FILES:
        (runtime / name).unlink(missing_ok=True)
    print(f"Deleted {cluster}. Evidence and ownership receipt remain in {runtime}.", flush=True)


def main() -> None:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Prepare or clean up one isolated chart verification Kind cluster.")
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--runtime", required=True)
    prepare_parser.add_argument("--registry-config", required=True)
    prepare_parser.add_argument("--values")
    cleanup_parser = commands.add_parser("cleanup")
    cleanup_parser.add_argument("--runtime", required=True)
    args = parser.parse_args()
    runtime = private_directory(args.runtime)
    if args.command == "prepare":
        prepare(runtime, args.registry_config, args.values)
    else:
        cleanup(runtime)


if __name__ == "__main__":
    main()
