"""Storage protocols — the seam that makes Q3 and Q4 cheap.

Three stores, deliberately separate because they have different lifetimes and different
readers: runs and checkpoints are the FSM's own memory; the ledger is triage's; cost is the
operator's.

The one method that matters most is :meth:`RunStore.commit_transition`. §15.3 requires the
checkpoint write and the run update to land **in one transaction**: a crash between them would
leave a run whose position disagrees with its own history, which is exactly the class of
disagreement this layer exists to end.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Protocol

from ai_harness.kernel.budget import CostEvent
from ai_harness.schemas.approval import ApprovalDecision, ApprovalRequest
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.enums import RunStatus, State
from ai_harness.schemas.job import JobRequest
from ai_harness.schemas.run import Run


class RunStore(Protocol):
    """Runs and their checkpoints — created, advanced, resumed, listed."""

    async def create(self, request: JobRequest, *, run_id: str | None = None) -> Run: ...

    async def load(self, run_id: str) -> Run | None: ...

    async def find_active(self, repo: str, issue: int) -> Run | None:
        """The live run for an issue, if any. What makes a second claim a no-op."""
        ...

    async def list_runs(
        self,
        *,
        repo: str | None = None,
        state: State | None = None,
        status: RunStatus | None = None,
        limit: int = 50,
    ) -> list[Run]: ...

    async def commit_transition(
        self,
        run: Run,
        checkpoint: Checkpoint,
    ) -> Run:
        """Persist the checkpoint and the updated run **atomically**."""
        ...

    async def checkpoints(self, run_id: str) -> list[Checkpoint]: ...

    async def next_seq(self, run_id: str) -> int: ...


class LedgerStore(Protocol):
    """The triage ledger: fingerprint → attempts, open blocker, and the resolution."""

    async def record_attempt(
        self,
        *,
        repo: str,
        signature: str,
        gate: str = "",
        triage_class: str = "",
        normalised: str | None = None,
    ) -> int:
        """Increment and return the attempt count for this signature."""
        ...

    async def attempts(self, repo: str, signature: str) -> int: ...

    async def open_blockers(self, repo: str) -> int:
        """How many auto-filed blockers are open globally — the §3.11 ``TRIAGE_MAX_OPEN`` cap."""
        ...

    async def set_blocker(self, repo: str, signature: str, blocker: str | None) -> None: ...

    async def record_resolution(self, repo: str, signature: str, resolution: str) -> None:
        """What actually fixed it. The shell ledger discards this; it is the reusable part."""
        ...


class CostStore(Protocol):
    """Spend, queryable by run, by repo and by day."""

    async def record(self, event: CostEvent) -> None: ...

    async def run_total(self, run_id: str) -> Decimal: ...

    async def repo_day_total(self, repo: str, day: datetime | None = None) -> Decimal: ...

    async def summary(
        self, *, repo: str | None = None, since: datetime | None = None
    ) -> dict[str, object]: ...


class ApprovalStore(Protocol):
    """Outstanding and settled approvals. Polled by the machine on re-dispatch."""

    async def request(self, request: ApprovalRequest) -> None: ...

    async def poll(self, approval_id: str) -> ApprovalDecision | None: ...

    async def decide(self, decision: ApprovalDecision) -> None: ...

    async def pending(self, *, repo: str | None = None) -> list[ApprovalRequest]: ...
