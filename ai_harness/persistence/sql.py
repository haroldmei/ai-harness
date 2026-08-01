"""One SQLAlchemy implementation of every store protocol, for both backends.

Q3 is answered by construction: SQLite and Postgres differ by a connection string, not by an
implementation, and the same conformance suite runs against both. The local CLI therefore needs
no database *server* — which is what keeps the "Postgres becomes a new single point of failure"
row of §24.1 from being true.

**Why synchronous SQLAlchemy behind an async facade.** The orchestration layer is async, but
these queries are local, sub-millisecond and transactional. Using the sync engine inside
``asyncio.to_thread`` buys transactional semantics that are identical on both backends and
avoids two more dependencies (``aiosqlite``, ``asyncpg``) whose failure modes differ from each
other. The seam is the protocol, so a future async driver changes this file and nothing else.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any, TypeVar

from sqlalchemy import Engine, create_engine, func, select
from sqlalchemy.orm import Session, sessionmaker

from ai_harness.kernel.budget import CostEvent, is_self_hosted
from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.persistence.models import (
    ApprovalRow,
    Base,
    CheckpointRow,
    ComparisonRow,
    CostRow,
    FingerprintRow,
    RunRow,
)
from ai_harness.schemas.approval import ApprovalDecision, ApprovalRequest
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.enums import Capability, Disposition, RunStatus, State, Verdict
from ai_harness.schemas.errors import ErrorInfo
from ai_harness.schemas.job import JobRequest
from ai_harness.schemas.run import Counters, Run
from ai_harness.schemas.shadow import Agreement, Comparison, Decision

T = TypeVar("T")

_COUNTER_FIELDS = (
    "review_rounds",
    "implement_attempts",
    "plan_attempts",
    "validate_attempts",
    "self_repair_attempts",
    "deps_retries",
    "env_defers",
    "rearms",
    "resolver_attempts",
    "empty_envelope_streak",
    "schema_repairs",
)


class SqlStore:
    """Implements ``RunStore``, ``LedgerStore``, ``CostStore`` and ``ApprovalStore``."""

    def __init__(self, engine: Engine, *, clock: Clock | None = None) -> None:
        self.engine = engine
        self._sessions = sessionmaker(engine, expire_on_commit=False)
        self._clock = clock or SystemClock()

    # ── lifecycle ────────────────────────────────────────────────────────────────

    def create_all(self) -> None:
        """Create the schema directly. Alembic owns this in deployment; tests use it here."""
        Base.metadata.create_all(self.engine)

    def dispose(self) -> None:
        self.engine.dispose()

    async def _run(self, fn: Callable[[Session], T]) -> T:
        def _work() -> T:
            with self._sessions() as session, session.begin():
                return fn(session)

        return await asyncio.to_thread(_work)

    # ── RunStore ─────────────────────────────────────────────────────────────────

    async def create(self, request: JobRequest, *, run_id: str | None = None) -> Run:
        from ai_harness.kernel.ids import new_run_id

        identifier = run_id or new_run_id()
        now = self._clock.now()

        def _create(session: Session) -> Run:
            row = RunRow(
                run_id=identifier,
                repo=request.repo,
                forge=request.forge,
                issue=request.issue,
                state=State.PREPARE.value,
                status=RunStatus.RUNNING.value,
                request=request.model_dump(mode="json"),
                engine=request.profile.engine,
                started_at=now,
                updated_at=now,
            )
            session.add(row)
            session.flush()
            return _to_run(row)

        return await self._run(_create)

    async def load(self, run_id: str) -> Run | None:
        def _load(session: Session) -> Run | None:
            row = session.get(RunRow, run_id)
            return _to_run(row) if row else None

        return await self._run(_load)

    async def find_active(self, repo: str, issue: int) -> Run | None:
        def _find(session: Session) -> Run | None:
            row = session.scalars(
                select(RunRow)
                .where(RunRow.repo == repo, RunRow.issue == issue)
                .where(RunRow.disposition.is_(None))
                .order_by(RunRow.started_at.desc())
                .limit(1)
            ).first()
            return _to_run(row) if row else None

        return await self._run(_find)

    async def list_runs(
        self,
        *,
        repo: str | None = None,
        state: State | None = None,
        status: RunStatus | None = None,
        limit: int = 50,
    ) -> list[Run]:
        def _list(session: Session) -> list[Run]:
            query = select(RunRow)
            if repo:
                query = query.where(RunRow.repo == repo)
            if state:
                query = query.where(RunRow.state == state.value)
            if status:
                query = query.where(RunRow.status == status.value)
            rows = session.scalars(query.order_by(RunRow.started_at.desc()).limit(limit)).all()
            return [_to_run(row) for row in rows]

        return await self._run(_list)

    async def commit_transition(self, run: Run, checkpoint: Checkpoint) -> Run:
        """Write the checkpoint and the run update in ONE transaction (§15.3).

        A crash between the two would leave a run whose position disagrees with its own
        history — the disagreement this whole layer exists to end.
        """

        def _commit(session: Session) -> Run:
            row = session.get(RunRow, run.run_id)
            if row is None:
                raise KeyError(f"unknown run {run.run_id}")
            _apply(row, run, self._clock.now())
            session.add(_to_checkpoint_row(checkpoint))
            session.flush()
            return _to_run(row)

        return await self._run(_commit)

    async def checkpoints(self, run_id: str) -> list[Checkpoint]:
        def _load(session: Session) -> list[Checkpoint]:
            rows = session.scalars(
                select(CheckpointRow)
                .where(CheckpointRow.run_id == run_id)
                .order_by(CheckpointRow.seq)
            ).all()
            return [_to_checkpoint(row) for row in rows]

        return await self._run(_load)

    async def next_seq(self, run_id: str) -> int:
        def _next(session: Session) -> int:
            highest = session.scalar(
                select(func.max(CheckpointRow.seq)).where(CheckpointRow.run_id == run_id)
            )
            return 0 if highest is None else int(highest) + 1

        return await self._run(_next)

    # ── LedgerStore ──────────────────────────────────────────────────────────────

    async def record_attempt(
        self,
        *,
        repo: str,
        signature: str,
        gate: str = "",
        triage_class: str = "",
        normalised: str | None = None,
    ) -> int:
        now = self._clock.now()

        def _record(session: Session) -> int:
            row = session.scalars(
                select(FingerprintRow).where(
                    FingerprintRow.repo == repo, FingerprintRow.signature == signature
                )
            ).first()
            if row is None:
                row = FingerprintRow(
                    repo=repo,
                    signature=signature,
                    gate=gate,
                    triage_class=triage_class,
                    normalised=normalised,
                    attempts=0,
                    first_seen_at=now,
                )
                session.add(row)
            row.attempts += 1
            row.last_seen_at = now
            if gate:
                row.gate = gate
            if triage_class:
                row.triage_class = triage_class
            session.flush()
            return row.attempts

        return await self._run(_record)

    async def attempts(self, repo: str, signature: str) -> int:
        def _attempts(session: Session) -> int:
            row = session.scalars(
                select(FingerprintRow).where(
                    FingerprintRow.repo == repo, FingerprintRow.signature == signature
                )
            ).first()
            return row.attempts if row else 0

        return await self._run(_attempts)

    async def open_blockers(self, repo: str) -> int:
        def _count(session: Session) -> int:
            return int(
                session.scalar(
                    select(func.count())
                    .select_from(FingerprintRow)
                    .where(FingerprintRow.repo == repo, FingerprintRow.open_blocker.is_not(None))
                )
                or 0
            )

        return await self._run(_count)

    async def set_blocker(self, repo: str, signature: str, blocker: str | None) -> None:
        def _set(session: Session) -> None:
            row = session.scalars(
                select(FingerprintRow).where(
                    FingerprintRow.repo == repo, FingerprintRow.signature == signature
                )
            ).first()
            if row is not None:
                row.open_blocker = blocker

        await self._run(_set)

    async def record_resolution(self, repo: str, signature: str, resolution: str) -> None:
        def _resolve(session: Session) -> None:
            row = session.scalars(
                select(FingerprintRow).where(
                    FingerprintRow.repo == repo, FingerprintRow.signature == signature
                )
            ).first()
            if row is not None:
                row.resolution = resolution
                row.open_blocker = None

        await self._run(_resolve)

    # ── CostStore ────────────────────────────────────────────────────────────────

    async def record(self, event: CostEvent) -> None:
        at = event.at or self._clock.now()

        def _record(session: Session) -> None:
            session.add(
                CostRow(
                    run_id=event.run_id,
                    repo=event.repo,
                    state=event.state,
                    provider=event.provider,
                    model=event.model,
                    template_id=event.template_id,
                    usd=event.usd,
                    input_tokens=event.input_tokens,
                    output_tokens=event.output_tokens,
                    cache_read_tokens=event.cache_read_tokens,
                    cache_write_tokens=event.cache_write_tokens,
                    gpu_seconds=event.gpu_seconds,
                    at=at,
                )
            )

        await self._run(_record)

    async def run_total(self, run_id: str) -> Decimal:
        def _total(session: Session) -> Decimal:
            value = session.scalar(select(func.sum(CostRow.usd)).where(CostRow.run_id == run_id))
            return Decimal(value or 0)

        return await self._run(_total)

    async def repo_day_total(self, repo: str, day: datetime | None = None) -> Decimal:
        when = day or self._clock.now()
        start = datetime(when.year, when.month, when.day, tzinfo=when.tzinfo or UTC)
        end = start + timedelta(days=1)

        def _total(session: Session) -> Decimal:
            value = session.scalar(
                select(func.sum(CostRow.usd)).where(
                    CostRow.repo == repo, CostRow.at >= start, CostRow.at < end
                )
            )
            return Decimal(value or 0)

        return await self._run(_total)

    async def summary(
        self, *, repo: str | None = None, since: datetime | None = None
    ) -> dict[str, Any]:
        def _summary(session: Session) -> dict[str, Any]:
            query = select(CostRow)
            if repo:
                query = query.where(CostRow.repo == repo)
            if since:
                query = query.where(CostRow.at >= since)
            rows = list(session.scalars(query).all())
            by_template: dict[str, Decimal] = {}
            for row in rows:
                key = row.template_id or ""
                by_template[key] = by_template.get(key, Decimal(0)) + row.usd
            # Local and hosted spend are different questions -- "what did the box cost to run"
            # and "what did we pay someone" -- and a single total answers neither (L5).
            local = [r for r in rows if is_self_hosted(r.provider or "")]
            hosted = [r for r in rows if not is_self_hosted(r.provider or "")]
            return {
                "calls": len(rows),
                "usd": str(sum((r.usd for r in rows), Decimal(0))),
                "local_usd": str(sum((r.usd for r in local), Decimal(0))),
                "hosted_usd": str(sum((r.usd for r in hosted), Decimal(0))),
                "local_calls": len(local),
                "hosted_calls": len(hosted),
                "input_tokens": sum(r.input_tokens for r in rows),
                "output_tokens": sum(r.output_tokens for r in rows),
                "cache_read_tokens": sum(r.cache_read_tokens for r in rows),
                "gpu_seconds": round(sum(r.gpu_seconds for r in rows), 1),
                "by_template": {k: str(v) for k, v in sorted(by_template.items())},
                "by_run": _group(rows, lambda r: r.run_id),
                "by_repo": _group(rows, lambda r: r.repo),
            }

        return await self._run(_summary)

    # ── ApprovalStore ────────────────────────────────────────────────────────────

    async def request(self, request: ApprovalRequest) -> None:
        def _request(session: Session) -> None:
            session.merge(
                ApprovalRow(
                    approval_id=request.approval_id,
                    run_id=request.run_id,
                    state=request.state.value,
                    capability=request.capability.value,
                    reason=request.reason,
                    evidence=list(request.evidence),
                    requested_at=request.requested_at,
                )
            )

        await self._run(_request)

    async def poll(self, approval_id: str) -> ApprovalDecision | None:
        def _poll(session: Session) -> ApprovalDecision | None:
            row = session.get(ApprovalRow, approval_id)
            if row is None or row.approved is None:
                return None
            return ApprovalDecision(
                approval_id=row.approval_id,
                approved=bool(row.approved),
                decided_by=row.decided_by or "unknown",
                reason=row.decision_reason or "",
                decided_at=row.decided_at,
            )

        return await self._run(_poll)

    async def decide(self, decision: ApprovalDecision) -> None:
        now = self._clock.now()

        def _decide(session: Session) -> None:
            row = session.get(ApprovalRow, decision.approval_id)
            if row is None:
                raise KeyError(f"unknown approval {decision.approval_id}")
            row.approved = decision.approved
            row.decided_by = decision.decided_by
            row.decision_reason = decision.reason
            row.decided_at = decision.decided_at or now

        await self._run(_decide)

    async def pending(self, *, repo: str | None = None) -> list[ApprovalRequest]:
        def _pending(session: Session) -> list[ApprovalRequest]:
            rows = session.scalars(select(ApprovalRow).where(ApprovalRow.approved.is_(None))).all()
            requests = [
                ApprovalRequest(
                    approval_id=row.approval_id,
                    run_id=row.run_id,
                    state=State(row.state),
                    capability=Capability(row.capability),
                    reason=row.reason,
                    evidence=list(row.evidence or []),
                    requested_at=row.requested_at,
                )
                for row in rows
            ]
            if repo is None:
                return requests
            run_ids = {
                r.run_id for r in session.scalars(select(RunRow).where(RunRow.repo == repo)).all()
            }
            return [r for r in requests if r.run_id in run_ids]

        return await self._run(_pending)

    # ── shadow comparisons (§24 Phase 2) ─────────────────────────────────────────

    async def observe(self, comparison: Comparison, *, repo: str = "") -> Comparison:
        """Record one observation. Idempotent on ``(run_id, head_sha, round)``.

        Idempotent because the shadow runner may be invoked twice for the same review — a retry,
        an overlapping nightly job, a rerun after a crash — and double-counting an agreement
        would inflate the very rate the cutover gates on. Re-observing *updates*, so a later run
        with a better explanation wins.
        """
        now = comparison.observed_at or self._clock.now()

        def _observe(session: Session) -> Comparison:
            row = session.scalars(
                select(ComparisonRow).where(
                    ComparisonRow.run_id == comparison.run_id,
                    ComparisonRow.head_sha == comparison.head_sha,
                    ComparisonRow.round == comparison.round,
                )
            ).first()
            if row is None:
                row = ComparisonRow(
                    run_id=comparison.run_id,
                    head_sha=comparison.head_sha,
                    round=comparison.round,
                    observed_at=now,
                )
                session.add(row)
            row.repo = repo or comparison.repo
            row.agreement = comparison.agreement.value
            row.shell_verdict = comparison.shell.verdict.value if comparison.shell.verdict else None
            row.shell_blocking = comparison.shell.blocking
            row.shell_note = comparison.shell.note
            row.shell_usd = comparison.shell.usd
            row.python_verdict = (
                comparison.python.verdict.value if comparison.python.verdict else None
            )
            row.python_blocking = comparison.python.blocking
            row.python_downgraded = comparison.python.downgraded
            row.python_note = comparison.python.note
            row.python_usd = comparison.python.usd
            if comparison.explanation:
                # An explanation is never *cleared* by a re-observation: it is written by a
                # human, and the automatic re-run has nothing better to say than they did.
                row.explanation = comparison.explanation
            session.flush()
            return _to_comparison(row)

        return await self._run(_observe)

    async def explain(self, run_id: str, head_sha: str, round_: int, explanation: str) -> bool:
        """Account for a disagreement. The cutover blocks until every one has this."""

        def _explain(session: Session) -> bool:
            row = session.scalars(
                select(ComparisonRow).where(
                    ComparisonRow.run_id == run_id,
                    ComparisonRow.head_sha == head_sha,
                    ComparisonRow.round == round_,
                )
            ).first()
            if row is None:
                return False
            row.explanation = explanation
            return True

        return await self._run(_explain)

    async def comparisons(
        self, *, repo: str | None = None, since: datetime | None = None
    ) -> list[Comparison]:
        def _load(session: Session) -> list[Comparison]:
            query = select(ComparisonRow).order_by(ComparisonRow.observed_at.asc())
            if repo:
                query = query.where(ComparisonRow.repo == repo)
            if since is not None:
                query = query.where(ComparisonRow.observed_at >= since)
            return [_to_comparison(row) for row in session.scalars(query).all()]

        return await self._run(_load)


# ── mapping ──────────────────────────────────────────────────────────────────────


def _to_comparison(row: ComparisonRow) -> Comparison:
    return Comparison(
        run_id=row.run_id,
        repo=row.repo,
        head_sha=row.head_sha,
        round=row.round,
        agreement=Agreement(row.agreement),
        explanation=row.explanation,
        observed_at=row.observed_at,
        shell=Decision(
            engine="shell",
            verdict=Verdict(row.shell_verdict) if row.shell_verdict else None,
            blocking=row.shell_blocking,
            note=row.shell_note,
            usd=row.shell_usd,
        ),
        python=Decision(
            engine="python",
            verdict=Verdict(row.python_verdict) if row.python_verdict else None,
            blocking=row.python_blocking,
            downgraded=row.python_downgraded,
            note=row.python_note,
            usd=row.python_usd,
        ),
    )


def _group(rows: list[CostRow], key: Callable[[CostRow], str]) -> dict[str, str]:
    totals: dict[str, Decimal] = {}
    for row in rows:
        totals[key(row)] = totals.get(key(row), Decimal(0)) + row.usd
    return {k: str(v) for k, v in sorted(totals.items())}


def _to_run(row: RunRow) -> Run:
    return Run(
        run_id=row.run_id,
        request=JobRequest.model_validate(row.request),
        state=State(row.state),
        status=RunStatus(row.status),
        disposition=Disposition(row.disposition) if row.disposition else None,
        counters=Counters(**{field: getattr(row, field) for field in _COUNTER_FIELDS}),
        spend_usd=row.spend_usd,
        tokens=row.tokens,
        base_sha=row.base_sha,
        head_sha=row.head_sha,
        branch=row.branch,
        worktree_path=row.worktree_path,
        mr_id=row.mr_id,
        mr_url=row.mr_url,
        defer_until=row.defer_until,
        blocked_on=row.blocked_on,
        pending_approval_id=row.pending_approval_id,
        lease_holder=row.lease_holder,
        started_at=row.started_at,
        updated_at=row.updated_at,
        finished_at=row.finished_at,
        last_error=row.last_error,
    )


def _apply(row: RunRow, run: Run, now: datetime) -> None:
    row.state = run.state.value
    row.status = run.status.value
    row.disposition = run.disposition.value if run.disposition else None
    for field in _COUNTER_FIELDS:
        setattr(row, field, getattr(run.counters, field))
    row.spend_usd = run.spend_usd
    row.tokens = run.tokens
    row.branch = run.branch
    row.base_sha = run.base_sha
    row.head_sha = run.head_sha
    row.worktree_path = run.worktree_path
    row.mr_id = run.mr_id
    row.mr_url = run.mr_url
    row.defer_until = run.defer_until
    row.blocked_on = run.blocked_on
    row.pending_approval_id = run.pending_approval_id
    row.lease_holder = run.lease_holder
    row.finished_at = run.finished_at
    row.last_error = run.last_error
    row.updated_at = now


def _to_checkpoint_row(checkpoint: Checkpoint) -> CheckpointRow:
    return CheckpointRow(
        run_id=checkpoint.run_id,
        seq=checkpoint.seq,
        state=checkpoint.state.value,
        next_state=checkpoint.next_state.value,
        status=checkpoint.status.value,
        attempt=checkpoint.attempt,
        round=checkpoint.round,
        idempotency_key=checkpoint.idempotency_key,
        started_at=checkpoint.started_at,
        finished_at=checkpoint.finished_at,
        duration_s=checkpoint.duration_s,
        usd=checkpoint.usd,
        input_tokens=checkpoint.input_tokens,
        output_tokens=checkpoint.output_tokens,
        cache_read_tokens=checkpoint.cache_read_tokens,
        model=checkpoint.model,
        template_id=checkpoint.template_id,
        prompt_sha256=checkpoint.prompt_sha256,
        prompt_bytes=checkpoint.prompt_bytes,
        base_sha=checkpoint.base_sha,
        head_sha=checkpoint.head_sha,
        isolation=checkpoint.isolation,
        artefacts=list(checkpoint.artefacts),
        result=dict(checkpoint.result),
        error=checkpoint.error.model_dump(mode="json") if checkpoint.error else None,
    )


def _to_checkpoint(row: CheckpointRow) -> Checkpoint:
    return Checkpoint(
        run_id=row.run_id,
        seq=row.seq,
        state=State(row.state),
        next_state=State(row.next_state),
        status=RunStatus(row.status),
        attempt=row.attempt,
        round=row.round,
        idempotency_key=row.idempotency_key,
        started_at=row.started_at,
        finished_at=row.finished_at,
        duration_s=float(row.duration_s) if row.duration_s is not None else None,
        usd=row.usd,
        input_tokens=row.input_tokens,
        output_tokens=row.output_tokens,
        cache_read_tokens=row.cache_read_tokens,
        model=row.model,
        template_id=row.template_id,
        prompt_sha256=row.prompt_sha256,
        prompt_bytes=row.prompt_bytes,
        base_sha=row.base_sha,
        head_sha=row.head_sha,
        isolation=row.isolation,
        artefacts=list(row.artefacts or []),
        result=dict(row.result or {}),
        error=ErrorInfo.model_validate(row.error) if row.error else None,
    )


def open_store(url: str, *, clock: Clock | None = None, create: bool = False) -> SqlStore:
    """Open a store from a URL. ``sqlite:///…`` or ``postgresql+psycopg://…``."""
    if url.startswith("sqlite"):
        path = url.split("///", 1)[-1]
        if path and path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        engine = create_engine(url, future=True)
    else:
        engine = create_engine(url, future=True, pool_pre_ping=True)
    store = SqlStore(engine, clock=clock)
    if create:
        store.create_all()
    return store
