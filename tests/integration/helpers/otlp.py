from __future__ import annotations

import os
import time

from opentelemetry.proto.collector.profiles.v1development.profiles_service_pb2 import (
    ExportProfilesServiceRequest,
)
from opentelemetry.proto.common.v1.common_pb2 import AnyValue, KeyValue
from opentelemetry.proto.profiles.v1development.profiles_pb2 import (
    Function,
    KeyValueAndUnit,
    Line,
    Link,
    Location,
    Mapping,
    Profile,
    ProfilesDictionary,
    ResourceProfiles,
    Sample,
    ScopeProfiles,
    Stack,
    ValueType,
)
from opentelemetry.proto.resource.v1.resource_pb2 import Resource


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


def profiles_payload(service_name: str, values: tuple[int, ...]) -> bytes:
    """One CPU profile with a sample per value, all on the same one-frame stack.

    The pinned ingest decodes the current `v1development` schema, which keeps
    strings, functions, locations, and stacks in a shared dictionary.
    """
    request = ExportProfilesServiceRequest(
        dictionary=ProfilesDictionary(
            mapping_table=[Mapping()],
            location_table=[Location(), Location(lines=[Line(function_index=1, line=42)])],
            function_table=[Function(), Function(name_strindex=3, filename_strindex=4)],
            link_table=[Link()],
            string_table=["", "cpu", "nanoseconds", "helm_profile_work", "helm_profile.py"],
            attribute_table=[KeyValueAndUnit()],
            stack_table=[Stack(), Stack(location_indices=[1])],
        ),
        resource_profiles=[
            ResourceProfiles(
                resource=Resource(
                    attributes=[
                        KeyValue(key="service.name", value=AnyValue(string_value=service_name)),
                    ],
                ),
                scope_profiles=[
                    ScopeProfiles(
                        profiles=[
                            Profile(
                                sample_type=ValueType(type_strindex=1, unit_strindex=2),
                                samples=[Sample(stack_index=1, values=[value]) for value in values],
                                time_unix_nano=time.time_ns(),
                                duration_nano=1_000_000,
                            ),
                        ],
                    ),
                ],
            ),
        ],
    )
    return request.SerializeToString()
