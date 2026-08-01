"""Issue #8 — the cross-field invariants, positive and negative, in the schema itself."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from ai_harness.schemas.enums import (
    Disposition,
    GateSelection,
    GateStatus,
    MergeStrategy,
    Severity,
    State,
    Tier,
    Verdict,
)
from ai_harness.schemas.gates import (
    GateIntegrityCheck,
    GateProfile,
    GateReport,
    GateResult,
    GateSpec,
)
from ai_harness.schemas.policy import Policy
from ai_harness.schemas.profile import RepoProfile
from ai_harness.schemas.review import Finding, ReviewResult


def _finding(severity: Severity = Severity.BLOCKER) -> Finding:
    return Finding(severity=severity, title="races on the lock", file="app/svc.py", line=42)


# ── invariant 4 — approve + blocker findings is corrected in code ────────────────


def test_approve_with_a_blocking_finding_is_downgraded() -> None:
    result = ReviewResult(verdict=Verdict.APPROVE, findings=[_finding()])
    assert result.verdict is Verdict.REQUEST_CHANGES
    assert result.downgraded
    assert result.downgrade_reason is not None and "app/svc.py:42" in result.downgrade_reason


def test_approve_with_only_nits_stands() -> None:
    result = ReviewResult(verdict=Verdict.APPROVE, findings=[_finding(Severity.NIT)])
    assert result.verdict is Verdict.APPROVE and not result.downgraded


def test_a_finding_must_be_falsifiable() -> None:
    with pytest.raises(ValidationError):
        Finding(severity=Severity.MAJOR, title="vague", file="", line=1)
    with pytest.raises(ValidationError):
        Finding(severity=Severity.MAJOR, title="vague", file="a.py", line=0)


def test_severity_histogram_covers_every_severity() -> None:
    histogram = ReviewResult(verdict=Verdict.COMMENT, findings=[_finding()]).severity_histogram()
    assert set(histogram) == {s.value for s in Severity}
    assert histogram["blocker"] == 1


# ── invariant 11 — a skipped required check is a failure ─────────────────────────


def test_exit_77_on_a_required_gate_is_promoted_to_fail() -> None:
    result = GateResult(name="integration", raw_status=GateStatus.SKIP, required=True)
    assert result.status is GateStatus.FAIL
    assert result.promoted and result.reason


def test_a_required_gate_absent_from_only_is_an_honest_skip() -> None:
    """The deployed lanes legitimately scope to --only unit; that is not a dodge."""
    result = GateResult(
        name="integration",
        raw_status=GateStatus.SKIP,
        required=True,
        selection=GateSelection.NOT_SELECTED,
    )
    assert result.status is GateStatus.SKIP and not result.promoted


def test_a_required_gate_removed_via_skip_is_a_failure() -> None:
    result = GateResult(
        name="integration",
        raw_status=GateStatus.SKIP,
        required=True,
        selection=GateSelection.DENY_LISTED,
    )
    assert result.status is GateStatus.FAIL and result.promoted


def test_a_non_required_skip_stays_a_skip() -> None:
    assert GateResult(name="i18n", raw_status=GateStatus.SKIP).status is GateStatus.SKIP


def test_a_timeout_is_a_failure_not_a_pass() -> None:
    assert GateResult(name="e2e", raw_status=GateStatus.TIMEOUT).status is GateStatus.FAIL


# ── reports ──────────────────────────────────────────────────────────────────────


def test_a_report_with_no_gates_is_not_green() -> None:
    """Rung 5 escalates: a repository with no discoverable gate is not deliverable into."""
    assert not GateReport(no_gates_discovered=True).green
    assert not GateReport().green


def test_green_requires_no_required_failure() -> None:
    report = GateReport(
        results=[
            GateResult(name="unit", raw_status=GateStatus.PASS, required=True),
            GateResult(name="i18n", raw_status=GateStatus.FAIL),
        ]
    )
    assert report.green, "a non-required failure does not gate the merge"
    red = GateReport(results=[GateResult(name="unit", raw_status=GateStatus.FAIL, required=True)])
    assert not red.green


def test_inherited_failures_are_forgiven_but_still_shown() -> None:
    report = GateReport(
        results=[GateResult(name="unit", raw_status=GateStatus.FAIL, required=True, inherited=True)]
    )
    assert report.green
    assert report.results[0].status is GateStatus.FAIL, "forgiven, never hidden"


def test_regression_comparison_reports_only_added_failures() -> None:
    base = GateReport(results=[GateResult(name="unit", raw_status=GateStatus.FAIL, required=True)])
    head = GateReport(
        results=[
            GateResult(name="unit", raw_status=GateStatus.FAIL, required=True),
            GateResult(name="lint", raw_status=GateStatus.FAIL, required=True),
        ]
    )
    assert [r.name for r in head.regression_against(base)] == ["lint"]


def test_requiredness_is_per_tier() -> None:
    spec = GateSpec(name="integration", required_from_tier=Tier.LAUNCH)
    assert not spec.required_at(Tier.PREVIEW)
    assert spec.required_at(Tier.LAUNCH) and spec.required_at(Tier.SCALE)


def test_advisory_gates_never_block() -> None:
    spec = GateSpec(name="quarantine", required_from_tier=Tier.TOY, advisory=True)
    assert not spec.required_at(Tier.SCALE)


def test_profile_reports_when_nothing_was_discovered() -> None:
    assert GateProfile().no_gates_discovered
    assert not GateProfile(gates=[GateSpec(name="unit")]).no_gates_discovered


# ── anti-weakening ───────────────────────────────────────────────────────────────


def test_integrity_check_is_clean_only_when_every_field_is_empty() -> None:
    assert GateIntegrityCheck().clean
    dirty = GateIntegrityCheck(deleted_tests=["test_auth.py::test_expiry"])
    assert not dirty.clean
    assert "deleted test: test_auth.py::test_expiry" in dirty.evidence()
    assert not GateIntegrityCheck(ci_modified=True).clean


# ── policy and profile defaults carry the adopted decisions ──────────────────────


def test_shipped_defaults_are_mr_only_and_deny_prod_deploy() -> None:
    from ai_harness.schemas.enums import Capability, Decision

    policy = Policy()
    assert policy.merge_strategy is MergeStrategy.MR_ONLY
    assert policy.decide(Capability.DEPLOY_PROD) is Decision.DENY
    assert policy.decide(Capability.MODIFY_CI) is Decision.REQUIRE_APPROVAL
    assert policy.decide(Capability.BYPASS_GATE) is Decision.DENY


def test_an_unknown_capability_is_denied() -> None:
    from ai_harness.schemas.enums import Capability, Decision

    policy = Policy(capabilities={})
    assert policy.decide(Capability.GIT_PUSH) is Decision.DENY


def test_failure_policy_preserves_evidence_for_three_days() -> None:
    policy = Policy()
    assert Disposition.ESCALATED in policy.failure.preserve_worktree_on
    assert policy.failure.preserve_worktree_ttl_h == 72
    assert policy.approval.timeout_to_deferred_h == 24
    assert policy.approval.timeout_to_escalated_h == 72


def test_profile_maps_issues_to_branches_and_back() -> None:
    profile = RepoProfile()
    assert profile.branch_for(2419) == "agent/issue-2419"
    assert profile.issue_from_branch("agent/issue-2419") == 2419
    assert profile.issue_from_branch("feature/unrelated") is None


def test_profile_rejects_unknown_fields() -> None:
    """A typo'd profile key must fail at startup, not be silently ignored."""
    with pytest.raises(ValidationError):
        RepoProfile(defaultBranch="main")  # type: ignore[call-arg]


def test_the_state_count_is_seven() -> None:
    assert len(list(State)) == 7
