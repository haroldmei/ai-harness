"""Issue #7 — budgets checked before the spend, not after it."""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal

from ai_harness.kernel.budget import (
    DEFAULT_BUDGET,
    BudgetSpec,
    CircuitBreaker,
    CostEvent,
    CostTracker,
    RunSpend,
)
from ai_harness.kernel.clock import FrozenClock


def _run(clock: FrozenClock, **kw: object) -> RunSpend:
    base = {"run_id": "r1", "repo": "acme/app", "started_at": clock.now()}
    base.update(kw)
    return RunSpend(**base)  # type: ignore[arg-type]


def _event(usd: str, **kw: object) -> CostEvent:
    base: dict[str, object] = {
        "run_id": "r1",
        "repo": "acme/app",
        "state": "REVIEW",
        "provider": "anthropic",
        "model": "opus",
        "usd": Decimal(usd),
    }
    base.update(kw)
    return CostEvent(**base)  # type: ignore[arg-type]


def test_an_unset_budget_is_a_configuration_error_not_unlimited() -> None:
    clock = FrozenClock()
    breaker = CircuitBreaker(BudgetSpec(), CostTracker(clock=clock), clock=clock)
    verdict = breaker.check(_run(clock))
    assert verdict is not None and verdict.reason == "not configured"


def test_the_shipped_defaults_are_the_q6_numbers() -> None:
    assert DEFAULT_BUDGET.max_usd_per_run == Decimal("25")
    assert DEFAULT_BUDGET.max_usd_per_repo_day == Decimal("500")
    assert DEFAULT_BUDGET.configured


def test_run_ceiling_stops_the_next_state() -> None:
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(DEFAULT_BUDGET, tracker, clock=clock)
    tracker.record(_event("25.10"))
    verdict = breaker.check(_run(clock))
    assert verdict is not None and "run cost ceiling" in verdict.reason


def test_repo_day_ceiling_is_shared_across_runs() -> None:
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(DEFAULT_BUDGET, tracker, clock=clock)
    for n in range(21):
        tracker.record(_event("24", run_id=f"other-{n}"))
    verdict = breaker.check(_run(clock))
    assert verdict is not None and "repo daily ceiling" in verdict.reason


def test_reservation_denies_before_the_call_not_after() -> None:
    """W3: recording cost after the call bounds a loop by iterations, not by dollars."""
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(DEFAULT_BUDGET, tracker, clock=clock)
    tracker.record(_event("24"))
    denied = breaker.reserve(_run(clock), Decimal("5"))
    assert denied.is_err
    assert denied.error is not None and "exceed the run ceiling" in denied.error.message
    assert tracker.run_total("r1") == Decimal("24"), "a denial must not spend"


def test_concurrent_reservations_cannot_both_fit() -> None:
    clock = FrozenClock()
    breaker = CircuitBreaker(DEFAULT_BUDGET, CostTracker(clock=clock), clock=clock)
    first = breaker.reserve(_run(clock), Decimal("20"))
    second = breaker.reserve(_run(clock), Decimal("20"))
    assert first.is_ok and second.is_err


def test_settling_releases_the_reservation_and_records_actuals() -> None:
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(DEFAULT_BUDGET, tracker, clock=clock)
    reservation = breaker.reserve(_run(clock), Decimal("10")).unwrap()
    breaker.settle(reservation, _event("2.29"))
    assert tracker.run_total("r1") == Decimal("2.29")
    assert breaker.committed("r1") == Decimal("2.29")
    breaker.settle(reservation, _event("2.29"))  # idempotent
    assert tracker.run_total("r1") == Decimal("2.29")


def test_wall_clock_and_attempt_ceilings() -> None:
    clock = FrozenClock()
    budget = BudgetSpec(
        max_usd_per_run=Decimal("25"),
        max_usd_per_repo_day=Decimal("500"),
        max_wall_clock_s=60,
        max_attempts_per_state={"IMPLEMENT": 3},
    )
    breaker = CircuitBreaker(budget, CostTracker(clock=clock), clock=clock)
    started = datetime(2026, 1, 1, tzinfo=UTC)
    clock.advance(61)
    assert breaker.check(_run(clock, started_at=started)) is not None
    fresh = CircuitBreaker(budget, CostTracker(clock=clock), clock=clock)
    verdict = fresh.check(_run(clock, started_at=clock.now(), attempts_by_state={"IMPLEMENT": 3}))
    assert verdict is not None and "IMPLEMENT attempt cap" in verdict.reason


def test_cost_is_attributable_per_run_and_per_repo_day() -> None:
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    tracker.record(_event("1.50"))
    tracker.record(_event("2.50", run_id="r2"))
    assert tracker.run_total("r1") == Decimal("1.50")
    assert tracker.repo_day_total("acme/app") == Decimal("4.00")
    assert all(e.at is not None for e in tracker.events)
