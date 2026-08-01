"""Shadow mode — run both engines, compare the *decisions*, change nothing.

§24 Phase 2's cutover mechanism. The shell reviewer posts the verdict and owns the label; the
Python reviewer records to a ``harness-shadow`` label and nothing else. ``ShadowComparator``
diffs what each *decided* — verdict, blocking findings, next state — not what each said.

Two things are worth stating plainly:

**Only the shell path may have side effects.** The Python path runs with forge writes blocked,
and a test asserts that a blocked write is an error rather than a silently skipped one.

**Expect disagreements where the Python path is right.** The shell reviewer's known defects are
in the comparison set: the ``{``-character extraction bug (#2419) and the approve-with-blockers
self-contradiction. A disagreement is not automatically a regression, which is why the cutover
criterion is *every disagreement explained*, not *zero disagreements*.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
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

    @classmethod
    def from_review(cls, engine: str, review: ReviewResult) -> Decision:
        return cls(
            engine=engine,
            verdict=review.verdict,
            blocking=len(review.blocking_findings),
            next_signal=Signal.ADVANCE if review.approved else Signal.FIX,
            downgraded=review.downgraded,
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

    @property
    def explained(self) -> bool:
        return self.agreement is Agreement.AGREE or bool(self.explanation)


def compare(
    *, run_id: str, head_sha: str, round_: int, shell: Decision, python: Decision
) -> Comparison:
    """Diff two decisions, and say *why* they differ when they do."""
    if python.verdict is None:
        return Comparison(
            run_id=run_id,
            head_sha=head_sha,
            round=round_,
            shell=shell,
            python=python,
            agreement=Agreement.SHELL_ONLY,
            explanation=python.note,
        )
    if shell.verdict is None:
        return Comparison(
            run_id=run_id,
            head_sha=head_sha,
            round=round_,
            shell=shell,
            python=python,
            agreement=Agreement.PYTHON_ONLY,
            explanation=shell.note or "the shell reviewer produced no verdict",
        )

    if shell.verdict is not python.verdict:
        explanation = ""
        if python.downgraded and shell.verdict is Verdict.APPROVE:
            # The known defect, observed: the shell obeyed a self-contradicting verdict.
            explanation = (
                "the model approved while listing blocking findings; the Python path downgraded "
                "it in code (invariant 4) and the shell path did not"
            )
        return Comparison(
            run_id=run_id,
            head_sha=head_sha,
            round=round_,
            shell=shell,
            python=python,
            agreement=Agreement.DISAGREE_VERDICT,
            explanation=explanation,
        )

    if shell.blocking != python.blocking:
        return Comparison(
            run_id=run_id,
            head_sha=head_sha,
            round=round_,
            shell=shell,
            python=python,
            agreement=Agreement.DISAGREE_FINDINGS,
            explanation=(
                f"same verdict, different blocking counts ({shell.blocking} vs {python.blocking})"
            ),
        )

    return Comparison(
        run_id=run_id,
        head_sha=head_sha,
        round=round_,
        shell=shell,
        python=python,
        agreement=Agreement.AGREE,
    )


@dataclass
class ShadowComparator:
    """Accumulates comparisons and reports the agreement rate the cutover gates on."""

    observations: list[Comparison] = field(default_factory=list)

    def observe(self, comparison: Comparison) -> Comparison:
        self.observations.append(comparison)
        return comparison

    @property
    def agreement_rate(self) -> float:
        if not self.observations:
            return 0.0
        agreed = sum(1 for o in self.observations if o.agreement is Agreement.AGREE)
        return agreed / len(self.observations)

    @property
    def unexplained(self) -> list[Comparison]:
        """Disagreements nobody has accounted for. The cutover blocks on this being empty."""
        return [o for o in self.observations if not o.explained]

    def may_cut_over(self, *, threshold: float = 0.95) -> bool:
        """Agreement above the threshold **and** every disagreement explained (§24 Phase 2)."""
        return bool(self.observations) and self.agreement_rate >= threshold and not self.unexplained

    def report(self) -> dict[str, object]:
        counts = Counter(o.agreement.value for o in self.observations)
        return {
            "observations": len(self.observations),
            "agreement_rate": round(self.agreement_rate, 4),
            "by_agreement": dict(sorted(counts.items())),
            "unexplained": [
                {
                    "run_id": o.run_id,
                    "head_sha": o.head_sha[:12],
                    "round": o.round,
                    "shell": o.shell.verdict.value if o.shell.verdict else None,
                    "python": o.python.verdict.value if o.python.verdict else None,
                }
                for o in self.unexplained
            ],
            "may_cut_over": self.may_cut_over(),
        }
