"""Policy as data (§18.5) — capabilities, approvals, budgets and failure handling.

The defaults encode the decisions adopted in issue #1: ``MR_ONLY`` (Q1), $25/run and
$500/repo/day (Q6), lockfile-only dependency installation (Q8), 72h worktree retention (Q10),
and approval timeouts of 24h → deferred, 72h → escalated (Q14).

Production deployment is out of scope by default (§2): ``DEPLOY_PROD`` is denied outright in
the standard policy, not merely approval-gated.
"""

from __future__ import annotations

from pydantic import BaseModel, Field

from ai_harness.kernel.budget import DEFAULT_BUDGET, BudgetSpec
from ai_harness.schemas.enums import Capability, Decision, Disposition, Isolation, MergeStrategy


class ApprovalPolicy(BaseModel):
    """When a human must say yes, and what happens when nobody does."""

    max_files_changed: int = 40
    max_lines_changed: int = 1500
    approve_on_risk: bool = True
    """A plan whose risk exceeds the threshold parks before any code is written."""
    timeout_to_deferred_h: int = 24
    timeout_to_escalated_h: int = 72
    """Q14: an approval nobody answers is a decision not to proceed."""


class FailurePolicy(BaseModel):
    """§16.4 — evidence first, cleanup last."""

    preserve_worktree_on: set[Disposition] = Field(default_factory=lambda: {Disposition.ESCALATED})
    preserve_worktree_ttl_h: int = 72
    always_preserve_artefacts: bool = True
    update_forge_on_failure: bool = True
    notify_on: set[Disposition] = Field(
        default_factory=lambda: {Disposition.ESCALATED, Disposition.BLOCKED}
    )


class Policy(BaseModel):
    """The whole operating envelope for a run."""

    model_config = {"extra": "forbid"}

    name: str = "standard"
    capabilities: dict[Capability, Decision] = Field(
        default_factory=lambda: {
            Capability.READ_REPO: Decision.ALLOW,
            Capability.WRITE_WORKSPACE: Decision.ALLOW,
            Capability.RUN_TESTS: Decision.ALLOW,
            # Q8: a dependency addition is a supply-chain decision.
            Capability.INSTALL_DEPS: Decision.REQUIRE_APPROVAL,
            Capability.NETWORK: Decision.REQUIRE_APPROVAL,
            Capability.GIT_PUSH: Decision.ALLOW,
            Capability.GIT_FORCE_PUSH: Decision.REQUIRE_APPROVAL,
            Capability.FORGE_COMMENT: Decision.ALLOW,
            Capability.FORGE_MERGE: Decision.REQUIRE_APPROVAL,
            # Q9: propose gates in the MR body; never write CI config autonomously.
            Capability.MODIFY_CI: Decision.REQUIRE_APPROVAL,
            Capability.MODIFY_MIGRATIONS: Decision.REQUIRE_APPROVAL,
            Capability.DEPLOY_DEV: Decision.REQUIRE_APPROVAL,
            Capability.DEPLOY_PROD: Decision.DENY,
            Capability.BYPASS_GATE: Decision.DENY,
        }
    )
    budget: BudgetSpec = DEFAULT_BUDGET
    approval: ApprovalPolicy = Field(default_factory=ApprovalPolicy)
    failure: FailurePolicy = Field(default_factory=FailurePolicy)

    merge_strategy: MergeStrategy = MergeStrategy.MR_ONLY
    require_isolation: Isolation = Isolation.BUBBLEWRAP
    allow_degraded_isolation: bool = False
    """Running with ``Isolation.NONE`` must be a decision, and it is logged on every run."""
    egress_allowlist: list[str] = Field(default_factory=list)
    require_approval_to_start: bool = False
    allow_deps_install_with_lockfile: bool = True
    """Q8's escape hatch: with a lockfile present and ``--ignore-scripts``, install is allowed."""

    def decide(self, capability: Capability) -> Decision:
        """Unknown capability → deny. Principle §7.4: unknown fails closed."""
        return self.capabilities.get(capability, Decision.DENY)
