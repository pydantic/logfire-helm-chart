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
                                            # The pinned server decoder drops string asInt values.
                                            "asInt": 1,
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


def exception_log_payload(service_name: str, run_id: str) -> dict:
    """A log record the issues pipeline groups into an issue.

    Grouping keys off the `logfire.exception.fingerprint` attribute (the SDK's
    exception_callback writes sha256 of its source); `exception.type` marks the
    record as an exception, and `helm.it.run` isolates the run through the
    filter alert's extra SQL filter.
    """
    now_nanos = time.time_ns()
    attributes = [
        {"key": "exception.type", "value": {"stringValue": "HelmItError"}},
        {"key": "exception.message", "value": {"stringValue": "helm integration exception"}},
        {
            "key": "exception.stacktrace",
            "value": {"stringValue": "HelmItError: helm integration exception"},
        },
        {"key": "logfire.exception.fingerprint", "value": {"stringValue": run_id}},
        {"key": "helm.it.run", "value": {"stringValue": run_id}},
    ]
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
                                "severityNumber": 17,
                                "severityText": "ERROR",
                                "body": {"stringValue": "helm integration exception"},
                                "attributes": attributes,
                            },
                        ],
                    },
                ],
            },
        ],
    }
