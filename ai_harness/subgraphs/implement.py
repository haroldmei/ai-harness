"""``IMPLEMENT`` — one state, three briefs, and the safety checks the shell bought the hard way.

The shell has three near-identical implementations of this: the builder
(``agent-inbox.sh:493-570``), the fixer (``agent-pr-fixer.sh:303-401``) and the fixer's inline
self-repair loop (``:495-557``). They differ in their *brief*, not in what they do, and they have
already drifted — different reset lists, different work detection, different push guards. Here
there is one implementation and a :class:`Brief`.

Every guard below exists because its absence cost something:

* **Work is "HEAD moved OR the tree is dirty".** The harness contract says *leave your edits
  uncommitted*, and models ignore it often enough that measuring only one of the two loses real
  work.
* **A commit that is not a descendant of the remote tip is refused.** Pushing it would rewrite
  someone else's history.
* **Provisioned artefacts never enter a commit.** A directory-only ``.gitignore`` does not match
  a *symlink* named ``node_modules``, which is how provisioned symlinks got committed.
* **Tag before gating; push before proposing** (invariants 14, 15). Three incidents of finished
  fixes vanishing, and builds restarting from nothing.
"""

from __future__ import annotations

import fnmatch
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.kernel.ids import idempotency_key
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.providers.git.protocol import DiffStat, GitClient
from ai_harness.schemas.enums import Brief, Signal
from ai_harness.schemas.plan import WorkPlan
from ai_harness.subgraphs.base import SubgraphResult

DEFAULT_MAX_FILES = 40
DEFAULT_MAX_LINES = 1500


@dataclass
class ImplementContext:
    """What IMPLEMENT is given. The model's actual editing happens through the broker."""

    run_id: str
    repo: str
    workspace: Path
    branch: str
    base_sha: str
    brief: Brief = Brief.BUILD
    plan_hash: str = ""
    attempt: int = 1
    max_attempts: int = 6
    max_files: int = DEFAULT_MAX_FILES
    max_lines: int = DEFAULT_MAX_LINES
    protected_paths: tuple[str, ...] = ()
    provisioned_paths: tuple[str, ...] = ("node_modules", ".env", ".venv", "*/node_modules")
    remote: str = "origin"
    may_push: bool = True
    empty_streak: int = 0

    # What the editor needs to write anything at all. Carried on the context rather than fetched
    # by the editor, because a state that reaches for the forge mid-edit is a state whose cost
    # and failure modes are no longer its own.
    plan: WorkPlan | None = None
    issue_title: str = ""
    issue_body: str = ""
    issue_number: int | None = None
    findings: tuple[str, ...] = ()
    """Blocking review findings, when this is a FIX brief."""
    gate_failure: str = ""
    """The diagnostic line, when this is a REPAIR brief."""


@dataclass
class ImplementResult:
    """What the state produced, in the terms the next state needs."""

    commit_sha: str | None = None
    diffstat: DiffStat = field(default_factory=DiffStat)
    tag: str | None = None
    pushed: bool = False
    dirty_before: bool = False
    head_moved: bool = False


@dataclass
class ImplementSubgraph:
    """The IMPLEMENT state. The model edits; this decides what that amounted to."""

    git: GitClient
    editor: Any = None
    """``async (ctx) -> Outcome[None]``. The agent that actually edits, via the broker."""
    state_name: str = "IMPLEMENT"

    async def execute(self, ctx: ImplementContext) -> Outcome[SubgraphResult]:
        key = idempotency_key("implement", run=ctx.run_id, plan=ctx.plan_hash, attempt=ctx.attempt)

        head_before = (await self.git.rev_parse("HEAD", cwd=ctx.workspace)).unwrap_or("")

        if self.editor is not None:
            edited = await self.editor(ctx)
            if edited.is_err:
                assert edited.error is not None
                # A transient, a policy denial or an approval requirement is returned as it is:
                # the categories already say what happens next, and re-labelling here would
                # start charging for failures that are not the attempt's fault.
                return Outcome.of(edited.error)

        head_after = (await self.git.rev_parse("HEAD", cwd=ctx.workspace)).unwrap_or("")
        dirty = (await self.git.status_is_dirty(cwd=ctx.workspace)).unwrap_or(False)
        head_moved = bool(head_after) and head_after != head_before

        if not head_moved and not dirty:
            # No work at all. Not a failure of the *tooling*, so it does not escalate here —
            # it replans, and the attempt cap is what eventually stops it.
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.REPLAN,
                    reason="the model produced no work: HEAD did not move and the tree is clean",
                    payload={"idempotency_key": key, "brief": ctx.brief.value},
                    base_sha=ctx.base_sha,
                    head_sha=head_after or head_before,
                )
            )

        provisioned = await self._provisioned_in_tree(ctx)
        if provisioned:
            return Outcome.fail(
                ErrorCategory.TOOL_FAILURE,
                f"refusing to commit provisioned artefacts: {', '.join(provisioned[:5])}",
                remedy=(
                    "a directory-only .gitignore does not match a symlink of the same name; "
                    "the reset list lives on RepoProfile"
                ),
                details={"paths": provisioned[:20]},
            )

        commit_sha: str | None = head_after if head_moved else None
        if dirty:
            committed = await self.git.commit_all(_message(ctx), cwd=ctx.workspace)
            if committed.is_err:
                return Outcome.of(committed.error)  # type: ignore[arg-type]
            commit_sha = committed.unwrap() or commit_sha

        if commit_sha is None:
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.REPLAN,
                    reason="nothing was committed after the edit",
                    payload={"idempotency_key": key},
                    base_sha=ctx.base_sha,
                )
            )

        descendant = await self.git.is_ancestor(ctx.base_sha, commit_sha, cwd=ctx.workspace)
        if descendant.is_ok and not descendant.unwrap():
            return Outcome.fail(
                ErrorCategory.REPO_CONFLICT,
                f"{commit_sha[:12]} is not a descendant of the base it claims to build on",
                remedy="re-pin the base and re-gate rather than pushing a divergent history",
            )

        stat = (await self.git.diff_stat(ctx.base_sha, commit_sha, cwd=ctx.workspace)).unwrap_or(
            DiffStat()
        )

        # Tag BEFORE anything can remove the worktree (invariant 14).
        tag = f"harness/{ctx.run_id}/IMPLEMENT/{ctx.attempt}"
        await self.git.tag(tag, cwd=ctx.workspace)

        breach = self._size_breach(ctx, stat)
        protected = self._protected(ctx, stat.paths)
        if breach or protected:
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.NEEDS_APPROVAL,
                    reason=" and ".join(filter(None, [breach, _protected_reason(protected)])),
                    payload={
                        "idempotency_key": key,
                        "files": stat.files_changed,
                        "lines": stat.insertions + stat.deletions,
                        "protected": protected,
                        "tag": tag,
                    },
                    base_sha=ctx.base_sha,
                    head_sha=commit_sha,
                )
            )

        # Early push (invariant 15): pushing a branch is not the same as proposing it, and it
        # turns "the process died, start over" into "the gate failed, try again from here".
        pushed = False
        if ctx.may_push and ctx.branch:
            pushed = (
                await self.git.push(
                    f"HEAD:refs/heads/{ctx.branch}", remote=ctx.remote, cwd=ctx.workspace
                )
            ).is_ok

        return Outcome.ok(
            SubgraphResult(
                signal=Signal.ADVANCE,
                reason=(
                    f"{ctx.brief.value}: {stat.files_changed} file(s), "
                    f"+{stat.insertions}/-{stat.deletions}"
                ),
                payload={
                    "idempotency_key": key,
                    "brief": ctx.brief.value,
                    "commit": commit_sha,
                    "files": stat.files_changed,
                    "insertions": stat.insertions,
                    "deletions": stat.deletions,
                    "paths": stat.paths[:50],
                    "tag": tag,
                    "pushed": pushed,
                    "head_moved": head_moved,
                    "was_dirty": dirty,
                },
                base_sha=ctx.base_sha,
                head_sha=commit_sha,
            )
        )

    async def _provisioned_in_tree(self, ctx: ImplementContext) -> list[str]:
        """Staged paths that match the provisioned list — symlinks included."""
        listed = await self.git.run("ls-files", "-z", cwd=ctx.workspace)
        if listed.is_err:
            return []
        offenders: list[str] = []
        for name in listed.unwrap().stdout.split("\0"):
            if not name:
                continue
            if any(_matches(name, pattern) for pattern in ctx.provisioned_paths):
                offenders.append(name)
        return offenders

    def _size_breach(self, ctx: ImplementContext, stat: DiffStat) -> str:
        lines = stat.insertions + stat.deletions
        if stat.files_changed > ctx.max_files:
            return f"{stat.files_changed} files changed (cap {ctx.max_files})"
        if lines > ctx.max_lines:
            return f"{lines} lines changed (cap {ctx.max_lines})"
        return ""

    def _protected(self, ctx: ImplementContext, paths: list[str]) -> list[str]:
        return [p for p in paths if any(_matches(p, pattern) for pattern in ctx.protected_paths)]


def _protected_reason(protected: list[str]) -> str:
    return f"touches protected paths: {', '.join(protected[:5])}" if protected else ""


def _message(ctx: ImplementContext) -> str:
    verb = {
        Brief.BUILD: "implement",
        Brief.FIX: "address review findings for",
        Brief.REPAIR: "repair the gates for",
    }
    return f"{verb[ctx.brief]} {ctx.repo} (run {ctx.run_id[:8]}, attempt {ctx.attempt})"


def _matches(path: str, pattern: str) -> bool:
    return (
        fnmatch.fnmatch(path, pattern)
        or fnmatch.fnmatch(path, f"*/{pattern}")
        or path.split("/")[0] == pattern
    )
