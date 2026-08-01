"""``agent tick`` — one pass, and the scheduler stays outside the agent.

§14.1, preserved exactly. ``agent-inbox.sh:15`` states it: *"Single-pass by design (the timer
re-invokes it)."* No script in the shell harness contains a sleep-loop or a cron expression, and
that is the single most portable decision in it — the same binary works under systemd, under
Kubernetes, or typed by hand, because the cadence lives in the scheduler and never in the code.

Four phases, in this order:

1. **reconcile** — make the world consistent with itself, statelessly (invariant 13);
2. **admit** — start work only if the concurrency ceiling allows it;
3. **dispatch** — advance runs that are ready, one boundary each;
4. **sweep** — expire preserved worktrees and drop the artefacts nothing needs.

Safe to call every two minutes: two overlapping ticks do no double work, because dispatch takes
a lease per run and a held lease is a no-op rather than an error.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.observability.logging import Logger
from ai_harness.orchestration.machine import Deps, run_until_boundary
from ai_harness.orchestration.reconcile import Reconciler, SweepReport
from ai_harness.schemas.enums import RunStatus, State


@dataclass(frozen=True, slots=True)
class TickReport:
    """What one pass did. The thing an operator reads to know the loop is alive."""

    repo: str
    reconciled: SweepReport
    dispatched: list[str] = field(default_factory=list)
    admitted: int = 0
    skipped_at_ceiling: int = 0
    swept: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "repo": self.repo,
            "closed_issues": self.reconciled.closed_issues,
            "released_claims": self.reconciled.released_claims,
            "unblocked": self.reconciled.unblocked,
            "escalated": self.reconciled.escalated,
            "dispatched": self.dispatched,
            "admitted": self.admitted,
            "skipped_at_ceiling": self.skipped_at_ceiling,
            "swept": self.swept,
        }


@dataclass
class Ticker:
    """One tick. Idempotent, single-pass, and it never sleeps."""

    deps: Deps
    reconciler: Reconciler
    worker_id: str = "tick"
    max_open_runs: int = 3
    max_dispatch_per_tick: int = 5
    sweeper: Any = None
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)

    async def tick(self, repo: str) -> TickReport:
        reconciled = await self.reconciler.sweep(repo)

        active = [
            run
            for run in await self.deps.store.list_runs(repo=repo, limit=200)
            if run.disposition is None
        ]
        in_flight = [r for r in active if r.status is RunStatus.RUNNING]
        ready = [
            r
            for r in active
            if r.status
            in (
                RunStatus.RUNNING,
                RunStatus.DEFERRED,
                RunStatus.BLOCKED,
                RunStatus.AWAITING_APPROVAL,
            )
        ]

        skipped = 0
        dispatched: list[str] = []
        for run in ready[: self.max_dispatch_per_tick]:
            if run.state is State.PREPARE and len(in_flight) >= self.max_open_runs:
                # The ceiling applies to *starting* work, never to draining it. Refusing to
                # advance an in-flight run would strand it at the ceiling forever.
                skipped += 1
                continue
            status = await run_until_boundary(run.run_id, self.worker_id, self.deps)
            dispatched.append(run.run_id)
            self.logger.info(
                "dispatched", run_id=run.run_id, state=run.state.value, status=status.value
            )

        swept: list[str] = []
        if self.sweeper is not None:
            swept = [str(path) for path in await self.sweeper.sweep()]

        report = TickReport(
            repo=repo,
            reconciled=reconciled,
            dispatched=dispatched,
            admitted=len([r for r in ready if r.state is State.PREPARE]) - skipped,
            skipped_at_ceiling=skipped,
            swept=swept,
        )
        self.logger.info("tick finished", **report.as_dict())
        return report


async def drained(store: Any, repo: str) -> bool:
    """Is it safe to cut this repository over? (§24.1's drain check, as a command not a judgement.)

    "Cut over only when no run is in flight for that repo" is listed as a mitigation, and a
    mitigation that depends on someone eyeballing a dashboard is not one.
    """
    runs = await store.list_runs(repo=repo, limit=200)
    return not [r for r in runs if r.disposition is None and r.status is RunStatus.RUNNING]
