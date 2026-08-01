"""Retry policy as data, and one place that applies it.

The shell harness expresses sixteen distinct bounds in sixteen places (§3.11). Here a policy
is a value: it can be printed, diffed, overridden per repository, and tested without calling
anything. Two rules are structural rather than conventional:

* ``attempts`` is a positive integer with no sentinel, so **"retry forever" is not
  expressible**.
* Whether an attempt consumes a budget is read from the :class:`ErrorCategory`, not passed by
  the caller — invariant 1, *a model call that never ran must not consume a budget*.

:class:`DependencyBreaker` is distinct from the *run* budget breaker. It exists so a fleet of
workers does not each spend four backoff cycles independently discovering that a provider is
down: once ``model:anthropic`` is open, every run defers immediately at zero cost.
"""

from __future__ import annotations

import random
from collections.abc import Awaitable, Callable
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, Field

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import RETRYABLE, ErrorCategory, Outcome

Fallback = Literal["defer", "escalate", "degrade", "none"]

_JITTER_RNG = random.Random()
"""Jitter source. Tests pass their own seeded ``Random`` so a backoff sequence is reproducible."""


class RetryPolicy(BaseModel):
    """How many times, how long apart, and what to do when the attempts run out."""

    model_config = {"frozen": True}

    attempts: int = Field(default=3, ge=1, le=100)
    """Total attempts including the first. There is deliberately no "unlimited"."""
    base_delay_s: float = Field(default=1.0, ge=0)
    max_delay_s: float = Field(default=60.0, ge=0)
    jitter: Literal["none", "full", "equal"] = "full"
    retry_on: frozenset[ErrorCategory] = Field(default=RETRYABLE)
    honour_retry_after: bool = True
    fallback: Fallback = "defer"

    def delay(self, attempt: int, *, rng: random.Random | None = None) -> float:
        """Backoff before ``attempt`` (1-based). Full jitter by default, per §16.1."""
        # 2.0 rather than 2: int ** int is typed Any in typeshed, which would silently make
        # every downstream delay untyped.
        exponential = min(self.base_delay_s * (2.0 ** max(attempt - 1, 0)), self.max_delay_s)
        if self.jitter == "none" or exponential == 0:
            return exponential
        source: random.Random = rng if rng is not None else _JITTER_RNG
        if self.jitter == "equal":
            return exponential / 2 + source.uniform(0, exponential / 2)
        return source.uniform(0, exponential)

    def permits(self, category: ErrorCategory) -> bool:
        return category in self.retry_on


NO_RETRY = RetryPolicy(attempts=1, retry_on=frozenset(), fallback="escalate")

DEFAULT_POLICIES: dict[ErrorCategory, RetryPolicy] = {
    # §16.2, transcribed. Every row of that table is a line here and nowhere else.
    ErrorCategory.TRANSIENT: RetryPolicy(
        attempts=4, base_delay_s=2, max_delay_s=60, retry_on=frozenset({ErrorCategory.TRANSIENT})
    ),
    ErrorCategory.RATE_LIMITED: RetryPolicy(
        attempts=6,
        base_delay_s=5,
        max_delay_s=300,
        retry_on=frozenset({ErrorCategory.RATE_LIMITED}),
        honour_retry_after=True,
    ),
    # Bounded at 2 CONSECUTIVE empties: unbounded spins forever against a permanently silent
    # CLI (a broken install, dead credentials), which is strictly worse than escalating.
    ErrorCategory.UNKNOWN: RetryPolicy(
        attempts=2,
        base_delay_s=5,
        max_delay_s=30,
        retry_on=frozenset({ErrorCategory.UNKNOWN}),
        fallback="escalate",
    ),
    ErrorCategory.ENVIRONMENT: RetryPolicy(
        attempts=3,
        base_delay_s=60,
        max_delay_s=600,
        retry_on=frozenset({ErrorCategory.ENVIRONMENT}),
        fallback="escalate",
    ),
    # Retrying a 403 burns quota and never succeeds.
    ErrorCategory.AUTH: NO_RETRY,
    # Re-route to VALIDATE against the new base; never resolve-and-retry blindly.
    ErrorCategory.REPO_CONFLICT: RetryPolicy(attempts=1, retry_on=frozenset(), fallback="none"),
    # Schema repairs: a clarified prompt, immediately, at most twice.
    ErrorCategory.VALIDATION: RetryPolicy(
        attempts=3,
        base_delay_s=0,
        max_delay_s=0,
        jitter="none",
        retry_on=frozenset({ErrorCategory.VALIDATION}),
        fallback="escalate",
    ),
    # Never retried, and not because it is hopeless: the same bytes are rejected identically
    # every time. What clears it is a *smaller assembly*, which is a new request rather than a
    # retry, and it belongs to the caller that knows what may be dropped (L6).
    ErrorCategory.CONTEXT_OVERFLOW: NO_RETRY,
    ErrorCategory.MODEL_FAILURE: RetryPolicy(
        attempts=2,
        base_delay_s=5,
        max_delay_s=30,
        retry_on=frozenset({ErrorCategory.MODEL_FAILURE}),
        fallback="escalate",
    ),
    # A deterministic tool error is a defect the fixer can own.
    ErrorCategory.TOOL_FAILURE: RetryPolicy(attempts=1, retry_on=frozenset(), fallback="degrade"),
    ErrorCategory.POLICY: NO_RETRY,
    ErrorCategory.NEEDS_HUMAN: NO_RETRY,
    ErrorCategory.PERMANENT: RetryPolicy(attempts=1, retry_on=frozenset(), fallback="none"),
    ErrorCategory.FATAL: NO_RETRY,
}


def policy_for(category: ErrorCategory) -> RetryPolicy:
    """The policy for a category. Every member is mapped; a new one fails the exhaustive test."""
    return DEFAULT_POLICIES[category]


class BreakerState(StrEnum):
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"


class DependencyBreaker:
    """One breaker per external dependency: ``forge:github.com``, ``model:anthropic``, …"""

    def __init__(
        self,
        key: str,
        *,
        failure_threshold: int = 5,
        cooldown_s: float = 60.0,
        clock: Clock | None = None,
    ) -> None:
        self.key = key
        self.failure_threshold = failure_threshold
        self.cooldown_s = cooldown_s
        self._clock = clock or SystemClock()
        self._consecutive_failures = 0
        self._opened_at: float | None = None

    @property
    def state(self) -> BreakerState:
        if self._opened_at is None:
            return BreakerState.CLOSED
        if self._clock.monotonic() - self._opened_at >= self.cooldown_s:
            return BreakerState.HALF_OPEN
        return BreakerState.OPEN

    def allow(self) -> bool:
        """``False`` means short-circuit to the fallback without spending anything."""
        return self.state is not BreakerState.OPEN

    def record_success(self) -> None:
        self._consecutive_failures = 0
        self._opened_at = None

    def record_failure(self) -> None:
        self._consecutive_failures += 1
        if self._consecutive_failures >= self.failure_threshold:
            self._opened_at = self._clock.monotonic()


class BreakerRegistry:
    """Breakers by dependency key, created on first use."""

    def __init__(
        self, *, failure_threshold: int = 5, cooldown_s: float = 60.0, clock: Clock | None = None
    ) -> None:
        self._breakers: dict[str, DependencyBreaker] = {}
        self._clock = clock or SystemClock()
        self._failure_threshold = failure_threshold
        self._cooldown_s = cooldown_s

    def get(self, key: str) -> DependencyBreaker:
        breaker = self._breakers.get(key)
        if breaker is None:
            breaker = DependencyBreaker(
                key,
                failure_threshold=self._failure_threshold,
                cooldown_s=self._cooldown_s,
                clock=self._clock,
            )
            self._breakers[key] = breaker
        return breaker

    def snapshot(self) -> dict[str, BreakerState]:
        return {key: breaker.state for key, breaker in self._breakers.items()}


async def call_with_retry[T](
    operation: Callable[[], Awaitable[Outcome[T]]],
    *,
    dependency: str | None = None,
    policies: dict[ErrorCategory, RetryPolicy] | None = None,
    clock: Clock | None = None,
    breakers: BreakerRegistry | None = None,
    rng: random.Random | None = None,
) -> Outcome[T]:
    """Apply the category's policy to an ``Outcome``-returning operation.

    The operation is never expected to raise: it returns failures. If one does raise, the
    exception is converted to :attr:`ErrorCategory.FATAL` here rather than escaping into a
    caller that has no way to classify it.
    """
    the_clock = clock or SystemClock()
    table = policies or DEFAULT_POLICIES
    breaker = breakers.get(dependency) if (breakers and dependency) else None

    if breaker is not None and not breaker.allow():
        return Outcome.fail(
            ErrorCategory.TRANSIENT,
            f"circuit breaker open for {dependency}",
            remedy=f"{dependency} is failing for everyone; the run defers at zero cost",
            dependency=dependency,
        )

    attempt = 1
    while True:
        try:
            result = await operation()
        except Exception as exc:  # the boundary exists precisely to stop exceptions here
            result = Outcome[T].fail(
                ErrorCategory.FATAL,
                f"{type(exc).__name__}: {exc}",
                dependency=dependency,
            )

        if result.is_ok:
            if breaker is not None:
                breaker.record_success()
            return result

        assert result.error is not None
        category = result.error.category
        if breaker is not None and category in {
            ErrorCategory.TRANSIENT,
            ErrorCategory.RATE_LIMITED,
            ErrorCategory.ENVIRONMENT,
            ErrorCategory.UNKNOWN,
        }:
            breaker.record_failure()

        policy = table.get(category, NO_RETRY)
        if not policy.permits(category) or attempt >= policy.attempts:
            return result

        delay = result.error.retry_after_s if policy.honour_retry_after else None
        if delay is None:
            delay = policy.delay(attempt, rng=rng)
        await the_clock.sleep(delay)
        attempt += 1
