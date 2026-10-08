from __future__ import annotations

import json
import os
import subprocess

import pytest


def test_disabled_autoscalers_use_requested_replicas() -> None:
    context = os.environ.get("LOGFIRE_TEST_KUBE_CONTEXT")
    namespace = os.environ.get("LOGFIRE_TEST_NAMESPACE")
    if not context or not namespace:
        pytest.skip("Deployment checks need the Kind runner's explicit context and namespace")
    result = subprocess.run(
        ["kubectl", "--context", context, "get", "deployment/logfire-ff-query-api", "-n", namespace, "-o", "json"],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    deployment = json.loads(result.stdout)
    assert deployment["spec"]["replicas"] == 2, deployment
    assert deployment["status"]["readyReplicas"] == 2, deployment
