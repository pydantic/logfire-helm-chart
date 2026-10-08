from __future__ import annotations

import json
import os
import subprocess


def test_disabled_autoscalers_use_requested_replicas() -> None:
    namespace = os.environ.get("LOGFIRE_K8S_NAMESPACE", "logfire-restricted")
    result = subprocess.run(
        ["kubectl", "get", "deployment/logfire-ff-query-api", "-n", namespace, "-o", "json"],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    deployment = json.loads(result.stdout)
    assert deployment["spec"]["replicas"] == 2, deployment
    assert deployment["status"]["readyReplicas"] == 2, deployment
