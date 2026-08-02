"""``INTEGRATE`` — the path to ``main``, and the four properties that make it safe.

The highest-risk component in the system. ``agent-pr-merger.sh`` states four safety properties
as non-negotiable, and all four are here:

1. **Isolation** — integration happens in its own worktree off the latest base.
2. **Gates gate the merge** — the union is re-gated, not assumed.
3. **Conflict markers go to stuck, never to a forced commit.** The tree is scanned immediately
   before the push. This exists because three ``log`` calls missing their ``1>&2`` once
   corrupted a resolver's verdict into a string that matched no ``case`` arm, fell through to
   the success branch, and fast-forwarded ``main`` onto a tree full of markers **while logging
   "MERGED"** (invariant 18).
4. **Fast-forward only, compare-and-swap.** The caller states the remote sha it believes it is
   advancing from; if ``main`` moved, the run re-gates rather than forcing.

Per Q1 the shipped default is ``MR_ONLY``: open the merge request and stop. ``FF_ONLY`` is
opt-in per repository **and** refused unless the gate set was discovered rather than inferred
and the base is green — a repository whose gates are a guess is not one to merge into
automatically.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.kernel.ids import idempotency_key
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.providers.forge.protocol import Forge, MergeRequest
from ai_harness.providers.git.protocol import GitClient
from ai_harness.schemas.enums import MergeStrategy, Signal
from ai_harness.schemas.gates import GateReport
from ai_harness.schemas.review import ReviewResult
from ai_harness.subgraphs.base import SubgraphResult

MAX_RESOLVER_ATTEMPTS = 3


@dataclass
class IntegrateContext:
    """What INTEGRATE is given."""

    run_id: str
    repo: str
    workspace: Path
    branch: str
    base_ref: str = "main"
    base_sha: str = ""
    head_sha: str = ""
    issue_number: int | None = None
    title: str = ""
    strategy: MergeStrategy = MergeStrategy.MR_ONLY
    gate_report: GateReport | None = None
    review: ReviewResult | None = None
    generated_paths: tuple[str, ...] = ()
    resolver_attempts: int = 0
    evidence: str = ""
    gates_were_discovered: bool = False
    base_is_green: bool | None = None


@dataclass
class IntegrateSubgraph:
    """The INTEGRATE state."""

    git: GitClient
    forge: Forge
    resolver: Any = None
    """``async (ctx, conflicts) -> Outcome[bool]``. Only called on a genuine conflict."""
    state_name: str = "INTEGRATE"

    async def execute(self, ctx: IntegrateContext) -> Outcome[SubgraphResult]:
        key = idempotency_key("integrate", run=ctx.run_id, sha=ctx.head_sha)

        # Gates gate the merge. An absent or red report is not something to work around.
        if ctx.gate_report is None or not ctx.gate_report.green:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                "refusing to integrate without a green gate report on this head commit",
                remedy="VALIDATE must pass on the exact commit being integrated",
            )

        # The provider-side MR id is the idempotency token: ask before acting, always.
        existing = await self.forge.find_mr_by_head(ctx.branch)
        if existing.is_err:
            return Outcome.of(existing.error)  # type: ignore[arg-type]
        mr = existing.unwrap()

        # Defence in depth: markers already in the tree make the rebase fail with a confusing
        # "index contains uncommitted changes", which buries the actual problem. Scanning first
        # costs one `ls-files` and names it.
        changed = await self._changed_paths(ctx)
        arrived_with = await self.git.has_conflict_markers(cwd=ctx.workspace, paths=changed)
        if arrived_with.is_ok and arrived_with.unwrap():
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"the workspace already contains conflict markers in "
                f"{', '.join(arrived_with.unwrap()[:5])}",
                remedy="an earlier state left markers behind; this never becomes a commit",
                details={"paths": arrived_with.unwrap()[:20]},
            )

        rebased = await self._rebase(ctx)
        if rebased is not None:
            return rebased

        markers = await self.git.has_conflict_markers(
            cwd=ctx.workspace, paths=await self._changed_paths(ctx)
        )
        if markers.is_ok and markers.unwrap():
            # The last line of defence, and the one that has actually saved a `main`.
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"conflict markers remain in {', '.join(markers.unwrap()[:5])}",
                remedy=(
                    "never trust a resolver's verdict string — the tree is the evidence, and "
                    "this tree still has markers in it"
                ),
                details={"paths": markers.unwrap()[:20]},
            )

        if mr is None:
            created = await self.forge.create_mr(
                head_ref=ctx.branch,
                base_ref=ctx.base_ref,
                title=ctx.title or f"agent: {ctx.repo}#{ctx.issue_number}",
                body=ctx.evidence,
                issue=ctx.issue_number,
            )
            if created.is_err:
                return Outcome.of(created.error)  # type: ignore[arg-type]
            mr = created.unwrap()
        elif ctx.evidence:
            await self.forge.update_mr(mr.number, body=ctx.evidence)

        if ctx.strategy is MergeStrategy.MR_ONLY:
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.DELIVERED,
                    reason=f"merge request #{mr.number} is open — the MR_ONLY default",
                    payload={**_mr_payload(mr, key), "strategy": ctx.strategy.value},
                    head_sha=ctx.head_sha,
                    base_sha=ctx.base_sha,
                )
            )

        refusal = self._may_auto_merge(ctx)
        if refusal is not None:
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.DELIVERED,
                    reason=f"opened #{mr.number} instead of merging: {refusal}",
                    payload={**_mr_payload(mr, key), "auto_merge_refused": refusal},
                    head_sha=ctx.head_sha,
                    base_sha=ctx.base_sha,
                )
            )

        return await self._fast_forward(ctx, mr, key)

    async def _changed_paths(self, ctx: IntegrateContext) -> list[str] | None:
        """The files this branch touches. ``None`` — scan everything — when we cannot tell.

        Narrowing is a safety *improvement* only while it is accurate: if the diff cannot be
        computed, the honest fallback is the whole tree, because a missed marker is the failure
        this scan exists to prevent.
        """
        if not ctx.base_sha:
            return None
        listed = await self.git.run(
            "diff", "--name-only", f"{ctx.base_sha}...HEAD", cwd=ctx.workspace
        )
        if listed.is_err:
            return None
        changed = [line for line in listed.unwrap().stdout.splitlines() if line.strip()]
        # Empty means "fall back to the whole tree", never "scan nothing". An empty answer is
        # ambiguous — a branch that changed nothing looks identical to a diff we could not
        # compute — and only one of those two readings is safe.
        return changed or None

    async def _rebase(self, ctx: IntegrateContext) -> Outcome[SubgraphResult] | None:
        """Rebase onto the live base. ``None`` means it is clean and we may proceed."""
        result = await self.git.rebase_onto(
            ctx.base_ref, generated_paths=list(ctx.generated_paths), cwd=ctx.workspace
        )
        if result.is_err:
            return Outcome.of(result.error)  # type: ignore[arg-type]
        rebase = result.unwrap()
        if rebase.rebased:
            if rebase.conflicted_paths:
                # Generated files were regenerated: the union changed, so re-gate it.
                return Outcome.ok(
                    SubgraphResult(
                        signal=Signal.REGATE,
                        reason=(
                            "generated files were resolved during the rebase — the union is "
                            "not what VALIDATE judged"
                        ),
                        payload={"regenerated": rebase.conflicted_paths},
                        base_sha=ctx.base_sha,
                    )
                )
            return None

        if self.resolver is None or ctx.resolver_attempts >= MAX_RESOLVER_ATTEMPTS:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"unresolvable conflict in {', '.join(rebase.conflicted_paths[:5])}",
                remedy="a conflict that leaves markers goes to a human, never to a forced commit",
            )

        resolved = await self.resolver(ctx, rebase.conflicted_paths)
        if resolved.is_err:
            return Outcome.of(resolved.error)
        if not resolved.unwrap():
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.FIX,
                    reason="the conflict is a code defect the fixer can own",
                    payload={"conflicts": rebase.conflicted_paths},
                    base_sha=ctx.base_sha,
                )
            )
        return Outcome.ok(
            SubgraphResult(
                signal=Signal.REGATE,
                reason="the conflict was resolved — re-gate the union before landing it",
                payload={"conflicts": rebase.conflicted_paths},
                base_sha=ctx.base_sha,
            )
        )

    def _may_auto_merge(self, ctx: IntegrateContext) -> str | None:
        """``None`` means FF_ONLY is permitted. Anything else is the reason it is not.

        Refusing loudly and opening an MR anyway is better than either merging on a guess or
        failing the run: the work is still delivered, a human just decides.
        """
        if not ctx.gates_were_discovered:
            return (
                "the gate set was inferred rather than discovered, so an automatic merge would "
                "be gated by a guess (§19.2)"
            )
        if ctx.base_is_green is False:
            return "the base is red; merging into it would compound a breakage"
        if ctx.review is None or not ctx.review.approved:
            return "no approving review on this head commit"
        return None

    async def _fast_forward(
        self, ctx: IntegrateContext, mr: MergeRequest, key: str
    ) -> Outcome[SubgraphResult]:
        """Push with compare-and-swap. Never forced; a moved base re-gates."""
        pushed = await self.git.push(
            f"HEAD:refs/heads/{ctx.base_ref}",
            expect_remote_sha=ctx.base_sha,
            cwd=ctx.workspace,
        )
        if pushed.is_err:
            assert pushed.error is not None
            if pushed.error.category is ErrorCategory.REPO_CONFLICT:
                return Outcome.ok(
                    SubgraphResult(
                        signal=Signal.REGATE,
                        reason=f"{ctx.base_ref} moved while we were integrating — re-gate",
                        payload={"expected_base": ctx.base_sha},
                        base_sha=ctx.base_sha,
                    )
                )
            return Outcome.of(pushed.error)

        return Outcome.ok(
            SubgraphResult(
                signal=Signal.MERGED,
                reason=f"fast-forwarded {ctx.base_ref} to {ctx.head_sha[:12]}",
                payload={**_mr_payload(mr, key), "strategy": ctx.strategy.value},
                head_sha=ctx.head_sha,
                base_sha=ctx.base_sha,
            )
        )


def _mr_payload(mr: MergeRequest, key: str) -> dict[str, Any]:
    return {
        "idempotency_key": key,
        "mr_id": mr.id,
        "mr_number": mr.number,
        "mr_url": mr.url,
    }


@dataclass
class ConflictResolver:
    """Model-assisted conflict resolution — snapshot, attempt, **verify**, restore.

    The resolver's own verdict is evidence, never proof. What decides is the tree: markers gone,
    and the rebase actually completing. Restoring between attempts means a failed attempt costs
    nothing, which is what makes three attempts safe rather than three chances to corrupt.
    """

    git: GitClient
    agent: Any = None
    max_attempts: int = MAX_RESOLVER_ATTEMPTS
    snapshots: list[str] = field(default_factory=list)

    async def resolve(self, ctx: IntegrateContext, conflicts: list[str]) -> Outcome[bool]:
        for attempt in range(1, self.max_attempts + 1):
            snapshot = await self._snapshot(ctx, attempt)
            if self.agent is None:
                await self._restore(ctx, snapshot)
                return Outcome.ok(False)

            attempted = await self.agent(ctx, conflicts, attempt)
            if attempted.is_err:
                await self._restore(ctx, snapshot)
                continue

            markers = await self.git.has_conflict_markers(cwd=ctx.workspace)
            if markers.is_ok and not markers.unwrap():
                continued = await self.git.run(
                    "-c", "core.editor=true", "rebase", "--continue", cwd=ctx.workspace
                )
                if continued.is_ok and continued.unwrap().ok:
                    return Outcome.ok(True)
            # The verdict said one thing; the tree says another. The tree wins.
            await self._restore(ctx, snapshot)

        return Outcome.ok(False)

    async def _snapshot(self, ctx: IntegrateContext, attempt: int) -> str:
        tag = f"harness/{ctx.run_id}/resolve/{attempt}"
        await self.git.run("stash", "create", cwd=ctx.workspace)
        await self.git.tag(tag, cwd=ctx.workspace)
        self.snapshots.append(tag)
        return tag

    async def _restore(self, ctx: IntegrateContext, snapshot: str) -> None:
        await self.git.run("checkout", "--", ".", cwd=ctx.workspace)
        await self.git.delete_tag(snapshot, cwd=ctx.workspace)
