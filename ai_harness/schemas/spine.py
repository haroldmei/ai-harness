"""Gate-spine comparison contracts (#98, S2 of Phase 8).

The same reasoning that put the shadow shapes in ``schemas/``: a comparison is **durable**, the
criterion spans more commits than one process sees, and the store sits below the code that
decides. So the shapes live here and the decision logic stays where it belongs.

What is being compared is one layer down from a review. Two *spines* — a repository's tuned
``quality-gates.sh`` and the declaration proposed to replace it — run on the same commit, and the
question is whether the declaration is the same contract. A spine that agrees on every gate it
runs while quietly not running one is the failure mode: from the outside it looks like a suite
that got faster.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum

from ai_harness.schemas.enums import GateStatus


class Difference(StrEnum):
    """How two spines disagreed about one gate."""

    AGREE = "agree"
    MISSING = "missing"
    """In the shell spine, absent from the declaration. The migration lost a gate."""
    ADDED = "added"
    """In the declaration, absent from the shell spine. Not a weakening, but not a like-for-like
    move either — somebody has to say it was intended."""
    STATUS = "status"
    """Both ran it and disagreed about the verdict."""
    REQUIREDNESS = "requiredness"
    """Both ran it, both agree on the status, and only one of them would have blocked a merge.
    A gate demoted to advisory is a gate removed, slowly."""
    REASON = "reason"
    """Same status, different diagnostic. Cosmetic unless the reason is what a human reads."""
    DURATION = "duration"
    """Same verdict, different wall-clock. Never disqualifying, recorded because a declaration
    that is ten times slower will be turned off by somebody in a hurry."""


DISQUALIFYING: frozenset[Difference] = frozenset(
    {Difference.MISSING, Difference.STATUS, Difference.REQUIREDNESS}
)
"""Stated **before** the run, because a threshold chosen afterwards is a threshold chosen to
pass. A lost gate, a verdict that flipped, or a gate that stopped being able to block are the
three ways a declaration is weaker than the spine it replaces; everything else is noise or
tuning."""

DURATION_TOLERANCE = 0.25
"""Below this relative difference, two durations are the same number. Gate timings vary with
what else is on the box, and a comparator that reports every jitter is a comparator nobody
reads."""


@dataclass(frozen=True, slots=True)
class GateOutcome:
    """One gate's result, reduced to what a comparison actually turns on."""

    name: str
    status: GateStatus | None
    required: bool = False
    reason: str = ""
    duration_s: float = 0.0

    @property
    def present(self) -> bool:
        return self.status is not None

    @property
    def green(self) -> bool:
        return self.status in (GateStatus.PASS, GateStatus.SKIP)


@dataclass(frozen=True, slots=True)
class GateDifference:
    """One gate, compared. Explainable on its own, because that is how it gets cleared."""

    gate: str
    kind: Difference
    shell: GateOutcome | None = None
    declared: GateOutcome | None = None
    note: str = ""
    explanation: str = ""

    @property
    def disqualifying(self) -> bool:
        """Whether this alone blocks the declaration from replacing the spine."""
        if self.kind not in DISQUALIFYING:
            return False
        if self.kind is Difference.STATUS:
            # A declaration that is *stricter* than the spine is not a weakening. The direction
            # that matters is green-here-red-there: that is the gate that would have caught
            # something and now does not.
            return bool(
                self.declared and self.declared.green and self.shell and not self.shell.green
            )
        return True

    @property
    def explained(self) -> bool:
        return self.kind is Difference.AGREE or bool(self.explanation)


@dataclass(frozen=True, slots=True)
class SpineComparison:
    """One commit, both spines, every gate accounted for."""

    repo: str
    commit_sha: str
    differences: list[GateDifference] = field(default_factory=list)
    observed_at: datetime | None = None

    @property
    def disagreements(self) -> list[GateDifference]:
        return [d for d in self.differences if d.kind is not Difference.AGREE]

    @property
    def unexplained(self) -> list[GateDifference]:
        return [d for d in self.disagreements if not d.explained]

    @property
    def blocking(self) -> list[GateDifference]:
        return [d for d in self.differences if d.disqualifying and not d.explanation]

    @property
    def clear(self) -> bool:
        """The cutover criterion, and it is #43's rather than a new one: **every disagreement
        explained**, not zero disagreements."""
        return not self.unexplained
