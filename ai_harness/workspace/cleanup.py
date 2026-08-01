"""The failure path — evidence first, cleanup last.

§16.4 inverts the shell's default deliberately. The shell removes the worktree in an
unconditional ``EXIT`` trap, and that trap is precisely what made three incidents possible
(#1764, #2152, #2196): a detached-HEAD commit orphaned by cleanup, and a finished fix lost.

The ordering is not a preference; each step exists because the step after it can destroy what
the step before it produced:

1. **flush artefacts** — before any cleanup can remove them;
2. **tag the work** ``harness/{run_id}/{state}`` — so a commit cannot be orphaned;
3. **push the branch** if it carries work and pushing is permitted — pushing a branch is not
   the same as proposing it, and it converts "the process died, start over" into "the gate
   failed, try again from here";
4. **write the checkpoint** with the error;
5. **update the forge** with a structured status;
6. **only then** consider cleanup — skipped entirely when the disposition is preserved.

Preserved worktrees are swept after ``preserve_worktree_ttl_h`` (Q10: 72h — a working day plus
a weekend), so evidence outlives the run without accumulating forever.
"""

from __future__ import annotations

import shutil
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import Outcome
from ai_harness.providers.git.protocol import GitClient
from ai_harness.schemas.enums import Disposition
from ai_harness.schemas.policy import FailurePolicy

PRESERVED_MARKER = ".harness-preserved"
"""Written into a preserved worktree: what run left it, when, and when the sweeper takes it."""


@dataclass(frozen=True, slots=True)
class TeardownReport:
    tagged: str | None = None
    pushed: bool = False
    preserved: bool = False
    removed: bool = False
    artefacts: list[str] = field(default_factory=list)


@dataclass
class Teardown:
    """Runs the §16.4 ordering. One implementation, every failure path."""

    git: GitClient
    policy: FailurePolicy
    clock: Clock = field(default_factory=SystemClock)

    async def finish(
        self,
        *,
        run_id: str,
        state: str,
        workspace: Path,
        branch: str,
        disposition: Disposition,
        may_push: bool = True,
        flush_artefacts: Callable[[], Awaitable[list[str]]] | None = None,
    ) -> Outcome[TeardownReport]:
        artefacts: list[str] = []
        if flush_artefacts is not None and self.policy.always_preserve_artefacts:
            # Step 1. Before anything can remove them.
            artefacts = await flush_artefacts()

        tag = None
        dirty = await self.git.status_is_dirty(cwd=workspace)
        head = await self.git.rev_parse("HEAD", cwd=workspace)
        has_work = head.is_ok and bool(head.unwrap())

        if has_work:
            # Step 2. The generalisation of agent-pr-fixer.sh:398-401.
            tag = f"harness/{run_id}/{state}"
            await self.git.tag(tag, cwd=workspace)

        pushed = False
        if has_work and may_push and branch and not dirty.unwrap_or(False):
            # Step 3. Early push: survivable work beats a clean remote.
            pushed = (await self.git.push(f"HEAD:refs/heads/{branch}", cwd=workspace)).is_ok

        preserve = disposition in self.policy.preserve_worktree_on
        removed = False
        if preserve:
            self._mark_preserved(workspace, run_id=run_id, state=state)
        else:
            # Step 6, and only now.
            await self.git.remove_worktree(workspace, force=True)
            removed = not workspace.exists()
            if tag and pushed:
                # The tag was insurance against losing the commit; the push made it reachable.
                await self.git.delete_tag(tag, cwd=None)

        return Outcome.ok(
            TeardownReport(
                tagged=tag,
                pushed=pushed,
                preserved=preserve,
                removed=removed,
                artefacts=artefacts,
            )
        )

    def _mark_preserved(self, workspace: Path, *, run_id: str, state: str) -> None:
        expires = self.clock.now() + timedelta(hours=self.policy.preserve_worktree_ttl_h)
        try:
            (workspace / PRESERVED_MARKER).write_text(
                f"run_id: {run_id}\nstate: {state}\n"
                f"preserved_at: {self.clock.now().isoformat()}\n"
                f"expires_at: {expires.isoformat()}\n"
            )
        except OSError:
            return


@dataclass
class WorktreeSweeper:
    """Removes preserved worktrees once their TTL has passed, and says what it removed."""

    root: Path
    git: GitClient
    ttl_hours: int = 72
    clock: Clock = field(default_factory=SystemClock)

    async def sweep(self) -> list[Path]:
        removed: list[Path] = []
        if not self.root.exists():
            return removed
        cutoff = self.clock.now() - timedelta(hours=self.ttl_hours)
        for candidate in sorted(self.root.iterdir()):
            marker = candidate / PRESERVED_MARKER
            if not marker.is_file():
                continue
            stamp = _preserved_at(marker)
            if stamp is None or stamp > cutoff:
                continue
            await self.git.remove_worktree(candidate, force=True)
            if candidate.exists():
                shutil.rmtree(candidate, ignore_errors=True)
            removed.append(candidate)
        return removed


def _preserved_at(marker: Path) -> datetime | None:
    try:
        for line in marker.read_text().splitlines():
            if line.startswith("preserved_at:"):
                return datetime.fromisoformat(line.split(":", 1)[1].strip())
    except (OSError, ValueError):
        return None
    return None
