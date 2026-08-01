"""The closed vocabularies. Every one of these is exhaustively tested somewhere.

The seven states are the product (§8). Parking is deliberately **not** a state: a deferred
run *is* in its state, and modelling that as an orthogonal status axis is what keeps
``resume`` trivially defined — re-enter the same state — and the state count at seven.
"""

from __future__ import annotations

from enum import StrEnum


class State(StrEnum):
    """The seven top-level states. There is no eighth."""

    PREPARE = "PREPARE"
    ANALYSE = "ANALYSE"
    IMPLEMENT = "IMPLEMENT"
    VALIDATE = "VALIDATE"
    REVIEW = "REVIEW"
    INTEGRATE = "INTEGRATE"
    COMPLETE = "COMPLETE"


TERMINAL_STATE = State.COMPLETE


class RunStatus(StrEnum):
    """The orthogonal status axis. A parked run re-enters the SAME state."""

    RUNNING = "running"
    DEFERRED = "deferred"
    BLOCKED = "blocked"
    AWAITING_APPROVAL = "awaiting_approval"
    PARKED_TERMINAL = "parked_terminal"


class Disposition(StrEnum):
    """How a run ended. Every terminal disposition needs a re-entry path (invariant 12)."""

    DELIVERED = "delivered"
    """An MR is open — the default success under MR_ONLY."""
    MERGED = "merged"
    ESCALATED = "escalated"
    BLOCKED = "blocked"
    ABANDONED = "abandoned"
    """Someone else owns the work (a live lease), or the issue was withdrawn."""
    CANCELLED = "cancelled"


class Tier(StrEnum):
    """Gate tiers, matching the shell registry so a mixed rollout means the same thing."""

    TOY = "toy"
    PREVIEW = "preview"
    LAUNCH = "launch"
    SCALE = "scale"


class GateStatus(StrEnum):
    PASS = "pass"
    FAIL = "fail"
    SKIP = "skip"
    TIMEOUT = "timeout"
    ERROR = "error"


class GateSelection(StrEnum):
    """Why a gate is (not) in this run — the allow-list/deny-list distinction of §19.3."""

    RAN = "ran"
    NOT_SELECTED = "not_selected"
    """Absent from ``--only``. An honest skip: the agent lanes legitimately scope their runs."""
    DENY_LISTED = "deny_listed"
    """Removed via ``--skip``. On a required gate this is the "dodge the hard gate" move."""


class GateSet(StrEnum):
    FAST = "fast"
    FULL = "full"


class Fault(StrEnum):
    """Whose fault a red gate is. ``ENVIRONMENT`` is the third outcome of invariant 10."""

    SELF = "self"
    PLAN = "plan"
    BASE = "base"
    ENVIRONMENT = "environment"
    INHERITED = "inherited"
    UNKNOWN = "unknown"


class TriageClass(StrEnum):
    """The six classes of ``agent-triage-failure.sh``, ported verbatim."""

    TRANSIENT = "transient"
    DEPS = "deps"
    SELF = "self"
    INFRA = "infra"
    UNRELATED = "unrelated"
    STALE_BASE = "stale_base"


class Brief(StrEnum):
    """One IMPLEMENT state, three briefs. The shell has three implementations of this."""

    BUILD = "build"
    FIX = "fix"
    REPAIR = "repair"


class Severity(StrEnum):
    BLOCKER = "blocker"
    MAJOR = "major"
    MINOR = "minor"
    NIT = "nit"


BLOCKING_SEVERITIES = frozenset({Severity.BLOCKER, Severity.MAJOR})
"""What makes an "approve" self-contradicting. Deterministically downgraded, never argued with."""


class Verdict(StrEnum):
    APPROVE = "approve"
    REQUEST_CHANGES = "request_changes"
    COMMENT = "comment"


class Risk(StrEnum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


class MergeStrategy(StrEnum):
    """Q1: ``MR_ONLY`` ships as the default; ``FF_ONLY`` is opt-in per repository."""

    MR_ONLY = "mr_only"
    FF_ONLY = "ff_only"
    MERGE_COMMIT = "merge_commit"
    SQUASH = "squash"


class Capability(StrEnum):
    """What a tool call is *for*. Policy is evaluated against this, never against a command."""

    READ_REPO = "read_repo"
    WRITE_WORKSPACE = "write_workspace"
    RUN_TESTS = "run_tests"
    INSTALL_DEPS = "install_deps"
    NETWORK = "network"
    GIT_PUSH = "git_push"
    GIT_FORCE_PUSH = "git_force_push"
    FORGE_COMMENT = "forge_comment"
    FORGE_MERGE = "forge_merge"
    MODIFY_CI = "modify_ci"
    MODIFY_MIGRATIONS = "modify_migrations"
    DEPLOY_DEV = "deploy_dev"
    DEPLOY_PROD = "deploy_prod"
    BYPASS_GATE = "bypass_gate"


class Decision(StrEnum):
    ALLOW = "allow"
    DENY = "deny"
    REQUIRE_APPROVAL = "require_approval"


class Isolation(StrEnum):
    """Probed, never assumed — and recorded, so a degraded run is visible (§18.2)."""

    CONTAINER = "container"
    BUBBLEWRAP = "bubblewrap"
    NONE = "none"


class DiscoveryRung(StrEnum):
    """Which rung of the §19.2 ladder produced the gate profile."""

    HARNESS_CONFIG = "harness_config"
    ENTRY_POINT = "entry_point"
    CI_CONFIG = "ci_config"
    MANIFEST = "manifest"
    NONE = "none"


class Signal(StrEnum):
    """What a successful subgraph concluded — the vocabulary the router routes on.

    This lives in ``schemas`` rather than in ``orchestration`` because a subgraph must be able
    to *say* one without importing the supervisor that reads it. The import contract caught the
    inversion the moment it was written, which is the point of having it.
    """

    ADVANCE = "advance"
    """The state did its job; take the happy edge."""
    REPLAN = "replan"
    """Nothing usable was produced but the plan can be reconsidered."""
    FIX = "fix"
    """A defect the implementer can own — go back to IMPLEMENT."""
    REGATE = "regate"
    """The union changed; VALIDATE must judge it again."""
    REPIN = "repin"
    """The base moved under us; PREPARE re-pins it."""
    RETRY_SAME = "retry_same"
    """Re-enter this state, budget-consuming (the model produced unusable output)."""
    NEEDS_APPROVAL = "needs_approval"
    BLOCKED = "blocked"
    ESCALATE = "escalate"
    DELIVERED = "delivered"
    MERGED = "merged"
    ABANDONED = "abandoned"
    """Someone else owns this work — not a failure, and not our run."""
