from __future__ import annotations

import base64
import gzip
import json
import os
import time
import uuid


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


def firehose_delivery(service_name: str, message: str) -> tuple[str, bytes, dict[str, str]]:
    """An Amazon Data Firehose delivery of one CloudWatch Logs event.

    CloudWatch Logs gzips each subscription message before Firehose adds it to a
    record, and Firehose sends endpoint parameters as common attributes.
    Returns the request ID that the acknowledgement must echo, the gzip body,
    and the headers without the access key.
    """
    now_ms = time.time_ns() // 1_000_000
    data_message = {
        "messageType": "DATA_MESSAGE",
        "owner": "123456789012",
        "logGroup": "/helm/integration",
        "logStream": "helm-it",
        "subscriptionFilters": ["helm-it"],
        "logEvents": [{"id": "1", "timestamp": now_ms, "message": message}],
    }
    request_id = str(uuid.uuid4())
    body = {
        "requestId": request_id,
        "timestamp": now_ms,
        "records": [
            {"data": base64.b64encode(gzip.compress(json.dumps(data_message).encode())).decode()},
        ],
    }
    headers = {
        "Content-Type": "application/json",
        "Content-Encoding": "gzip",
        "X-Amz-Firehose-Protocol-Version": "1.0",
        "X-Amz-Firehose-Request-Id": request_id,
        "X-Amz-Firehose-Common-Attributes": json.dumps(
            {"commonAttributes": {"service.name": service_name}}
        ),
    }
    return request_id, gzip.compress(json.dumps(body).encode()), headers
