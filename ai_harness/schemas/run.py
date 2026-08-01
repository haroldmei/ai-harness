"""``Run`` — the durable row that replaces four disagreeing stores (W1, W2).

Every counter the shell harness reconstructs by scraping PR comments is a field here: the
review round, the re-arm count, the environmental-defer count, the self-repair count, the
deps-retry count and the empty-envelope streak. They survive a reboot, which ``/tmp`` counters
did not, and reading one costs a query rather than an API call plus a regex.

``(state, status)`` is the whole position: a parked run *is* in its state.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, Field

from ai_harness.kernel.budget import RunSpend
from ai_harness.schemas.enums import Disposition, RunStatus, State
from ai_harness.schemas.job import JobRequest


class Counters(BaseModel):
    """Bounded loops, in one place. Every field is a §3.11 bound made durable."""

    review_rounds: int = 0
    implement_attempts: int = 0
    plan_attempts: int = 0
    validate_attempts: int = 0
    self_repair_attempts: int = 0
    deps_retries: int = 0
    env_defers: int = 0
    rearms: int = 0
    resolver_attempts: int = 0
    empty_envelope_streak: int = 0
    """Consecutive, and reset by any non-empty result — a streak, not a total."""
    schema_repairs: int = 0

    def bump(self, field: str, by: int = 1) -> Counters:
        return self.model_copy(update={field: getattr(self, field) + by})


class Run(BaseModel):
    """The unit of durable state. Labels become a projection of this, not the reverse."""

    run_id: str
    request: JobRequest
    state: State = State.PREPARE
    status: RunStatus = RunStatus.RUNNING
    disposition: Disposition | None = None

    counters: Counters = Field(default_factory=Counters)
    spend_usd: Decimal = Decimal(0)
    tokens: int = 0

    base_sha: str = ""
    head_sha: str = ""
    branch: str = ""
    worktree_path: str | None = None
    mr_id: str | None = None
    mr_url: str | None = None

    defer_until: datetime | None = None
    blocked_on: str | None = None
    pending_approval_id: str | None = None
    lease_holder: str | None = None

    started_at: datetime | None = None
    updated_at: datetime | None = None
    finished_at: datetime | None = None
    last_error: str | None = None

    @property
    def terminal(self) -> bool:
        return self.state is State.COMPLETE and self.disposition is not None

    @property
    def parked(self) -> bool:
        return self.status is not RunStatus.RUNNING

    def spend_view(self) -> RunSpend:
        """The projection the kernel breaker consumes, so it need not import this module."""
        return RunSpend(
            run_id=self.run_id,
            repo=self.request.repo,
            started_at=self.started_at or datetime.min,
            tokens=self.tokens,
            attempts_by_state={
                State.ANALYSE.value: self.counters.plan_attempts,
                State.IMPLEMENT.value: self.counters.implement_attempts,
                State.VALIDATE.value: self.counters.validate_attempts,
                State.REVIEW.value: self.counters.review_rounds,
            },
        )
