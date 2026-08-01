"""Worktree materialisation and the resume policy.

§3.4 is the most sophisticated part of the shell harness and the one with the clearest
data-loss history. Two things are ported exactly:

**Creation is serialised repo-wide.** Parallel ``git worktree add`` races on the shared
``.git/worktrees`` admin area, so every creation takes a per-repository lock — the same
``flock`` primitive the shell uses, through :class:`~ai_harness.kernel.lease.LeaseManager`.

**Resume beats discard, under three guards.** A killed build's work survives because the branch
was pushed *before* gating; the next attempt resumes from it. Resuming is only safe when:

1. the branch is **not already merged** into the base — resuming a merged branch rebuilds work
   that has already landed;
2. it is rebased onto the **live** base, not the base it was cut from. This is the converse
   check the shell was missing, and its absence caused #2138;
3. the operator has not disabled resume (``AGENT_RESUME=0`` in the shell; ``allow_resume`` here).

A product-level conflict during that rebase means the branch has diverged from reality: discard
it and start clean, rather than handing a half-rebased tree to a model.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from ai_harness.kernel.lease import LeaseManager
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.providers.git.protocol import GitClient
from ai_harness.workspace.generated import ConflictPolicy


class Strategy(StrEnum):
    """Why this worktree looks the way it does — recorded on the checkpoint."""

    FRESH = "fresh"
    RESUMED = "resumed"
    RESUMED_REBASED = "resumed_rebased"
    DISCARDED_AND_FRESH = "discarded_and_fresh"
    """A resumable branch existed but had diverged at product level."""


@dataclass(frozen=True, slots=True)
class Workspace:
    """A materialised worktree, and the facts a state needs about it."""

    path: Path
    branch: str
    base_sha: str
    head_sha: str
    strategy: Strategy
    detached: bool = False

    @property
    def resumed(self) -> bool:
        return self.strategy in (Strategy.RESUMED, Strategy.RESUMED_REBASED)


@dataclass
class WorktreeManager:
    """Materialises worktrees under a repo-wide lock, applying the resume policy."""

    git: GitClient
    leases: LeaseManager
    repo_key: str
    conflicts: ConflictPolicy
    allow_resume: bool = True
    lock_ttl_s: float = 600.0

    async def materialise(
        self,
        *,
        path: Path,
        branch: str,
        base_ref: str = "origin/main",
        remote: str = "origin",
        holder: str = "harness",
    ) -> Outcome[Workspace]:
        """Create the worktree for ``branch``, resuming existing work when it is safe."""
        async with self.leases.hold(
            f"worktree:{self.repo_key}", ttl_s=self.lock_ttl_s, holder=holder
        ) as lease:
            if lease is None:
                return Outcome.fail(
                    ErrorCategory.TRANSIENT,
                    "another worker is creating a worktree in this repository",
                    remedy="parallel `git worktree add` races on the shared .git/worktrees area",
                )
            return await self._materialise(
                path=path, branch=branch, base_ref=base_ref, remote=remote
            )

    async def _materialise(
        self, *, path: Path, branch: str, base_ref: str, remote: str
    ) -> Outcome[Workspace]:
        fetched = await self.git.fetch(remote)
        if fetched.is_err:
            return Outcome.of(fetched.error)  # type: ignore[arg-type]

        base = await self.git.rev_parse(base_ref)
        if base.is_err:
            return Outcome.of(base.error)  # type: ignore[arg-type]
        base_sha = base.unwrap()

        # A stale worktree at this path is removed rather than reused: its index may be mid-
        # rebase, and a half-finished state is worse than none.
        await self.git.remove_worktree(path, force=True)

        remote_branch = f"{remote}/{branch}"
        resumable = await self._is_resumable(remote_branch, base_sha)

        if not resumable:
            created = await self.git.add_worktree(path, base_sha, branch=branch)
            if created.is_err:
                return Outcome.of(created.error)  # type: ignore[arg-type]
            return Outcome.ok(
                Workspace(
                    path=path,
                    branch=branch,
                    base_sha=base_sha,
                    head_sha=created.unwrap().head,
                    strategy=Strategy.FRESH,
                )
            )

        created = await self.git.add_worktree(path, remote_branch, branch=branch)
        if created.is_err:
            return Outcome.of(created.error)  # type: ignore[arg-type]

        # cwd=path is load-bearing: without it this asks whether the *primary* checkout is up
        # to date with the base, which is a different question and usually a different answer.
        up_to_date = await self.git.is_ancestor(base_sha, "HEAD", cwd=path)
        if up_to_date.is_ok and up_to_date.unwrap():
            head = await self.git.rev_parse("HEAD", cwd=path)
            return Outcome.ok(
                Workspace(
                    path=path,
                    branch=branch,
                    base_sha=base_sha,
                    head_sha=head.unwrap_or(""),
                    strategy=Strategy.RESUMED,
                )
            )

        rebased = await self.git.rebase_onto(
            base_sha, generated_paths=self.conflicts.generated_paths, cwd=path
        )
        if rebased.is_ok and rebased.unwrap().rebased:
            return Outcome.ok(
                Workspace(
                    path=path,
                    branch=branch,
                    base_sha=base_sha,
                    head_sha=rebased.unwrap().head,
                    strategy=Strategy.RESUMED_REBASED,
                )
            )

        # Diverged at product level: discard the branch and start clean rather than hand a
        # half-rebased tree to a model.
        await self.git.remove_worktree(path, force=True)
        fresh = await self.git.add_worktree(path, base_sha, branch=branch)
        if fresh.is_err:
            return Outcome.of(fresh.error)  # type: ignore[arg-type]
        return Outcome.ok(
            Workspace(
                path=path,
                branch=branch,
                base_sha=base_sha,
                head_sha=fresh.unwrap().head,
                strategy=Strategy.DISCARDED_AND_FRESH,
            )
        )

    async def _is_resumable(self, remote_branch: str, base_sha: str) -> bool:
        """The three guards. Any doubt means "do not resume" — fail closed."""
        if not self.allow_resume:
            return False
        exists = await self.git.rev_parse(remote_branch)
        if exists.is_err:
            return False
        head = exists.unwrap()

        # Merged into the base already ⇒ resuming would rebuild work that has landed. An
        # error reading ancestry is also a "no": any doubt fails closed.
        already_merged = await self.git.is_ancestor(head, base_sha)
        return not (already_merged.is_err or already_merged.unwrap())

    async def detached_at(
        self, *, path: Path, ref: str, holder: str = "harness"
    ) -> Outcome[Workspace]:
        """A detached worktree at ``ref`` — the fixer's and reviewer's shape.

        ``-B`` fails with *"Cannot force update the current branch"* when the PR branch is
        checked out in the primary copy; detaching never touches the ref.
        """
        async with self.leases.hold(
            f"worktree:{self.repo_key}", ttl_s=self.lock_ttl_s, holder=holder
        ) as lease:
            if lease is None:
                return Outcome.fail(ErrorCategory.TRANSIENT, "worktree lock is held")
            await self.git.remove_worktree(path, force=True)
            created = await self.git.add_worktree(path, ref, detach=True)
            if created.is_err:
                return Outcome.of(created.error)  # type: ignore[arg-type]
            info = created.unwrap()
            return Outcome.ok(
                Workspace(
                    path=path,
                    branch="",
                    base_sha=info.head,
                    head_sha=info.head,
                    strategy=Strategy.FRESH,
                    detached=True,
                )
            )
