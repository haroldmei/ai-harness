"""Issues #13 and #14 — the discovery ladder and the shell adapter, against real trees."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.quality.adapters.shell import ShellGateAdapter
from ai_harness.quality.discovery import describe, discover
from ai_harness.schemas.enums import DiscoveryRung, GateSet, GateStatus, Tier

REPO_ROOT = Path(__file__).resolve().parents[2]


# ── the ladder ───────────────────────────────────────────────────────────────────


def test_rung_1_explicit_config_is_authoritative(tmp_path: Path) -> None:
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness/gates.yaml").write_text(
        "tier: preview\ngates:\n  - name: unit\n    command: [pytest]\n"
    )
    (tmp_path / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    found = discover(tmp_path)
    assert found.rung is DiscoveryRung.HARNESS_CONFIG
    assert not found.profile.discovered, "explicit config is a contract, not an inference"


def test_rung_2_finds_the_shell_spine_and_reads_its_registry(tmp_path: Path) -> None:
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "quality-gates.sh").write_text(
        "#!/usr/bin/env bash\nGATES=(typecheck lint unit integration)\n"
    )
    found = discover(tmp_path)
    assert found.rung is DiscoveryRung.ENTRY_POINT
    assert found.profile.entry_point == ["bash", "scripts/quality-gates.sh"]
    assert [g.name for g in found.profile.gates] == ["typecheck", "lint", "unit", "integration"]


def test_rung_2_detects_make_check_only_when_the_target_exists(tmp_path: Path) -> None:
    (tmp_path / "Makefile").write_text("build:\n\techo no check target here\n")
    assert discover(tmp_path).rung is not DiscoveryRung.ENTRY_POINT
    (tmp_path / "Makefile").write_text("check:\n\tpytest\n")
    assert discover(tmp_path).rung is DiscoveryRung.ENTRY_POINT


def test_rung_3_parses_ci_configuration_and_marks_it_inferred(tmp_path: Path) -> None:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "ci.yml").write_text(
        "jobs:\n  test:\n    steps:\n      - name: unit\n        run: pytest -q\n"
    )
    found = discover(tmp_path)
    assert found.rung is DiscoveryRung.CI_CONFIG
    assert found.profile.discovered, "an inference must be visibly an inference"
    assert found.profile.gates


def test_rung_4_infers_from_manifests(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text(
        "[tool.pytest.ini_options]\n[tool.ruff]\n[tool.mypy]\n"
    )
    found = discover(tmp_path)
    assert found.rung is DiscoveryRung.MANIFEST
    assert {g.name for g in found.profile.gates} == {"unit", "lint", "typecheck"}


def test_rung_5_escalates_rather_than_merging_ungated(tmp_path: Path) -> None:
    found = discover(tmp_path)
    assert found.rung is DiscoveryRung.NONE
    assert found.escalates and found.profile.no_gates_discovered
    described = describe(found)
    assert described["escalates"] is True
    assert len(described["considered"]) == 4, "each higher rung must say why it did not match"


def test_discovery_is_a_pure_function_of_the_tree(tmp_path: Path) -> None:
    (tmp_path / "go.mod").write_text("module example.com/x\n")
    assert describe(discover(tmp_path)) == describe(discover(tmp_path))


def test_this_repository_discovers_its_own_shell_spine() -> None:
    found = discover(REPO_ROOT)
    assert found.rung is DiscoveryRung.ENTRY_POINT
    assert "typecheck" in [g.name for g in found.profile.gates]
    assert "unit" in [g.name for g in found.profile.gates]


# ── the adapter ──────────────────────────────────────────────────────────────────


def _spine(tmp_path: Path, body: str) -> Path:
    scripts = tmp_path / "scripts"
    scripts.mkdir(exist_ok=True)
    path = scripts / "quality-gates.sh"
    path.write_text(body)
    path.chmod(0o755)
    return path


SCORECARD_SPINE = """#!/usr/bin/env bash
# A stand-in for quality-gates.sh: parses the same flags, writes the same scorecard shape.
json=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json="$2"; shift 2;;
    --tier|--only|--skip) shift 2;;
    *) shift;;
  esac
done
cat > "$json" <<'EOF'
[{"gate":"typecheck","status":"pass","reason":"","duration_s":31},
 {"gate":"unit","status":"fail","reason":"E   AssertionError","duration_s":214},
 {"gate":"integration","status":"skip","reason":"docker unavailable","duration_s":null}]
EOF
echo "RESULT: 1 gate(s) FAILED"
exit 1
"""


async def test_the_adapter_consumes_the_scorecard_shape_unchanged(tmp_path: Path) -> None:
    _spine(tmp_path, SCORECARD_SPINE)
    found = discover(tmp_path, tier=Tier.LAUNCH)
    adapter = ShellGateAdapter(root=tmp_path, profile=found.profile)
    result = await adapter.run(only=["typecheck", "unit", "integration"])
    assert result.is_ok
    report = result.unwrap()
    assert report.by_name("typecheck").status is GateStatus.PASS  # type: ignore[union-attr]
    assert report.by_name("unit").status is GateStatus.FAIL  # type: ignore[union-attr]
    assert report.gate_time_s == 245


async def test_a_required_skip_from_the_scorecard_is_promoted_to_a_failure(tmp_path: Path) -> None:
    """Invariant 11, applied at the adapter boundary rather than trusted from the shell."""
    _spine(tmp_path, SCORECARD_SPINE)
    found = discover(tmp_path, tier=Tier.LAUNCH)
    adapter = ShellGateAdapter(root=tmp_path, profile=found.profile)
    report = (await adapter.run(only=["typecheck", "unit", "integration"])).unwrap()
    integration = report.by_name("integration")
    assert integration is not None
    assert integration.status is GateStatus.FAIL and integration.promoted


async def test_gates_the_only_list_excluded_are_honest_skips(tmp_path: Path) -> None:
    """Regression: scoping to --only must not fail every required gate you did not ask for.

    Observed running the real spine against this repository: the scorecard reports the whole
    registry with the unselected gates marked skipped, and deriving selection from the
    requested list alone promoted each of them to a failure. The deployed lanes legitimately
    run `--only unit`; that is a scope, not a dodge.
    """
    _spine(tmp_path, SCORECARD_SPINE)
    found = discover(tmp_path, tier=Tier.LAUNCH)
    adapter = ShellGateAdapter(root=tmp_path, profile=found.profile)
    report = (await adapter.run(only=["typecheck"])).unwrap()
    unit = report.by_name("unit")
    integration = report.by_name("integration")
    assert unit is not None and integration is not None
    assert integration.status is GateStatus.SKIP and not integration.promoted
    assert unit.status is GateStatus.FAIL, "a gate that RAN and failed still fails"


async def test_a_gate_absent_from_the_scorecard_did_not_silently_pass(tmp_path: Path) -> None:
    _spine(tmp_path, SCORECARD_SPINE)
    found = discover(tmp_path, tier=Tier.LAUNCH)
    adapter = ShellGateAdapter(root=tmp_path, profile=found.profile)
    report = (await adapter.run(only=["typecheck", "unit", "integration", "contract"])).unwrap()
    contract = report.by_name("contract")
    assert contract is not None
    assert contract.status is GateStatus.FAIL and "absent from the scorecard" in contract.reason


async def test_no_scorecard_is_an_environment_failure_not_a_red_gate(tmp_path: Path) -> None:
    """Blaming the code when the runner died is how a merge queue accuses an innocent base."""
    _spine(tmp_path, "#!/usr/bin/env bash\necho 'no space left on device' >&2\nexit 2\n")
    found = discover(tmp_path)
    adapter = ShellGateAdapter(root=tmp_path, profile=found.profile)
    result = await adapter.run(only=["unit"])
    assert result.is_err and result.category is ErrorCategory.ENVIRONMENT


async def test_a_wedged_suite_is_killed_with_its_whole_process_group(tmp_path: Path) -> None:
    _spine(
        tmp_path,
        "#!/usr/bin/env bash\nsleep 300 &\nsleep 300\n",
    )
    found = discover(tmp_path)
    adapter = ShellGateAdapter(root=tmp_path, profile=found.profile, timeout_s=1.0)
    result = await adapter.run(only=["unit"])
    assert result.is_err and result.category is ErrorCategory.ENVIRONMENT
    assert result.error is not None and "killed" in result.error.message


async def test_the_adapter_refuses_when_nothing_was_discovered(tmp_path: Path) -> None:
    found = discover(tmp_path)
    adapter = ShellGateAdapter(root=tmp_path, profile=found.profile)
    result = await adapter.run()
    assert result.is_err and result.category is ErrorCategory.ENVIRONMENT


@pytest.mark.parametrize("gate_set", [GateSet.FAST, GateSet.FULL])
async def test_both_gate_sets_produce_a_schema_valid_report(
    tmp_path: Path, gate_set: GateSet
) -> None:
    _spine(tmp_path, SCORECARD_SPINE)
    found = discover(tmp_path, tier=Tier.PREVIEW)
    adapter = ShellGateAdapter(root=tmp_path, profile=found.profile)
    report = (await adapter.run(gate_set=gate_set)).unwrap()
    assert json.loads(report.model_dump_json())["tier"] == "preview"


def test_the_bare_origin_fixture_is_a_real_repository(bare_origin: Path) -> None:
    """Issue #20: the suites run against real git in tmp, never a mocked git."""
    import subprocess

    head = subprocess.run(
        ["git", "-C", str(bare_origin), "rev-parse", "main"],
        capture_output=True,
        text=True,
        check=True,
    )
    assert len(head.stdout.strip()) == 40
