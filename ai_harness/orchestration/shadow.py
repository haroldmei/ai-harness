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
from datetime import datetime, timedelta
from typing import Any

from ai_harness.schemas.enums import Verdict
from ai_harness.schemas.shadow import Agreement, Comparison, Decision

__all__ = [
    "Agreement",
    "Comparison",
    "Decision",
    "ShadowComparator",
    "compare",
    "load_comparator",
    "window_start",
]

OBSERVATION_WINDOW_DAYS = 7
"""§24 Phase 2's "at least a week". Kept as a constant so the report and the gate agree."""


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
        """§24 Phase 2, all three parts: **a week** of observation, agreement above the
        threshold, and every disagreement explained.

        The window is part of the gate rather than only part of the report, because the failure
        it prevents is the tempting one: four reviews in one afternoon, all agreeing, and a
        cutover that looks fully evidenced.
        """
        return (
            bool(self.observations)
            and self.long_enough
            and self.agreement_rate >= threshold
            and not self.unexplained
        )

    @property
    def observed_days(self) -> float:
        """How long the observation has actually been running.

        A 100% agreement rate over four reviews in one afternoon is not the evidence §24 Phase 2
        asks for, and a report that showed only the rate would let it look like it was.
        """
        stamped = [o.observed_at for o in self.observations if o.observed_at is not None]
        if len(stamped) < 2:
            return 0.0
        return (max(stamped) - min(stamped)).total_seconds() / 86400

    @property
    def long_enough(self) -> bool:
        return self.observed_days >= OBSERVATION_WINDOW_DAYS

    def cost_per_review(self) -> dict[str, float]:
        """Both paths, priced on the *same* reviews (§24.1's "cost increases" risk row).

        Comparing a month of shell spend against a week of Python spend proves nothing; these
        are the same commits at the same rounds, so the ratio is the only honest one available.
        """
        if not self.observations:
            return {"shell": 0.0, "python": 0.0, "ratio": 0.0}
        shell = sum(float(o.shell.usd) for o in self.observations)
        python = sum(float(o.python.usd) for o in self.observations)
        count = len(self.observations)
        return {
            "shell": round(shell / count, 6),
            "python": round(python / count, 6),
            "ratio": round(python / shell, 4) if shell else 0.0,
        }

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
            "observed_days": round(self.observed_days, 2),
            "long_enough": self.long_enough,
            "cost_per_review_usd": self.cost_per_review(),
            "blocked_by": self._blockers(),
        }

    def _blockers(self) -> list[str]:
        """Why the cutover is not allowed yet, in the operator's words rather than a boolean."""
        reasons: list[str] = []
        if not self.observations:
            reasons.append("nothing has been observed")
        if not self.long_enough:
            reasons.append(
                f"observed for {self.observed_days:.1f} of {OBSERVATION_WINDOW_DAYS} days"
            )
        if self.observations and self.agreement_rate < 0.95:
            reasons.append(f"agreement {self.agreement_rate:.1%} is below 95%")
        if self.unexplained:
            reasons.append(f"{len(self.unexplained)} disagreements are unexplained")
        return reasons


def window_start(now: datetime, *, days: int = OBSERVATION_WINDOW_DAYS) -> datetime:
    return now - timedelta(days=days)


async def load_comparator(
    store: Any, *, repo: str | None = None, since: Any = None
) -> ShadowComparator:
    """Rebuild the comparator from durable observations.

    This is the whole point of the table: the process that reports on the week is never the
    process that observed it.
    """
    return ShadowComparator(observations=list(await store.comparisons(repo=repo, since=since)))
