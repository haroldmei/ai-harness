"""Issues #33 and #34 — the supervisor loop and the boundary that cannot raise."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest

from ai_harness.kernel.budget import DEFAULT_BUDGET, BudgetSpec, CircuitBreaker, CostTracker
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import LeaseManager, MemoryLeaseBackend
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.orchestration.machine import Deps, run_until_boundary
from ai_harness.orchestration.registry import Registry, StatePolicy
from ai_harness.persistence.sql import SqlStore
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.schemas.approval import ApprovalDecision, ApprovalRequest
from ai_harness.schemas.enums import Capability, Disposition, RunStatus, Signal, State
from ai_harness.schemas.job import JobRequest
from ai_harness.subgraphs.base import SubgraphResult


@dataclass
class ScriptedSubgraph:
    """Returns queued outcomes in order. The subgraph equivalent of ``ScriptedLLM``."""

    state_name: str
    outcomes: list[Outcome[SubgraphResult]] = field(default_factory=list)
    calls: int = 0

    async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
        self.calls += 1
        if not self.outcomes:
            return Outcome.ok(SubgraphResult(signal=Signal.ADVANCE))
        return self.outcomes[min(self.calls - 1, len(self.outcomes) - 1)]


@dataclass
class ExplodingSubgraph:
    state_name: str = "REVIEW"

    async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
        raise RuntimeError("the state blew up")


@dataclass
class HangingSubgraph:
    state_name: str = "REVIEW"

    async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
        import asyncio

        await asyncio.sleep(3600)
        raise AssertionError("unreachable")


def _ok(signal: Signal = Signal.ADVANCE, **kw: Any) -> Outcome[SubgraphResult]:
    return Outcome.ok(SubgraphResult(signal=signal, **kw))


@pytest.fixture
def harness(tmp_path: Path) -> tuple[SqlStore, Deps, FrozenClock]:
    clock = FrozenClock()
    store = open_sqlite(tmp_path / "machine.db", clock=clock)
    deps = Deps(
        store=store,
        registry=Registry(),
        leases=LeaseManager(MemoryLeaseBackend(clock=clock), clock=clock),
        breaker=CircuitBreaker(DEFAULT_BUDGET, CostTracker(clock=clock), clock=clock),
        clock=clock,
    )
    return store, deps, clock


async def _new_run(store: SqlStore, **kw: Any) -> str:
    request = JobRequest(repo="acme/app", issue=7, **kw)
    run = await store.create(request)
    return run.run_id


# ── the happy path ───────────────────────────────────────────────────────────────


async def test_a_run_walks_the_states_until_it_terminates(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, _clock = harness
    for state in (State.PREPARE, State.ANALYSE, State.IMPLEMENT, State.VALIDATE, State.REVIEW):
        deps.registry.bind(state, ScriptedSubgraph(state.value))
    deps.registry.bind(State.INTEGRATE, ScriptedSubgraph("INTEGRATE", [_ok(Signal.DELIVERED)]))

    run_id = await _new_run(store)
    status = await run_until_boundary(run_id, "worker-1", deps)

    assert status is RunStatus.PARKED_TERMINAL
    run = await store.load(run_id)
    assert run is not None and run.disposition is Disposition.DELIVERED
    timeline = [c.state for c in await store.checkpoints(run_id)]
    assert timeline == [
        State.PREPARE,
        State.ANALYSE,
        State.IMPLEMENT,
        State.VALIDATE,
        State.REVIEW,
        State.INTEGRATE,
    ]


async def test_an_unbound_state_escalates_rather_than_silently_succeeding(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    """Phases 3–4 replace these one at a time; until then a run must stop and say so."""
    store, deps, _clock = harness
    run_id = await _new_run(store)
    status = await run_until_boundary(run_id, "worker-1", deps)
    assert status is RunStatus.AWAITING_APPROVAL
    run = await store.load(run_id)
    assert run is not None and "not implemented yet" in (run.last_error or "")


# ── the boundary ─────────────────────────────────────────────────────────────────


async def test_an_exception_parks_the_run_and_the_process_survives(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    """Principle §7.2: nothing raises across a state boundary."""
    store, deps, _clock = harness
    deps.registry.bind(State.PREPARE, ExplodingSubgraph("PREPARE"))
    run_id = await _new_run(store)

    status = await run_until_boundary(run_id, "worker-1", deps)

    assert status is RunStatus.PARKED_TERMINAL
    run = await store.load(run_id)
    assert run is not None and run.disposition is Disposition.ESCALATED
    checkpoint = (await store.checkpoints(run_id))[-1]
    assert checkpoint.error is not None
    assert checkpoint.error.category is ErrorCategory.FATAL
    assert "RuntimeError" in checkpoint.error.message


async def test_a_state_that_will_not_finish_is_an_environment_failure(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, _clock = harness
    deps.registry.bind(State.PREPARE, HangingSubgraph("PREPARE"))
    deps.registry.policies[State.PREPARE] = StatePolicy(timeout_s=0.05, max_attempts=3)
    run_id = await _new_run(store)

    status = await run_until_boundary(run_id, "worker-1", deps)

    assert status is RunStatus.DEFERRED, "an environment failure defers, it does not blame code"
    run = await store.load(run_id)
    assert run is not None and "exceeded" in (run.last_error or "")


# ── budgets, before the spend ────────────────────────────────────────────────────


async def test_the_breaker_stops_the_run_before_a_state_executes(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    """W3: bounded by dollars, not by iterations — and checked *before* the call."""
    store, deps, clock = harness
    tracker = CostTracker(clock=clock)
    deps.breaker = CircuitBreaker(DEFAULT_BUDGET, tracker, clock=clock)
    subgraph = ScriptedSubgraph("PREPARE")
    deps.registry.bind(State.PREPARE, subgraph)

    run_id = await _new_run(store)
    run = await store.load(run_id)
    assert run is not None
    await store.commit_transition(
        run.model_copy(update={"spend_usd": Decimal("30")}),
        _checkpoint(run_id, 0),
    )
    # The breaker reads the tracker, so put the spend where the breaker will see it.
    from ai_harness.kernel.budget import CostEvent

    tracker.record(
        CostEvent(
            run_id=run_id,
            repo="acme/app",
            state="REVIEW",
            provider="anthropic",
            model="opus",
            usd=Decimal("30"),
        )
    )

    status = await run_until_boundary(run_id, "worker-1", deps)
    assert status is RunStatus.PARKED_TERMINAL
    assert subgraph.calls == 0, "the state must not run at all"


async def test_an_unconfigured_budget_is_a_configuration_error(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, clock = harness
    deps.breaker = CircuitBreaker(BudgetSpec(), CostTracker(clock=clock), clock=clock)
    deps.registry.bind(State.PREPARE, ScriptedSubgraph("PREPARE"))
    run_id = await _new_run(store)

    assert await run_until_boundary(run_id, "worker-1", deps) is RunStatus.PARKED_TERMINAL
    run = await store.load(run_id)
    assert run is not None and "not configured" in (run.last_error or "")


async def test_the_state_attempt_cap_is_read_from_the_durable_counter(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    """W1: a /tmp counter reset by a reboot re-opens a bounded loop. This one does not."""
    store, deps, _clock = harness
    deps.registry.bind(State.REVIEW, ScriptedSubgraph("REVIEW", [_ok(Signal.FIX)]))
    deps.registry.policies[State.REVIEW] = StatePolicy(
        timeout_s=60, max_attempts=2, counter="review_rounds"
    )
    run_id = await _new_run(store)
    run = await store.load(run_id)
    assert run is not None
    await store.commit_transition(
        run.model_copy(
            update={"state": State.REVIEW, "counters": run.counters.bump("review_rounds", 2)}
        ),
        _checkpoint(run_id, 0, next_state=State.REVIEW),
    )

    status = await run_until_boundary(run_id, "worker-1", deps)
    assert status is RunStatus.PARKED_TERMINAL
    reloaded = await store.load(run_id)
    assert reloaded is not None and "attempted 2 times" in (reloaded.last_error or "")


# ── parking ──────────────────────────────────────────────────────────────────────


async def test_a_deferred_run_releases_its_lease_and_resumes_when_the_timer_expires(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, clock = harness
    deps.registry.bind(
        State.PREPARE,
        ScriptedSubgraph("PREPARE", [Outcome.fail(ErrorCategory.TRANSIENT, "blip"), _ok()]),
    )
    deps.registry.bind(State.ANALYSE, ScriptedSubgraph("ANALYSE", [_ok(Signal.ESCALATE)]))
    run_id = await _new_run(store)

    first = await run_until_boundary(run_id, "worker-1", deps)
    assert first is RunStatus.DEFERRED
    run = await store.load(run_id)
    assert run is not None and run.state is State.PREPARE, "a parked run IS in its state"
    assert run.counters.implement_attempts == 0

    # Too early: nothing happens, and the lease is free for the next worker to try.
    assert await run_until_boundary(run_id, "worker-2", deps) is RunStatus.DEFERRED
    clock.advance(120)
    assert await run_until_boundary(run_id, "worker-3", deps) is RunStatus.PARKED_TERMINAL


async def test_an_approval_parks_and_a_denial_terminates(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, clock = harness
    deps.registry.bind(State.IMPLEMENT, ScriptedSubgraph("IMPLEMENT", [_ok(Signal.NEEDS_APPROVAL)]))
    run_id = await _new_run(store)
    run = await store.load(run_id)
    assert run is not None
    await store.commit_transition(
        run.model_copy(update={"state": State.IMPLEMENT}),
        _checkpoint(run_id, 0, next_state=State.IMPLEMENT),
    )

    assert await run_until_boundary(run_id, "worker-1", deps) is RunStatus.AWAITING_APPROVAL

    run = await store.load(run_id)
    assert run is not None and run.status is RunStatus.AWAITING_APPROVAL
    await store.request(
        ApprovalRequest(
            approval_id="a1",
            run_id=run_id,
            state=State.IMPLEMENT,
            capability=Capability.MODIFY_CI,
            reason="touched CI",
            requested_at=clock.now(),
        )
    )
    await store.commit_transition(
        run.model_copy(update={"pending_approval_id": "a1"}),
        _checkpoint(run_id, 99, next_state=State.IMPLEMENT),
    )

    # Unanswered: still parked.
    assert await run_until_boundary(run_id, "worker-1", deps) is RunStatus.AWAITING_APPROVAL

    await store.decide(
        ApprovalDecision(approval_id="a1", approved=False, decided_by="hmei", reason="no")
    )
    assert await run_until_boundary(run_id, "worker-1", deps) is RunStatus.PARKED_TERMINAL
    final = await store.load(run_id)
    assert final is not None and final.disposition is Disposition.ESCALATED


async def test_a_blocked_run_resumes_only_when_its_blocker_closes(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, _clock = harness
    closed = {"value": False}

    async def blocker_is_closed(reference: str) -> bool:
        assert reference == "#412"
        return closed["value"]

    deps.blocker_is_closed = blocker_is_closed
    deps.registry.bind(State.ANALYSE, ScriptedSubgraph("ANALYSE", [_ok(Signal.ESCALATE)]))
    run_id = await _new_run(store)
    run = await store.load(run_id)
    assert run is not None
    await store.commit_transition(
        run.model_copy(
            update={
                "state": State.ANALYSE,
                "status": RunStatus.BLOCKED,
                "blocked_on": "#412",
            }
        ),
        _checkpoint(run_id, 0, next_state=State.ANALYSE),
    )

    assert await run_until_boundary(run_id, "worker-1", deps) is RunStatus.BLOCKED
    closed["value"] = True
    assert await run_until_boundary(run_id, "worker-1", deps) is RunStatus.PARKED_TERMINAL


async def test_a_run_owned_by_another_worker_is_not_an_error(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, _clock = harness
    deps.registry.bind(State.PREPARE, ScriptedSubgraph("PREPARE"))
    run_id = await _new_run(store)
    held = await deps.leases.acquire(f"run:{run_id}", ttl_s=600, holder="worker-1")
    assert held is not None

    assert await run_until_boundary(run_id, "worker-2", deps) is RunStatus.RUNNING
    run = await store.load(run_id)
    assert run is not None and run.state is State.PREPARE, "nothing happened, and that is fine"


# ── budgets and counters on the failure path ─────────────────────────────────────


async def test_a_blameless_failure_moves_no_counter(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, _clock = harness
    deps.registry.bind(
        State.REVIEW,
        ScriptedSubgraph("REVIEW", [Outcome.fail(ErrorCategory.RATE_LIMITED, "429")]),
    )
    run_id = await _new_run(store)
    run = await store.load(run_id)
    assert run is not None
    await store.commit_transition(
        run.model_copy(update={"state": State.REVIEW}),
        _checkpoint(run_id, 0, next_state=State.REVIEW),
    )

    await run_until_boundary(run_id, "worker-1", deps)
    reloaded = await store.load(run_id)
    assert reloaded is not None
    assert reloaded.counters.review_rounds == 0, "a rate limit costs no round (#2407's lesson)"


async def test_an_empty_envelope_counts_a_streak_not_a_round(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, clock = harness
    deps.registry.bind(
        State.REVIEW,
        ScriptedSubgraph("REVIEW", [Outcome.fail(ErrorCategory.UNKNOWN, "no envelope")]),
    )
    run_id = await _new_run(store)
    run = await store.load(run_id)
    assert run is not None
    await store.commit_transition(
        run.model_copy(update={"state": State.REVIEW}),
        _checkpoint(run_id, 0, next_state=State.REVIEW),
    )

    await run_until_boundary(run_id, "worker-1", deps)
    clock.advance(120)
    await run_until_boundary(run_id, "worker-1", deps)

    reloaded = await store.load(run_id)
    assert reloaded is not None
    assert reloaded.counters.empty_envelope_streak == 2
    assert reloaded.counters.review_rounds == 0


async def test_a_success_resets_the_empty_envelope_streak(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, _clock = harness
    deps.registry.bind(State.REVIEW, ScriptedSubgraph("REVIEW", [_ok(Signal.ESCALATE)]))
    run_id = await _new_run(store)
    run = await store.load(run_id)
    assert run is not None
    await store.commit_transition(
        run.model_copy(
            update={
                "state": State.REVIEW,
                "counters": run.counters.bump("empty_envelope_streak", 2),
            }
        ),
        _checkpoint(run_id, 0, next_state=State.REVIEW),
    )

    await run_until_boundary(run_id, "worker-1", deps)
    reloaded = await store.load(run_id)
    assert reloaded is not None and reloaded.counters.empty_envelope_streak == 0


# ── resume ───────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("interrupt_after", [1, 2, 3])
async def test_a_run_interrupted_mid_walk_resumes_to_the_same_disposition(
    harness: tuple[SqlStore, Deps, FrozenClock], interrupt_after: int
) -> None:
    """The chaos property, at the supervisor level: any worker, from any checkpoint."""
    store, deps, _clock = harness
    calls = {"n": 0}

    class Counting:
        def __init__(self, state_name: str, signal: Signal) -> None:
            self.state_name = state_name
            self.signal = signal

        async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
            calls["n"] += 1
            if calls["n"] == interrupt_after:
                # A worker dying here must lose nothing: the last checkpoint is the truth.
                raise KeyboardInterrupt
            return _ok(self.signal)

    for state in (State.PREPARE, State.ANALYSE, State.IMPLEMENT, State.VALIDATE, State.REVIEW):
        deps.registry.bind(state, Counting(state.value, Signal.ADVANCE))
    deps.registry.bind(State.INTEGRATE, Counting("INTEGRATE", Signal.DELIVERED))

    run_id = await _new_run(store)
    with pytest.raises(KeyboardInterrupt):
        await run_until_boundary(run_id, "worker-1", deps)

    calls["n"] = -1000  # the "restarted process" no longer interrupts
    status = await run_until_boundary(run_id, "worker-2", deps)
    assert status is RunStatus.PARKED_TERMINAL
    run = await store.load(run_id)
    assert run is not None and run.disposition is Disposition.DELIVERED


def _checkpoint(run_id: str, seq: int, **kw: Any) -> Any:
    from ai_harness.schemas.checkpoint import Checkpoint

    base: dict[str, Any] = {
        "run_id": run_id,
        "seq": seq,
        "state": State.PREPARE,
        "next_state": State.PREPARE,
    }
    base.update(kw)
    return Checkpoint(**base)


async def test_the_defer_timer_is_recorded_so_any_worker_honours_it(
    harness: tuple[SqlStore, Deps, FrozenClock],
) -> None:
    store, deps, clock = harness
    deps.registry.bind(
        State.PREPARE,
        ScriptedSubgraph("PREPARE", [Outcome.fail(ErrorCategory.ENVIRONMENT, "no docker")]),
    )
    run_id = await _new_run(store)
    await run_until_boundary(run_id, "worker-1", deps)

    run = await store.load(run_id)
    assert run is not None and run.defer_until is not None
    assert run.defer_until > clock.now()
    assert run.defer_until <= clock.now() + timedelta(seconds=301)
