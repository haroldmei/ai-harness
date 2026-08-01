"""The stateless reconciliation sweep (invariant 13).

*Reconciliation must be a stateless sweep*, so it self-heals races and out-of-band actions. The
shell's version closes every open issue whose PR carries the ``merged`` label — **independent of
what this run did** — and that independence is what makes it fix three separate failure modes at
once: the post-merge index race, a transient ``gh issue close`` failure, and a PR merged by a
human while the harness was not looking.

Written the same way here: it takes no arguments about "what just happened", reads the world as
it currently is, and makes it consistent. Running it twice changes nothing the second time.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import timedelta
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.lease import LeaseManager
from ai_harness.observability.logging import Logger
from ai_harness.persistence.sql import SqlStore
from ai_harness.providers.forge.protocol import Forge
from ai_harness.schemas.enums import Disposition, RunStatus, State

STALE_CLAIM_MINUTES = 20


@dataclass(frozen=True, slots=True)
class SweepReport:
    """What the sweep changed. Empty on a healthy tick, which is the normal case."""

    closed_issues: list[int] = field(default_factory=list)
    released_claims: list[str] = field(default_factory=list)
    unblocked: list[str] = field(default_factory=list)
    escalated: list[str] = field(default_factory=list)

    @property
    def changed(self) -> bool:
        return bool(self.closed_issues or self.released_claims or self.unblocked or self.escalated)


@dataclass
class Reconciler:
    """Makes the world consistent with itself, from whatever state it is in."""

    store: SqlStore
    forge: Forge
    leases: LeaseManager
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)
    escalate_after_hours: int = 6

    async def sweep(self, repo: str) -> SweepReport:
        closed = await self._close_landed_issues(repo)
        released = await self._release_stale_claims(repo)
        unblocked = await self._unblock_cleared(repo)
        escalated = await self._escalate_stuck(repo)
        report = SweepReport(
            closed_issues=closed,
            released_claims=released,
            unblocked=unblocked,
            escalated=escalated,
        )
        if report.changed:
            self.logger.info(
                "reconciliation changed something",
                repo=repo,
                closed=closed,
                released=released,
                unblocked=unblocked,
                escalated=escalated,
            )
        return report

    async def _close_landed_issues(self, repo: str) -> list[int]:
        """Close every open issue whose branch has landed — regardless of who landed it.

        Not "close the issue for the run that just merged": that version misses the human merge,
        the dropped API call and the index race, which are three of the reasons this exists.
        """
        closed: list[int] = []
        issues = await self.forge.list_issues(state="open")
        if issues.is_err:
            return closed
        for issue in issues.unwrap():
            branch = f"agent/issue-{issue.number}"
            landed = await self.forge.is_merged(branch, base_ref="main")
            if landed.is_ok and landed.unwrap():
                result = await self.forge.close_issue(issue.number, reason="completed")
                if result.is_ok:
                    closed.append(issue.number)
        return closed

    async def _release_stale_claims(self, repo: str) -> list[str]:
        """A claim with no live lease and no recent update is released.

        The shell needs a 20-minute heuristic because a label carries no expiry. Here the lease
        *is* the liveness signal, and the heuristic is only a backstop for a run whose row was
        written but whose worker never started.
        """
        released: list[str] = []
        cutoff = self.clock.now() - timedelta(minutes=STALE_CLAIM_MINUTES)
        for run in await self.store.list_runs(repo=repo, status=RunStatus.RUNNING, limit=200):
            if run.updated_at is not None and run.updated_at > cutoff:
                continue
            handle = await self.leases.acquire(f"run:{run.run_id}", ttl_s=1.0, holder="reconciler")
            if handle is None:
                continue  # someone is genuinely working on it
            await self.leases.release(handle)
            released.append(run.run_id)
        return released

    async def _unblock_cleared(self, repo: str) -> list[str]:
        """Invariant 12: every terminal state needs a re-entry path, or the queue rots.

        Stuck PRs whose blocker had already been fixed is the failure this prevents.
        """
        unblocked: list[str] = []
        for run in await self.store.list_runs(repo=repo, status=RunStatus.BLOCKED, limit=200):
            if run.blocked_on is None:
                continue
            cleared = await self.forge.blocker_closed(run.blocked_on)
            if cleared.is_ok and cleared.unwrap():
                await self._update(run, {"status": RunStatus.RUNNING, "blocked_on": None})
                unblocked.append(run.run_id)
        return unblocked

    async def _escalate_stuck(self, repo: str) -> list[str]:
        """Past the deadline with nobody looking, a parked run becomes a human's problem."""
        escalated: list[str] = []
        cutoff = self.clock.now() - timedelta(hours=self.escalate_after_hours)
        for status in (RunStatus.DEFERRED, RunStatus.BLOCKED):
            for run in await self.store.list_runs(repo=repo, status=status, limit=200):
                if run.updated_at is None or run.updated_at > cutoff:
                    continue
                await self._update(
                    run,
                    {
                        "state": State.COMPLETE,
                        "status": RunStatus.PARKED_TERMINAL,
                        "disposition": Disposition.ESCALATED,
                        "finished_at": self.clock.now(),
                        "last_error": (
                            f"{status.value} for more than {self.escalate_after_hours}h with no "
                            "progress"
                        ),
                    },
                )
                escalated.append(run.run_id)
        return escalated

    async def _update(self, run: Any, updates: dict[str, Any]) -> None:
        from ai_harness.schemas.checkpoint import Checkpoint

        advanced = run.model_copy(update=updates)
        seq = await self.store.next_seq(run.run_id)
        await self.store.commit_transition(
            advanced,
            Checkpoint(
                run_id=run.run_id,
                seq=seq,
                state=run.state,
                next_state=advanced.state,
                status=advanced.status,
                finished_at=self.clock.now(),
                result={"by": "reconciler", "why": updates.get("last_error", "condition cleared")},
            ),
        )
