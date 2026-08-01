"""Local fan-out: N worker processes, and nothing that looks like a scheduler.

§14.3's job contract is what makes this trivial — a worker needs **a run id and configuration**,
nothing else. There is no work to hand over, no state to serialise, no affinity to preserve, so
"fan out" reduces to "start the process more than once".

That is the whole reason Celery and Temporal are not here (§25). Both would want to own process
lifecycle, and both would add a broker to carry a payload that fits in one argument. What this
module does instead is spawn, wait, and report exit codes; systemd, Kubernetes and a developer's
terminal each do the same thing with their own supervision, which is where supervision belongs.

A crashed worker is not handled here on purpose. The lease expires, the queue re-offers the run,
and some other worker resumes it from its last checkpoint — recovery is a property of the store
and the lease, not of whoever started the process.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

from ai_harness.observability.logging import Logger


@dataclass(frozen=True, slots=True)
class WorkerExit:
    """One worker process, after the fact."""

    worker_id: str
    returncode: int
    stderr: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0


@dataclass
class SubprocessBackend:
    """Runs ``command`` once per worker, concurrently, and reports how each finished.

    ``command`` is supplied by the caller rather than defaulted, because the entry point that
    assembles a live ``Deps`` — real engines, a real forge, a real workspace — does not exist
    yet and is part of the cutover work (#76). A default here would be a command that starts,
    finds an empty registry, and escalates real runs. The seam is ready; the wiring is not, and
    saying so is better than shipping a plausible-looking default.
    """

    command: list[str]
    """Argv, with ``{worker_id}`` substituted in any element."""
    workers: int = 2
    logger: Logger = field(default_factory=Logger)
    prefix: str = "worker"

    async def fan_out(self) -> list[WorkerExit]:
        results = await asyncio.gather(
            *(self._spawn(f"{self.prefix}-{n}") for n in range(self.workers))
        )
        failed = [r for r in results if not r.ok]
        if failed:
            # Reported, never raised: one worker dying is an expected event that the lease and
            # the queue already recover from. Raising would take the healthy workers with it.
            self.logger.warning("workers exited non-zero", count=len(failed))
        return list(results)

    async def _spawn(self, worker_id: str) -> WorkerExit:
        argv = [part.replace("{worker_id}", worker_id) for part in self.command]
        try:
            process = await asyncio.create_subprocess_exec(
                *argv, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE
            )
        except OSError as exc:
            self.logger.warning("worker failed to start", worker=worker_id, error=str(exc))
            return WorkerExit(worker_id=worker_id, returncode=127, stderr=str(exc))

        _, stderr = await process.communicate()
        return WorkerExit(
            worker_id=worker_id,
            returncode=process.returncode or 0,
            stderr=stderr.decode(errors="replace")[-2000:],
        )
