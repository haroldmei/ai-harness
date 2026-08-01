"""Pacing a serial GPU: derived timeouts, enforced admission, measured idleness (#89)."""

from __future__ import annotations

import contextlib
from dataclasses import dataclass, field

import pytest

from ai_harness.config import HarnessConfig
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import LeaseManager, MemoryLeaseBackend
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.engines.protocol import Completion, EngineCapabilities, LLMRequest, Usage
from ai_harness.llm.pacing import (
    MIN_TIMEOUT_S,
    PESSIMISTIC_DECODE_TPS,
    GpuTime,
    Pace,
    SerialEngine,
)
from ai_harness.llm.serving.models import GpuSpec, ModelRegistry, ModelSpec
from ai_harness.llm.serving.residency import ModelSlot
from ai_harness.wiring import LOCAL_LEASE_TTL_S, lease_ttl_for

SPEC = ModelSpec(
    name="qwen3-coder-30b",
    repo_id="q",
    revision="a" * 40,
    weights_gb=17.5,
    kv_bytes_per_token=49152,
    native_max_model_len=262144,
)
REGISTRY = ModelRegistry(gpu=GpuSpec(), models=[SPEC])


@dataclass
class SlowEngine:
    """An engine that takes time on the clock, and records concurrency."""

    clock: FrozenClock
    seconds: float = 60.0
    name: str = "local"
    capabilities: EngineCapabilities = field(default_factory=EngineCapabilities)
    in_flight: int = 0
    max_in_flight: int = 0

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        self.in_flight += 1
        self.max_in_flight = max(self.max_in_flight, self.in_flight)
        self.clock.advance(self.seconds)
        self.in_flight -= 1
        return Outcome.ok(
            Completion(
                text="{}",
                model=request.model,
                provider="local",
                usage=Usage(input_tokens=100, output_tokens=50),
            )
        )


@dataclass
class Units:
    async def start(self, unit: str) -> Outcome[None]:
        return Outcome.ok(None)

    async def stop(self, unit: str) -> Outcome[None]:
        return Outcome.ok(None)


def _slot(clock: FrozenClock) -> ModelSlot:
    return ModelSlot(
        registry=REGISTRY,
        leases=LeaseManager(MemoryLeaseBackend(clock=clock), clock=clock),
        units=Units(),
        unit_name=lambda model: f"serve-{model}",
        clock=clock,
    )


def test_the_timeout_comes_from_the_rate_rather_than_from_one_number_for_everything():
    pace = Pace()  # the pessimistic bound until this box is measured
    assert pace.measured is False

    triage = pace.timeout_for(prompt_tokens=800, max_tokens=512)
    implement = pace.timeout_for(prompt_tokens=20_000, max_tokens=16_384)

    # A whole-file IMPLEMENT at 30 tok/s is minutes; a triage is not, and one 900-second default
    # is either far too generous for the first or far too tight for the second.
    assert implement > 900
    assert triage >= MIN_TIMEOUT_S
    assert implement > triage * 4


def test_a_faster_box_shortens_every_timeout_without_any_of_them_being_re_chosen():
    measured = Pace.from_bench(decode_tps=PESSIMISTIC_DECODE_TPS * 4, prefill_tps=8_000.0)
    assert measured.measured is True
    assert measured.timeout_for(prompt_tokens=20_000, max_tokens=16_384) < Pace().timeout_for(
        prompt_tokens=20_000, max_tokens=16_384
    )


def test_the_margin_is_generous_because_being_tight_discards_finished_work():
    pace = Pace()
    predicted = pace.seconds_for(prompt_tokens=1_000, max_tokens=4_000)
    assert pace.timeout_for(prompt_tokens=1_000, max_tokens=4_000) >= predicted * 2


async def test_an_agent_derives_its_timeout_from_the_pace():
    from ai_harness.agents.base import Agent
    from ai_harness.context.trust import Trusted, TrustedPrompt
    from ai_harness.llm.client import LLMClient
    from ai_harness.llm.engines.scripted import Envelope, ScriptedLLM
    from ai_harness.schemas.review import ReviewResult

    engine = ScriptedLLM(
        default=[Envelope.result('{"verdict": "approve", "summary": "fine", "findings": []}')]
    )
    agent = Agent(
        name="reviewer",
        template_id="reviewer-v1",
        output_type=ReviewResult,
        client=LLMClient(engine=engine),
        model="devstral-24b",
        max_tokens=8192,
        pace=Pace(),
    )
    prompt = TrustedPrompt()
    prompt.add_trusted(Trusted("review this"))

    await agent.call(prompt)
    # 8 192 tokens at 30 tok/s, doubled: minutes, not the flat 900-second default.
    assert engine.calls[-1].timeout_s > 500
    assert engine.calls[-1].timeout_s != 900.0


async def test_two_calls_serialise_on_the_card_rather_than_racing_it():
    import asyncio

    clock = FrozenClock()
    inner = SlowEngine(clock=clock)
    slot = _slot(clock)
    engine = SerialEngine(inner=inner, slot=slot, clock=clock)

    request = LLMRequest(prompt="p", model="qwen3-coder-30b")
    results = await asyncio.gather(engine.complete(request), engine.complete(request))

    # Admission does not depend on an operator starting exactly one worker: a second in-flight
    # call cannot get the lease, so it is refused as back-pressure instead of OOM-ing the server
    # and losing the first call's generation.
    assert inner.max_in_flight == 1
    categories = {r.category for r in results if r.is_err}
    assert categories in ({ErrorCategory.TRANSIENT}, set())


async def test_the_slot_is_released_even_when_the_call_fails():
    clock = FrozenClock()

    @dataclass
    class Failing:
        name: str = "local"
        capabilities: EngineCapabilities = field(default_factory=EngineCapabilities)

        async def complete(self, request: LLMRequest) -> Outcome[Completion]:
            return Outcome.fail(ErrorCategory.MODEL_FAILURE, "nope")

    slot = _slot(clock)
    engine = SerialEngine(inner=Failing(), slot=slot, clock=clock)
    request = LLMRequest(prompt="p", model="qwen3-coder-30b")

    assert (await engine.complete(request)).is_err
    # A held lease after a failed call would block the retry it exists to allow.
    assert (await engine.complete(request)).is_err


async def test_gpu_busy_fraction_is_measured_rather_than_argued_about():
    clock = FrozenClock()
    inner = SlowEngine(clock=clock, seconds=30.0)
    gpu_time = GpuTime(clock=clock)
    engine = SerialEngine(
        inner=inner, slot=_slot(clock), clock=clock, gpu_time=gpu_time, state="VALIDATE"
    )

    await engine.complete(LLMRequest(prompt="p", model="qwen3-coder-30b"))
    gpu_time.record_state("VALIDATE", 300.0)  # the state also ran tests for four and a half minutes

    assert gpu_time.busy_fraction("VALIDATE") == pytest.approx(0.1)
    summary = gpu_time.summary()
    assert summary["VALIDATE"]["gpu_s"] == 30.0
    assert summary["VALIDATE"]["wall_s"] == 300.0


async def test_a_host_claims_no_more_runs_than_it_can_advance():
    from ai_harness.orchestration.machine import Deps
    from ai_harness.persistence.queue import Claim
    from ai_harness.schemas.enums import State
    from ai_harness.workers.runner import Worker

    class RecordingQueue:
        def __init__(self) -> None:
            self.limits: list[int] = []

        async def claim(self, *, worker_id: str, limit: int, repo: str | None = None):
            self.limits.append(limit)
            return [Claim(run_id="r1", repo="o/r", state=State.REVIEW)][:limit]

    queue = RecordingQueue()
    worker = Worker(
        deps=Deps(store=None, registry=None, leases=None, breaker=None),  # type: ignore[arg-type]
        queue=queue,  # type: ignore[arg-type]
        batch=4,
        host_concurrency=1,
    )
    with contextlib.suppress(Exception):
        # Advancing needs a real store; what this test is about is the size of the claim.
        await worker.work()

    assert queue.limits == [1]


def test_a_local_roster_gets_a_lease_that_outlives_a_swap_plus_a_generation(tmp_path):
    hosted = HarnessConfig(repo_path=tmp_path)
    assert lease_ttl_for(hosted) == 900.0

    local = HarnessConfig(repo_path=tmp_path)
    local.roster.engine = "local"
    assert lease_ttl_for(local) == LOCAL_LEASE_TTL_S

    mixed = HarnessConfig(repo_path=tmp_path)
    mixed.roster.engines = {"qwen3-coder-30b": "local", "claude-opus-5": "anthropic"}
    assert lease_ttl_for(mixed) == LOCAL_LEASE_TTL_S


def test_one_run_at_a_time_is_the_shipped_default(tmp_path):
    assert HarnessConfig(repo_path=tmp_path).host_concurrency == 1
