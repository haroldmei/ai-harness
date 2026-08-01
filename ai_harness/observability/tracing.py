"""Tracing — the same spans, now exportable.

Deferred from Phase 0 deliberately: JSON logs suffice below ~10 runs a day, and the §26 trigger
is volume or an existing tracing backend. Because the span *fields* were fixed in Phase 0, this
is an exporter rather than a redesign — ``round`` and ``attempt`` were already separate axes and
the prompt was already a digest.

Two contracts carry over unchanged, and both are tested:

* **no prompt text is exported** — ``template_id``, ``sha256`` and a byte count, never the
  content (§21.4);
* **telemetry never fails the caller** — an unreachable collector degrades to the local JSON
  sink, because losing a span is survivable and losing a run is not.

OpenTelemetry is an optional extra. The import is lazy and its absence is a supported state, so
the default test suite stays hermetic and a host without the SDK still runs.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any
from uuid import uuid4

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.observability.logging import JsonlSpanSink, Logger
from ai_harness.schemas.telemetry import Span

SERVICE_NAME = "ai-harness"


@dataclass
class Tracer:
    """Creates spans and hands them to whichever sinks are configured."""

    sinks: list[Any] = field(default_factory=list)
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)
    run_id: str = ""

    @contextmanager
    def span(
        self,
        name: str,
        *,
        state: str | None = None,
        round_: int = 0,
        attempt: int = 1,
        parent_id: str | None = None,
        **attributes: str,
    ) -> Iterator[Span]:
        """Time a block and emit a span for it, whatever happens inside."""
        started = self.clock.monotonic()
        span = Span(
            span_id=uuid4().hex[:16],
            run_id=self.run_id,
            parent_id=parent_id,
            name=name,
            state=state,
            round=round_,
            attempt=attempt,
            started_at=self.clock.now(),
            attributes=dict(attributes),
        )
        try:
            yield span
            span = span.model_copy(update={"outcome": span.outcome or "ok"})
        except Exception as exc:
            span = span.model_copy(update={"outcome": f"error:{type(exc).__name__}"})
            raise
        finally:
            self.emit(span.model_copy(update={"duration_s": self.clock.monotonic() - started}))

    def emit(self, span: Span) -> None:
        """Fan out to every sink. A sink that raises is skipped, never propagated."""
        for sink in self.sinks:
            try:
                sink.emit(span)
            except Exception:
                self.logger.warning("span sink failed", sink=type(sink).__name__)


@dataclass
class OTelSpanSink:
    """Exports to an OpenTelemetry collector, if the SDK is installed and reachable.

    Constructed lazily and defensively: a missing SDK, a missing collector or a broken exporter
    all degrade to ``enabled = False``, and the caller keeps its local JSON sink.
    """

    endpoint: str = ""
    service_name: str = SERVICE_NAME
    enabled: bool = False
    _tracer: Any = None
    fallback: JsonlSpanSink | None = None

    def __post_init__(self) -> None:
        self.enabled = self._start()

    def _start(self) -> bool:
        try:  # pragma: no cover — exercised only where the optional extra is installed
            from opentelemetry import trace
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
            from opentelemetry.sdk.resources import Resource
            from opentelemetry.sdk.trace import TracerProvider
            from opentelemetry.sdk.trace.export import BatchSpanProcessor
        except ImportError:
            return False
        try:  # pragma: no cover
            provider = TracerProvider(resource=Resource.create({"service.name": self.service_name}))
            exporter = (
                OTLPSpanExporter(endpoint=self.endpoint) if self.endpoint else OTLPSpanExporter()
            )
            provider.add_span_processor(BatchSpanProcessor(exporter))
            trace.set_tracer_provider(provider)
            self._tracer = trace.get_tracer(self.service_name)
        except Exception:
            return False
        return True

    def emit(self, span: Span) -> None:
        if not self.enabled or self._tracer is None:
            if self.fallback is not None:
                self.fallback.emit(span)
            return
        try:  # pragma: no cover
            with self._tracer.start_as_current_span(span.name) as otel_span:
                for key, value in attributes_for(span).items():
                    otel_span.set_attribute(key, value)
        except Exception:
            if self.fallback is not None:
                self.fallback.emit(span)


def attributes_for(span: Span) -> dict[str, str | int | float]:
    """The span's fields as OTel attributes.

    ``round`` and ``attempt`` stay separate: collapsing them loses the distinction between "the
    fourth review round" and "the fourth attempt at the first round", which is the difference
    between a change that keeps being rejected and a provider that keeps timing out.
    """
    values: dict[str, str | int | float] = {
        "harness.run_id": span.run_id,
        "harness.state": span.state or "",
        "harness.round": span.round,
        "harness.attempt": span.attempt,
        "harness.outcome": span.outcome or "",
        "harness.template_id": span.template_id or "",
        "harness.prompt_sha256": span.prompt_sha256 or "",
        "harness.prompt_bytes": span.prompt_bytes or 0,
        "llm.provider": span.provider or "",
        "llm.model": span.model or "",
        "llm.input_tokens": span.input_tokens,
        "llm.output_tokens": span.output_tokens,
        "llm.cache_read_tokens": span.cache_read_tokens,
        "llm.cost_usd": float(span.usd),
    }
    values.update({f"harness.{k}": v for k, v in span.attributes.items()})
    return values


def total_cost(spans: list[Span]) -> Decimal:
    return sum((s.usd for s in spans), Decimal(0))
