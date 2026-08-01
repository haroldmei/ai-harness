"""Provider-agnostic dispatch: budget-aware, breaker-aware, always instrumented.

Everything that costs money goes through here, in this order:

1. **reserve** an estimate against the run's ceiling — a denial parks the run *before* the
   call rather than discovering the overspend afterwards (W3);
2. dispatch through the retry policy and the dependency breaker, so a provider outage defers
   every run at zero cost instead of each burning four backoff cycles;
3. **price** the usage (or trust a provider-reported cost) and settle the reservation;
4. emit a span carrying tokens, cost, duration, ``round`` and ``attempt`` as separate axes, and
   a prompt *digest* — ``template_id``, ``sha256``, byte count. Never the text (§21.4).

The span contract is the shell's, verbatim: **telemetry never fails the caller.**
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal
from typing import Protocol
from uuid import uuid4

from ai_harness.kernel.budget import CircuitBreaker, CostEvent, CostTracker, RunSpend
from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.ids import digest
from ai_harness.kernel.outcome import Outcome
from ai_harness.kernel.retry import BreakerRegistry, call_with_retry
from ai_harness.llm.engines.protocol import Completion, Engine, LLMRequest
from ai_harness.llm.pricing import price, rate_for
from ai_harness.schemas.telemetry import Span


class SpanSink(Protocol):
    """Where spans go. The default drops them; Phase 5 swaps in an OTel exporter."""

    def emit(self, span: Span) -> None: ...


class NullSink:
    def emit(self, span: Span) -> None:
        return None


@dataclass
class LLMClient:
    """One engine, wrapped in the machinery that makes it safe to call unattended."""

    engine: Engine
    tracker: CostTracker = field(default_factory=CostTracker)
    breaker: CircuitBreaker | None = None
    breakers: BreakerRegistry = field(default_factory=BreakerRegistry)
    clock: Clock = field(default_factory=SystemClock)
    sink: SpanSink = field(default_factory=NullSink)

    async def complete(
        self,
        request: LLMRequest,
        *,
        run: RunSpend | None = None,
        state: str | None = None,
        round_: int = 0,
        attempt: int = 1,
    ) -> Outcome[Completion]:
        reservation = None
        if self.breaker is not None and run is not None:
            reserved = self.breaker.reserve(run, self.estimate(request))
            if reserved.is_err:
                assert reserved.error is not None
                return Outcome.of(reserved.error)
            reservation = reserved.unwrap()

        started = self.clock.monotonic()
        outcome = await call_with_retry(
            lambda: self.engine.complete(request),
            dependency=f"model:{self.engine.name}",
            clock=self.clock,
            breakers=self.breakers,
        )
        duration = self.clock.monotonic() - started

        usd = Decimal(0)
        completion: Completion | None = None
        if outcome.is_ok:
            completion = outcome.unwrap()
            usd = price(
                completion.usage,
                provider=completion.provider,
                model=completion.model,
                at=self.clock.now(),
            )

        event = None
        if run is not None and completion is not None:
            event = CostEvent(
                run_id=run.run_id,
                repo=run.repo,
                state=state or "",
                provider=completion.provider,
                model=completion.model,
                usd=usd,
                input_tokens=completion.usage.input_tokens,
                output_tokens=completion.usage.output_tokens,
                cache_read_tokens=completion.usage.cache_read_tokens,
                cache_write_tokens=completion.usage.cache_write_tokens,
                template_id=request.template_id,
            )
        if self.breaker is not None and reservation is not None:
            self.breaker.settle(reservation, event)
        elif event is not None:
            self.tracker.record(event)

        self._emit(
            request=request,
            outcome=outcome,
            completion=completion,
            usd=usd,
            duration=duration,
            run=run,
            state=state,
            round_=round_,
            attempt=attempt,
        )
        return outcome

    def estimate(self, request: LLMRequest) -> Decimal:
        """A pre-call upper bound: the prompt as written plus ``max_tokens`` of output."""
        rate, _known = rate_for(self.engine.name, request.model, self.clock.now())
        approx_input_tokens = Decimal(max(len(request.prompt) + len(request.system), 1)) / 4
        return (
            approx_input_tokens * rate.input_ + Decimal(request.max_tokens) * rate.output
        ) / Decimal(1_000_000)

    def _emit(
        self,
        *,
        request: LLMRequest,
        outcome: Outcome[Completion],
        completion: Completion | None,
        usd: Decimal,
        duration: float,
        run: RunSpend | None,
        state: str | None,
        round_: int,
        attempt: int,
    ) -> None:
        try:
            prompt_material = request.system + request.prompt
            span = Span(
                span_id=uuid4().hex[:16],
                run_id=run.run_id if run else "",
                name=f"llm:{request.template_id}",
                state=state,
                round=round_,
                attempt=attempt,
                started_at=self.clock.now(),
                duration_s=duration,
                outcome="ok" if outcome.is_ok else str(outcome.category),
                provider=self.engine.name,
                model=completion.model if completion else request.model,
                input_tokens=completion.usage.input_tokens if completion else 0,
                output_tokens=completion.usage.output_tokens if completion else 0,
                cache_read_tokens=completion.usage.cache_read_tokens if completion else 0,
                cache_write_tokens=completion.usage.cache_write_tokens if completion else 0,
                usd=usd,
                template_id=request.template_id,
                prompt_sha256=digest(prompt_material),
                prompt_bytes=len(prompt_material.encode("utf-8", "replace")),
            )
            self.sink.emit(span)
        except Exception:  # telemetry never fails the caller — the shell's contract, kept
            return
