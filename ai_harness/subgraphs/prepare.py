"""``PREPARE`` — the workspace exists, the base is pinned, and the deps are real.

The first state, and the one whose failures are cheapest to get wrong: everything after it
assumes a tree it can edit, a base it can diff against, and an install that actually landed. Each
of those is a separate way to waste a whole run, so each is a separate outcome here.

Four things this state owns, and none of them is a detail:

* **The claim.** Two workers must not build the same issue. The worktree lock is per repository
  and the run lease is per run, and a branch somebody else is already holding is
  :attr:`~ai_harness.schemas.enums.Signal.ABANDONED` — *not* a failure. Losing that race is the
  ordinary answer, not an exception (§14.3).
* **Resume.** A branch from a previous attempt is reused when it is safe and discarded when it
  is not; :class:`~ai_harness.workspace.worktree.WorktreeManager` owns that policy and reports
  which of the three strategies it applied, so the decision is in the checkpoint rather than in
  someone's memory.
* **Isolation.** Probed, never assumed (§18.2). A run that silently degraded to no isolation is a
  run whose safety claims are false, so a degraded probe escalates unless the policy said in
  advance that it may not.
* **Dependencies.** ``npm ci`` exiting 0 is not evidence the install landed, which is why
  :class:`~ai_harness.workspace.deps.DepsProvisioner` verifies afterwards. A *verification*
  failure routes to ``REPLAN`` rather than escalating: §9.1's own row says an undeclared
  dependency is a code defect the agent can fix, and sending it to a human first would burn the
  cheapest fix in the system.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.schemas.enums import Isolation, Signal
from ai_harness.security.sandbox import probe
from ai_harness.subgraphs.base import SubgraphResult
from ai_harness.workspace.deps import DepsProvisioner
from ai_harness.workspace.worktree import WorktreeManager


@dataclass
class PrepareContext:
    """What PREPARE is given. Assembled by the caller, never fetched from here."""

    run_id: str
    repo: str
    workspace: Path
    branch: str
    base_ref: str = "origin/main"
    remote: str = "origin"
    issue_number: int | None = None
    holder: str = "harness"

    workspaces: tuple[str, ...] = ()
    """Sub-packages that carry their own manifest — a monorepo's ``[backend, frontend]``."""
    provision_deps: bool = True
    allow_install_without_lockfile: bool = False
    deps_timeout_s: float = 900.0

    isolation: Isolation = Isolation.BUBBLEWRAP
    allow_degraded_isolation: bool = False

    claimed_by: str | None = None
    """Set when another worker already holds this issue. Abandon rather than race it."""


@dataclass
class PrepareSubgraph:
    """The PREPARE state."""

    worktrees: WorktreeManager
    state_name: str = "PREPARE"
    env: dict[str, str] = field(default_factory=dict)

    async def execute(self, ctx: PrepareContext) -> Outcome[SubgraphResult]:
        if ctx.claimed_by:
            # Someone else owns the work. Not a failure and not our run (§9.1).
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.ABANDONED,
                    reason=f"{ctx.claimed_by} already holds {ctx.branch}",
                    payload={"branch": ctx.branch, "claimed_by": ctx.claimed_by},
                )
            )

        sandbox = probe(ctx.isolation, allow_degraded=ctx.allow_degraded_isolation)
        if sandbox.degraded and not ctx.allow_degraded_isolation:
            # Escalate rather than proceed. The alternative is a run that produces a diff nobody
            # can claim was produced under the isolation the policy names.
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.ESCALATE,
                    reason=f"isolation degraded to {sandbox.chosen.value}: {sandbox.reason}",
                    payload={"isolation": sandbox.chosen.value, "degraded": True},
                    isolation=sandbox.chosen.value,
                )
            )

        materialised = await self.worktrees.materialise(
            path=ctx.workspace,
            branch=ctx.branch,
            base_ref=ctx.base_ref,
            remote=ctx.remote,
            holder=ctx.holder,
        )
        if materialised.is_err:
            # Returned as it is: TRANSIENT here means another worker is mid-`git worktree add`,
            # and relabelling it would spend an attempt on a lock we simply have to wait for.
            return Outcome.of(materialised.error)  # type: ignore[arg-type]

        workspace = materialised.unwrap()
        payload: dict[str, object] = {
            "branch": workspace.branch,
            "strategy": workspace.strategy.value,
            "resumed": workspace.resumed,
            "workspace": str(workspace.path),
            "isolation": sandbox.chosen.value,
        }

        if ctx.provision_deps:
            provisioner = DepsProvisioner(
                root=workspace.path,
                workspaces=list(ctx.workspaces),
                allow_install_without_lockfile=ctx.allow_install_without_lockfile,
                timeout_s=ctx.deps_timeout_s,
                env=dict(self.env),
            )
            provisioned = await provisioner.provision()
            if provisioned.is_err:
                error = provisioned.error
                assert error is not None
                if error.category is ErrorCategory.POLICY:
                    # A missing lockfile is a supply-chain decision (Q8), not something to fix
                    # by installing anyway.
                    return Outcome.of(error)
                return Outcome.ok(
                    SubgraphResult(
                        signal=Signal.REPLAN,
                        reason=f"dependencies could not be provisioned: {error.message}",
                        payload={**payload, "deps_error": error.message},
                        base_sha=workspace.base_sha,
                        head_sha=workspace.head_sha,
                        isolation=sandbox.chosen.value,
                    )
                )

            report = provisioned.unwrap()
            payload["deps"] = {
                "ecosystem": report.ecosystem.value if report.ecosystem else None,
                "installed": report.installed,
                "verified": report.verified,
                "lockfile_present": report.lockfile_present,
                # Named rather than counted: "3 undeclared imports" sends a human looking, and
                # the list is what the fixer's brief needs anyway.
                "undeclared": report.undeclared[:20],
                "unresolved": report.unresolved[:20],
            }
            if not report.verified:
                # The install command succeeded and the tree still does not have what it claimed
                # to install. That is the incident this check exists for, and the agent can fix
                # an undeclared dependency (§9.1's REPLAN row).
                return Outcome.ok(
                    SubgraphResult(
                        signal=Signal.REPLAN,
                        reason="dependencies installed but verification failed",
                        payload=payload,
                        base_sha=workspace.base_sha,
                        head_sha=workspace.head_sha,
                        isolation=sandbox.chosen.value,
                    )
                )

        return Outcome.ok(
            SubgraphResult(
                signal=Signal.ADVANCE,
                reason=(
                    f"workspace ready at {workspace.path.name}, base pinned at "
                    f"{workspace.base_sha[:12]} ({workspace.strategy.value})"
                ),
                payload=payload,
                base_sha=workspace.base_sha,
                head_sha=workspace.head_sha,
                isolation=sandbox.chosen.value,
            )
        )
