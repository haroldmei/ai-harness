"""``git`` over subprocess — the one implementation.

Every method returns an ``Outcome``: no ``CalledProcessError`` escapes this module, because a
caller that must catch exceptions is a caller that will eventually forget to. Failures are
classified into the same taxonomy everything else uses — a network fetch failure is
``TRANSIENT``, a rejected credential is ``AUTH``, a non-fast-forward push is ``REPO_CONFLICT``.

Three behaviours are ported deliberately from the shell:

* **Worktree creation is serialised repo-wide.** Parallel ``git worktree add`` races on the
  shared ``.git/worktrees`` admin area (``agent-pr-reviewer.sh:92-95``). The lock lives in
  :mod:`ai_harness.workspace.worktree`; this module exposes the primitive it guards.
* **Generated-file conflicts are resolved by policy, never by a model** — take the base copy
  and let the build regenerate it. Three shell sites implement this with drifted path lists;
  here the list comes from ``RepoProfile`` and the code exists once.
* **Push is compare-and-swap.** ``expect_remote_sha`` is verified against the remote *before*
  the push and the push itself is never forced, so "main moved" fails loudly instead of
  overwriting someone.
"""

from __future__ import annotations

import asyncio
import fnmatch
import os
from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.kernel.outcome import ErrorCategory, ErrorRecord, Outcome
from ai_harness.providers.git.protocol import (
    CommandResult,
    DiffStat,
    RebaseResult,
    WorktreeInfo,
)

CONFLICT_MARKERS = ("<<<<<<< ", "=======", ">>>>>>> ")

_TRANSIENT_HINTS = (
    "could not resolve host",
    "connection timed out",
    "connection reset",
    "the remote end hung up",
    "rpc failed",
    "operation timed out",
    "temporary failure",
)
_AUTH_HINTS = (
    "authentication failed",
    "permission denied",
    "access denied",
    "could not read username",
    "invalid credentials",
)
_CONFLICT_HINTS = (
    "non-fast-forward",
    "failed to push some refs",
    "fetch first",
    "cannot lock ref",
    "would be overwritten",
)


@dataclass
class GitCLI:
    """A git client rooted at one repository."""

    root: Path
    binary: str = "git"
    timeout_s: float = 300.0
    env: dict[str, str] = field(default_factory=dict)
    author_name: str = "ai-harness"
    author_email: str = "harness@invalid.local"
    """The harness commits as itself.

    Inheriting the host's ``user.name``/``user.email`` looks harmless on a developer machine
    and fails on a fresh worker, which has no global git config at all: ``git commit`` exits
    non-zero, no commit is made, and a caller that ignores the Outcome sees an empty diff and
    no error. CI found exactly that. Identity is passed per-invocation with ``-c`` so it also
    cannot be changed underneath a run by an unrelated config edit.
    """

    # ── plumbing ─────────────────────────────────────────────────────────────────

    def _identity(self) -> list[str]:
        return [
            "-c",
            f"user.name={self.author_name}",
            "-c",
            f"user.email={self.author_email}",
        ]

    async def run(self, *args: str, cwd: Path | None = None) -> Outcome[CommandResult]:
        argv = [self.binary, *self._identity(), *args]
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                cwd=str(cwd or self.root),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env={
                    **os.environ,
                    "GIT_TERMINAL_PROMPT": "0",  # never block an unattended run on a prompt
                    "GIT_ADVICE": "0",
                    **self.env,
                },
            )
        except FileNotFoundError:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{self.binary} is not installed",
                dependency="git",
            )

        try:
            out, err = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except TimeoutError:
            process.kill()
            await process.wait()
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"git {' '.join(args[:2])} exceeded {self.timeout_s:.0f}s",
                dependency="git",
            )

        result = CommandResult(
            argv=argv,
            returncode=process.returncode or 0,
            stdout=out.decode("utf-8", "replace"),
            stderr=err.decode("utf-8", "replace"),
        )
        return Outcome.ok(result)

    async def _checked(self, *args: str, cwd: Path | None = None) -> Outcome[CommandResult]:
        outcome = await self.run(*args, cwd=cwd)
        if outcome.is_err:
            return outcome
        result = outcome.unwrap()
        if result.ok:
            return Outcome.ok(result)
        return Outcome.of(_classify(result))

    # ── queries ──────────────────────────────────────────────────────────────────

    async def rev_parse(self, ref: str, *, cwd: Path | None = None) -> Outcome[str]:
        return (await self._checked("rev-parse", ref, cwd=cwd)).map(lambda r: r.output)

    async def fetch(self, remote: str = "origin", *, cwd: Path | None = None) -> Outcome[None]:
        return (await self._checked("fetch", "--prune", remote, cwd=cwd)).map(lambda _: None)

    async def is_ancestor(
        self, ancestor: str, descendant: str, *, cwd: Path | None = None
    ) -> Outcome[bool]:
        outcome = await self.run("merge-base", "--is-ancestor", ancestor, descendant, cwd=cwd)
        if outcome.is_err:
            return Outcome.of(outcome.error) if outcome.error else Outcome.ok(False)
        result = outcome.unwrap()
        if result.returncode in (0, 1):
            return Outcome.ok(result.returncode == 0)
        return Outcome.of(_classify(result))

    async def merge_base(self, a: str, b: str, *, cwd: Path | None = None) -> Outcome[str]:
        return (await self._checked("merge-base", a, b, cwd=cwd)).map(lambda r: r.output)

    async def status_is_dirty(self, *, cwd: Path | None = None) -> Outcome[bool]:
        return (await self._checked("status", "--porcelain", cwd=cwd)).map(lambda r: bool(r.output))

    async def diff_stat(
        self, base: str, head: str = "HEAD", *, cwd: Path | None = None
    ) -> Outcome[DiffStat]:
        outcome = await self._checked("diff", "--numstat", f"{base}..{head}", cwd=cwd)
        if outcome.is_err:
            return Outcome.of(outcome.error) if outcome.error else Outcome.ok(DiffStat())
        insertions = deletions = 0
        paths: list[str] = []
        for line in outcome.unwrap().output.splitlines():
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            added, removed, path = parts
            insertions += int(added) if added.isdigit() else 0
            deletions += int(removed) if removed.isdigit() else 0
            paths.append(path)
        return Outcome.ok(
            DiffStat(
                files_changed=len(paths), insertions=insertions, deletions=deletions, paths=paths
            )
        )

    async def has_conflict_markers(self, *, cwd: Path | None = None) -> Outcome[list[str]]:
        """Scan the *tree* for markers.

        Invariant 18: never trust a resolver's verdict string. The shell fast-forwarded ``main``
        onto a tree full of markers while logging "MERGED", because three ``log`` calls missing
        their ``1>&2`` corrupted the verdict travelling on stdout. The tree is the evidence.
        """
        outcome = await self.run("ls-files", "-z", cwd=cwd)
        if outcome.is_err:
            return Outcome.of(outcome.error) if outcome.error else Outcome.ok([])
        base = cwd or self.root
        offenders: list[str] = []
        for name in outcome.unwrap().stdout.split("\0"):
            if not name:
                continue
            path = base / name
            try:
                text = path.read_text(errors="replace")
            except (OSError, UnicodeDecodeError):
                continue
            if any(text.startswith(m) or f"\n{m}" in text for m in CONFLICT_MARKERS):
                offenders.append(name)
        return Outcome.ok(offenders)

    # ── worktrees ────────────────────────────────────────────────────────────────

    async def add_worktree(
        self, path: Path, ref: str, *, branch: str | None = None, detach: bool = False
    ) -> Outcome[WorktreeInfo]:
        """Materialise a worktree.

        ``detach`` exists because ``-B`` fails with *"Cannot force update the current branch"*
        when the branch is already checked out in the primary copy — the fixer's case
        (``agent-pr-fixer.sh:184``). A detached worktree never touches the ref.
        """
        args = ["worktree", "add", "-f"]
        if detach:
            args += ["--detach", str(path), ref]
        elif branch:
            args += ["-B", branch, str(path), ref]
        else:
            args += [str(path), ref]
        outcome = await self._checked(*args)
        if outcome.is_err:
            return (
                Outcome.of(outcome.error)
                if outcome.error
                else Outcome.ok(WorktreeInfo(path=path, head="", branch=None, detached=detach))
            )
        head = await self.rev_parse("HEAD", cwd=path)
        return Outcome.ok(
            WorktreeInfo(
                path=path,
                head=head.unwrap_or(""),
                branch=None if detach else branch,
                detached=detach,
            )
        )

    async def remove_worktree(self, path: Path, *, force: bool = True) -> Outcome[None]:
        args = ["worktree", "remove"]
        if force:
            args.append("--force")
        args.append(str(path))
        outcome = await self.run(*args)
        if outcome.is_err:
            return Outcome.of(outcome.error) if outcome.error else Outcome.ok(None)
        # Pruning is harmless when the directory is already gone, and it is the difference
        # between a stale admin entry and a worktree that can never be recreated at that path.
        await self.run("worktree", "prune")
        return Outcome.ok(None)

    async def list_worktrees(self) -> Outcome[list[WorktreeInfo]]:
        outcome = await self._checked("worktree", "list", "--porcelain")
        if outcome.is_err:
            return Outcome.of(outcome.error) if outcome.error else Outcome.ok([])
        infos: list[WorktreeInfo] = []
        path: Path | None = None
        head = ""
        branch: str | None = None
        detached = False
        for line in [*outcome.unwrap().stdout.splitlines(), ""]:
            if line.startswith("worktree "):
                path = Path(line.removeprefix("worktree "))
                head, branch, detached = "", None, False
            elif line.startswith("HEAD "):
                head = line.removeprefix("HEAD ")
            elif line.startswith("branch "):
                branch = line.removeprefix("branch ").removeprefix("refs/heads/")
            elif line.strip() == "detached":
                detached = True
            elif not line.strip() and path is not None:
                infos.append(WorktreeInfo(path=path, head=head, branch=branch, detached=detached))
                path = None
        return Outcome.ok(infos)

    # ── writes ───────────────────────────────────────────────────────────────────

    async def commit_all(self, message: str, *, cwd: Path | None = None) -> Outcome[str | None]:
        """Stage everything and commit. ``None`` means there was nothing to commit."""
        staged = await self._checked("add", "-A", cwd=cwd)
        if staged.is_err:
            return Outcome.of(staged.error) if staged.error else Outcome.ok(None)
        dirty = await self.run("diff", "--cached", "--quiet", cwd=cwd)
        if dirty.is_ok and dirty.unwrap().returncode == 0:
            return Outcome.ok(None)
        committed = await self._checked("commit", "--no-verify", "-m", message, cwd=cwd)
        if committed.is_err:
            return Outcome.of(committed.error) if committed.error else Outcome.ok(None)
        return (await self.rev_parse("HEAD", cwd=cwd)).map(lambda sha: sha or None)

    async def tag(self, name: str, *, cwd: Path | None = None) -> Outcome[None]:
        """Tag the current commit.

        Invariant 14: tag the work *before* the gates run, delete the tag only after a
        successful push. Three incidents (#1764, #2152, #2196) of finished fixes vanishing into
        an unconditional cleanup are what this one line prevents.
        """
        return (await self._checked("tag", "-f", name, cwd=cwd)).map(lambda _: None)

    async def delete_tag(self, name: str, *, cwd: Path | None = None) -> Outcome[None]:
        outcome = await self.run("tag", "-d", name, cwd=cwd)
        return Outcome.ok(None) if outcome.is_ok else Outcome.of(outcome.error)  # type: ignore[arg-type]

    async def rebase_onto(
        self, base: str, *, generated_paths: list[str], cwd: Path | None = None
    ) -> Outcome[RebaseResult]:
        """Rebase onto ``base``, resolving generated-file conflicts by taking the base copy.

        This replaces three near-identical shell implementations whose auto-resolvable path
        lists had already drifted apart (§3.14). The list is data, from ``RepoProfile``.
        """
        started = await self.run("rebase", base, cwd=cwd)
        if started.is_err:
            return Outcome.of(started.error) if started.error else Outcome.ok(RebaseResult(False))
        if started.unwrap().ok:
            head = await self.rev_parse("HEAD", cwd=cwd)
            return Outcome.ok(RebaseResult(rebased=True, head=head.unwrap_or("")))

        conflicted = await self._conflicted_paths(cwd=cwd)
        if not conflicted:
            await self.run("rebase", "--abort", cwd=cwd)
            return Outcome.fail(
                ErrorCategory.REPO_CONFLICT,
                "rebase failed with no conflicted paths — treat as unresolvable",
                details={"stderr": started.unwrap().stderr[-1000:]},
            )

        product = [p for p in conflicted if not _is_generated(p, generated_paths)]
        if product:
            await self.run("rebase", "--abort", cwd=cwd)
            return Outcome.ok(
                RebaseResult(rebased=False, conflicted_paths=conflicted, generated_only=False)
            )

        for path in conflicted:
            # Take the base's copy: a generated file is regenerated by the build, so the
            # branch's version carries no information worth merging.
            await self.run("checkout", "--ours", "--", path, cwd=cwd)
            await self.run("add", "--", path, cwd=cwd)
        continued = await self.run("-c", "core.editor=true", "rebase", "--continue", cwd=cwd)
        if continued.is_ok and continued.unwrap().ok:
            head = await self.rev_parse("HEAD", cwd=cwd)
            return Outcome.ok(
                RebaseResult(
                    rebased=True,
                    conflicted_paths=conflicted,
                    generated_only=True,
                    head=head.unwrap_or(""),
                )
            )
        await self.run("rebase", "--abort", cwd=cwd)
        return Outcome.ok(
            RebaseResult(rebased=False, conflicted_paths=conflicted, generated_only=True)
        )

    async def _conflicted_paths(self, *, cwd: Path | None = None) -> list[str]:
        outcome = await self.run("diff", "--name-only", "--diff-filter=U", cwd=cwd)
        if outcome.is_err:
            return []
        return [line.strip() for line in outcome.unwrap().output.splitlines() if line.strip()]

    async def push(
        self,
        refspec: str,
        *,
        remote: str = "origin",
        expect_remote_sha: str | None = None,
        cwd: Path | None = None,
    ) -> Outcome[None]:
        """Push, never forced, optionally compare-and-swapping on the remote's current sha.

        ``expect_remote_sha`` is the mechanism behind "fast-forward only, and if ``main`` moved,
        bail": the caller states what it believes it is advancing from, and a moved target is a
        ``REPO_CONFLICT`` that re-routes to re-gating rather than a force-push.
        """
        if expect_remote_sha is not None:
            target = refspec.split(":")[-1]
            observed = await self.run("ls-remote", remote, target, cwd=cwd)
            if observed.is_err:
                return Outcome.of(observed.error) if observed.error else Outcome.ok(None)
            head = observed.unwrap().output.split()[0] if observed.unwrap().output else ""
            if head != expect_remote_sha:
                return Outcome.fail(
                    ErrorCategory.REPO_CONFLICT,
                    f"{remote}/{target} moved: expected {expect_remote_sha[:12] or '(none)'}, "
                    f"found {head[:12] or '(none)'}",
                    remedy="re-gate against the new base rather than forcing",
                )
        return (await self._checked("push", remote, refspec, cwd=cwd)).map(lambda _: None)

    async def force_push_with_lease(
        self, refspec: str, *, remote: str = "origin", cwd: Path | None = None
    ) -> Outcome[None]:
        """A separate method, because a force-push must be a separate *decision*.

        Policy gates the capability (``GIT_FORCE_PUSH``); making it a flag on :meth:`push` would
        let a caller reach it by passing a boolean.
        """
        return (await self._checked("push", "--force-with-lease", remote, refspec, cwd=cwd)).map(
            lambda _: None
        )


def _is_generated(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def _classify(result: CommandResult) -> ErrorRecord:
    text = f"{result.stdout}\n{result.stderr}".lower()
    if any(hint in text for hint in _AUTH_HINTS):
        category = ErrorCategory.AUTH
        remedy = "refresh the git credential; this is never retried"
    elif any(hint in text for hint in _TRANSIENT_HINTS):
        category = ErrorCategory.TRANSIENT
        remedy = None
    elif any(hint in text for hint in _CONFLICT_HINTS):
        category = ErrorCategory.REPO_CONFLICT
        remedy = "fetch and re-gate against the new base"
    else:
        category = ErrorCategory.TOOL_FAILURE
        remedy = None
    return ErrorRecord(
        category=category,
        message=f"git {' '.join(result.argv[1:3])} failed: {result.stderr.strip()[:300]}",
        remedy=remedy,
        dependency="git",
        details={"returncode": result.returncode, "argv": result.argv},
    )
