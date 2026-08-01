"""Approval requests and decisions.

An approval must carry the *specific* evidence — the diff-size breach, the protected path, the
deleted test — because a generic "approve?" is a question a human cannot answer without doing
the harness's work again. Per Q14 an unanswered request is a decision not to proceed.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from pydantic import BaseModel, Field

from ai_harness.schemas.enums import Capability, State


class ApprovalRequest(BaseModel):
    approval_id: str
    run_id: str
    state: State
    capability: Capability
    reason: str
    evidence: list[str] = Field(default_factory=list)
    requested_at: datetime
    defer_after_h: int = 24
    escalate_after_h: int = 72

    def deferred_by(self, now: datetime) -> bool:
        return now >= self.requested_at + timedelta(hours=self.defer_after_h)

    def expired_by(self, now: datetime) -> bool:
        return now >= self.requested_at + timedelta(hours=self.escalate_after_h)


class ApprovalDecision(BaseModel):
    approval_id: str
    approved: bool
    decided_by: str
    reason: str = ""
    decided_at: datetime | None = None

    @property
    def denied(self) -> bool:
        return not self.approved
