#!/usr/bin/env python3
"""Check that repeated Dex rendering preserves output and user values."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


repo_root = Path(__file__).resolve().parent.parent
chart = repo_root / "charts/logfire"

with tempfile.TemporaryDirectory() as directory:
    probe = Path(directory)
    templates = probe / "templates"
    templates.mkdir()
    (probe / "Chart.yaml").write_text(
        "apiVersion: v2\nname: logfire\nversion: 0.0.0\n"
    )
    shutil.copyfile(chart / "values.yaml", probe / "values.yaml")
    for helper in (chart / "templates").glob("_helpers*.tpl"):
        shutil.copyfile(helper, templates / helper.name)
    (templates / "probe.yaml").write_text('''\
{{- $before := index .Values "logfire-dex" "config" | toJson -}}
{{- $first := include "logfire.dexConfig" . -}}
{{- $second := include "logfire.dexConfig" . -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: dex-render-probe
data:
  before: {{ $before | quote }}
  first: {{ $first }}
  second: {{ $second }}
  after: {{ index .Values "logfire-dex" "config" | toJson | quote }}
''')
    scenarios = {
        "default": {},
        "user clients and connectors": {
            "staticClients": [
                {"id": "another-client", "name": "Another client", "secret": "test"}
            ],
            "connectors": [
                {"id": "test", "type": "oidc", "name": "Test", "config": {"issuer": "https://idp.example.com"}}
            ],
        },
    }
    for name, config in scenarios.items():
        overlay = probe / "overlay.json"
        overlay.write_text(json.dumps({"logfire-dex": {"config": config}}))
        rendered = subprocess.run(
            ["helm", "template", "dex-probe", str(probe), "-f", str(overlay)],
            check=True, text=True, capture_output=True,
        ).stdout
        data = {}
        for line in rendered.splitlines():
            key, separator, value = line.strip().partition(": ")
            if separator and key in {"before", "first", "second", "after"}:
                data[key] = json.loads(value)
        if set(data) != {"before", "first", "second", "after"}:
            raise SystemExit(f"{name}: incomplete probe output")
        if data["first"] != data["second"]:
            raise SystemExit(f"{name}: repeated Dex rendering changed the configuration")
        if data["before"] != data["after"]:
            raise SystemExit(f"{name}: Dex rendering changed the user's values")
        print(f"PASS {name}: identical renders and unchanged user values")
