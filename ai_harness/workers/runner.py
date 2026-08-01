"""``agent work`` — claim, advance one boundary, exit.

A worker needs **nothing but configuration**: no local state, no memory of previous runs, no
affinity to a particular run. That is what makes the fleet story simple — a worker that dies is
replaced by any other worker, and the run resumes from its last checkpoint.

Single-pass, like everything else (§14.1). The process exits; the scheduler decides whether to
start another. A worker that looped internally would need its own health checks, its own
back-pressure and its own shutdown story, and would still be a worse version of what systemd or
Kubernetes already does.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ai_harness.observability.logging import Logger
from ai_harness.orchestration.machine import Deps, run_until_boundary
from ai_harness.persistence.queue import Claim, Queue
from ai_harness.schemas.enums import RunStatus


@dataclass(frozen=True, slots=True)
class WorkReport:
    """What one worker invocation did."""

    worker_id: str
    claimed: list[str] = field(default_factory=list)
    statuses: dict[str, str] = field(default_factory=dict)

    @property
    def idle(self) -> bool:
        return not self.claimed


@dataclass
class Worker:
    """One dispatch: claim → advance → exit."""

    deps: Deps
    queue: Queue
    worker_id: str = "worker"
    batch: int = 1
    logger: Logger = field(default_factory=Logger)

    async def work(self, *, repo: str | None = None) -> WorkReport:
        claims = await self.queue.claim(worker_id=self.worker_id, limit=self.batch, repo=repo)
        if not claims:
            self.logger.info("no work available", worker=self.worker_id, repo=repo)
            return WorkReport(worker_id=self.worker_id)

        statuses: dict[str, str] = {}
        for claim in claims:
            statuses[claim.run_id] = (await self._advance(claim)).value
        return WorkReport(
            worker_id=self.worker_id,
            claimed=[c.run_id for c in claims],
            statuses=statuses,
        )

    async def _advance(self, claim: Claim) -> RunStatus:
        """The claim said which run; the lease decides whether we may act on it.

        Both halves are needed (invariant 7). A claim without a lease lets two workers advance
        one run; a lease without a claim means nobody knows which run to look at.
        """
        status = await run_until_boundary(claim.run_id, self.worker_id, self.deps)
        self.logger.info(
            "advanced",
            worker=self.worker_id,
            run_id=claim.run_id,
            from_state=claim.state.value,
            status=status.value,
        )
        return status
