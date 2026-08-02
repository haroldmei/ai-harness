"""The git seam.

Git operations are spread across every shell stage, with three different isolation strategies
and three near-identical rebase-with-generated-resolution implementations (§3.14). Collapsing
them needs one interface, and that interface has to make two things explicit that the shell
leaves implicit:

* **A conflict is not an error.** ``RebaseResult`` distinguishes clean, generated-file-only and
  genuine content conflicts, because the three route to three different places (continue,
  regenerate, hand to the resolver).
* **A push is a compare-and-swap.** The caller states the remote sha it believes it is
  advancing from; if the remote moved, the push fails rather than forcing. Force-with-lease is
  a *different method*, so it cannot be reached by passing a flag.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from ai_harness.kernel.outcome import Outcome


@dataclass(frozen=True, slots=True)
class CommandResult:
    """The raw result of one git invocation. Kept for evidence, not for parsing by callers."""

    argv: list[str]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    @property
    def output(self) -> str:
        return self.stdout.strip()


@dataclass(frozen=True, slots=True)
class DiffStat:
    files_changed: int = 0
    insertions: int = 0
    deletions: int = 0
    paths: list[str] = field(default_factory=list)


@dataclass(frozen=True, slots=True)
class WorktreeInfo:
    path: Path
    head: str
    branch: str | None
    detached: bool


@dataclass(frozen=True, slots=True)
class RebaseResult:
    """Rebase outcome, split by *what kind* of conflict was hit."""

    rebased: bool
    conflicted_paths: list[str] = field(default_factory=list)
    generated_only: bool = False
    """True when every conflicted path is a declared generated file — resolvable by policy."""
    head: str = ""

    @property
    def needs_resolver(self) -> bool:
        return bool(self.conflicted_paths) and not self.generated_only


class GitClient(Protocol):
    """Everything the harness does to a repository, and nothing it does not."""

    async def run(self, *args: str, cwd: Path | None = None) -> Outcome[CommandResult]: ...

    async def rev_parse(self, ref: str, *, cwd: Path | None = None) -> Outcome[str]: ...

    async def fetch(self, remote: str = "origin", *, cwd: Path | None = None) -> Outcome[None]: ...

    async def is_ancestor(
        self, ancestor: str, descendant: str, *, cwd: Path | None = None
    ) -> Outcome[bool]: ...

    async def merge_base(self, a: str, b: str, *, cwd: Path | None = None) -> Outcome[str]: ...

    async def add_worktree(
        self, path: Path, ref: str, *, branch: str | None = None, detach: bool = False
    ) -> Outcome[WorktreeInfo]: ...

    async def remove_worktree(self, path: Path, *, force: bool = True) -> Outcome[None]: ...

    async def list_worktrees(self) -> Outcome[list[WorktreeInfo]]: ...

    async def status_is_dirty(self, *, cwd: Path | None = None) -> Outcome[bool]: ...

    async def commit_all(self, message: str, *, cwd: Path | None = None) -> Outcome[str | None]: ...

    async def tag(self, name: str, *, cwd: Path | None = None) -> Outcome[None]: ...

    async def delete_tag(self, name: str, *, cwd: Path | None = None) -> Outcome[None]: ...

    async def rebase_onto(
        self, base: str, *, generated_paths: list[str], cwd: Path | None = None
    ) -> Outcome[RebaseResult]: ...

    async def push(
        self,
        refspec: str,
        *,
        remote: str = "origin",
        expect_remote_sha: str | None = None,
        cwd: Path | None = None,
    ) -> Outcome[None]: ...

    async def diff_stat(
        self, base: str, head: str = "HEAD", *, cwd: Path | None = None
    ) -> Outcome[DiffStat]: ...

    async def has_conflict_markers(
        self, *, cwd: Path | None = None, paths: list[str] | None = None
    ) -> Outcome[list[str]]: ...
