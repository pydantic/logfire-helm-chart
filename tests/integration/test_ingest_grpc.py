from __future__ import annotations

import os

import pytest
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor, SpanExportResult
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

pytestmark = pytest.mark.anyio


async def test_grpc_traces_endpoint_accepts_payload(write_token: str) -> None:
    endpoint = os.environ.get("LOGFIRE_GRPC_ENDPOINT", "localhost:8444")

    provider = TracerProvider(
        resource=Resource.create({"service.name": "helm-it-ingest-grpc"})
    )
    memory = InMemorySpanExporter()
    provider.add_span_processor(SimpleSpanProcessor(memory))
    with provider.get_tracer("helm-it").start_as_current_span("helm-it-grpc-span"):
        pass
    spans = memory.get_finished_spans()
    assert spans

    exporter = OTLPSpanExporter(
        endpoint=endpoint,
        insecure=True,
        headers=(("authorization", write_token),),
        timeout=30,
    )
    try:
        assert exporter.export(spans) is SpanExportResult.SUCCESS
    finally:
        exporter.shutdown()
