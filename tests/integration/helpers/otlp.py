from __future__ import annotations

import os
import time


def _ids() -> tuple[str, str, int, int]:
    trace_id = os.urandom(16).hex()
    span_id = os.urandom(8).hex()
    end_nanos = time.time_ns()
    start_nanos = end_nanos - 1_000_000
    return trace_id, span_id, start_nanos, end_nanos


def trace_payload(service_name: str) -> dict:
    trace_id, span_id, start_nanos, end_nanos = _ids()
    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [
                        {"key": "service.name", "value": {"stringValue": service_name}},
                    ],
                },
                "scopeSpans": [
                    {
                        "scope": {"name": "helm-integration"},
                        "spans": [
                            {
                                "traceId": trace_id,
                                "spanId": span_id,
                                "name": "integration-span",
                                "kind": 1,
                                "startTimeUnixNano": str(start_nanos),
                                "endTimeUnixNano": str(end_nanos),
                                "attributes": [],
                                "status": {},
                            },
                        ],
                    },
                ],
            },
        ],
    }


def metric_payload(service_name: str) -> dict:
    now_nanos = time.time_ns()
    start_nanos = now_nanos - 1_000_000
    return {
        "resourceMetrics": [
            {
                "resource": {
                    "attributes": [
                        {"key": "service.name", "value": {"stringValue": service_name}},
                    ],
                },
                "scopeMetrics": [
                    {
                        "scope": {"name": "helm-integration"},
                        "metrics": [
                            {
                                "name": "helm.integration.counter",
                                "sum": {
                                    "isMonotonic": True,
                                    "aggregationTemporality": 2,
                                    "dataPoints": [
                                        {
                                            "asInt": "1",
                                            "startTimeUnixNano": str(start_nanos),
                                            "timeUnixNano": str(now_nanos),
                                            "attributes": [],
                                        },
                                    ],
                                },
                            },
                        ],
                    },
                ],
            },
        ],
    }


def log_payload(service_name: str) -> dict:
    now_nanos = time.time_ns()
    return {
        "resourceLogs": [
            {
                "resource": {
                    "attributes": [
                        {"key": "service.name", "value": {"stringValue": service_name}},
                    ],
                },
                "scopeLogs": [
                    {
                        "scope": {"name": "helm-integration"},
                        "logRecords": [
                            {
                                "timeUnixNano": str(now_nanos),
                                "observedTimeUnixNano": str(now_nanos),
                                "severityNumber": 9,
                                "severityText": "INFO",
                                "body": {"stringValue": "integration log"},
                                "attributes": [],
                            },
                        ],
                    },
                ],
            },
        ],
    }
