"""The review contract — where a self-contradicting verdict is corrected in code.

Invariant 4: *a schema-valid answer that violates a cross-field invariant is corrected in
code*. A model that returns ``approve`` while listing blocker findings has not approved
anything; the shell reviewer handles this with an ``if`` at one call site, and the port
handles it in the type, so every consumer of a ``ReviewResult`` sees the corrected verdict.

Findings must be falsifiable: a citation is required, because *"MUST cite a file:line"* in a
prompt is a request, and a validator is a guarantee.
"""

from __future__ import annotations

from pydantic import BaseModel, Field, model_validator

from ai_harness.schemas.enums import BLOCKING_SEVERITIES, Severity, Verdict


class Finding(BaseModel):
    """One reviewer finding. Unfalsifiable findings are rejected, not down-weighted."""

    severity: Severity
    title: str = Field(min_length=1)
    file: str = Field(min_length=1)
    line: int = Field(ge=1)
    detail: str = ""
    suggested_fix: str | None = None

    @property
    def citation(self) -> str:
        return f"{self.file}:{self.line}"

    @property
    def blocking(self) -> bool:
        return self.severity in BLOCKING_SEVERITIES


class ReviewResult(BaseModel):
    """A verdict plus its evidence, reconciled."""

    verdict: Verdict
    summary: str = ""
    findings: list[Finding] = Field(default_factory=list)
    acceptance_criteria_met: bool | None = None
    tests_exercise_the_change: bool | None = None
    """§19.5's question, asked of the model as a second line of defence behind the check."""

    round: int = Field(default=1, ge=1)
    model: str = ""
    downgraded: bool = False
    downgrade_reason: str | None = None

    @model_validator(mode="after")
    def _reconcile_verdict_with_findings(self) -> ReviewResult:
        blocking = [f for f in self.findings if f.blocking]
        if self.verdict is Verdict.APPROVE and blocking:
            object.__setattr__(self, "verdict", Verdict.REQUEST_CHANGES)
            object.__setattr__(self, "downgraded", True)
            object.__setattr__(
                self,
                "downgrade_reason",
                "approve is inconsistent with "
                + ", ".join(f"{f.severity} at {f.citation}" for f in blocking),
            )
        return self

    @property
    def blocking_findings(self) -> list[Finding]:
        return [f for f in self.findings if f.blocking]

    @property
    def approved(self) -> bool:
        return self.verdict is Verdict.APPROVE

    def severity_histogram(self) -> dict[str, int]:
        counts = dict.fromkeys((s.value for s in Severity), 0)
        for finding in self.findings:
            counts[finding.severity.value] += 1
        return counts
