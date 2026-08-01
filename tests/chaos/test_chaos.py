"""Issue #57 — the chaos suite: degradation, never a crash.

The property the shell harness earned the hard way, and the one the port must not lose: **a
crashed stage costs one tick, not the run.** Every fault below is injected deliberately, and
every assertion is about what survives — the run parks as ``DEFERRED`` or ``ESCALATED``, no
counter is lost, and nothing is done twice.

``SIGKILL`` at each checkpoint boundary is enumerated, not sampled: the interesting bug is
always at the boundary nobody thought to try.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest

from ai_harness.kernel.budget import DEFAULT_BUDGET, CircuitBreaker, CostTracker
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import LeaseManager, MemoryLeaseBackend
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.orchestration.machine import Deps, run_until_boundary
from ai_harness.orchestration.registry import Registry
from ai_harness.persistence.recorder import Recorder, record_safely
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.providers.forge.fake import FakeForge, Faults
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.enums import Disposition, RunStatus, Signal, State
from ai_harness.schemas.job import JobRequest
from ai_harness.subgraphs.base import SubgraphResult

WALK = [State.PREPARE, State.ANALYSE, State.IMPLEMENT, State.VALIDATE, State.REVIEW]


@dataclass
class Flaky:
    """A subgraph that fails in a chosen way on a chosen call."""

    state_name: str
    signal: Signal = Signal.ADVANCE
    fail_on: int = 0
    failure: Any = None
    kill_on: int = 0
    calls: int = 0
    seen: list[int] = field(default_factory=list)

    async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
        self.calls += 1
        self.seen.append(self.calls)
        if self.kill_on and self.calls == self.kill_on:
            raise KeyboardInterrupt  # stands in for SIGKILL: nothing after this runs
        if self.fail_on and self.calls == self.fail_on and self.failure is not None:
            return self.failure
        return Outcome.ok(SubgraphResult(signal=self.signal))


def _harness(tmp_path: Path) -> tuple[Any, Deps, FrozenClock]:
    clock = FrozenClock()
    store = open_sqlite(tmp_path / "chaos.db", clock=clock)
    deps = Deps(
        store=store,
        registry=Registry(),
        leases=LeaseManager(MemoryLeaseBackend(clock=clock), clock=clock),
        breaker=CircuitBreaker(DEFAULT_BUDGET, CostTracker(clock=clock), clock=clock),
        clock=clock,
    )
    for state in WALK:
        deps.registry.bind(state, Flaky(state.value))
    deps.registry.bind(State.INTEGRATE, Flaky("INTEGRATE", signal=Signal.DELIVERED))
    return store, deps, clock


async def _new_run(store: Any) -> str:
    run = await store.create(JobRequest(repo="acme/app", issue=7))
    return str(run.run_id)


# ── the kill boundary, enumerated ────────────────────────────────────────────────


@pytest.mark.parametrize("boundary", [1, 2, 3, 4, 5, 6])
async def test_a_kill_at_every_checkpoint_boundary_resumes_identically(
    tmp_path: Path, boundary: int
) -> None:
    store, deps, _clock = _harness(tmp_path)
    order = [*WALK, State.INTEGRATE]
    victim = order[boundary - 1]
    killer = Flaky(
        victim.value,
        signal=Signal.DELIVERED if victim is State.INTEGRATE else Signal.ADVANCE,
        kill_on=1,
    )
    deps.registry.bind(victim, killer)

    run_id = await _new_run(store)
    with pytest.raises(KeyboardInterrupt):
        await run_until_boundary(run_id, "worker-1", deps)

    # The worker died. Its lease is gone, the last checkpoint stands, and any other worker
    # picks the run up exactly where it was.
    killer.kill_on = 0
    status = await run_until_boundary(run_id, "worker-2", deps)

    run = await store.load(run_id)
    assert run is not None
    assert status is RunStatus.PARKED_TERMINAL
    assert run.disposition is Disposition.DELIVERED
    history = await store.checkpoints(run_id)
    assert [c.seq for c in history] == list(range(len(history))), "no gap, no duplicate"


async def test_a_dead_worker_strands_no_lease(tmp_path: Path) -> None:
    store, deps, _clock = _harness(tmp_path)
    deps.registry.bind(State.PREPARE, Flaky("PREPARE", kill_on=1))
    run_id = await _new_run(store)
    with pytest.raises(KeyboardInterrupt):
        await run_until_boundary(run_id, "worker-1", deps)

    handle = await deps.leases.acquire(f"run:{run_id}", ttl_s=60, holder="worker-2")
    assert handle is not None, "a killed worker must not hold the run hostage"


# ── injected failures ────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "category",
    [
        ErrorCategory.TRANSIENT,
        ErrorCategory.RATE_LIMITED,
        ErrorCategory.UNKNOWN,
        ErrorCategory.ENVIRONMENT,
    ],
)
async def test_a_blameless_failure_parks_and_charges_nothing(
    tmp_path: Path, category: ErrorCategory
) -> None:
    store, deps, _clock = _harness(tmp_path)
    deps.registry.bind(
        State.REVIEW,
        Flaky("REVIEW", fail_on=1, failure=Outcome.fail(category, "injected")),
    )
    run_id = await _new_run(store)
    run = await store.load(run_id)
    assert run is not None
    await store.commit_transition(
        run.model_copy(update={"state": State.REVIEW}),
        Checkpoint(run_id=run_id, seq=0, state=State.VALIDATE, next_state=State.REVIEW),
    )

    status = await run_until_boundary(run_id, "worker-1", deps)
    reloaded = await store.load(run_id)
    assert reloaded is not None
    assert status is RunStatus.DEFERRED
    assert reloaded.state is State.REVIEW
    assert reloaded.counters.review_rounds == 0


async def test_an_unreachable_database_cannot_fail_a_shell_stage(tmp_path: Path) -> None:
    """The Phase 1 guarantee, re-asserted under chaos."""
    store = open_sqlite(tmp_path / "broken.db", clock=FrozenClock())
    store.dispose()
    (tmp_path / "broken.db").write_text("not a database at all")
    result = await record_safely(
        Recorder(store=store, clock=FrozenClock()), repo="acme/app", issue=7, stage="inbox"
    )
    assert result is None


async def test_a_forge_outage_does_not_lose_the_side_effect(tmp_path: Path) -> None:
    """A dropped response is not a dropped write, and a retry must not double it."""
    forge = FakeForge(faults=Faults(drop_comment_response=True))
    forge.seed_issue(7)
    first = await forge.comment(7, "starting", key="run-1")
    assert first.is_err
    forge.faults.drop_comment_response = False
    await forge.comment(7, "starting", key="run-1")
    assert len(forge.comments[7]) == 1


async def test_a_dropped_merge_response_never_double_merges() -> None:
    forge = FakeForge(faults=Faults(drop_merge_response=True))
    mr = (await forge.create_mr(head_ref="h", base_ref="main", title="t", body="")).unwrap()
    assert (await forge.merge_mr(mr.number)).is_err
    forge.faults.drop_merge_response = False
    await forge.merge_mr(mr.number)
    assert len([m for m in forge.mrs.values() if m.merged]) == 1


async def test_rate_limits_across_a_whole_walk_lose_no_progress(tmp_path: Path) -> None:
    store, deps, clock = _harness(tmp_path)
    limited = Flaky(
        "IMPLEMENT",
        fail_on=1,
        failure=Outcome.fail(ErrorCategory.RATE_LIMITED, "429"),
    )
    deps.registry.bind(State.IMPLEMENT, limited)
    run_id = await _new_run(store)

    await run_until_boundary(run_id, "worker-1", deps)
    mid = await store.load(run_id)
    assert mid is not None and mid.state is State.IMPLEMENT

    clock.advance(600)
    await run_until_boundary(run_id, "worker-1", deps)
    final = await store.load(run_id)
    assert final is not None and final.disposition is Disposition.DELIVERED


async def test_a_lease_lost_mid_state_does_not_corrupt_the_record(tmp_path: Path) -> None:
    clock = FrozenClock()
    store = open_sqlite(tmp_path / "chaos.db", clock=clock)
    backend = MemoryLeaseBackend(clock=clock)
    deps = Deps(
        store=store,
        registry=Registry(),
        leases=LeaseManager(backend, clock=clock),
        breaker=CircuitBreaker(DEFAULT_BUDGET, CostTracker(clock=clock), clock=clock),
        clock=clock,
    )

    @dataclass
    class Thief:
        state_name: str = "PREPARE"
        run_id: str = ""

        async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
            backend.steal(f"run:{self.run_id}")  # someone else reclaims it mid-state
            return Outcome.ok(SubgraphResult(signal=Signal.ESCALATE))

    run_id = await _new_run(store)
    deps.registry.bind(State.PREPARE, Thief(run_id=run_id))

    await run_until_boundary(run_id, "worker-1", deps)
    run = await store.load(run_id)
    assert run is not None and run.disposition is Disposition.ESCALATED
    assert len(await store.checkpoints(run_id)) == 1


async def test_a_state_that_raises_anything_still_parks(tmp_path: Path) -> None:
    store, deps, _clock = _harness(tmp_path)

    @dataclass
    class Exploding:
        state_name: str = "PREPARE"

        async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
            raise MemoryError("out of memory")

    deps.registry.bind(State.PREPARE, Exploding())
    run_id = await _new_run(store)
    status = await run_until_boundary(run_id, "worker-1", deps)
    assert status is RunStatus.PARKED_TERMINAL
    run = await store.load(run_id)
    assert run is not None and run.disposition is Disposition.ESCALATED


async def test_two_workers_racing_one_run_do_no_double_work(tmp_path: Path) -> None:
    import asyncio

    store, deps, _clock = _harness(tmp_path)
    run_id = await _new_run(store)
    await asyncio.gather(
        run_until_boundary(run_id, "worker-1", deps),
        run_until_boundary(run_id, "worker-2", deps),
    )
    history = await store.checkpoints(run_id)
    assert [c.seq for c in history] == list(range(len(history)))
