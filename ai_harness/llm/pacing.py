"""Pacing: timeouts derived from a measured rate, and one call on the card at a time.

Every timeout, retry and cadence default in this harness was chosen against a hosted model that
answers in seconds. Locally a single REVIEW of a large diff takes minutes, an IMPLEMENT takes
longer, and there is exactly one card — so two workers do not double throughput, they halve it
and add swap thrash on top.

Two mechanisms, and both are deliberately mechanical rather than advisory:

* :class:`Pace` turns a *measured* decode and prefill rate into a per-call timeout. One 900-second
  default for every call is either far too generous for a triage or far too tight for a whole-file
  IMPLEMENT, and being wrong in the second direction throws away generation that was nearly done.

* :class:`SerialEngine` wraps an engine so every call takes the GPU slot first. Admission then
  does not depend on an operator starting exactly one worker, which is the kind of invariant that
  holds until the evening somebody starts a second one to "catch up".

`selfhost.md` claims the LLM is not the bottleneck — that the GPU is idle during most of the
cycle. That is a claim about this repository's gate suite, so :class:`Pace` records what it
actually observes and the run report states it, rather than either believing or dismissing it.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import Outcome
from ai_harness.llm.engines.protocol import Completion, Engine, EngineCapabilities, LLMRequest
from ai_harness.llm.serving.residency import ModelSlot

PESSIMISTIC_DECODE_TPS = 30.0
"""`selfhost.md`'s lower bound for a 4-bit 30B model. A planning number until #81 measures this
box; the primary model is a mixture-of-experts with ~3B active parameters, so the real figure may
be several times higher — and every default here scales with it rather than being re-chosen."""

PESSIMISTIC_PREFILL_TPS = 2_000.0

TIMEOUT_MARGIN = 2.0
"""Double the predicted time. Generation rate varies with the KV cache's occupancy and with
whatever else is on the card; a timeout that fires at 1.1x the estimate discards work that was
nearly finished, which is the expensive direction to be wrong in."""

MIN_TIMEOUT_S = 60.0


@dataclass
class Pace:
    """What this box actually does, and what follows from it."""

    decode_tps: float = PESSIMISTIC_DECODE_TPS
    prefill_tps: float = PESSIMISTIC_PREFILL_TPS
    measured: bool = False
    """False until `agent serving bench` has run. Recorded, because a number derived from a
    guess should be visibly derived from a guess."""

    def seconds_for(self, *, prompt_tokens: int, max_tokens: int) -> float:
        prefill = prompt_tokens / max(self.prefill_tps, 1.0)
        decode = max_tokens / max(self.decode_tps, 1.0)
        return prefill + decode

    def timeout_for(self, *, prompt_tokens: int, max_tokens: int) -> float:
        predicted = self.seconds_for(prompt_tokens=prompt_tokens, max_tokens=max_tokens)
        return max(predicted * TIMEOUT_MARGIN, MIN_TIMEOUT_S)

    @classmethod
    def from_bench(cls, *, decode_tps: float, prefill_tps: float) -> Pace:
        return cls(decode_tps=decode_tps, prefill_tps=prefill_tps, measured=True)


@dataclass
class GpuTime:
    """How much of a state's wall-clock was actually generation.

    This is the number `selfhost.md`'s central claim turns on, and it is cheap to keep: the
    client already times every call, and the state already knows when it started. What it buys is
    an answer to "would a faster card help" that is not a guess.
    """

    clock: Clock = field(default_factory=SystemClock)
    busy_s: dict[str, float] = field(default_factory=dict)
    wall_s: dict[str, float] = field(default_factory=dict)

    def record_call(self, state: str, seconds: float) -> None:
        self.busy_s[state] = self.busy_s.get(state, 0.0) + seconds

    def record_state(self, state: str, seconds: float) -> None:
        self.wall_s[state] = self.wall_s.get(state, 0.0) + seconds

    def busy_fraction(self, state: str) -> float:
        wall = self.wall_s.get(state, 0.0)
        return self.busy_s.get(state, 0.0) / wall if wall > 0 else 0.0

    def summary(self) -> dict[str, dict[str, float]]:
        return {
            state: {
                "wall_s": round(wall, 1),
                "gpu_s": round(self.busy_s.get(state, 0.0), 1),
                "gpu_busy_fraction": round(self.busy_fraction(state), 3),
            }
            for state, wall in sorted(self.wall_s.items())
        }


@dataclass
class SerialEngine:
    """An engine that holds the GPU slot for the duration of every call.

    Wrapping rather than asking: an admission rule the caller must remember is an admission rule
    that stops holding the first time somebody adds a call site. A second in-flight call cannot
    get the lease, so it is refused as back-pressure — which is the same answer the server would
    give by OOM-ing, arrived at without losing the first call's work.
    """

    inner: Engine
    slot: ModelSlot
    run_id: str = ""
    holder: str = "worker"
    name: str = "local"
    capabilities: EngineCapabilities = field(default_factory=EngineCapabilities)
    gpu_time: GpuTime | None = None
    state: str = ""
    clock: Clock = field(default_factory=SystemClock)

    def __post_init__(self) -> None:
        self.name = self.inner.name
        self.capabilities = self.inner.capabilities

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        acquired = await self.slot.acquire(request.model, run_id=self.run_id, holder=self.holder)
        if acquired.is_err:
            assert acquired.error is not None
            return Outcome.of(acquired.error)

        handle = acquired.unwrap()
        started = self.clock.monotonic()
        try:
            return await self.inner.complete(request)
        finally:
            if self.gpu_time is not None:
                self.gpu_time.record_call(self.state, self.clock.monotonic() - started)
            await self.slot.release(handle)
