"""This repository's own gate declaration, and the drift that would make it a lie (#96).

A declaration that has wandered away from the pipeline it claims to mirror is worse than no
declaration, because it reads as a promise. So the two are compared here rather than by eye:
every gate command in `.harness/gates.yaml` must be a command CI runs, and every check CI runs
must be a declared gate.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

from ai_harness.quality.discovery import discover
from ai_harness.quality.runner import GateRunner
from ai_harness.schemas.enums import DiscoveryRung, GateSet, Tier

REPO_ROOT = Path(__file__).resolve().parents[2]
GATES_YAML = REPO_ROOT / ".harness/gates.yaml"
CI_YAML = REPO_ROOT / ".github/workflows/ci.yml"

SETUP_STEPS = re.compile(r"^(uv |pip |python -m pip)")
"""Environment construction, not a gate. `uv venv` failing is a broken runner, not red code."""


def _ci_commands() -> list[str]:
    workflow = yaml.safe_load(CI_YAML.read_text())
    steps = workflow["jobs"]["check"]["steps"]
    return [
        " ".join(str(step["run"]).split())
        for step in steps
        if "run" in step and not SETUP_STEPS.match(str(step["run"]).strip())
    ]


def _declared_commands() -> list[str]:
    profile = yaml.safe_load(GATES_YAML.read_text())
    return [" ".join(gate["command"]) for gate in profile["gates"]]


def test_the_declaration_and_ci_run_the_same_commands():
    declared = _declared_commands()
    ci = _ci_commands()

    # Both directions. A gate CI does not run is a promise nobody keeps; a CI check nobody
    # declared is a gate the harness cannot see when it decides whether a change may merge.
    assert sorted(declared) == sorted(ci), (
        "`.harness/gates.yaml` and .github/workflows/ci.yml have drifted.\n"
        f"  declared only: {sorted(set(declared) - set(ci))}\n"
        f"  CI only      : {sorted(set(ci) - set(declared))}"
    )


def test_the_commands_name_the_interpreter_that_gates_the_merge():
    # A bare `ruff` is whichever ruff is on PATH, which is how a gate silently starts checking
    # with a different version than the one that gates the merge.
    for command in _declared_commands():
        assert command.startswith(".venv/bin/"), command


def test_every_declared_gate_is_required_at_every_tier():
    """There is no scale at which merging the harness with red types is acceptable."""
    profile = discover(REPO_ROOT).profile
    for tier in (Tier.TOY, Tier.PREVIEW, Tier.LAUNCH, Tier.SCALE):
        required = profile.model_copy(update={"tier": tier}).required_names()
        assert required == {"lint", "format", "typecheck", "contracts", "unit"}


def test_the_fast_set_is_a_subset_that_actually_exists():
    profile = discover(REPO_ROOT).profile
    names = {gate.name for gate in profile.gates}
    assert set(profile.fast_set) <= names
    assert "unit" not in profile.fast_set  # the one a human waits on


def test_a_declared_profile_reaches_the_native_runner_not_the_shell_adapter():
    """The gap #96 exposed: rung 1 had no runner reachable from the CLI.

    `ShellGateAdapter` calls a *discovered* spine and consumes its scorecard. A declared profile
    has no spine to call, so before this it produced `no gate entry point was discovered` — the
    harness could not run the gates it had just been told about, including its own.
    """
    found = discover(REPO_ROOT)
    assert found.rung is DiscoveryRung.HARNESS_CONFIG
    assert found.profile.entry_point is None

    runner = GateRunner(root=REPO_ROOT, profile=found.profile)
    assert runner.profile.names_for(GateSet.FULL) == [
        "lint",
        "format",
        "typecheck",
        "contracts",
        "unit",
    ]


async def test_the_runner_honours_a_declared_gates_requiredness(tmp_path):
    """A gate the tier table has never heard of is still required if the profile says so.

    `required_names(tier)` is the shell spine's vocabulary — `docs-refs`, `iteration-immutable`,
    `mobile-e2e`. A rung-1 profile whose gate names are its own (`contracts`, `format`) would
    have had every one of them read as optional, which is invariant 11 failing silently in the
    direction that looks green.
    """
    from ai_harness.schemas.gates import GateProfile, GateSpec

    profile = GateProfile(
        tier=Tier.LAUNCH,
        gates=[
            GateSpec(
                name="contracts",
                command=["python", "-c", "raise SystemExit(1)"],
                required_from_tier=Tier.TOY,
            )
        ],
    )
    report = (await GateRunner(root=tmp_path, profile=profile).run()).unwrap()

    result = next(r for r in report.results if r.name == "contracts")
    assert result.required is True
    assert not report.green
