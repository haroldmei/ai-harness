"""The work queue — and why it is a query rather than a broker.

§25: ``SELECT … FOR UPDATE SKIP LOCKED`` **is** the work-stealing primitive the shell implements
by hand with rotated per-issue flocks, and it adds **zero new infrastructure**, because Postgres
is already the checkpoint store. Celery or Temporal would each add a service, a serialisation
format and a second place for state to live.

``SKIP LOCKED`` is the whole mechanism: each worker takes a row lock on the runs it selects, and
other workers running the same query *skip* those rows rather than blocking behind them. The
ordering is whatever the ``ORDER BY`` says rather than whatever a queue implementation decided.

On SQLite there is no ``SKIP LOCKED`` and no need for one — writers are serialised by the
database and the local CLI runs one worker. The fallback is documented rather than silent,
because a fallback nobody knows about is how "it works on my machine" starts.

The cost is stated in the design and worth repeating: no fan-out beyond a few hundred concurrent
runs before Postgres becomes the bottleneck. That is far past where this system is.

A claim here is only half of one (invariant 7). The queue says *which* run to look at; the lease
says whether this worker may act on it. Either alone strands work — but the queue also *reads*
the lease table, so it stops offering runs somebody is already holding rather than letting every
idle worker discover that one dispatch at a time.

This lives in ``persistence`` rather than ``providers`` because it is a query over the runs
table, not an external service — and the import contract says so: the two are peers, and a
queue reaching across into the ORM models would be a sideways import.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import datetime
from typing import Protocol

from sqlalchemy import ColumnElement, Engine, and_, func, literal, or_, select
from sqlalchemy.orm import Session, sessionmaker

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.lease import RUN_LEASE_PREFIX
from ai_harness.persistence.models import LeaseRow, RunRow
from ai_harness.schemas.enums import RunStatus, State


@dataclass(frozen=True, slots=True)
class Claim:
    """A run this worker may attempt. Not permission — that is the lease."""

    run_id: str
    repo: str
    state: State
    status: RunStatus
    attempts: int = 0


class Queue(Protocol):
    """Where the next unit of work comes from."""

    async def claim(
        self, *, worker_id: str, limit: int = 1, repo: str | None = None
    ) -> list[Claim]:
        """Runs that are ready to advance, skipping anything another worker is holding."""
        ...

    async def depth(self, *, repo: str | None = None) -> int:
        """How much work is waiting. What an autoscaler would read."""
        ...


SKIP_LOCKED_DIALECTS = {"postgresql"}

CLAIMABLE = (
    RunStatus.RUNNING.value,
    RunStatus.DEFERRED.value,
    RunStatus.BLOCKED.value,
    RunStatus.AWAITING_APPROVAL.value,
)


@dataclass
class SqlQueue:
    """Claims runs that are ready to advance."""

    engine: Engine
    clock: Clock = field(default_factory=SystemClock)
    _sessions: sessionmaker[Session] | None = None

    def __post_init__(self) -> None:
        self._sessions = sessionmaker(self.engine, expire_on_commit=False)

    @property
    def uses_skip_locked(self) -> bool:
        return self.engine.dialect.name in SKIP_LOCKED_DIALECTS

    async def claim(
        self, *, worker_id: str, limit: int = 1, repo: str | None = None
    ) -> list[Claim]:
        now = self.clock.now()

        def _claim() -> list[Claim]:
            assert self._sessions is not None
            with self._sessions() as session, session.begin():
                query = (
                    select(RunRow)
                    .where(RunRow.disposition.is_(None))
                    .where(RunRow.status.in_(CLAIMABLE))
                    .where(_ready(now))
                    .where(_unheld(now))
                    .order_by(RunRow.updated_at.asc())
                    .limit(limit)
                )
                if repo:
                    query = query.where(RunRow.repo == repo)
                if self.uses_skip_locked:
                    # The work-stealing primitive, for free: other workers skip these rows
                    # instead of queueing behind them.
                    query = query.with_for_update(skip_locked=True)
                rows = session.scalars(query).all()
                for row in rows:
                    # Touching updated_at is what stops one worker re-claiming the same run on
                    # its next poll before the machine has advanced it.
                    row.updated_at = now
                return [
                    Claim(
                        run_id=row.run_id,
                        repo=row.repo,
                        state=State(row.state),
                        status=RunStatus(row.status),
                        attempts=_attempts(row),
                    )
                    for row in rows
                ]

        return await asyncio.to_thread(_claim)

    async def depth(self, *, repo: str | None = None) -> int:
        now = self.clock.now()

        def _depth() -> int:
            assert self._sessions is not None
            with self._sessions() as session:
                query = (
                    select(func.count())
                    .select_from(RunRow)
                    .where(RunRow.disposition.is_(None))
                    .where(RunRow.status.in_(CLAIMABLE))
                    .where(_ready(now))
                    .where(_unheld(now))
                )
                if repo:
                    query = query.where(RunRow.repo == repo)
                return int(session.scalar(query) or 0)

        return await asyncio.to_thread(_depth)


def _attempts(row: RunRow) -> int:
    """How many times *this* state has been tried, not how many times the run has moved.

    Carried on the claim so a dispatcher can prioritise or shed without a second query. The
    counters stay per-state because they are per-state budgets (§10) — summing them would let a
    run that has planned four times exhaust the implement budget it has not touched.
    """
    return {
        State.ANALYSE.value: row.plan_attempts,
        State.IMPLEMENT.value: row.implement_attempts,
        State.VALIDATE.value: row.validate_attempts,
        State.REVIEW.value: row.review_rounds,
    }.get(row.state, 0)


def _ready(now: datetime) -> ColumnElement[bool]:
    """A deferred run is not ready until its timer expires — that is what deferral means."""
    return or_(RunRow.defer_until.is_(None), RunRow.defer_until <= now)


def _unheld(now: datetime) -> ColumnElement[bool]:
    """Exclude runs another worker is currently holding.

    ``SKIP LOCKED`` only separates workers whose *transactions overlap*. Two workers whose
    claims are milliseconds apart both see an unlocked row, and without this both get handed the
    same run — the second one then bounces off the lease and does nothing, which is invariant 7
    working as designed but a queue wasting a whole dispatch to discover it. At fleet scale that
    is every idle worker spinning on the same head of the queue.

    The exclusion is exact rather than heuristic because the lease has an expiry column: a
    holder that stopped renewing releases its runs at a knowable time, with no staleness guess.
    """
    held = select(literal(1)).where(
        and_(
            LeaseRow.key == RUN_LEASE_PREFIX + RunRow.run_id,
            LeaseRow.expires_at > now,
        )
    )
    return ~held.exists()
