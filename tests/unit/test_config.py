"""Issue #12 — configuration is a schema: layered, validated at startup, printable."""

from __future__ import annotations

from decimal import Decimal
from pathlib import Path

import pytest

from ai_harness.config import (
    SHELL_ENV_NAMES,
    Bounds,
    ConfigError,
    HarnessConfig,
    load_config,
    load_policy,
    load_profile,
)
from ai_harness.schemas.enums import Capability, Decision, MergeStrategy, Tier

ROOT = Path(__file__).resolve().parents[2]


def test_defaults_are_the_shell_bounds() -> None:
    """The port starts by behaving identically; every §3.11 number is here, once."""
    bounds = Bounds()
    assert bounds.pipeline_max_rounds == 10
    assert bounds.pr_max_rounds == 4
    assert bounds.pr_fixer_max_self_repair == 3
    assert bounds.triage_max_open == 5
    assert bounds.gate_timeout_s == 3600


def test_a_file_layer_overrides_defaults(tmp_path: Path) -> None:
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness/config.yaml").write_text(
        "forge: gitlab\nbounds:\n  pr_max_rounds: 2\nprofile:\n  name: acme/app\n"
    )
    config = load_config(root=tmp_path)
    assert config.forge == "gitlab"
    assert config.bounds.pr_max_rounds == 2
    assert config.profile.name == "acme/app"


def test_environment_overrides_the_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness/config.yaml").write_text("log_level: info\n")
    monkeypatch.setenv("HARNESS_LOG_LEVEL", "debug")
    assert load_config(root=tmp_path).log_level == "debug"


def test_an_invalid_value_fails_at_startup_with_its_field_path(tmp_path: Path) -> None:
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness/config.yaml").write_text("tier: lanuch\n")
    with pytest.raises(ConfigError) as exc:
        load_config(root=tmp_path)
    assert "tier" in str(exc.value), "the operator must be told which field is wrong"


def test_an_unknown_key_is_rejected_not_ignored(tmp_path: Path) -> None:
    """A typo'd knob that is silently ignored is how a run does something else entirely."""
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness/config.yaml").write_text("logs_level: debug\n")
    with pytest.raises(ConfigError):
        load_config(root=tmp_path)


def test_malformed_yaml_is_reported_as_such(tmp_path: Path) -> None:
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness/config.yaml").write_text("forge: [unclosed\n")
    with pytest.raises(ConfigError):
        load_config(root=tmp_path)


def test_shell_env_renders_only_names_the_shell_actually_reads() -> None:
    """The Phase 0 beachhead: one schema, two engines, no drift on a shared bound."""
    env = HarnessConfig(tier=Tier.LAUNCH).shell_env()
    assert env["PR_MAX_ROUNDS"] == "4"
    assert env["QG_GATE_TIMEOUT"] == "3600"
    assert env["TIER"] == "launch"
    assert set(SHELL_ENV_NAMES.values()) <= set(env)


def test_shell_env_follows_an_override(tmp_path: Path) -> None:
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness/config.yaml").write_text("bounds:\n  pr_max_rounds: 7\n")
    assert load_config(root=tmp_path).shell_env()["PR_MAX_ROUNDS"] == "7"


def test_describe_prints_effective_values() -> None:
    described = HarnessConfig().describe()
    assert described["bounds"]["pr_max_rounds"] == 4
    assert described["policy"]["merge_strategy"] == "mr_only"


# ── the shipped policies ─────────────────────────────────────────────────────────


def test_standard_policy_carries_the_adopted_decisions() -> None:
    policy = load_policy("standard", root=ROOT)
    assert policy.merge_strategy is MergeStrategy.MR_ONLY
    assert policy.budget.max_usd_per_run == Decimal("25")
    assert policy.budget.max_usd_per_repo_day == Decimal("500")
    assert policy.approval.timeout_to_escalated_h == 72
    assert policy.failure.preserve_worktree_ttl_h == 72
    assert policy.decide(Capability.DEPLOY_PROD) is Decision.DENY


def test_readonly_policy_permits_nothing_mutating() -> None:
    policy = load_policy("readonly", root=ROOT)
    mutating = {
        Capability.WRITE_WORKSPACE,
        Capability.INSTALL_DEPS,
        Capability.GIT_PUSH,
        Capability.GIT_FORCE_PUSH,
        Capability.FORGE_COMMENT,
        Capability.FORGE_MERGE,
        Capability.MODIFY_CI,
        Capability.MODIFY_MIGRATIONS,
        Capability.DEPLOY_DEV,
        Capability.DEPLOY_PROD,
        Capability.BYPASS_GATE,
    }
    assert all(policy.decide(c) is Decision.DENY for c in mutating)


def test_permissive_still_denies_prod_deploy_and_gate_bypass() -> None:
    policy = load_policy("permissive", root=ROOT)
    assert policy.merge_strategy is MergeStrategy.FF_ONLY
    assert policy.decide(Capability.DEPLOY_PROD) is Decision.DENY
    assert policy.decide(Capability.BYPASS_GATE) is Decision.DENY


def test_an_unknown_policy_name_is_an_error() -> None:
    with pytest.raises(ConfigError):
        load_policy("yolo", root=ROOT)


def test_profiles_load_from_a_path(tmp_path: Path) -> None:
    path = tmp_path / "profile.yaml"
    path.write_text("name: acme/app\nworkspaces: [backend, frontend]\nbranch_prefix: bot/issue-\n")
    profile = load_profile(path)
    assert profile.branch_for(12) == "bot/issue-12"


def test_no_skillforge_specific_string_survives_in_the_package() -> None:
    """W12: the harness must be able to target an arbitrary repository."""
    offenders = []
    for path in (ROOT / "ai_harness").rglob("*.py"):
        text = path.read_text().lower()
        if "skillforge" in text or "06-iteration-log" in text:
            offenders.append(str(path))
    assert not offenders, f"host-project coupling leaked into {offenders}"
