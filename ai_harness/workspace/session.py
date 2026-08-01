"""``WorktreeSession`` — acquire, work, **always** release.

The shell releases with an ``EXIT`` trap, which is right about "always" and wrong about "what":
it removes the worktree unconditionally, including on the failure path where the worktree is
the only remaining evidence. Here the release path runs the §16.4 ordering and honours
``preserve_worktree_on``, so an escalated run leaves its tree behind on purpose and a merged one
does not.

The session is the only place that knows both halves — how the workspace was created and how it
must be torn down — which is what keeps that pairing from drifting apart across seven states.
"""

from __future__ import annotations

import contextlib
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import Outcome
from ai_harness.providers.git.protocol import GitClient
from ai_harness.schemas.enums import Disposition
from ai_harness.schemas.policy import FailurePolicy
from ai_harness.workspace.cleanup import Teardown, TeardownReport
from ai_harness.workspace.worktree import Workspace, WorktreeManager


@dataclass
class SessionResult:
    """How the session ended. Set by the caller; read by the teardown."""

    disposition: Disposition = Disposition.ESCALATED
    may_push: bool = True
    flush_artefacts: Callable[[], Awaitable[list[str]]] | None = None
    teardown: TeardownReport | None = None


@dataclass
class WorktreeSession:
    """Materialises a workspace and guarantees the teardown that matches it."""

    manager: WorktreeManager
    git: GitClient
    policy: FailurePolicy = field(default_factory=FailurePolicy)
    clock: Clock = field(default_factory=SystemClock)

    @contextlib.asynccontextmanager
    async def open(
        self,
        *,
        run_id: str,
        state: str,
        path: Path,
        branch: str,
        base_ref: str = "origin/main",
        holder: str = "harness",
    ) -> AsyncIterator[tuple[Outcome[Workspace], SessionResult]]:
        """Yield the workspace and a mutable result the caller fills in before exiting.

        The default disposition is ``ESCALATED``: if a caller leaves without saying how it
        ended — including by raising — the tree is preserved. Defaulting the other way would
        delete evidence exactly when something went wrong.
        """
        created = await self.manager.materialise(
            path=path, branch=branch, base_ref=base_ref, holder=holder
        )
        result = SessionResult()
        try:
            yield created, result
        finally:
            if created.is_ok:
                teardown = Teardown(git=self.git, policy=self.policy, clock=self.clock)
                report = await teardown.finish(
                    run_id=run_id,
                    state=state,
                    workspace=created.unwrap().path,
                    branch=branch,
                    disposition=result.disposition,
                    may_push=result.may_push,
                    flush_artefacts=result.flush_artefacts,
                )
                result.teardown = report.value_or_none
