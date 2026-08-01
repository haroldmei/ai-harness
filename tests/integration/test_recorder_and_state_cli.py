"""Issues #29 and #30 — the dual-write recorder, and the commands that read it."""

from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path

from typer.testing import CliRunner

from ai_harness.cli.main import app
from ai_harness.kernel.budget import CostEvent
from ai_harness.kernel.clock import FrozenClock
from ai_harness.persistence.recorder import Recorder, record_safely
from ai_harness.persistence.sql import SqlStore
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.schemas.enums import Disposition, RunStatus, State

runner = CliRunner()


def _store(tmp_path: Path) -> SqlStore:
    return open_sqlite(tmp_path / "harness.db", clock=FrozenClock())


# ── the recorder ─────────────────────────────────────────────────────────────────


async def test_a_shell_stage_boundary_becomes_a_run_and_a_checkpoint(tmp_path: Path) -> None:
    store = _store(tmp_path)
    recorder = Recorder(store=store, clock=FrozenClock())
    run = await recorder.record(repo="acme/app", issue=7, stage="inbox", branch="agent/issue-7")
    assert run is not None
    assert run.state is State.IMPLEMENT and run.branch == "agent/issue-7"
    assert [c.seq for c in await store.checkpoints(run.run_id)] == [0]


async def test_successive_stages_append_to_one_run(tmp_path: Path) -> None:
    """The shell's four stages are one unit of work, and the store should say so."""
    store = _store(tmp_path)
    recorder = Recorder(store=store, clock=FrozenClock())
    first = await recorder.record(repo="acme/app", issue=7, stage="inbox")
    await recorder.record(repo="acme/app", issue=7, stage="reviewer")
    last = await recorder.record(repo="acme/app", issue=7, stage="merger", outcome="merged")

    assert first is not None and last is not None and first.run_id == last.run_id
    assert last.state is State.COMPLETE and last.disposition is Disposition.MERGED
    timeline = await store.checkpoints(first.run_id)
    assert [c.state for c in timeline] == [State.IMPLEMENT, State.REVIEW, State.INTEGRATE]
    assert len(await store.list_runs()) == 1


async def test_a_finished_run_does_not_absorb_the_next_one(tmp_path: Path) -> None:
    store = _store(tmp_path)
    recorder = Recorder(store=store, clock=FrozenClock())
    await recorder.record(repo="acme/app", issue=7, stage="merger", outcome="merged")
    await recorder.record(repo="acme/app", issue=7, stage="inbox")
    assert len(await store.list_runs()) == 2


async def test_an_unknown_stage_is_still_recorded(tmp_path: Path) -> None:
    """An unmapped stage is evidence too — dropping it would lose the boundary entirely."""
    store = _store(tmp_path)
    run = await Recorder(store=store, clock=FrozenClock()).record(
        repo="acme/app", issue=7, stage="scout"
    )
    assert run is not None
    assert (await store.checkpoints(run.run_id))[0].result["stage"] == "scout"


async def test_the_recorder_cannot_fail_its_caller(tmp_path: Path) -> None:
    """The rule the whole design turns on: this is a shadow write into production stages."""
    store = open_sqlite(tmp_path / "gone.db", clock=FrozenClock())
    store.dispose()
    (tmp_path / "gone.db").write_text("this is not a database")

    result = await record_safely(
        Recorder(store=store, clock=FrozenClock()), repo="acme/app", issue=7, stage="inbox"
    )
    assert result is None, "a broken store yields nothing, and raises nothing"


async def test_counters_recorded_by_the_shell_survive(tmp_path: Path) -> None:
    store = _store(tmp_path)
    recorder = Recorder(store=store, clock=FrozenClock())
    run = await recorder.record(
        repo="acme/app", issue=7, stage="reviewer", counters={"review_rounds": 3}
    )
    assert run is not None
    reloaded = await store.load(run.run_id)
    assert reloaded is not None and reloaded.counters.review_rounds == 3


# ── the CLI ──────────────────────────────────────────────────────────────────────


def test_record_exits_zero_even_when_everything_is_wrong(tmp_path: Path) -> None:
    """Invoked from the production pipeline: it may lose a row, never a run."""
    (tmp_path / ".harness").mkdir()
    (tmp_path / ".harness/config.yaml").write_text("database_url: postgresql+psycopg://nope/nope\n")
    result = runner.invoke(
        app,
        [
            "record",
            "--repo",
            "acme/app",
            "--issue",
            "7",
            "--stage",
            "inbox",
            "--path",
            str(tmp_path),
        ],
    )
    assert result.exit_code == 0, result.output


def test_record_then_ls_then_inspect(tmp_path: Path) -> None:
    common = ["--path", str(tmp_path)]
    assert (
        runner.invoke(
            app, ["record", "--repo", "acme/app", "--issue", "7", "--stage", "inbox", *common]
        ).exit_code
        == 0
    )
    assert (
        runner.invoke(
            app,
            [
                "record",
                "--repo",
                "acme/app",
                "--issue",
                "7",
                "--stage",
                "merger",
                "--outcome",
                "merged",
                *common,
            ],
        ).exit_code
        == 0
    )

    listed = runner.invoke(app, ["ls", "--json", *common])
    assert listed.exit_code == 0
    rows = json.loads(listed.stdout)
    assert len(rows) == 1 and rows[0]["disposition"] == "merged"

    inspected = runner.invoke(app, ["inspect", rows[0]["run_id"], *common])
    assert inspected.exit_code == 0
    assert "why" in inspected.stdout and "timeline" in inspected.stdout
    assert "IMPLEMENT" in inspected.stdout and "INTEGRATE" in inspected.stdout


def test_ls_is_empty_rather_than_broken_before_anything_is_recorded(tmp_path: Path) -> None:
    result = runner.invoke(app, ["ls", "--path", str(tmp_path)])
    assert result.exit_code == 0 and "no runs recorded" in result.stdout


def test_inspect_reports_an_unknown_run_clearly(tmp_path: Path) -> None:
    runner.invoke(app, ["record", "--repo", "a/b", "--stage", "inbox", "--path", str(tmp_path)])
    result = runner.invoke(app, ["inspect", "nope", "--path", str(tmp_path)])
    assert result.exit_code == 1 and "no run nope" in result.output


async def test_why_answers_the_question_without_opening_a_log(tmp_path: Path) -> None:
    """§24 Phase 1's stated payoff: "why is this PR stuck", from one query."""
    from ai_harness.cli.commands.state import _why

    store = _store(tmp_path)
    run = await Recorder(store=store, clock=FrozenClock()).record(
        repo="acme/app", issue=7, stage="reviewer"
    )
    assert run is not None
    assert "running in REVIEW" in _why(run)

    blocked = run.model_copy(update={"status": RunStatus.BLOCKED, "blocked_on": "#412"})
    assert "blocked on #412" in _why(blocked)

    deferred = run.model_copy(update={"status": RunStatus.DEFERRED})
    assert "deferred until" in _why(deferred)

    approval = run.model_copy(
        update={"status": RunStatus.AWAITING_APPROVAL, "pending_approval_id": "a1"}
    )
    assert "awaiting approval a1" in _why(approval)


def test_cost_reports_spend_from_the_store(tmp_path: Path) -> None:
    import asyncio

    from ai_harness.cli.commands.state import _store as cli_store

    # Write through the same resolution the CLI uses, or the test would seed a different file.
    store = cli_store(tmp_path)
    asyncio.run(
        store.record(
            CostEvent(
                run_id="r1",
                repo="acme/app",
                state="REVIEW",
                provider="anthropic",
                model="claude-opus-5",
                usd=Decimal("2.29"),
                template_id="reviewer-v1",
            )
        )
    )
    store.dispose()
    result = runner.invoke(app, ["cost", "--path", str(tmp_path)])
    assert result.exit_code == 0
    payload = json.loads(result.stdout)
    assert Decimal(payload["usd"]) == Decimal("2.29")
    assert payload["by_template"]["reviewer-v1"].startswith("2.29")


def test_replay_emits_the_decision_sequence(tmp_path: Path) -> None:
    common = ["--path", str(tmp_path)]
    runner.invoke(app, ["record", "--repo", "a/b", "--issue", "1", "--stage", "inbox", *common])
    runner.invoke(app, ["record", "--repo", "a/b", "--issue", "1", "--stage", "gates", *common])
    rows = json.loads(runner.invoke(app, ["ls", "--json", *common]).stdout)

    replayed = runner.invoke(app, ["replay", rows[0]["run_id"], *common])
    assert replayed.exit_code == 0
    lines = [json.loads(line) for line in replayed.stdout.strip().splitlines()]
    assert [line["state"] for line in lines] == ["IMPLEMENT", "VALIDATE"]
    assert all(line["idempotency_key"] for line in lines)


def test_only_the_layers_that_should_touch_durable_state_do(tmp_path: Path) -> None:
    """Who may reach the store, and why the set is exactly this.

    Phase 1 shipped this as "nothing reads shadow state at all". Phase 2 legitimately widens
    it: the supervisor *is* the thing that reads a run and advances it. What has not changed —
    and what the Phase 1 rollback still rests on — is that the shell pipeline remains
    authoritative, the recorder cannot fail it, and a shadow run writes nothing to the forge.
    Those three are asserted elsewhere in this file and in the shadow-mode suite.

    Widening this set again should require the same deliberate edit, which is the point.
    """
    import subprocess

    root = Path(__file__).resolve().parents[2]
    readers = subprocess.run(
        ["grep", "-rln", "--include=*.py", "from ai_harness.persistence", str(root / "ai_harness")],
        capture_output=True,
        text=True,
    ).stdout.split()
    # Phase 3 adds policies/: the approval gateway records and polls approvals, which is
    # durable state by definition. Phase 5 adds workers/: a worker asks the queue what to
    # claim, and the queue is a query over the runs table (§25). What must NOT appear here is
    # agents, subgraphs, quality or context — those receive what they need through their
    # context object, so a state cannot quietly fetch or mutate the run it is executing.
    allowed = {"persistence", "cli", "orchestration", "policies", "workers"}
    for reader in readers:
        relative = Path(reader).relative_to(root / "ai_harness")
        assert relative.parts[0] in allowed, f"{relative} reads durable state before Phase 4"

    # …and workers get the queue only. A worker that could reach the store directly would be
    # able to advance a run without going through the supervisor, which is where the lease,
    # the budget check and the checkpoint live.
    worker_imports = subprocess.run(
        [
            "grep",
            "-rhn",
            "--include=*.py",
            "from ai_harness.persistence",
            str(root / "ai_harness" / "workers"),
        ],
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    for line in worker_imports:
        assert "persistence.queue" in line, f"a worker reaches past the queue: {line.strip()}"
