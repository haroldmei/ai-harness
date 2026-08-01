"""``Outcome[T]`` and the error taxonomy every layer classifies into.

Two design principles live here, and both were bought with production incidents:

*Nothing raises across a state boundary* (§7.2). Every operation returns an ``Outcome``;
the router dispatches on its error class. An unexpected exception is caught at the state
boundary and converted into ``Outcome`` with :attr:`ErrorCategory.FATAL` — the process does
not die, the run parks.

*A model call that never ran must not consume a budget* (§7.3). That is a property of the
``Outcome``, not of each caller's ``if``: :data:`NON_BUDGET_CONSUMING` is read by the budget
layer, so a caller cannot forget it.

:attr:`ErrorCategory.UNKNOWN` is deliberately distinct from
:attr:`ErrorCategory.MODEL_FAILURE`. A zero-byte envelope means the harness learned
*nothing*, which is the opposite of a verdict of "genuine failure". Collapsing the two made
the one failure most worth retrying the one guaranteed to escalate, and discarded a
completed $2.29 review (#2407).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Any


class ErrorCategory(StrEnum):
    """How a failure must be treated. The category decides retry, budget and routing."""

    TRANSIENT = "transient"
    """Self-healing: a network blip, an overloaded endpoint, a flaky subprocess."""

    RATE_LIMITED = "rate_limited"
    """A provider said "later". Honour ``Retry-After``; never count it against a budget."""

    UNKNOWN = "unknown"
    """No output at all. The call may have succeeded — we cannot tell (#2407)."""

    ENVIRONMENT = "environment"
    """The tooling could not run: Docker down, disk full, dependency unresolvable.
    Distinct from "the code is broken" — conflating them accuses an innocent base."""

    AUTH = "auth"
    """Credentials rejected. Never retried: a 403 burns quota and never succeeds."""

    REPO_CONFLICT = "repo_conflict"
    """The base moved, or the tree conflicts. Re-route; never resolve-and-retry blindly."""

    VALIDATION = "validation"
    """Model output failed its schema. Bounded repair, then escalate with the last output."""

    CONTEXT_OVERFLOW = "context_overflow"
    """The prompt was longer than the model's window. The most *predictable* failure in the
    system, and the one a hosted 200k-token model made invisible: it is deterministic, the
    caller knows both numbers, and the fix is to assemble less — never to retry the same bytes
    and never to blame the model. Distinct from MODEL_FAILURE because nothing ran."""

    MODEL_FAILURE = "model_failure"
    """The model ran and produced unusable output. Its own fault, so it costs budget."""

    TOOL_FAILURE = "tool_failure"
    """A deterministic tool error — a defect the fixer can own."""

    POLICY = "policy"
    """A capability was denied. Not a transient condition; never retried."""

    NEEDS_HUMAN = "needs_human"
    """Requires a decision the harness may not make."""

    PERMANENT = "permanent"
    """Terminal and understood. Complete the run."""

    FATAL = "fatal"
    """An unexpected exception crossed a state boundary. The run parks; the process lives."""


RETRYABLE: frozenset[ErrorCategory] = frozenset(
    {
        ErrorCategory.TRANSIENT,
        ErrorCategory.RATE_LIMITED,
        ErrorCategory.UNKNOWN,
        ErrorCategory.ENVIRONMENT,
        ErrorCategory.VALIDATION,
        ErrorCategory.MODEL_FAILURE,
    }
)
"""Categories a retry can plausibly clear. Everything else is re-routed or escalated."""

NON_BUDGET_CONSUMING: frozenset[ErrorCategory] = frozenset(
    {
        ErrorCategory.TRANSIENT,
        ErrorCategory.RATE_LIMITED,
        ErrorCategory.UNKNOWN,
        ErrorCategory.ENVIRONMENT,
        ErrorCategory.REPO_CONFLICT,
        ErrorCategory.AUTH,
        ErrorCategory.POLICY,
        ErrorCategory.NEEDS_HUMAN,
        ErrorCategory.CONTEXT_OVERFLOW,
    }
)
"""Failures that are not the attempt's fault. None of these may increment a state budget.

``CONTEXT_OVERFLOW`` is here because the server rejected the request before generating a token:
nothing was produced, so nothing was spent. It is deliberately *not* in :data:`RETRYABLE` —
re-sending the identical prompt fails identically, and the only useful response is to assemble
a smaller one (§17.1, L6).


An empty-envelope *streak* is bounded separately (§16.2) precisely because the category
itself must stay non-consuming.
"""


class OutcomeUnwrapError(RuntimeError):
    """Raised by :meth:`Outcome.unwrap` on a failed outcome. Never raised across a boundary."""


@dataclass(frozen=True, slots=True)
class ErrorRecord:
    """A failure, described well enough to route it *and* to tell a human what to do.

    ``remedy`` matters more than it looks: the shell merger picks a different remedy text
    depending on whether the cause was Docker starvation or an unresolved npm workspace,
    because telling a human to chase the wrong one wastes the escalation.
    """

    category: ErrorCategory
    message: str
    remedy: str | None = None
    retry_after_s: float | None = None
    dependency: str | None = None
    """The breaker key this failure belongs to, e.g. ``model:anthropic``."""
    evidence: str | None = None
    """An artefact id. Never the prompt or the raw content — see §21.4."""
    occurred_at: datetime | None = None
    details: dict[str, Any] = field(default_factory=dict)

    @property
    def retryable(self) -> bool:
        return self.category in RETRYABLE

    @property
    def budget_consuming(self) -> bool:
        return self.category not in NON_BUDGET_CONSUMING


@dataclass(frozen=True, slots=True)
class Outcome[T]:
    """Either a value or an :class:`ErrorRecord`. Construct via :meth:`ok` / :meth:`fail`."""

    value_or_none: T | None = None
    error: ErrorRecord | None = None

    @classmethod
    def ok(cls, value: T) -> Outcome[T]:
        return cls(value_or_none=value, error=None)

    @classmethod
    def fail(
        cls,
        category: ErrorCategory,
        message: str,
        *,
        remedy: str | None = None,
        retry_after_s: float | None = None,
        dependency: str | None = None,
        evidence: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> Outcome[T]:
        return cls(
            value_or_none=None,
            error=ErrorRecord(
                category=category,
                message=message,
                remedy=remedy,
                retry_after_s=retry_after_s,
                dependency=dependency,
                evidence=evidence,
                details=details or {},
            ),
        )

    @classmethod
    def of(cls, error: ErrorRecord) -> Outcome[T]:
        return cls(value_or_none=None, error=error)

    @property
    def is_ok(self) -> bool:
        return self.error is None

    @property
    def is_err(self) -> bool:
        return self.error is not None

    @property
    def category(self) -> ErrorCategory | None:
        return self.error.category if self.error else None

    @property
    def retryable(self) -> bool:
        return self.error is not None and self.error.retryable

    @property
    def budget_consuming(self) -> bool:
        """Success consumes budget; a failure consumes it only if it was the attempt's fault."""
        return True if self.error is None else self.error.budget_consuming

    def unwrap(self) -> T:
        if self.error is not None:
            raise OutcomeUnwrapError(f"{self.error.category}: {self.error.message}")
        # An ok Outcome always carries a value; None is only reachable for Outcome[None].
        return self.value_or_none  # type: ignore[return-value]

    def unwrap_or(self, default: T) -> T:
        return default if self.error is not None else self.unwrap()

    def map[U](self, fn: Callable[[T], U]) -> Outcome[U]:
        """Transform a value, preserving a failure untouched."""
        if self.error is not None:
            return Outcome[U].of(self.error)
        return Outcome[U].ok(fn(self.unwrap()))
