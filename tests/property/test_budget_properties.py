"""Issue #7 — the property, not the example: *no execution path spends past a breaker*."""

from __future__ import annotations

from decimal import Decimal

from hypothesis import given, settings
from hypothesis import strategies as st

from ai_harness.kernel.budget import (
    BudgetSpec,
    CircuitBreaker,
    CostEvent,
    CostTracker,
    RunSpend,
)
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome

_amounts = st.lists(st.integers(min_value=1, max_value=2000), min_size=1, max_size=40)


@settings(max_examples=200, deadline=None)
@given(ceiling_cents=st.integers(min_value=100, max_value=5000), spends=_amounts)
def test_spend_never_exceeds_the_ceiling_when_every_call_reserves(
    ceiling_cents: int, spends: list[int]
) -> None:
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    budget = BudgetSpec(
        max_usd_per_run=Decimal(ceiling_cents) / 100,
        max_usd_per_repo_day=Decimal("100000"),
    )
    breaker = CircuitBreaker(budget, tracker, clock=clock)
    run = RunSpend(run_id="r", repo="acme/app", started_at=clock.now())

    for cents in spends:
        estimate = Decimal(cents) / 100
        reservation = breaker.reserve(run, estimate)
        if reservation.is_err:
            continue  # denied before the call — the point of reserving
        breaker.settle(
            reservation.unwrap(),
            CostEvent(
                run_id="r",
                repo="acme/app",
                state="IMPLEMENT",
                provider="anthropic",
                model="opus",
                usd=estimate,
            ),
        )

    assert tracker.run_total("r") <= budget.max_usd_per_run


@settings(max_examples=100, deadline=None)
@given(
    categories=st.lists(
        st.sampled_from(list(ErrorCategory)),
        min_size=1,
        max_size=20,
    )
)
def test_non_consuming_failures_never_move_a_counter(categories: list[ErrorCategory]) -> None:
    """Invariant 1, as a property over every taxonomy member rather than a chosen few."""
    consumed = 0
    for category in categories:
        outcome: Outcome[None] = Outcome.fail(category, "x")
        if outcome.budget_consuming:
            consumed += 1
    expected = sum(1 for c in categories if Outcome.fail(c, "x").budget_consuming)
    assert consumed == expected
    assert all(not Outcome.fail(c, "x").budget_consuming for c in categories if c in _free())


def _free() -> frozenset[ErrorCategory]:
    from ai_harness.kernel.outcome import NON_BUDGET_CONSUMING

    return NON_BUDGET_CONSUMING
