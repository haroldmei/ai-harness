"""The audit log (§21.5) — what was attempted, what was decided, and what happened.

Separate from the application log on purpose. A log line is for a human debugging; an audit
record answers "what did this autonomous system actually do to my repository", and it must be
complete even when nothing went wrong. Every brokered tool call writes one, allowed or not.

Arguments are redacted on the way in, because an audit trail that leaks the token it was
auditing is worse than none.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.redaction import Redactor
from ai_harness.schemas.enums import Capability, Decision


@dataclass(frozen=True, slots=True)
class AuditRecord:
    run_id: str
    state: str
    actor: str
    tool: str
    capability: Capability
    decision: Decision
    at: datetime
    arguments: dict[str, Any] = field(default_factory=dict)
    outcome: str = ""
    reason: str = ""
    evidence: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "run_id": self.run_id,
            "state": self.state,
            "actor": self.actor,
            "tool": self.tool,
            "capability": self.capability.value,
            "decision": self.decision.value,
            "outcome": self.outcome,
            "reason": self.reason,
            "evidence": self.evidence,
            "arguments": self.arguments,
            "at": self.at.isoformat(),
        }


@dataclass
class AuditLog:
    """Collects audit records. In-memory here; a durable sink is a Phase 5 concern."""

    redactor: Redactor = field(default_factory=Redactor)
    clock: Clock = field(default_factory=SystemClock)
    records: list[AuditRecord] = field(default_factory=list)

    def write(
        self,
        *,
        run_id: str,
        state: str,
        actor: str,
        tool: str,
        capability: Capability,
        decision: Decision,
        arguments: dict[str, Any] | None = None,
        outcome: str = "",
        reason: str = "",
        evidence: list[str] | None = None,
    ) -> AuditRecord:
        record = AuditRecord(
            run_id=run_id,
            state=state,
            actor=actor,
            tool=tool,
            capability=capability,
            decision=decision,
            at=self.clock.now(),
            arguments={
                key: self.redactor.field(key, value) for key, value in (arguments or {}).items()
            },
            outcome=outcome,
            reason=reason,
            evidence=list(evidence or []),
        )
        self.records.append(record)
        return record

    def for_run(self, run_id: str) -> list[AuditRecord]:
        return [r for r in self.records if r.run_id == run_id]

    def denials(self) -> list[AuditRecord]:
        return [r for r in self.records if r.decision is not Decision.ALLOW]
