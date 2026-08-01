"""Reading a shell spine as a declaration, and refusing to invent the parts it cannot read (#97)."""

from __future__ import annotations

from pathlib import Path

import yaml

from ai_harness.quality.adopt import (
    TIMEOUT_HEADROOM,
    adopt,
    lowest_required_tier,
    read_registry,
    read_required_by_tier,
    read_stack_gates,
)
from ai_harness.schemas.enums import Tier
from ai_harness.schemas.gates import GateProfile

REPO_ROOT = Path(__file__).resolve().parents[2]
LEGACY_SPINE = REPO_ROOT / "scripts/quality-gates.sh"

SPINE = """\
#!/usr/bin/env bash
GATES=(typecheck lint unit integration exotic)

declare -A REQUIRED_BY_TIER=(
  [toy]="typecheck"
  [preview]="typecheck lint unit"
  [launch]="typecheck lint unit integration"
)

STACK_GATES=(integration)

gate_typecheck() { :; }
"""


def _spine(tmp_path: Path, *, body: str = SPINE, hooks: tuple[str, ...] = ()) -> Path:
    scripts = tmp_path / "scripts"
    scripts.mkdir(exist_ok=True)
    path = scripts / "quality-gates.sh"
    path.write_text(body)
    for hook in hooks:
        (scripts / f"{hook}.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
    return path


# ── reading the spine, not a transcription of one ────────────────────────────────


def test_the_registry_the_tier_table_and_the_stack_set_are_read_from_the_spine():
    assert read_registry(SPINE) == ["typecheck", "lint", "unit", "integration", "exotic"]

    table = read_required_by_tier(SPINE)
    assert table[Tier.TOY] == {"typecheck"}
    assert table[Tier.LAUNCH] == {"typecheck", "lint", "unit", "integration"}
    assert Tier.SCALE not in table  # this spine does not define one, and none is invented

    assert read_stack_gates(SPINE) == {"integration"}


def test_required_from_tier_is_the_lowest_tier_that_demands_the_gate():
    table = read_required_by_tier(SPINE)
    assert lowest_required_tier("typecheck", table) is Tier.TOY
    assert lowest_required_tier("lint", table) is Tier.PREVIEW
    assert lowest_required_tier("integration", table) is Tier.LAUNCH
    # Never required at any tier is not the same as required at the highest one.
    assert lowest_required_tier("exotic", table) is None


def test_this_repositorys_own_tier_table_is_read_rather_than_assumed():
    """`registry.REQUIRED_BY_TIER` is a transcription of one spine. Adoption reads the original."""
    table = read_required_by_tier(LEGACY_SPINE.read_text())
    assert table[Tier.TOY] == {"typecheck", "lint"}
    assert "mobile-e2e" in table[Tier.LAUNCH]


# ── what adoption produces ───────────────────────────────────────────────────────


def test_a_gate_with_a_hook_is_adopted_and_one_without_is_reported(tmp_path):
    spine = _spine(tmp_path, hooks=("typecheck", "lint", "integration"))
    adoption = adopt(spine, root=tmp_path)

    assert [g.name for g in adoption.gates] == ["typecheck", "lint", "integration"]
    assert [u.name for u in adoption.unexpressible] == ["unit", "exotic"]
    assert not adoption.complete
    # The reason is the useful part: it says what the next decision is, not just that one exists.
    assert "no single command to declare" in adoption.unexpressible[0].why


def test_every_gate_in_the_registry_is_accounted_for(tmp_path):
    spine = _spine(tmp_path, hooks=("typecheck",))
    adoption = adopt(spine, root=tmp_path)

    accounted = {g.name for g in adoption.gates} | {u.name for u in adoption.unexpressible}
    assert accounted == set(read_registry(SPINE))


def test_adopting_this_repositorys_legacy_spine_accounts_for_all_22_gates():
    adoption = adopt(LEGACY_SPINE, root=REPO_ROOT)

    accounted = {g.name for g in adoption.gates} | {u.name for u in adoption.unexpressible}
    assert accounted == set(read_registry(LEGACY_SPINE.read_text()))
    assert len(accounted) == 22
    # Some are expressible because the product already factored them into their own scripts;
    # the rest are bash inside the spine, and saying so is the finding.
    assert adoption.gates and adoption.unexpressible
    assert not adoption.inferred_requiredness  # this spine declares its own table


def test_a_stack_gate_keeps_its_resource_class(tmp_path):
    spine = _spine(tmp_path, hooks=("integration", "typecheck"))
    adoption = adopt(spine, root=tmp_path)

    resources = {g.name: g.resource for g in adoption.gates}
    assert resources["integration"] == "stack"  # boots containers, binds ports
    assert resources["typecheck"] == "cpu"


def test_a_spine_without_a_tier_table_says_its_requiredness_was_inferred(tmp_path):
    spine = _spine(tmp_path, body="GATES=(typecheck lint)\n", hooks=("typecheck", "lint"))
    adoption = adopt(spine, root=tmp_path)

    assert adoption.inferred_requiredness is True
    rendered = adoption.as_yaml()
    # Rung 3 labels an inferred gate set as inferred for exactly this reason: a guess that reads
    # as a contract is worse than a guess that says it is one.
    assert "INFERRED" in rendered
    assert "Check every" in rendered


def test_timeouts_come_from_the_scorecard_when_there_is_one(tmp_path):
    spine = _spine(tmp_path, hooks=("typecheck",))
    scorecard = tmp_path / "gates.json"
    scorecard.write_text('[{"gate": "typecheck", "status": "PASS", "duration_s": 30}]')

    adoption = adopt(spine, scorecard=scorecard, root=tmp_path)
    assert adoption.gates[0].timeout_s == 30 * TIMEOUT_HEADROOM

    # A timeout set at the observed duration fires on the first slow day, and the failure looks
    # like a broken gate rather than a busy machine.
    assert adoption.gates[0].timeout_s > 30


def test_a_missing_or_malformed_scorecard_only_costs_the_tuning(tmp_path):
    spine = _spine(tmp_path, hooks=("typecheck",))
    broken = tmp_path / "nope.json"
    broken.write_text("{not json")

    adoption = adopt(spine, scorecard=broken, root=tmp_path)
    assert adoption.gates[0].timeout_s == 3600  # the default, and no exception


def test_a_spine_with_no_registry_enumerates_nothing_and_says_why(tmp_path):
    spine = _spine(tmp_path, body="#!/usr/bin/env bash\necho hello\n")
    adoption = adopt(spine, root=tmp_path)

    assert adoption.gates == []
    assert any("no GATES=()" in note for note in adoption.notes)


# ── the output is a proposal that actually loads ─────────────────────────────────


def test_the_emitted_declaration_loads_through_rung_1_without_hand_editing(tmp_path):
    spine = _spine(tmp_path, hooks=("typecheck", "lint", "integration"))
    rendered = adopt(spine, root=tmp_path).as_yaml(tier=Tier.LAUNCH)

    profile = GateProfile(**yaml.safe_load(rendered))
    assert [g.name for g in profile.gates] == ["typecheck", "lint", "integration"]
    assert profile.tier is Tier.LAUNCH
    assert profile.required_names() == {"typecheck", "lint", "integration"}


def test_adoption_is_idempotent(tmp_path):
    spine = _spine(tmp_path, hooks=("typecheck", "lint"))
    first = adopt(spine, root=tmp_path).as_yaml()
    second = adopt(spine, root=tmp_path).as_yaml()
    assert first == second


def test_the_proposal_says_it_is_a_proposal(tmp_path):
    spine = _spine(tmp_path, hooks=("typecheck",))
    rendered = adopt(spine, root=tmp_path).as_yaml()
    # Q9: propose gates; never write the contract autonomously. The file says so to whoever
    # opens it, not just the issue that asked for it.
    assert "NOT authoritative until a human" in rendered


def test_the_command_writes_nothing_without_out(tmp_path, capsys):
    from typer.testing import CliRunner

    from ai_harness.cli.main import app

    _spine(tmp_path, hooks=("typecheck",))
    result = CliRunner().invoke(app, ["gates", "adopt", str(tmp_path)])

    assert result.exit_code == 0
    assert "tier: launch" in result.stdout
    assert not (tmp_path / ".harness/gates.yaml").exists()

    written = CliRunner().invoke(
        app, ["gates", "adopt", str(tmp_path), "--out", str(tmp_path / ".harness/gates.yaml")]
    )
    assert written.exit_code == 0
    assert (tmp_path / ".harness/gates.yaml").exists()
