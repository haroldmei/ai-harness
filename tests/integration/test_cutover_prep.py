"""#76 and #79 — the code halves, so only the empirical halves remain.

Neither issue can be closed here: each has criteria that need a real repository, a real host and
a week of elapsed time. What *was* missing is the tooling, and in #76's case the absence was
worse than "unstarted" — comparisons lived in a list, so a week of observation could not survive
a restart and the primary criterion was unsatisfiable rather than merely unmet.

These tests assert the tooling exists and behaves, and nothing here claims either issue is done.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from typer.testing import CliRunner

from ai_harness.cli.commands.install import CREATED, UNCHANGED, Plan, write_if_different
from ai_harness.cli.main import app
from ai_harness.deploy.units import LABELS, render, unit_name
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.orchestration.shadow import (
    OBSERVATION_WINDOW_DAYS,
    ShadowComparator,
    compare,
    load_comparator,
)
from ai_harness.orchestration.shadow_runner import ShadowRunner
from ai_harness.persistence.sql import SqlStore
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.providers.forge.fake import FakeForge
from ai_harness.providers.forge.protocol import Issue, MergeRequest
from ai_harness.schemas.enums import Signal, Verdict
from ai_harness.schemas.shadow import Agreement, Comparison, Decision
from ai_harness.subgraphs.base import SubgraphResult

runner = CliRunner()

# ── #76: a comparison must survive the process that made it ──────────────────────


def _store(tmp_path: Path, clock: FrozenClock) -> SqlStore:
    return open_sqlite(tmp_path / "harness.db", clock=clock)


def _decision(engine: str, verdict: Verdict | None, **kw: Any) -> Decision:
    base: dict[str, Any] = {"engine": engine, "verdict": verdict}
    base.update(kw)
    return Decision(**base)


def _comparison(**kw: Any) -> Comparison:
    base: dict[str, Any] = {
        "run_id": "run-1",
        "repo": "acme/app",
        "head_sha": "abc123def456",
        "round": 1,
        "shell": _decision("shell", Verdict.APPROVE, usd=Decimal("0.40")),
        "python": _decision("python", Verdict.APPROVE, usd=Decimal("0.12")),
        "agreement": Agreement.AGREE,
    }
    base.update(kw)
    return Comparison(**base)


async def test_an_observation_outlives_the_process_that_made_it(tmp_path: Path) -> None:
    """The gap that made the week unsatisfiable rather than unstarted.

    Observations lived in a list on a comparator. A restart, a deploy or a crash reset the
    evidence to zero — and the report would still print an agreement rate, computed over
    whatever happened to survive.
    """
    clock = FrozenClock()
    store = _store(tmp_path, clock)
    try:
        await store.observe(_comparison(), repo="acme/app")
    finally:
        store.dispose()

    reopened = _store(tmp_path, clock)
    try:
        comparator = await load_comparator(reopened, repo="acme/app")
        assert len(comparator.observations) == 1
        assert comparator.observations[0].shell.verdict is Verdict.APPROVE
    finally:
        reopened.dispose()


async def test_re_observing_the_same_review_does_not_double_count(tmp_path: Path) -> None:
    """A retry or an overlapping nightly job must not inflate the rate the cutover gates on."""
    clock = FrozenClock()
    store = _store(tmp_path, clock)
    try:
        await store.observe(_comparison(), repo="acme/app")
        await store.observe(_comparison(), repo="acme/app")
        assert len(await store.comparisons(repo="acme/app")) == 1
    finally:
        store.dispose()


async def test_a_human_explanation_is_not_erased_by_a_re_run(tmp_path: Path) -> None:
    """The automatic re-observation has nothing better to say than the person who wrote it."""
    clock = FrozenClock()
    store = _store(tmp_path, clock)
    try:
        await store.observe(_comparison(agreement=Agreement.DISAGREE_VERDICT), repo="acme/app")
        assert await store.explain("run-1", "abc123def456", 1, "the Python path was right")
        await store.observe(_comparison(agreement=Agreement.DISAGREE_VERDICT), repo="acme/app")
        stored = (await store.comparisons(repo="acme/app"))[0]
        assert stored.explanation == "the Python path was right"
        assert stored.explained
    finally:
        store.dispose()


async def test_the_cutover_gate_reports_why_it_is_blocked(tmp_path: Path) -> None:
    """A boolean tells an operator nothing they can act on."""
    clock = FrozenClock()
    store = _store(tmp_path, clock)
    try:
        await store.observe(_comparison(), repo="acme/app")
        await store.observe(
            _comparison(run_id="run-2", agreement=Agreement.DISAGREE_VERDICT), repo="acme/app"
        )
        comparator = await load_comparator(store, repo="acme/app")
        report = comparator.report()

        assert report["may_cut_over"] is False
        blockers = report["blocked_by"]
        assert isinstance(blockers, list)
        assert any("days" in reason for reason in blockers), "the week has not elapsed"
        assert any("unexplained" in reason for reason in blockers)
    finally:
        store.dispose()


async def test_a_week_of_agreement_is_required_not_just_a_high_rate(tmp_path: Path) -> None:
    """100% agreement over four reviews in one afternoon is not the evidence §24 asks for."""
    clock = FrozenClock()
    store = _store(tmp_path, clock)
    try:
        for index in range(4):
            clock.advance(3600)
            await store.observe(_comparison(run_id=f"run-{index}"), repo="acme/app")
        comparator = await load_comparator(store, repo="acme/app")
        assert comparator.agreement_rate == 1.0
        assert not comparator.long_enough
        assert not comparator.may_cut_over()

        clock.advance(int(timedelta(days=OBSERVATION_WINDOW_DAYS).total_seconds()))
        await store.observe(_comparison(run_id="run-last"), repo="acme/app")
        assert (await load_comparator(store, repo="acme/app")).may_cut_over()
    finally:
        store.dispose()


def test_both_paths_are_priced_on_the_same_reviews() -> None:
    """§24.1's "cost increases" row. A month of shell against a week of Python proves nothing."""
    comparator = ShadowComparator(
        observations=[
            _comparison(
                shell=_decision("shell", Verdict.APPROVE, usd=Decimal("0.40")),
                python=_decision("python", Verdict.APPROVE, usd=Decimal("0.10")),
            ),
            _comparison(
                run_id="run-2",
                shell=_decision("shell", Verdict.APPROVE, usd=Decimal("0.60")),
                python=_decision("python", Verdict.APPROVE, usd=Decimal("0.30")),
            ),
        ]
    )
    cost = comparator.cost_per_review()
    assert cost["shell"] == 0.5 and cost["python"] == 0.2
    assert cost["ratio"] == 0.4, "the Python path is 40% of the shell path's cost per review"


# ── #76: the runner that makes an observation possible at all ────────────────────


@dataclass
class StubReviewer:
    """The Python REVIEW path, scripted."""

    verdict: Verdict = Verdict.APPROVE
    blocking: int = 0
    downgraded: bool = False
    fails: str = ""
    seen: list[str] = field(default_factory=list)

    async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
        self.seen.append(ctx.diff_text)
        if self.fails:
            return Outcome.fail(ErrorCategory.MODEL_FAILURE, self.fails)
        return Outcome.ok(
            SubgraphResult(
                signal=Signal.ADVANCE,
                payload={
                    "review": {
                        "verdict": self.verdict.value,
                        "blocking_findings": ["x"] * self.blocking,
                        "downgraded": self.downgraded,
                    }
                },
                usd=Decimal("0.11"),
            )
        )


def _forge(body: str, *, blocked: bool = True) -> FakeForge:
    forge = FakeForge(writes_blocked=blocked)
    forge.issues[7] = Issue(number=7, title="a change", body=body, state="open")
    forge.mrs[7] = MergeRequest(
        id="7", number=7, head_ref="pr/7", base_ref="main", title="a change", head_sha="deadbeef"
    )
    return forge


def _runner(tmp_path: Path, forge: FakeForge, reviewer: StubReviewer) -> ShadowRunner:
    clock = FrozenClock()
    return ShadowRunner(
        reviewer=reviewer,
        forge=forge,
        store=_store(tmp_path, clock),
        repo="acme/app",
        clock=clock,
    )


async def test_the_runner_refuses_a_forge_that_can_write(tmp_path: Path) -> None:
    """Shadow mode that could post is not shadow mode."""
    runner_ = _runner(tmp_path, _forge("Approved", blocked=False), StubReviewer())
    try:
        outcome = await runner_.observe(7)
        assert outcome.category is ErrorCategory.POLICY
        assert "can write" in (outcome.error.message if outcome.error else "")
    finally:
        runner_.store.dispose()


async def test_an_observation_records_both_decisions(tmp_path: Path) -> None:
    reviewer = StubReviewer(verdict=Verdict.APPROVE)
    runner_ = _runner(tmp_path, _forge("Verdict: approved\n"), reviewer)
    try:
        observation = (await runner_.observe(7)).unwrap()
        assert observation.recorded
        assert observation.comparison.agreement is Agreement.AGREE
        assert observation.comparison.python.usd == Decimal("0.11")
        assert reviewer.seen and "diff for MR 7" in reviewer.seen[0], "it reviewed the real diff"
    finally:
        runner_.store.dispose()


async def test_a_disagreement_is_recorded_with_its_reason(tmp_path: Path) -> None:
    """The known defect, observed: the shell obeyed a self-contradicting verdict."""
    reviewer = StubReviewer(verdict=Verdict.REQUEST_CHANGES, blocking=2, downgraded=True)
    runner_ = _runner(
        tmp_path, _forge("Verdict: approved\n- **blocking**: leaks a token\n"), reviewer
    )
    try:
        observation = (await runner_.observe(7)).unwrap()
        assert observation.comparison.agreement is Agreement.DISAGREE_VERDICT
        assert "downgraded it in code" in observation.comparison.explanation
        assert observation.comparison.explained, "a known defect explains itself"
    finally:
        runner_.store.dispose()


async def test_a_python_failure_is_observed_not_dropped(tmp_path: Path) -> None:
    """ "The Python reviewer crashed on 3% of PRs" is what a week of observation is *for*."""
    runner_ = _runner(
        tmp_path, _forge("Verdict: approved"), StubReviewer(fails="the model returned nothing")
    )
    try:
        observation = (await runner_.observe(7)).unwrap()
        assert observation.comparison.agreement is Agreement.SHELL_ONLY
        assert "returned nothing" in observation.comparison.explanation
    finally:
        runner_.store.dispose()


async def test_a_pull_request_with_no_shell_verdict_is_python_only(tmp_path: Path) -> None:
    runner_ = _runner(tmp_path, _forge("just a description, no verdict here"), StubReviewer())
    try:
        observation = (await runner_.observe(7)).unwrap()
        assert observation.comparison.agreement is Agreement.PYTHON_ONLY
    finally:
        runner_.store.dispose()


def test_the_report_command_gates_non_zero_while_blocked(tmp_path: Path) -> None:
    """So a nightly job notices, rather than a person remembering to look."""
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness" / "config.yaml").write_text("profile:\n  name: acme/app\n")
    result = runner.invoke(app, ["shadow", "report", "--path", str(tmp_path), "--gate"])
    assert result.exit_code == 1
    assert "nothing has been observed" in result.output


def test_the_report_command_prints_the_blockers(tmp_path: Path) -> None:
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness" / "config.yaml").write_text("profile:\n  name: acme/app\n")
    result = runner.invoke(app, ["shadow", "report", "--path", str(tmp_path)])
    assert result.exit_code == 0
    payload = json.loads(result.output)
    assert payload["may_cut_over"] is False
    assert payload["blocked_by"]


# ── #79: units and an idempotent install ─────────────────────────────────────────


def test_the_units_are_single_pass_driven_by_a_timer() -> None:
    """§14.1: the cadence belongs to the scheduler, never to the binary."""
    spec = render("tick", repo="acme/app", working_dir="/srv/app", agent_bin="/usr/bin/agent")
    assert "Type=oneshot" in spec.service
    assert "OnUnitActiveSec=2min" in spec.timer
    assert "Persistent=true" in spec.timer, "a host that was asleep must catch up"
    assert "RandomizedDelaySec" in spec.timer, "several repos must not fire simultaneously"
    assert "/usr/bin/agent tick --path /srv/app --repo acme/app" in spec.service


def test_unit_names_are_deterministic_so_a_reinstall_targets_the_same_files() -> None:
    assert unit_name("tick", "acme/app") == "ai-harness-tick-acme-app"
    assert unit_name("tick", "Acme/App") == unit_name("tick", "acme/app")


def test_an_unknown_unit_kind_is_refused() -> None:
    with pytest.raises(ValueError, match="unknown unit kind"):
        render("daemon", repo="acme/app", working_dir="/x", agent_bin="/x/agent")


def test_writing_the_same_content_twice_changes_nothing(tmp_path: Path) -> None:
    """The idempotency mechanism, in isolation."""
    plan = Plan()
    target = tmp_path / "x.service"
    write_if_different(target, "content", plan, dry_run=False)
    write_if_different(target, "content", plan, dry_run=False)
    assert [a["outcome"] for a in plan.actions] == [CREATED, UNCHANGED]
    assert plan.changed, "the first write did change something"


def test_a_changed_template_still_lands(tmp_path: Path) -> None:
    """Comparing content rather than existence is what lets an upgrade apply."""
    plan = Plan()
    target = tmp_path / "x.service"
    write_if_different(target, "old", plan, dry_run=False)
    write_if_different(target, "new", plan, dry_run=False)
    assert target.read_text() == "new"
    assert plan.actions[-1]["outcome"] == "updated"


def _repo(tmp_path: Path, engine: str = "shell") -> Path:
    (tmp_path / ".harness").mkdir(exist_ok=True)
    (tmp_path / ".harness" / "config.yaml").write_text(
        f"profile:\n  name: acme/app\n  engine: {engine}\n"
    )
    return tmp_path


def test_agent_install_is_idempotent(tmp_path: Path) -> None:
    """The acceptance criterion: running it twice changes nothing the second time."""
    root = _repo(tmp_path)
    units = tmp_path / "units"
    common = ["install", "--path", str(root), "--unit-dir", str(units)]

    first = runner.invoke(app, common)
    assert first.exit_code == 0, first.output
    assert json.loads(first.output)["changed"] is True

    second = runner.invoke(app, common)
    assert second.exit_code == 0, second.output
    payload = json.loads(second.output)
    assert payload["changed"] is False
    assert all(action["outcome"] == "unchanged" for action in payload["actions"])


def test_install_writes_both_unit_pairs(tmp_path: Path) -> None:
    root = _repo(tmp_path)
    units = tmp_path / "units"
    runner.invoke(app, ["install", "--path", str(root), "--unit-dir", str(units)])
    written = sorted(p.name for p in units.iterdir())
    assert written == [
        "ai-harness-tick-acme-app.service",
        "ai-harness-tick-acme-app.timer",
        "ai-harness-work-acme-app.service",
        "ai-harness-work-acme-app.timer",
    ]


def test_a_dry_run_writes_nothing(tmp_path: Path) -> None:
    root = _repo(tmp_path)
    units = tmp_path / "units"
    result = runner.invoke(
        app, ["install", "--path", str(root), "--unit-dir", str(units), "--dry-run"]
    )
    assert result.exit_code == 0
    assert json.loads(result.output)["changed"] is True, "it reports what it would do"
    assert not units.exists(), "and does none of it"


def test_install_refuses_to_enable_timers_for_an_uncut_over_repository(tmp_path: Path) -> None:
    """The one action here that could start driving runs nobody has watched (#76)."""
    root = _repo(tmp_path, engine="shell")
    result = runner.invoke(
        app,
        ["install", "--path", str(root), "--unit-dir", str(tmp_path / "units"), "--enable"],
    )
    assert result.exit_code == 1
    assert "refusing to enable" in result.output and "#76" in result.output


def test_the_label_set_covers_every_state_the_loop_projects() -> None:
    names = {name for name, _colour, _description in LABELS}
    assert {"agent", "wip", "done", "needs-human"} <= names, "the inbox loop"
    assert "harness-shadow" in names, "shadow mode"
    assert {"proposed", "proposed-speculative"} <= names, "the scout"


def test_preflight_is_green_on_an_idle_repository(tmp_path: Path) -> None:
    root = _repo(tmp_path)
    result = runner.invoke(app, ["preflight", "--path", str(root)])
    assert result.exit_code == 0
    assert json.loads(result.output)["safe_to_flip"] is True


def test_preflight_refuses_while_a_run_is_in_flight(tmp_path: Path) -> None:
    """Flipping mid-run means one run advanced by two engines, each believing it owns it.

    Synchronous on purpose: ``CliRunner`` invokes a command that calls ``asyncio.run``, which
    cannot nest inside a running loop. That is a property of the test, not of the command — no
    production caller invokes the CLI from inside an event loop.
    """
    import asyncio

    from ai_harness.schemas.job import JobRequest

    root = _repo(tmp_path)
    (root / ".harness" / "state").mkdir(parents=True, exist_ok=True)
    store = open_sqlite(root / ".harness" / "state" / "harness.db", clock=FrozenClock())
    try:
        asyncio.run(store.create(JobRequest(repo="acme/app", issue=7, title="in flight")))
    finally:
        store.dispose()

    result = runner.invoke(app, ["preflight", "--path", str(root)])
    assert result.exit_code == 1
    payload = json.loads(result.output)
    assert payload["safe_to_flip"] is False and payload["running"]


def test_the_comparison_logic_is_unchanged_by_the_move_to_schemas() -> None:
    """The contracts moved so the table could see them; the decisions must not have moved."""
    agreed = compare(
        run_id="r",
        head_sha="s",
        round_=1,
        shell=_decision("shell", Verdict.APPROVE),
        python=_decision("python", Verdict.APPROVE),
    )
    assert agreed.agreement is Agreement.AGREE and agreed.explained

    findings = compare(
        run_id="r",
        head_sha="s",
        round_=1,
        shell=_decision("shell", Verdict.REQUEST_CHANGES, blocking=1),
        python=_decision("python", Verdict.REQUEST_CHANGES, blocking=3),
    )
    assert findings.agreement is Agreement.DISAGREE_FINDINGS
