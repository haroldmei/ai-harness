"""Issue #4 — retry policy as data, and the dependency breaker."""

from __future__ import annotations

import random

import pytest

from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.kernel.retry import (
    DEFAULT_POLICIES,
    BreakerRegistry,
    BreakerState,
    DependencyBreaker,
    RetryPolicy,
    call_with_retry,
    policy_for,
)


@pytest.mark.parametrize("category", list(ErrorCategory))
def test_every_category_has_a_policy(category: ErrorCategory) -> None:
    assert policy_for(category).attempts >= 1


def test_unlimited_retry_is_not_expressible() -> None:
    with pytest.raises(ValueError):
        RetryPolicy(attempts=0)
    assert all(p.attempts <= 100 for p in DEFAULT_POLICIES.values())


def test_auth_is_never_retried() -> None:
    """Retrying a 403 burns quota and never succeeds."""
    assert not policy_for(ErrorCategory.AUTH).permits(ErrorCategory.AUTH)
    assert policy_for(ErrorCategory.AUTH).attempts == 1


def test_backoff_is_exponential_and_capped() -> None:
    policy = RetryPolicy(attempts=6, base_delay_s=2, max_delay_s=60, jitter="none")
    assert [policy.delay(n) for n in range(1, 7)] == [2, 4, 8, 16, 32, 60]


def test_full_jitter_stays_within_the_envelope() -> None:
    policy = RetryPolicy(base_delay_s=10, max_delay_s=100)
    rng = random.Random(1)
    assert all(0 <= policy.delay(3, rng=rng) <= 40 for _ in range(50))


async def test_transient_retries_without_sleeping_in_real_time() -> None:
    clock = FrozenClock()
    calls = 0

    async def flaky() -> Outcome[str]:
        nonlocal calls
        calls += 1
        if calls < 3:
            return Outcome.fail(ErrorCategory.TRANSIENT, "blip")
        return Outcome.ok("done")

    result = await call_with_retry(flaky, clock=clock)
    assert result.unwrap() == "done"
    assert calls == 3
    assert len(clock.slept) == 2


async def test_retry_after_is_honoured_verbatim() -> None:
    clock = FrozenClock()

    async def limited() -> Outcome[str]:
        return Outcome.fail(ErrorCategory.RATE_LIMITED, "429", retry_after_s=42)

    await call_with_retry(limited, clock=clock)
    assert clock.slept == [42] * 5  # attempts=6 ⇒ five waits


async def test_exceptions_become_fatal_outcomes_not_crashes() -> None:
    async def explodes() -> Outcome[str]:
        raise ValueError("boom")

    result = await call_with_retry(explodes, clock=FrozenClock())
    assert result.category is ErrorCategory.FATAL
    assert result.error is not None and "boom" in result.error.message


async def test_open_breaker_defers_at_zero_cost() -> None:
    """A fleet must not each spend four backoff cycles discovering the same outage."""
    clock = FrozenClock()
    registry = BreakerRegistry(failure_threshold=2, cooldown_s=60, clock=clock)
    calls = 0

    async def down() -> Outcome[str]:
        nonlocal calls
        calls += 1
        return Outcome.fail(ErrorCategory.TRANSIENT, "connection refused")

    policies = {ErrorCategory.TRANSIENT: RetryPolicy(attempts=2, base_delay_s=1, jitter="none")}
    await call_with_retry(
        down, dependency="model:anthropic", policies=policies, clock=clock, breakers=registry
    )
    assert registry.get("model:anthropic").state is BreakerState.OPEN

    before = calls
    result = await call_with_retry(
        down, dependency="model:anthropic", policies=policies, clock=clock, breakers=registry
    )
    assert calls == before, "an open breaker must not dispatch at all"
    assert result.is_err and result.error is not None
    assert "circuit breaker open" in result.error.message


def test_breaker_half_opens_after_the_cooldown() -> None:
    clock = FrozenClock()
    breaker = DependencyBreaker("forge:github.com", failure_threshold=1, cooldown_s=30, clock=clock)
    breaker.record_failure()
    assert breaker.state is BreakerState.OPEN and not breaker.allow()
    clock.advance(31)
    assert breaker.state is BreakerState.HALF_OPEN and breaker.allow()
    breaker.record_success()
    assert breaker.state is BreakerState.CLOSED
