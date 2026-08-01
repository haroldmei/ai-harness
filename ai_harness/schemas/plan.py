"""``WorkPlan`` — the only LLM output that influences routing, and it is schema-constrained.

The shell harness plans implicitly, inside the build prompt. Making the plan a typed artefact
is what allows ANALYSE to decide *out of scope* or *epic* deterministically, to cache on an
input hash, and to route a high-risk plan to approval before any code is written.
"""

from __future__ import annotations

from hashlib import sha256

from pydantic import BaseModel, Field

from ai_harness.schemas.enums import Risk, TriageClass


class PlannedChange(BaseModel):
    path: str = Field(min_length=1)
    intent: str = Field(min_length=1)


class WorkPlan(BaseModel):
    """What will be changed, why, and what would make it wrong."""

    summary: str = Field(min_length=1)
    approach: str = ""
    changes: list[PlannedChange] = Field(default_factory=list)
    acceptance_mapping: list[str] = Field(default_factory=list)
    """How each acceptance criterion will be demonstrated — usually a test name."""
    out_of_scope: list[str] = Field(default_factory=list)
    risk: Risk = Risk.LOW
    touches_protected_paths: list[str] = Field(default_factory=list)

    in_scope: bool = True
    is_epic: bool = False
    underspecified: bool = False
    escalation_reason: str | None = None

    def plan_hash(self) -> str:
        """Stable identity for the plan, so IMPLEMENT can be idempotent on it."""
        material = "\x1f".join(
            [
                self.summary.strip().lower(),
                self.approach.strip().lower(),
                *sorted(f"{c.path}:{c.intent}".lower() for c in self.changes),
            ]
        )
        return sha256(material.encode()).hexdigest()[:16]

    @property
    def deliverable(self) -> bool:
        return self.in_scope and not self.is_epic and not self.underspecified


class TriageDecision(BaseModel):
    """A red gate, classified. The six classes are the shell taxonomy, unchanged."""

    triage_class: TriageClass
    fingerprint: str | None = None
    """``None`` when the evidence carried no distinguishing content — the caller fails closed."""
    reason: str = ""
    remedy: str | None = None
    blocker_title: str | None = None
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)
    evidence_lines: list[str] = Field(default_factory=list)

    @property
    def files_a_blocker(self) -> bool:
        return self.triage_class in (TriageClass.INFRA, TriageClass.UNRELATED)

    @property
    def consumes_budget(self) -> bool:
        """A transient, a deps problem or a stale base is not the attempt's fault."""
        return self.triage_class is TriageClass.SELF
