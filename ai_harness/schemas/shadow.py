"""Shadow-mode contracts (§24 Phase 2).

These are in ``schemas/`` rather than beside ``compare()`` for one reason: a comparison is now
**durable**. The cutover gates on a week of agreement, a week outlives every process, and the
store cannot import ``orchestration`` — it sits below it. So the shapes live here, where both
the comparator and the table can see them, and the *decision logic* stays where it belongs.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from enum import StrEnum

from ai_harness.schemas.enums import Signal, Verdict
from ai_harness.schemas.review import ReviewResult


class Agreement(StrEnum):
    AGREE = "agree"
    DISAGREE_VERDICT = "disagree_verdict"
    DISAGREE_FINDINGS = "disagree_findings"
    SHELL_ONLY = "shell_only"
    """The Python path produced nothing — it failed, or was not run."""
    PYTHON_ONLY = "python_only"


@dataclass(frozen=True, slots=True)
class Decision:
    """What one engine decided, reduced to what actually matters for the comparison."""

    engine: str
    verdict: Verdict | None
    blocking: int = 0
    next_signal: Signal | None = None
    downgraded: bool = False
    note: str = ""
    usd: Decimal = Decimal(0)
    """What this decision cost. §24.1's "cost increases" row needs both paths priced on the
    same reviews — comparing a month of shell spend against a week of Python spend proves
    nothing, and comparing per-run averages flatters whichever path escalates more."""

    @classmethod
    def from_review(
        cls, engine: str, review: ReviewResult, *, usd: Decimal = Decimal(0)
    ) -> Decision:
        return cls(
            engine=engine,
            verdict=review.verdict,
            blocking=len(review.blocking_findings),
            next_signal=Signal.ADVANCE if review.approved else Signal.FIX,
            downgraded=review.downgraded,
            usd=usd,
        )

    @classmethod
    def absent(cls, engine: str, note: str) -> Decision:
        return cls(engine=engine, verdict=None, note=note)


@dataclass(frozen=True, slots=True)
class Comparison:
    """One shadow observation, explainable on its own."""

    run_id: str
    head_sha: str
    round: int
    shell: Decision
    python: Decision
    agreement: Agreement
    explanation: str = ""
    repo: str = ""
    observed_at: datetime | None = None

    @property
    def explained(self) -> bool:
        return self.agreement is Agreement.AGREE or bool(self.explanation)
