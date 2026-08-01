"""Two spines, compared: the shadow pattern one layer down (#98)."""

from __future__ import annotations

from datetime import UTC, datetime

from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.quality.compare import compare_spines, render
from ai_harness.schemas.enums import GateSet, GateStatus, Tier
from ai_harness.schemas.gates import GateReport, GateResult
from ai_harness.schemas.spine import Difference, GateDifference, GateOutcome, SpineComparison


def _report(*results: GateResult, sha: str = "abc123") -> GateReport:
    return GateReport(
        commit_sha=sha,
        tier=Tier.LAUNCH,
        gate_set=GateSet.FULL,
        results=list(results),
    )


def _gate(
    name: str,
    status: GateStatus = GateStatus.PASS,
    *,
    required: bool = True,
    reason: str = "",
    duration: float = 10.0,
) -> GateResult:
    return GateResult(
        name=name,
        raw_status=status,
        required=required,
        reason=reason,
        duration_s=duration,
    )


def test_two_identical_scorecards_agree_on_every_gate():
    both = _report(_gate("lint"), _gate("unit"))
    comparison = compare_spines(both, both)

    assert comparison.disagreements == []
    assert comparison.clear
    assert "agree on every gate" in render(comparison)


def test_a_gate_the_declaration_does_not_run_is_the_failure_this_exists_to_catch():
    shell = _report(_gate("lint"), _gate("mutation"))
    declared = _report(_gate("lint"))

    comparison = compare_spines(shell, declared)
    missing = next(d for d in comparison.disagreements if d.gate == "mutation")

    assert missing.kind is Difference.MISSING
    assert missing.disqualifying
    # From the outside, a suite that stops running a gate looks like a suite that got faster.
    assert "looks exactly like a suite that got faster" in missing.note
    assert not comparison.clear


def test_a_declaration_that_is_green_where_the_spine_is_red_blocks():
    shell = _report(_gate("unit", GateStatus.FAIL))
    declared = _report(_gate("unit", GateStatus.PASS))

    difference = compare_spines(shell, declared).disagreements[0]
    assert difference.kind is Difference.STATUS
    assert difference.disqualifying
    assert "would have caught something and now does not" in difference.note


def test_a_declaration_that_is_stricter_is_reported_but_does_not_block():
    # Blocking on this would push people towards adopting the weaker reading, which is the
    # opposite of what the comparison is for.
    shell = _report(_gate("unit", GateStatus.PASS))
    declared = _report(_gate("unit", GateStatus.FAIL))

    difference = compare_spines(shell, declared).disagreements[0]
    assert difference.kind is Difference.STATUS
    assert not difference.disqualifying
    assert "stricter" in difference.note


def test_a_gate_demoted_to_advisory_is_a_gate_removed_slowly():
    shell = _report(_gate("coverage", required=True))
    declared = _report(_gate("coverage", required=False))

    difference = compare_spines(shell, declared).disagreements[0]
    assert difference.kind is Difference.REQUIREDNESS
    assert difference.disqualifying


def test_a_slower_gate_that_agrees_does_not_block():
    shell = _report(_gate("unit", duration=30.0))
    declared = _report(_gate("unit", duration=90.0))

    difference = compare_spines(shell, declared).disagreements[0]
    assert difference.kind is Difference.DURATION
    assert not difference.disqualifying
    # Recorded anyway: a declaration that is much slower gets turned off by somebody in a hurry.
    assert "90s" in difference.note


def test_timing_jitter_is_not_a_disagreement():
    shell = _report(_gate("unit", duration=30.0))
    declared = _report(_gate("unit", duration=33.0))
    assert compare_spines(shell, declared).disagreements == []


def test_a_gate_only_the_declaration_runs_is_reported_as_added():
    shell = _report(_gate("lint"))
    declared = _report(_gate("lint"), _gate("format"))

    difference = compare_spines(shell, declared).disagreements[0]
    assert difference.kind is Difference.ADDED
    assert not difference.disqualifying  # not a weakening, but somebody says it was intended


def test_the_criterion_is_every_disagreement_explained_not_zero():
    shell = _report(_gate("lint"), _gate("mutation"))
    declared = _report(_gate("lint"))
    comparison = compare_spines(shell, declared)
    assert not comparison.clear

    explained = SpineComparison(
        repo=comparison.repo,
        commit_sha=comparison.commit_sha,
        differences=[
            d
            if d.kind is Difference.AGREE
            else GateDifference(
                gate=d.gate,
                kind=d.kind,
                shell=d.shell,
                declared=d.declared,
                note=d.note,
                explanation="mutation moves with the product; it was never this repo's gate",
            )
            for d in comparison.differences
        ],
    )
    # A disagreement is not automatically a regression — #43's rule, and the reason the gate is
    # explanation rather than absence.
    assert explained.clear
    assert explained.disagreements
    assert explained.blocking == []


# ── durability ───────────────────────────────────────────────────────────────────


def _comparison(**kwargs: object) -> SpineComparison:
    return compare_spines(
        _report(_gate("lint"), _gate("mutation")),
        _report(_gate("lint")),
        repo="o/r",
        commit_sha="abc123",
    )


async def test_a_comparison_survives_a_restart(tmp_path):
    store = open_sqlite(tmp_path / "harness.db")
    try:
        await store.record_spine(_comparison())
    finally:
        store.dispose()

    # A new process, a new connection: evidence that resets on restart makes the criterion
    # unsatisfiable rather than merely unstarted.
    reopened = open_sqlite(tmp_path / "harness.db")
    try:
        recorded = await reopened.spine_comparisons(repo="o/r")
        assert len(recorded) == 1
        assert {d.gate for d in recorded[0].differences} == {"lint", "mutation"}
        assert recorded[0].unexplained
    finally:
        reopened.dispose()


async def test_re_comparing_the_same_commit_updates_rather_than_double_counts(tmp_path):
    store = open_sqlite(tmp_path / "harness.db")
    try:
        await store.record_spine(_comparison())
        await store.record_spine(_comparison())

        recorded = await store.spine_comparisons(repo="o/r")
        assert len(recorded) == 1
        assert len(recorded[0].differences) == 2
    finally:
        store.dispose()


async def test_an_explanation_is_per_gate_and_outlives_a_re_run(tmp_path):
    store = open_sqlite(tmp_path / "harness.db")
    try:
        await store.record_spine(_comparison())
        touched = await store.explain_spine("o/r", "mutation", "moves with the product")
        assert touched == 1

        # A re-run carries no explanation; the human's writing must outlive the machine's.
        await store.record_spine(_comparison())
        recorded = await store.spine_comparisons(repo="o/r")
        assert recorded[0].clear
        assert recorded[0].unexplained == []
    finally:
        store.dispose()


def test_the_report_says_which_are_blocking_and_which_are_merely_noted():
    comparison = SpineComparison(
        repo="o/r",
        commit_sha="abc123def456",
        observed_at=datetime.now(UTC),
        differences=[
            GateDifference(
                gate="mutation",
                kind=Difference.MISSING,
                shell=GateOutcome(name="mutation", status=GateStatus.PASS, required=True),
                note="lost",
            ),
            GateDifference(
                gate="unit",
                kind=Difference.DURATION,
                shell=GateOutcome(name="unit", status=GateStatus.PASS),
                declared=GateOutcome(name="unit", status=GateStatus.PASS),
                note="slower",
            ),
        ],
    )
    rendered = render(comparison)

    assert "BLOCK missing" in rendered
    assert "note  duration" in rendered
    assert "2 disagreement(s), 2 unexplained, 1 blocking" in rendered
