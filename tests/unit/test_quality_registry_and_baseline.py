"""Issues #15 and #17 — tiers, selection semantics, and inherited-red forgiveness."""

from __future__ import annotations

from pathlib import Path

import pytest

from ai_harness.quality.baseline import BaselineStatus, BaselineStore
from ai_harness.quality.registry import (
    REQUIRED_BY_TIER,
    UnknownTierError,
    build_profile,
    parse_tier,
    required_names,
    select,
    unregistered_result,
)
from ai_harness.schemas.enums import GateSelection, GateStatus, Tier

LOGS = Path(__file__).resolve().parents[1] / "fixtures" / "gate_logs"


# ── tiers ────────────────────────────────────────────────────────────────────────


def test_a_typo_in_the_tier_aborts_rather_than_weakening_the_run() -> None:
    """`--tier lanuch` once dropped six required gates and printed "all gates pass"."""
    with pytest.raises(UnknownTierError) as exc:
        parse_tier("lanuch")
    assert "known" in str(exc.value), "the message must list the tiers that exist"


def test_required_sets_grow_monotonically_with_the_tier() -> None:
    for lower, higher in (
        (Tier.TOY, Tier.PREVIEW),
        (Tier.PREVIEW, Tier.LAUNCH),
        (Tier.LAUNCH, Tier.SCALE),
    ):
        assert set(REQUIRED_BY_TIER[lower]) <= set(REQUIRED_BY_TIER[higher])


def test_the_launch_set_matches_the_shell_registry() -> None:
    assert set(REQUIRED_BY_TIER[Tier.LAUNCH]) == {
        "typecheck",
        "lint",
        "docs-refs",
        "iteration-immutable",
        "migration-drift",
        "unit",
        "coverage",
        "integration",
        "contract",
        "visual",
        "mobile-e2e",
    }


def test_an_explicit_required_override_wins() -> None:
    assert required_names(Tier.LAUNCH, ["unit"]) == {"unit"}


# ── selection ────────────────────────────────────────────────────────────────────


def test_absent_from_only_is_an_honest_skip_but_deny_listed_is_not() -> None:
    selection = select(["unit", "integration", "e2e"], only=["unit"], skip=["integration"])
    assert selection["unit"] is GateSelection.RAN
    assert selection["e2e"] is GateSelection.NOT_SELECTED
    assert selection["integration"] is GateSelection.DENY_LISTED


def test_a_named_gate_with_no_implementation_fails_loudly() -> None:
    result = unregistered_result("brand-new-gate")
    assert result.status is GateStatus.FAIL and "no implementation" in result.reason


def test_stack_gates_get_their_own_resource_class() -> None:
    profile = build_profile(["unit", "integration"], tier=Tier.LAUNCH)
    by_name = {g.name: g for g in profile.gates}
    assert by_name["unit"].resource == "cpu"
    assert by_name["integration"].resource == "stack"
    assert by_name["integration"].required_at(Tier.LAUNCH)


# ── baselines ────────────────────────────────────────────────────────────────────


def test_no_baseline_for_this_sha_means_every_failure_is_new(tmp_path: Path) -> None:
    """Fail closed: a baseline can only forgive what it demonstrably saw on that base."""
    store = BaselineStore(tmp_path)
    verdict = store.evaluate("unit", "deadbeef", (LOGS / "pytest_failure.log").read_text())
    assert verdict.status is BaselineStatus.NO_BASELINE
    assert not verdict.may_forgive and verdict.new_failures


def test_a_failure_already_red_on_the_exact_base_is_forgiven(tmp_path: Path) -> None:
    store = BaselineStore(tmp_path)
    log = (LOGS / "pytest_failure.log").read_text()
    store.record("unit", "abc123", log)
    verdict = store.evaluate("unit", "abc123", log)
    assert verdict.status is BaselineStatus.FORGIVEN and verdict.may_forgive
    assert verdict.forgiven


def test_a_new_failure_alongside_an_inherited_one_keeps_the_gate_red(tmp_path: Path) -> None:
    store = BaselineStore(tmp_path)
    store.record("unit", "abc123", "FAILED backend/tests/test_a.py::test_one - boom\n")
    verdict = store.evaluate(
        "unit",
        "abc123",
        "FAILED backend/tests/test_a.py::test_one - boom\n"
        "FAILED backend/tests/test_b.py::test_two - new\n",
    )
    assert verdict.status is BaselineStatus.NEW_FAILURES
    assert verdict.new_failures == ["backend/tests/test_b.py::test_two"]
    assert verdict.forgiven == ["backend/tests/test_a.py::test_one"]


def test_a_baseline_for_a_different_sha_is_not_consulted(tmp_path: Path) -> None:
    store = BaselineStore(tmp_path)
    log = "FAILED backend/tests/test_a.py::test_one - boom\n"
    store.record("unit", "abc123", log)
    assert store.evaluate("unit", "zzz999", log).status is BaselineStatus.NO_BASELINE


def test_a_failure_with_no_extractable_test_id_is_not_forgivable(tmp_path: Path) -> None:
    """You cannot forgive what you cannot name — an import error, a crash, a timeout."""
    store = BaselineStore(tmp_path)
    store.record("unit", "abc123", "FAILED backend/tests/test_a.py::test_one - boom\n")
    verdict = store.evaluate("unit", "abc123", "collection failed: cannot import app.widgets\n")
    assert verdict.status is BaselineStatus.NOT_FORGIVABLE and not verdict.may_forgive


def test_an_unreadable_baseline_is_not_an_empty_baseline(tmp_path: Path) -> None:
    store = BaselineStore(tmp_path)
    store.record("unit", "abc123", "FAILED a.py::t - x\n")
    (tmp_path / "abc123" / "unit.json").write_text("{ truncated")
    verdict = store.evaluate("unit", "abc123", "FAILED a.py::t - x\n")
    assert verdict.status is BaselineStatus.NO_BASELINE


def test_recording_is_separate_from_consulting(tmp_path: Path) -> None:
    """A run *on* the base records; only a branch consults. A red base cannot forgive itself."""
    store = BaselineStore(tmp_path)
    recorded = store.record("unit", "abc123", "FAILED a.py::t - x\n")
    assert recorded == ["a.py::t"]
    assert store.load("unit", "abc123") == ["a.py::t"]
    assert store.load("unit", "other") is None
