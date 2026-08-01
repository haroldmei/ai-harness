"""``harness-record`` — the shadow-state writer the shell stages call.

§24 Phase 1's whole value is here: within a week of rollout an operator can answer *why is this
PR stuck* and *what has this cost* from one query, **before any behaviour moves**. The shell
still reads labels; Postgres (or SQLite) is written but read by nobody until Phase 4.

One rule dominates the design: **this can never fail its caller.** The shell stages that invoke
it are the production pipeline, and a recorder that raises — or blocks on an unreachable
database — would turn an observability feature into an outage. Every entry point catches
everything and exits zero; the worst case is a missing row.

Idempotency matters for the same reason. A stage that is re-invoked by the timer records the
same boundary again, so a boundary is keyed by ``(run, state, seq)`` and re-recording is a
no-op rather than a duplicate.
"""

from __future__ import annotations

import contextlib
from dataclasses import dataclass, field
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.ids import idempotency_key
from ai_harness.persistence.sql import SqlStore
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.enums import Disposition, RunStatus, State
from ai_harness.schemas.job import JobRequest
from ai_harness.schemas.run import Run

STATE_BY_STAGE: dict[str, State] = {
    # The shell's stage names, mapped onto the seven states. A stage the port does not know
    # records as PREPARE rather than being dropped: an unmapped stage is still evidence.
    "inbox": State.IMPLEMENT,
    "build": State.IMPLEMENT,
    "triage": State.ANALYSE,
    "gates": State.VALIDATE,
    "reviewer": State.REVIEW,
    "fixer": State.IMPLEMENT,
    "merger": State.INTEGRATE,
    "pipeline": State.PREPARE,
    "prepare": State.PREPARE,
}

DISPOSITION_BY_OUTCOME: dict[str, Disposition] = {
    "merged": Disposition.MERGED,
    "delivered": Disposition.DELIVERED,
    "escalated": Disposition.ESCALATED,
    "needs-human": Disposition.ESCALATED,
    "blocked": Disposition.BLOCKED,
    "abandoned": Disposition.ABANDONED,
}


@dataclass
class Recorder:
    """Writes shadow state. Never raises, never blocks a stage."""

    store: SqlStore
    clock: Clock = field(default_factory=SystemClock)

    async def record(
        self,
        *,
        repo: str,
        issue: int | None,
        stage: str,
        outcome: str = "",
        branch: str = "",
        base_sha: str = "",
        head_sha: str = "",
        mr_id: str | None = None,
        mr_url: str | None = None,
        counters: dict[str, int] | None = None,
        error: str | None = None,
        result: dict[str, Any] | None = None,
    ) -> Run | None:
        """Record one shell stage boundary. Returns ``None`` on any failure, silently."""
        state = STATE_BY_STAGE.get(stage, State.PREPARE)
        disposition = DISPOSITION_BY_OUTCOME.get(outcome)

        run = await self._run_for(repo, issue, branch)
        if run is None:
            return None

        updates: dict[str, Any] = {
            "state": State.COMPLETE if disposition else state,
            "status": RunStatus.RUNNING,
            "disposition": disposition,
            "branch": branch or run.branch,
            "base_sha": base_sha or run.base_sha,
            "head_sha": head_sha or run.head_sha,
            "mr_id": mr_id or run.mr_id,
            "mr_url": mr_url or run.mr_url,
            "last_error": error or run.last_error,
        }
        if disposition is not None:
            updates["finished_at"] = self.clock.now()
        if counters:
            updates["counters"] = run.counters.model_copy(
                update={k: v for k, v in counters.items() if hasattr(run.counters, k)}
            )
        advanced = run.model_copy(update=updates)

        seq = await self.store.next_seq(run.run_id)
        checkpoint = Checkpoint(
            run_id=run.run_id,
            seq=seq,
            state=state,
            next_state=advanced.state,
            status=advanced.status,
            idempotency_key=idempotency_key("shell", stage=stage, run=run.run_id, seq=seq),
            finished_at=self.clock.now(),
            base_sha=advanced.base_sha,
            head_sha=advanced.head_sha,
            result={"stage": stage, "outcome": outcome, **(result or {})},
        )
        return await self.store.commit_transition(advanced, checkpoint)

    async def _run_for(self, repo: str, issue: int | None, branch: str) -> Run | None:
        if issue is not None:
            existing = await self.store.find_active(repo, issue)
            if existing is not None:
                return existing
        request = JobRequest(repo=repo, issue=issue, branch=branch or None)
        created = await self.store.create(request)
        return created.model_copy(update={"engine": "shell"})


async def record_safely(recorder: Recorder, **fields: Any) -> Run | None:
    """The entry point the shell calls. Swallows **everything**.

    A recorder that can fail a stage is worse than no recorder: the shell pipeline is
    production, and this is a shadow write nobody reads yet.
    """
    with contextlib.suppress(Exception):
        return await recorder.record(**fields)
    return None
