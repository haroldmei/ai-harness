"""Scout contracts (Q12, §3.16).

A candidate is not an issue. It becomes one only after its citation survives a local read, a
different model fails to refute it, and its fingerprint is absent from both the open and the
closed issues. Everything here is shaped to make those three checks possible — which is why
``evidence`` is a required-in-practice string rather than free prose, and why ``confidence`` is
a number the ranking can use rather than an adjective.
"""

from __future__ import annotations

from pydantic import BaseModel, Field, field_validator

SEVERITY_WEIGHT: dict[str, float] = {"p0": 3.0, "p1": 2.0, "p2": 1.0}


class ScoutCandidate(BaseModel):
    """One finding, before anyone has decided whether it is real."""

    title: str
    body: str = ""
    engine: str = "bug"
    """``bug`` | ``ux`` | ``req`` | ``journey`` | ``docs``."""
    severity: str = "p2"
    evidence: str = ""
    """``path:line``. Re-verified against the working tree before filing (discipline 1)."""
    confidence: float = 1.0
    business_impact: float = 1.0
    labels: list[str] = Field(default_factory=list)
    fingerprint: str = ""

    @field_validator("severity")
    @classmethod
    def _known_severity(cls, value: str) -> str:
        """An unknown severity is not silently treated as low.

        Same rule as an unknown tier aborting rather than defaulting: a typo that quietly
        demotes a p0 to the bottom of the queue is worse than a loud rejection.
        """
        if value not in SEVERITY_WEIGHT:
            raise ValueError(
                f"unknown severity {value!r}; expected one of {sorted(SEVERITY_WEIGHT)}"
            )
        return value

    @property
    def rank(self) -> float:
        """severity × confidence × business impact — the order the queue is filed in."""
        return SEVERITY_WEIGHT[self.severity] * self.confidence * self.business_impact


class ScoutVerdict(BaseModel):
    """The critic's answer. A different model from the producer, always."""

    refuted: bool = False
    reason: str = ""
    """``false gap`` | ``already built`` | ``stale spec`` | ``imagined`` | ``duplicate`` |
    ``low value`` — the six the shell's critic uses."""
    confidence: float = 1.0

    @property
    def survives(self) -> bool:
        return not self.refuted


class ScoutReport(BaseModel):
    """What one pass did. Auditable after the fact: why was X filed, or not?"""

    produced: int = 0
    filed: list[int] = Field(default_factory=list)
    dropped: dict[str, int] = Field(default_factory=dict)
    """reason → count. This is the number that tells an operator the disciplines are working."""
    withheld: int = 0
    """Survivors past the per-run cap. Not lost — the next pass sees them again."""

    @property
    def filed_nothing(self) -> bool:
        return not self.filed
