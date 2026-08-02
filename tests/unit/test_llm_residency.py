"""One card, one resident model, and the bill for the difference (#85)."""

from __future__ import annotations

from dataclasses import dataclass, field

from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import LeaseManager, MemoryLeaseBackend
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.serving.models import GpuSpec, ModelRegistry, ModelSpec
from ai_harness.llm.serving.residency import GPU_SLOT_KEY, ModelSlot, ResidencyPolicy
from ai_harness.observability.logging import Logger

GPU = GpuSpec(vram_gb=24.0, reserve_gb=1.0)
QWEN = ModelSpec(
    name="qwen3-coder-30b",
    repo_id="q",
    revision="a" * 40,
    weights_gb=17.5,
    kv_bytes_per_token=49152,
    native_max_model_len=262144,
    port=8000,
)
DEVSTRAL = ModelSpec(
    name="devstral-24b",
    repo_id="d",
    revision="b" * 40,
    weights_gb=14.0,
    kv_bytes_per_token=81920,
    native_max_model_len=131072,
    port=8001,
)
REGISTRY = ModelRegistry(gpu=GPU, models=[QWEN, DEVSTRAL])


@dataclass
class FakeUnits:
    """systemd, without systemd. Tracks what is up, and can refuse to start one model."""

    running: set[str] = field(default_factory=set)
    calls: list[str] = field(default_factory=list)
    refuse: str | None = None
    load_seconds: float = 20.0
    clock: FrozenClock | None = None

    async def start(self, unit: str) -> Outcome[None]:
        self.calls.append(f"start {unit}")
        if self.refuse is not None and self.refuse in unit:
            return Outcome.fail(ErrorCategory.ENVIRONMENT, f"{unit} failed to start")
        if self.clock is not None:
            self.clock.advance(self.load_seconds)
        self.running.add(unit)
        return Outcome.ok(None)

    async def stop(self, unit: str) -> Outcome[None]:
        self.calls.append(f"stop {unit}")
        self.running.discard(unit)
        return Outcome.ok(None)


def _slot(units: FakeUnits, *, clock: FrozenClock, policy: ResidencyPolicy | None = None):
    return ModelSlot(
        registry=REGISTRY,
        leases=LeaseManager(MemoryLeaseBackend(clock=clock), clock=clock),
        units=units,
        unit_name=lambda model: f"serve-{model}",
        policy=policy or ResidencyPolicy(),
        clock=clock,
        logger=Logger(),
    )


async def test_two_models_are_never_resident_at_once():
    clock = FrozenClock()
    units = FakeUnits(clock=clock)
    slot = _slot(units, clock=clock)

    handle = (await slot.acquire("qwen3-coder-30b", run_id="r1")).unwrap()
    assert units.running == {"serve-qwen3-coder-30b"}
    await slot.release(handle)

    handle = (await slot.acquire("devstral-24b", run_id="r1")).unwrap()
    # The eviction happens before the load, in that order: starting the second model while the
    # first still holds 17 GB is the OOM this class exists to prevent.
    # Every *other* model is stopped before the load, not merely the one this object remembers
    # being resident. `self.resident` is per-process memory and residency is a fact about the
    # card: a fresh worker process (every dispatch is one) would otherwise start its model beside
    # a server it never knew about, and the new one dies on a full card.
    assert units.calls == [
        "stop serve-devstral-24b",
        "start serve-qwen3-coder-30b",
        "stop serve-qwen3-coder-30b",
        "start serve-devstral-24b",
    ]
    assert units.running == {"serve-devstral-24b"}
    assert handle.swapped and handle.swap_seconds == 20.0


async def test_a_second_call_cannot_be_in_flight_while_one_holds_the_card():
    clock = FrozenClock()
    slot = _slot(FakeUnits(clock=clock), clock=clock)

    first = (await slot.acquire("qwen3-coder-30b", run_id="r1")).unwrap()
    contended = await slot.acquire("devstral-24b", run_id="r1", holder="other")

    assert contended.category is ErrorCategory.TRANSIENT
    assert slot.resident == "qwen3-coder-30b"  # nothing was swapped under an in-flight call
    await slot.release(first)
    assert (await slot.acquire("devstral-24b", run_id="r1")).is_ok


async def test_re_acquiring_the_resident_model_costs_nothing():
    clock = FrozenClock()
    units = FakeUnits(clock=clock)
    slot = _slot(units, clock=clock)

    first = (await slot.acquire("qwen3-coder-30b", run_id="r1")).unwrap()
    await slot.release(first)
    again = (await slot.acquire("qwen3-coder-30b", run_id="r1")).unwrap()

    assert not again.swapped
    # The second acquire adds nothing: what costs is the load, and it is already loaded. The
    # leading stop belongs to the first acquire's sweep of the models it cannot see.
    assert units.calls == ["stop serve-devstral-24b", "start serve-qwen3-coder-30b"]
    assert slot.swap_count("r1") == 1


async def test_swap_seconds_are_charged_to_the_run_that_caused_them():
    clock = FrozenClock()
    units = FakeUnits(clock=clock, load_seconds=30.0)
    slot = _slot(units, clock=clock)

    for model in ("qwen3-coder-30b", "devstral-24b", "qwen3-coder-30b"):
        handle = (await slot.acquire(model, run_id="r1")).unwrap()
        await slot.release(handle)
    other = (await slot.acquire("devstral-24b", run_id="r2")).unwrap()
    await slot.release(other)

    assert slot.swap_seconds("r1") == 90.0
    assert slot.swap_seconds("r2") == 30.0
    assert slot.swap_count("r1") == 3


async def test_the_swap_cap_escalates_rather_than_continuing_to_pay():
    clock = FrozenClock()
    slot = _slot(FakeUnits(clock=clock), clock=clock, policy=ResidencyPolicy(max_swaps_per_run=2))

    for model in ("qwen3-coder-30b", "devstral-24b"):
        handle = (await slot.acquire(model, run_id="r1")).unwrap()
        await slot.release(handle)

    third = await slot.acquire("qwen3-coder-30b", run_id="r1")
    assert third.category is ErrorCategory.NEEDS_HUMAN
    assert third.error is not None and third.error.details["cap"] == 2


async def test_a_model_that_cannot_be_served_escalates_and_never_self_reviews():
    clock = FrozenClock()
    units = FakeUnits(clock=clock, refuse="devstral")
    slot = _slot(units, clock=clock)

    handle = (await slot.acquire("qwen3-coder-30b", run_id="r1")).unwrap()
    await slot.release(handle)
    failed = await slot.acquire("devstral-24b", run_id="r1")

    assert failed.category is ErrorCategory.NEEDS_HUMAN
    assert failed.error is not None
    assert "roster refusal" in (failed.error.remedy or "")
    # And the card is free again, so the next attempt is not blocked by a lease nobody holds.
    assert slot.resident is None
    assert (await slot.acquire("qwen3-coder-30b", run_id="r1")).is_ok


async def test_thrashing_is_named_in_a_warning_rather_than_silently_paid_for():
    clock = FrozenClock()
    warnings: list[tuple[str, dict[str, object]]] = []

    class Recording(Logger):
        def warning(self, message: str, **fields: object) -> None:  # type: ignore[override]
            warnings.append((message, fields))

    slot = _slot(FakeUnits(clock=clock), clock=clock, policy=ResidencyPolicy(thrash_swaps=3))
    slot.logger = Recording()

    for model in ("qwen3-coder-30b", "devstral-24b") * 3:
        handle = (await slot.acquire(model, run_id="r1")).unwrap()
        await slot.release(handle)

    assert any("thrashing" in message for message, _ in warnings)
    alternation = next(fields["alternation"] for message, fields in warnings if "thrash" in message)
    assert "qwen3-coder-30b -> devstral-24b" in str(alternation)


async def test_the_lease_ttl_outlives_a_swap_plus_a_generation():
    # A lease that expires mid-generation is a lost run, and generation is now minutes.
    assert ResidencyPolicy().lease_ttl_s >= 1800.0
    clock = FrozenClock()
    slot = _slot(FakeUnits(clock=clock), clock=clock)
    handle = (await slot.acquire("qwen3-coder-30b", run_id="r1")).unwrap()
    assert handle.lease.key == GPU_SLOT_KEY
    assert handle.lease.ttl_s == ResidencyPolicy().lease_ttl_s
