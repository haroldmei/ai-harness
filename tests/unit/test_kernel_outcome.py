"""Issue #3 — the Outcome contract, exhaustively over the taxonomy."""

from __future__ import annotations

import pytest

from ai_harness.kernel.outcome import (
    NON_BUDGET_CONSUMING,
    RETRYABLE,
    ErrorCategory,
    Outcome,
    OutcomeUnwrapError,
)


def test_ok_carries_its_value() -> None:
    result = Outcome.ok(42)
    assert result.is_ok and not result.is_err
    assert result.unwrap() == 42
    assert result.category is None


def test_failure_never_unwraps_silently() -> None:
    result: Outcome[int] = Outcome.fail(ErrorCategory.AUTH, "403")
    assert result.is_err
    with pytest.raises(OutcomeUnwrapError):
        result.unwrap()
    assert result.unwrap_or(7) == 7


def test_map_preserves_failure() -> None:
    failed: Outcome[int] = Outcome.fail(ErrorCategory.TRANSIENT, "blip")
    mapped = failed.map(lambda v: v * 2)
    assert mapped.is_err
    assert mapped.error is not None and mapped.error.message == "blip"
    assert Outcome.ok(3).map(lambda v: v * 2).unwrap() == 6


@pytest.mark.parametrize("category", list(ErrorCategory))
def test_every_category_is_classified(category: ErrorCategory) -> None:
    """A new member without a place in both sets is a test failure, not a runtime surprise."""
    result: Outcome[None] = Outcome.fail(category, "x")
    assert result.retryable == (category in RETRYABLE)
    assert result.budget_consuming == (category not in NON_BUDGET_CONSUMING)


def test_empty_envelope_is_not_a_model_failure() -> None:
    """#2407: collapsing UNKNOWN into MODEL_FAILURE discarded a completed $2.29 review."""
    assert ErrorCategory.UNKNOWN is not ErrorCategory.MODEL_FAILURE
    assert ErrorCategory.UNKNOWN in RETRYABLE
    assert ErrorCategory.UNKNOWN in NON_BUDGET_CONSUMING
    assert ErrorCategory.MODEL_FAILURE not in NON_BUDGET_CONSUMING


def test_a_call_that_never_ran_consumes_nothing() -> None:
    """Invariant 1, asserted as a property of the Outcome rather than of each caller."""
    for category in (
        ErrorCategory.TRANSIENT,
        ErrorCategory.RATE_LIMITED,
        ErrorCategory.UNKNOWN,
        ErrorCategory.ENVIRONMENT,
    ):
        assert not Outcome.fail(category, "x").budget_consuming


def test_success_consumes_budget() -> None:
    assert Outcome.ok("done").budget_consuming
