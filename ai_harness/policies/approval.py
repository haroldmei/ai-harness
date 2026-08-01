"""The approval gateway — a park, never a prompt.

Two properties, both structural:

**A parked run holds no lease and no worker.** ``run_until_boundary`` returns when it sees
``AWAITING_APPROVAL``, and returning releases the lease. A gateway that blocked waiting for a
human would pin a worker for up to three days and make the run unresumable by anyone else.

**An approval nobody answers is a decision not to proceed** (Q14). 24h → ``DEFERRED``, 72h →
``ESCALATED``, driven by the injectable clock rather than by a background job, so the timeout is
computed from the stored request whenever anyone looks — including a worker that only started
today.

Requests carry the *specific* evidence: the path, the command, the deleted test. A human should
not have to re-derive what the harness already knew in order to answer.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from uuid import uuid4

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.persistence.sql import SqlStore
from ai_harness.schemas.approval import ApprovalDecision, ApprovalRequest
from ai_harness.schemas.enums import Capability, RunStatus, State
from ai_harness.schemas.policy import ApprovalPolicy


class ApprovalState(StrEnum):
    PENDING = "pending"
    APPROVED = "approved"
    DENIED = "denied"
    TIMED_OUT_DEFERRED = "timed_out_deferred"
    TIMED_OUT_ESCALATED = "timed_out_escalated"


@dataclass(frozen=True, slots=True)
class ApprovalOutcome:
    """Where the run goes now that the approval has (or has not) been answered."""

    state: ApprovalState
    request: ApprovalRequest
    decision: ApprovalDecision | None = None
    reason: str = ""

    @property
    def may_proceed(self) -> bool:
        return self.state is ApprovalState.APPROVED

    @property
    def terminal(self) -> bool:
        return self.state in (ApprovalState.DENIED, ApprovalState.TIMED_OUT_ESCALATED)

    @property
    def run_status(self) -> RunStatus:
        if self.state is ApprovalState.PENDING:
            return RunStatus.AWAITING_APPROVAL
        if self.state is ApprovalState.TIMED_OUT_DEFERRED:
            return RunStatus.DEFERRED
        if self.terminal:
            return RunStatus.PARKED_TERMINAL
        return RunStatus.RUNNING


@dataclass
class ApprovalGateway:
    """Requests approvals, and answers "may this run continue" on re-dispatch."""

    store: SqlStore
    policy: ApprovalPolicy = field(default_factory=ApprovalPolicy)
    clock: Clock = field(default_factory=SystemClock)

    async def request(
        self,
        *,
        run_id: str,
        state: State,
        capability: Capability,
        reason: str,
        evidence: list[str] | None = None,
    ) -> Outcome[ApprovalRequest]:
        """Record the request. The caller then parks; it does not wait."""
        if not reason:
            # A request without a reason cannot be answered, only guessed at.
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                "an approval request must say what it is asking for",
            )
        approval = ApprovalRequest(
            approval_id=uuid4().hex[:16],
            run_id=run_id,
            state=state,
            capability=capability,
            reason=reason,
            evidence=list(evidence or []),
            requested_at=self.clock.now(),
            defer_after_h=self.policy.timeout_to_deferred_h,
            escalate_after_h=self.policy.timeout_to_escalated_h,
        )
        await self.store.request(approval)
        return Outcome.ok(approval)

    async def poll(self, approval_id: str) -> Outcome[ApprovalOutcome]:
        """Has this been answered, and if not, has it been unanswered for too long?"""
        pending = [r for r in await self.store.pending() if r.approval_id == approval_id]
        decision = await self.store.poll(approval_id)

        if decision is not None:
            request = pending[0] if pending else await self._reconstruct(approval_id)
            if request is None:
                return Outcome.fail(ErrorCategory.NEEDS_HUMAN, f"no approval request {approval_id}")
            return Outcome.ok(
                ApprovalOutcome(
                    state=ApprovalState.APPROVED if decision.approved else ApprovalState.DENIED,
                    request=request,
                    decision=decision,
                    reason=decision.reason
                    or ("approved" if decision.approved else "denied by the operator"),
                )
            )

        if not pending:
            return Outcome.fail(ErrorCategory.NEEDS_HUMAN, f"no approval request {approval_id}")

        request = pending[0]
        now = self.clock.now()
        if request.expired_by(now):
            return Outcome.ok(
                ApprovalOutcome(
                    state=ApprovalState.TIMED_OUT_ESCALATED,
                    request=request,
                    reason=(
                        f"unanswered for {request.escalate_after_h}h — an approval nobody "
                        "answers is a decision not to proceed"
                    ),
                )
            )
        if request.deferred_by(now):
            return Outcome.ok(
                ApprovalOutcome(
                    state=ApprovalState.TIMED_OUT_DEFERRED,
                    request=request,
                    reason=(
                        f"unanswered for {request.defer_after_h}h — deferred, and escalated at "
                        f"{request.escalate_after_h}h"
                    ),
                )
            )
        return Outcome.ok(
            ApprovalOutcome(state=ApprovalState.PENDING, request=request, reason="waiting")
        )

    async def decide(
        self, approval_id: str, *, approved: bool, by: str, reason: str = ""
    ) -> Outcome[ApprovalDecision]:
        decision = ApprovalDecision(
            approval_id=approval_id,
            approved=approved,
            decided_by=by,
            reason=reason,
            decided_at=self.clock.now(),
        )
        try:
            await self.store.decide(decision)
        except KeyError:
            return Outcome.fail(ErrorCategory.NEEDS_HUMAN, f"no approval request {approval_id}")
        return Outcome.ok(decision)

    async def pending_for(self, repo: str | None = None) -> list[ApprovalRequest]:
        return await self.store.pending(repo=repo)

    async def _reconstruct(self, approval_id: str) -> ApprovalRequest | None:
        """A decided request is no longer "pending"; fetch it from the row that decided it."""
        from sqlalchemy import select

        from ai_harness.persistence.models import ApprovalRow

        def _load(session: object) -> ApprovalRequest | None:
            row = session.scalars(  # type: ignore[attr-defined]
                select(ApprovalRow).where(ApprovalRow.approval_id == approval_id)
            ).first()
            if row is None:
                return None
            return ApprovalRequest(
                approval_id=row.approval_id,
                run_id=row.run_id,
                state=State(row.state),
                capability=Capability(row.capability),
                reason=row.reason,
                evidence=list(row.evidence or []),
                requested_at=row.requested_at,
            )

        return await self.store._run(_load)
