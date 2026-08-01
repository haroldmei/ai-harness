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

from dataclasses import dataclass, field, replace
from decimal import Decimal
from typing import Protocol
from uuid import uuid4

from ai_harness.kernel.budget import CircuitBreaker, CostEvent, CostTracker, RunSpend
from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.ids import digest
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.kernel.retry import BreakerRegistry, call_with_retry
from ai_harness.kernel.tokens import CalibratedCounter
from ai_harness.llm.engines.protocol import Completion, Engine, LLMRequest
from ai_harness.llm.engines.routing import FALLBACK_WORTHY
from ai_harness.llm.pricing import is_self_hosted, price, rate_for
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
    fallback_limit: int = 3
    """How many hosted fallbacks one run may take before the local failure escalates (L7)."""
    decode_tps: float = 30.0
    """Tokens per second of generation, used to reserve model-time before dispatch. The
    pessimistic bound until #81 measures this box."""
    prefill_tps: float = 2000.0
    counter: CalibratedCounter | None = None
    """Calibrated from every completion's reported prompt tokens. No call is made to learn the
    model's characters-per-token ratio; the calls the harness already makes report it."""

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
            reserved = self.breaker.reserve(
                run, self.estimate(request), self.estimate_seconds(request)
            )
            if reserved.is_err:
                assert reserved.error is not None
                return Outcome.of(reserved.error)
            reservation = reserved.unwrap()

        # L7: a run gets an allowance of hosted fallbacks, and once it is spent the local
        # failure surfaces as an escalation rather than as more spending. The switch is set here
        # because this is where the run is known; the router only knows models.
        dispatched = request
        allowance_spent = (
            run is not None and self.fallback_limit >= 0 and run.fallbacks >= self.fallback_limit
        )
        if allowance_spent and request.allow_fallback:
            dispatched = replace(request, allow_fallback=False)

        started = self.clock.monotonic()
        outcome = await call_with_retry(
            lambda: self.engine.complete(dispatched),
            dependency=f"model:{self.engine.name}",
            clock=self.clock,
            breakers=self.breakers,
        )
        duration = self.clock.monotonic() - started
        fallback = _fallback_of(outcome)
        if fallback is not None and run is not None:
            run.fallbacks += 1

        usd = Decimal(0)
        completion: Completion | None = None
        if outcome.is_ok:
            completion = outcome.unwrap()
            if self.counter is not None:
                self.counter.calibrate(
                    characters=len(request.system) + len(request.prompt),
                    tokens=completion.usage.input_tokens,
                )
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
                # Only our own card counts: a hosted provider's capacity is not the resource
                # this box runs out of, and charging their latency to our GPU ceiling would
                # make a fallback look like local congestion.
                gpu_seconds=duration if is_self_hosted(completion.provider) else 0.0,
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
            fallback=fallback,
        )

        if outcome.is_err and allowance_spent:
            error = outcome.error
            assert error is not None
            if error.category in FALLBACK_WORTHY:
                # The local model failed in a way a hosted one could have survived, and this run
                # has already used its allowance. Escalating here is the honest end: continuing
                # would turn "no per-token cost" into a number nobody agreed to.
                return Outcome.fail(
                    ErrorCategory.NEEDS_HUMAN,
                    f"the local model is unavailable and this run has already used its "
                    f"{self.fallback_limit} hosted fallback(s)",
                    remedy=(
                        f"the underlying failure was: {error.message}. Fix the serving stack, or "
                        "raise roster.max_fallbacks_per_run deliberately — it is the ceiling that "
                        "keeps a local run from silently becoming a paid one"
                    ),
                    details={
                        "underlying": str(error.category),
                        "fallbacks_used": run.fallbacks if run else 0,
                    },
                )
        return outcome

    def estimate(self, request: LLMRequest) -> Decimal:
        """A pre-call upper bound: the prompt as written plus ``max_tokens`` of output."""
        rate, _known = rate_for(self.engine.name, request.model, self.clock.now())
        approx_input_tokens = Decimal(max(len(request.prompt) + len(request.system), 1)) / 4
        return (
            approx_input_tokens * rate.input_ + Decimal(request.max_tokens) * rate.output
        ) / Decimal(1_000_000)

    def estimate_seconds(self, request: LLMRequest) -> float:
        """A pre-call upper bound on generation time, from the measured rates.

        The defaults are `selfhost.md`'s pessimistic bound rather than a measurement, which is
        the safe direction: over-estimating reserves too much time and denies early, and
        under-estimating is how a run discovers its ceiling after spending it. `agent serving
        bench` replaces them with this box's real numbers (#81).
        """
        if not is_self_hosted(self.engine.name):
            return 0.0
        prompt_chars = len(request.prompt) + len(request.system)
        prefill = (prompt_chars / 4) / max(self.prefill_tps, 1.0)
        decode = request.max_tokens / max(self.decode_tps, 1.0)
        return prefill + decode

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
        fallback: dict[str, str] | None = None,
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
                attributes=_attributes(completion, fallback),
            )
            self.sink.emit(span)
        except Exception:  # telemetry never fails the caller — the shell's contract, kept
            return


def _fallback_of(outcome: Outcome[Completion]) -> dict[str, str] | None:
    """The router marks a completion it did not get from the primary engine. Nothing else does."""
    if outcome.is_err:
        return None
    marker = outcome.unwrap().raw.get("fallback")
    return {str(k): str(v) for k, v in marker.items()} if isinstance(marker, dict) else None


def _attributes(completion: Completion | None, fallback: dict[str, str] | None) -> dict[str, str]:
    """Span attributes that are cheap to compute and expensive to reconstruct later.

    The prefix-cache hit ratio is the local analogue of provider prompt caching. There is no
    vendor bill to save, so the saving is wall-clock — and on a serial GPU wall-clock is the
    binding constraint. Recording it is what makes the tier ordering of §17.3 falsifiable rather
    than merely plausible.
    """
    attributes: dict[str, str] = {}
    if fallback:
        attributes.update({f"fallback.{key}": str(value) for key, value in fallback.items()})
    if completion is not None and completion.usage.input_tokens > 0:
        ratio = completion.usage.cache_read_tokens / completion.usage.input_tokens
        attributes["cache.hit_ratio"] = f"{ratio:.3f}"
    return attributes
