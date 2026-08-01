"""Issues #21 and #22 — one conformance suite, run against every backend.

Postgres is exercised when ``HARNESS_TEST_POSTGRES_URL`` names a reachable database and skipped
otherwise, so the default suite stays hermetic. The point of the parametrisation is that
neither backend gets its own assertions: a behaviour that only holds on SQLite is not a
behaviour the harness has.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from sqlalchemy.exc import IntegrityError

from ai_harness.kernel.budget import CostEvent
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.persistence.postgres import open_postgres, url_for
from ai_harness.persistence.sql import SqlStore
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.schemas.approval import ApprovalDecision, ApprovalRequest
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.enums import Capability, Disposition, RunStatus, State
from ai_harness.schemas.errors import ErrorInfo
from ai_harness.schemas.job import JobRequest
from ai_harness.schemas.run import Run

POSTGRES_URL = os.environ.get("HARNESS_TEST_POSTGRES_URL")


@pytest.fixture(params=["sqlite", "postgres"])
def store(request: pytest.FixtureRequest, tmp_path: Path) -> Iterator[SqlStore]:
    clock = FrozenClock()
    if request.param == "sqlite":
        opened = open_sqlite(tmp_path / "harness.db", clock=clock)
    else:
        if not POSTGRES_URL:
            pytest.skip("set HARNESS_TEST_POSTGRES_URL to run the Postgres conformance pass")
        opened = open_postgres(POSTGRES_URL, clock=clock, create=True)
        _truncate(opened)
    try:
        yield opened
    finally:
        opened.dispose()


def _truncate(store: SqlStore) -> None:
    from sqlalchemy import text

    with store.engine.begin() as connection:
        connection.execute(
            text(
                "TRUNCATE runs, checkpoints, leases, fingerprint_ledger, approvals, "
                "cost_events, artefacts RESTART IDENTITY CASCADE"
            )
        )


def _request(**kw: object) -> JobRequest:
    base: dict[str, object] = {"repo": "acme/app", "issue": 7, "title": "fix the thing"}
    base.update(kw)
    return JobRequest(**base)  # type: ignore[arg-type]


def _checkpoint(run: Run, seq: int, **kw: object) -> Checkpoint:
    base: dict[str, object] = {
        "run_id": run.run_id,
        "seq": seq,
        "state": State.PREPARE,
        "next_state": State.ANALYSE,
    }
    base.update(kw)
    return Checkpoint(**base)  # type: ignore[arg-type]


# ── runs and checkpoints ─────────────────────────────────────────────────────────


async def test_a_run_round_trips_through_the_store(store: SqlStore) -> None:
    created = await store.create(_request())
    loaded = await store.load(created.run_id)
    assert loaded is not None
    assert loaded.request.repo == "acme/app" and loaded.request.issue == 7
    assert loaded.state is State.PREPARE and loaded.status is RunStatus.RUNNING


async def test_the_transition_writes_checkpoint_and_run_together(store: SqlStore) -> None:
    """§15.3 — one transaction. A partial write is the disagreement this layer removes."""
    run = await store.create(_request())
    advanced = run.model_copy(update={"state": State.ANALYSE, "base_sha": "abc123"})
    await store.commit_transition(advanced, _checkpoint(run, 0))

    reloaded = await store.load(run.run_id)
    assert reloaded is not None and reloaded.state is State.ANALYSE
    assert reloaded.base_sha == "abc123"
    assert [c.seq for c in await store.checkpoints(run.run_id)] == [0]


async def test_a_failed_transition_leaves_neither_half_behind(store: SqlStore) -> None:
    run = await store.create(_request())
    await store.commit_transition(
        run.model_copy(update={"state": State.ANALYSE}), _checkpoint(run, 0)
    )

    with pytest.raises(IntegrityError):
        # Same seq: the unique constraint rejects it, and the run update must roll back with it.
        await store.commit_transition(
            run.model_copy(update={"state": State.IMPLEMENT}), _checkpoint(run, 0)
        )

    reloaded = await store.load(run.run_id)
    assert reloaded is not None
    assert reloaded.state is State.ANALYSE, "the run must not advance when its checkpoint fails"
    assert len(await store.checkpoints(run.run_id)) == 1


async def test_checkpoints_are_append_only(store: SqlStore) -> None:
    run = await store.create(_request())
    await store.commit_transition(run, _checkpoint(run, 0))
    with pytest.raises(IntegrityError):
        await store.commit_transition(run, _checkpoint(run, 0, state=State.REVIEW))


async def test_next_seq_counts_from_zero_and_advances(store: SqlStore) -> None:
    run = await store.create(_request())
    assert await store.next_seq(run.run_id) == 0
    await store.commit_transition(run, _checkpoint(run, 0))
    assert await store.next_seq(run.run_id) == 1


async def test_counters_survive_a_reload(store: SqlStore) -> None:
    """W1: a reboot silently reset the /tmp counters, re-opening bounded loops."""
    run = await store.create(_request())
    bumped = run.model_copy(
        update={
            "counters": run.counters.bump("review_rounds", 3).bump("empty_envelope_streak", 2),
        }
    )
    await store.commit_transition(bumped, _checkpoint(run, 0))
    reloaded = await store.load(run.run_id)
    assert reloaded is not None
    assert reloaded.counters.review_rounds == 3
    assert reloaded.counters.empty_envelope_streak == 2


async def test_a_checkpoint_carries_its_error_and_no_prompt_text(store: SqlStore) -> None:
    run = await store.create(_request())
    error = ErrorInfo(category=ErrorCategory.UNKNOWN, message="the CLI produced no envelope")
    await store.commit_transition(
        run,
        _checkpoint(run, 0, error=error, prompt_sha256="a" * 64, prompt_bytes=1234),
    )
    stored = (await store.checkpoints(run.run_id))[0]
    assert stored.error is not None and stored.error.category is ErrorCategory.UNKNOWN
    assert stored.prompt_sha256 == "a" * 64 and stored.prompt_bytes == 1234


async def test_find_active_ignores_finished_runs(store: SqlStore) -> None:
    first = await store.create(_request())
    await store.commit_transition(
        first.model_copy(update={"state": State.COMPLETE, "disposition": Disposition.MERGED}),
        _checkpoint(first, 0, next_state=State.COMPLETE),
    )
    assert await store.find_active("acme/app", 7) is None
    second = await store.create(_request())
    active = await store.find_active("acme/app", 7)
    assert active is not None and active.run_id == second.run_id


async def test_listing_filters_by_repo_state_and_status(store: SqlStore) -> None:
    await store.create(_request())
    other = await store.create(_request(repo="acme/other", issue=9))
    await store.commit_transition(
        other.model_copy(update={"state": State.REVIEW, "status": RunStatus.DEFERRED}),
        _checkpoint(other, 0, next_state=State.REVIEW),
    )
    assert len(await store.list_runs(repo="acme/app")) == 1
    assert len(await store.list_runs(state=State.REVIEW)) == 1
    assert len(await store.list_runs(status=RunStatus.DEFERRED)) == 1
    assert len(await store.list_runs()) == 2


# ── the resume property ──────────────────────────────────────────────────────────


@pytest.mark.parametrize("interrupt_at", [0, 1, 2, 3])
async def test_a_run_interrupted_at_any_checkpoint_resumes_to_the_same_place(
    store: SqlStore, interrupt_at: int
) -> None:
    """The property §23 requires: resume is a lookup, not an inference."""
    path = [State.PREPARE, State.ANALYSE, State.IMPLEMENT, State.VALIDATE, State.REVIEW]
    run = await store.create(_request())
    for seq in range(interrupt_at + 1):
        run = run.model_copy(update={"state": path[seq + 1]})
        await store.commit_transition(
            run, _checkpoint(run, seq, state=path[seq], next_state=path[seq + 1])
        )

    # "Crash", then resume from the durable record alone.
    resumed = await store.load(run.run_id)
    assert resumed is not None
    assert resumed.state is path[interrupt_at + 1]
    history = await store.checkpoints(run.run_id)
    assert [c.state for c in history] == path[: interrupt_at + 1]
    assert history[-1].next_state is resumed.state


# ── the ledger ───────────────────────────────────────────────────────────────────


async def test_the_ledger_counts_attempts_per_signature(store: SqlStore) -> None:
    for _ in range(3):
        await store.record_attempt(repo="acme/app", signature="deadbeef", gate="unit")
    assert await store.attempts("acme/app", "deadbeef") == 3
    assert await store.attempts("acme/app", "other") == 0
    assert await store.attempts("acme/other", "deadbeef") == 0


async def test_open_blockers_are_capped_globally_not_per_signature(store: SqlStore) -> None:
    """Invariant 8: fingerprint + ledger + a GLOBAL cap (#2381→#2385)."""
    for n in range(4):
        await store.record_attempt(repo="acme/app", signature=f"sig{n}")
        await store.set_blocker("acme/app", f"sig{n}", f"#{100 + n}")
    assert await store.open_blockers("acme/app") == 4
    await store.set_blocker("acme/app", "sig0", None)
    assert await store.open_blockers("acme/app") == 3


async def test_the_ledger_keeps_the_resolution(store: SqlStore) -> None:
    """The shell ledger counts attempts and discards resolutions — the reusable half."""
    await store.record_attempt(repo="acme/app", signature="sig", normalised="assertionerror ...")
    await store.set_blocker("acme/app", "sig", "#42")
    await store.record_resolution("acme/app", "sig", "pinned the flaky clock in conftest")
    assert await store.open_blockers("acme/app") == 0


# ── cost ─────────────────────────────────────────────────────────────────────────


def _event(usd: str, **kw: object) -> CostEvent:
    base: dict[str, object] = {
        "run_id": "r1",
        "repo": "acme/app",
        "state": "REVIEW",
        "provider": "anthropic",
        "model": "claude-opus-5",
        "usd": Decimal(usd),
        "at": datetime(2026, 1, 1, 12, tzinfo=UTC),
    }
    base.update(kw)
    return CostEvent(**base)  # type: ignore[arg-type]


async def test_cost_is_queryable_per_run_and_per_repo_day(store: SqlStore) -> None:
    await store.record(_event("1.50", template_id="reviewer-v1"))
    await store.record(_event("2.50", run_id="r2", template_id="planner-v1"))
    await store.record(_event("9.99", at=datetime(2026, 1, 2, 12, tzinfo=UTC)))

    assert await store.run_total("r1") == Decimal("11.49")
    assert await store.repo_day_total("acme/app", datetime(2026, 1, 1, tzinfo=UTC)) == Decimal(
        "4.00"
    )
    summary = await store.summary(repo="acme/app")
    assert summary["calls"] == 3
    assert Decimal(summary["by_template"]["reviewer-v1"]) == Decimal("1.50")
    assert Decimal(summary["by_run"]["r1"]) == Decimal("11.49")


async def test_money_is_never_a_float(store: SqlStore) -> None:
    await store.record(_event("0.10"))
    await store.record(_event("0.20"))
    total = await store.run_total("r1")
    assert total == Decimal("0.30"), "a float ceiling eventually rounds the wrong way"
    assert isinstance(total, Decimal)


async def test_cost_can_be_filtered_by_time(store: SqlStore) -> None:
    await store.record(_event("1.00"))
    await store.record(_event("2.00", at=datetime(2026, 6, 1, tzinfo=UTC)))
    recent = await store.summary(since=datetime(2026, 5, 1, tzinfo=UTC))
    assert recent["calls"] == 1


# ── approvals ────────────────────────────────────────────────────────────────────


async def test_an_approval_is_pending_until_it_is_decided(store: SqlStore) -> None:
    run = await store.create(_request())
    request = ApprovalRequest(
        approval_id="a1",
        run_id=run.run_id,
        state=State.IMPLEMENT,
        capability=Capability.MODIFY_CI,
        reason="the diff touches .github/workflows",
        evidence=[".github/workflows/ci.yml"],
        requested_at=datetime(2026, 1, 1, tzinfo=UTC),
    )
    await store.request(request)
    assert await store.poll("a1") is None
    assert [r.approval_id for r in await store.pending()] == ["a1"]

    await store.decide(
        ApprovalDecision(approval_id="a1", approved=False, decided_by="hmei", reason="no")
    )
    decision = await store.poll("a1")
    assert decision is not None and decision.denied and decision.decided_by == "hmei"
    assert await store.pending() == []


async def test_approval_timeouts_are_computable_from_the_stored_request(store: SqlStore) -> None:
    """Q14: 24h → deferred, 72h → escalated. The clock decides, not a background job."""
    requested = datetime(2026, 1, 1, tzinfo=UTC)
    request = ApprovalRequest(
        approval_id="a2",
        run_id="r1",
        state=State.REVIEW,
        capability=Capability.FORGE_MERGE,
        reason="protected branch",
        requested_at=requested,
    )
    await store.request(request)
    stored = (await store.pending())[0]
    assert not stored.deferred_by(requested + timedelta(hours=23))
    assert stored.deferred_by(requested + timedelta(hours=25))
    assert not stored.expired_by(requested + timedelta(hours=71))
    assert stored.expired_by(requested + timedelta(hours=73))


# ── backend parity ───────────────────────────────────────────────────────────────


def test_the_postgres_url_normaliser_leaves_an_explicit_driver_alone() -> None:
    assert url_for("postgres://u:p@h/db") == "postgresql+psycopg://u:p@h/db"
    assert url_for("postgresql://u:p@h/db") == "postgresql+psycopg://u:p@h/db"
    assert url_for("postgresql+asyncpg://u:p@h/db") == "postgresql+asyncpg://u:p@h/db"


def test_sqlite_enforces_foreign_keys(tmp_path: Path) -> None:
    """Off by default in SQLite — without the pragma the cascade silently does nothing."""
    from sqlalchemy import text

    store = open_sqlite(tmp_path / "fk.db")
    with store.engine.connect() as connection:
        assert connection.execute(text("PRAGMA foreign_keys")).scalar() == 1
    store.dispose()


def test_the_local_path_needs_no_database_server(tmp_path: Path) -> None:
    """A4, falsified: `agent run` must work with nothing installed."""
    store = open_sqlite(tmp_path / "local.db")
    assert (tmp_path / "local.db").exists()
    store.dispose()


# ── migrations ───────────────────────────────────────────────────────────────────


def _alembic_config(url: str) -> Any:
    from alembic.config import Config

    root = Path(__file__).resolve().parents[2]
    config = Config(str(root / "alembic.ini"))
    config.set_main_option("script_location", str(root / "ai_harness/persistence/migrations"))
    config.set_main_option("sqlalchemy.url", url)
    return config


def test_migrations_run_forward_and_backward_cleanly(tmp_path: Path) -> None:
    """Issue #21: a migration that cannot be reversed is a migration you cannot roll back."""
    from alembic import command
    from sqlalchemy import create_engine, inspect

    url = f"sqlite:///{tmp_path / 'migrated.db'}"
    config = _alembic_config(url)

    command.upgrade(config, "head")
    engine = create_engine(url)
    tables = set(inspect(engine).get_table_names())
    assert {
        "runs",
        "checkpoints",
        "leases",
        "fingerprint_ledger",
        "approvals",
        "cost_events",
        "artefacts",
    } <= tables

    command.downgrade(config, "base")
    remaining = set(inspect(engine).get_table_names()) - {"alembic_version"}
    assert remaining == set(), f"downgrade left {remaining} behind"
    engine.dispose()


def test_the_migrated_schema_matches_the_models(tmp_path: Path) -> None:
    """The models and the migrations must not drift — one is generated from the other."""
    from alembic import command
    from sqlalchemy import create_engine, inspect

    from ai_harness.persistence.models import Base

    migrated_url = f"sqlite:///{tmp_path / 'a.db'}"
    command.upgrade(_alembic_config(migrated_url), "head")
    migrated = create_engine(migrated_url)

    declared = create_engine(f"sqlite:///{tmp_path / 'b.db'}")
    Base.metadata.create_all(declared)

    for table in sorted(Base.metadata.tables):
        from_migration = {c["name"] for c in inspect(migrated).get_columns(table)}
        from_models = {c["name"] for c in inspect(declared).get_columns(table)}
        assert from_migration == from_models, f"{table} drifted: {from_migration ^ from_models}"
    migrated.dispose()
    declared.dispose()
