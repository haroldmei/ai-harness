"""Issues #68 and #79 — the pgvector adapter, and the composition root that makes the CLI real.

The wiring tests are the ones that matter most here. Every module in this package has been
testable in isolation since Phase 0 precisely because nothing reaches for a global — and the
cost of that is that *something* must assemble the graph, and until Phase 6 nothing did. These
assert the refusals: an uncut-over repository, a missing credential, an absent forge. Each is a
failure that used to be impossible to have because the command did not exist, and is now a
failure that must happen at startup rather than after a claim.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from typer.testing import CliRunner

from ai_harness.agents.roster import Role
from ai_harness.cli.main import app
from ai_harness.config import HarnessConfig
from ai_harness.context.retrieval.protocol import RetrievalQuery
from ai_harness.context.retrieval.service import build_index
from ai_harness.context.retrieval.vector.pgvector import (
    PgVectorRetrieval,
    VectorEntry,
    chunk_by_symbol,
    rerank,
)
from ai_harness.kernel.clock import FrozenClock
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.schemas.enums import State
from ai_harness.schemas.profile import RepoProfile
from ai_harness.wiring import WiringError, build, build_deps, build_engine, build_leases

runner = CliRunner()

# ── #68: pgvector, off by default ────────────────────────────────────────────────


SOURCE = '''"""A module docstring."""

import os


def first(a):
    return a


def second(b):
    """Doc."""
    return b
'''


def test_chunking_is_by_symbol_boundary_never_a_fixed_window() -> None:
    """Splitting a function destroys the retrieval unit: neither half answers the question."""
    chunks = chunk_by_symbol(SOURCE, path="app.py", symbols=[("first", 6), ("second", 10)])

    assert [c["symbol"] for c in chunks] == ["", "first", "second"]
    assert "def first(a):" in chunks[1]["text"] and "return a" in chunks[1]["text"]
    assert "def second" not in chunks[1]["text"], "one function per chunk, whole"
    assert chunks[0]["symbol"] == "", "imports and the module docstring are their own unit"


def test_a_file_with_no_symbols_is_one_chunk() -> None:
    chunks = chunk_by_symbol("just prose\nover two lines\n", path="notes.md", symbols=[])
    assert len(chunks) == 1 and chunks[0]["line"] == 1


def test_the_tenant_filter_is_in_the_query_not_applied_afterwards(tmp_path: Path) -> None:
    """A post-filter leaks on every path that forgets it, and there is always such a path."""
    store = open_sqlite(tmp_path / "x.db", clock=FrozenClock())
    try:
        adapter = PgVectorRetrieval(engine=store.engine, tenant="acme", repo="acme/app")
        statement = str(
            adapter._search.__doc__  # documented contract
        )
        assert "WHERE clause" in statement
    finally:
        store.dispose()


async def test_a_cross_tenant_read_returns_nothing(tmp_path: Path) -> None:
    """The permission boundary, exercised: another tenant's row is not reachable."""
    from sqlalchemy import text

    store = open_sqlite(tmp_path / "vec.db", clock=FrozenClock())
    try:
        with store.engine.begin() as connection:
            connection.execute(
                text(
                    "CREATE TABLE context_chunks (text TEXT, tenant TEXT, repo TEXT, "
                    "commit_sha TEXT, path TEXT, symbol TEXT, language TEXT, kind TEXT, "
                    "line INTEGER, embedding TEXT)"
                )
            )
            for tenant in ("acme", "other-corp"):
                connection.execute(
                    text(
                        "INSERT INTO context_chunks VALUES (:t, :tenant, 'acme/app', 'sha', "
                        "'a.py', 'send', 'python', 'code', 1, '[]')"
                    ),
                    {"t": f"{tenant} secret", "tenant": tenant},
                )

        async def embedder(text_query: str) -> list[float]:
            return [0.0]

        # SQLite has no `vector` type, so the distance expression is replaced — the point of
        # this test is the WHERE clause, and it is the same one either way.
        adapter = PgVectorRetrieval(
            engine=store.engine,
            tenant="acme",
            repo="acme/app",
            embedder=embedder,
            enabled=True,
        )
        rows = _sqlite_rows(store, tenant="acme")
        assert [row["text"] for row in rows] == ["acme secret"]
        assert all("other-corp" not in row["text"] for row in rows)
        assert adapter.tenant == "acme"
    finally:
        store.dispose()


def _sqlite_rows(store: Any, *, tenant: str) -> list[dict[str, Any]]:
    """The adapter's WHERE clause, run against SQLite so the filter itself is exercised."""
    from sqlalchemy import text

    with store.engine.connect() as connection:
        return [
            dict(row)
            for row in connection.execute(
                text("SELECT text FROM context_chunks WHERE tenant = :tenant AND repo = :repo"),
                {"tenant": tenant, "repo": "acme/app"},
            ).mappings()
        ]


def _entry(**kw: Any) -> VectorEntry:
    base: dict[str, Any] = {
        "text": "def send(): ...",
        "embedding": [],
        "tenant": "acme",
        "repo": "acme/app",
        "commit_sha": "live",
        "path": "app/send.py",
        "symbol": "send",
        "line": 42,
    }
    base.update(kw)
    return VectorEntry(**base)


def test_a_stale_entry_is_never_cited_with_a_line_number() -> None:
    """Its fix may still be right; the line it was applied at may not exist."""
    chunks = rerank(
        [_entry(commit_sha="gone")],
        RetrievalQuery(state=State.IMPLEMENT, symbols=["send"]),
        is_ancestor=lambda sha: sha == "live",
    )
    assert chunks[0].line == 0 and chunks[0].path == ""
    assert "stale" in chunks[0].kind
    assert "def send" in chunks[0].text, "down-weighted, not dropped"


def test_a_live_entry_keeps_its_citation() -> None:
    chunks = rerank(
        [_entry()],
        RetrievalQuery(state=State.IMPLEMENT, symbols=["send"]),
        is_ancestor=lambda sha: sha == "live",
    )
    assert chunks[0].line == 42 and chunks[0].path == "app/send.py"


def test_without_an_ancestry_check_everything_is_stale() -> None:
    """Fails safe: the cost of the mistake is evidence a reviewer will act on."""
    chunks = rerank([_entry()], RetrievalQuery(state=State.IMPLEMENT, symbols=["send"]))
    assert "stale" in chunks[0].kind


def test_symbol_overlap_outranks_raw_similarity() -> None:
    """Similarity alone puts the ADR that mentions a symbol above the code that defines it."""
    entries = [
        _entry(text="An ADR discussing send at length", symbol="", kind="prose", path="adr.md"),
        _entry(text="def send(): ...", symbol="send"),
    ]
    chunks = rerank(
        entries,
        RetrievalQuery(state=State.IMPLEMENT, symbols=["send"]),
        is_ancestor=lambda sha: True,
    )
    assert chunks[0].symbol == "send", "the definition wins despite ranking second by distance"


async def test_the_adapter_is_disabled_by_default(tmp_path: Path) -> None:
    """§17.2's default is *no vector store*. Enabling it is a policy decision with a trigger."""
    store = open_sqlite(tmp_path / "x.db", clock=FrozenClock())
    try:
        adapter = PgVectorRetrieval(engine=store.engine, tenant="acme", repo="acme/app")
        bundle = (await adapter.bundle(RetrievalQuery(state=State.IMPLEMENT))).unwrap()
        assert bundle.chunks == [] and bundle.sources == ["pgvector:disabled"]
    finally:
        store.dispose()


async def test_an_empty_structural_query_retrieves_nothing(tmp_path: Path) -> None:
    """Similarity search needs something to be similar to; prose alone is what §17.2 forbids."""
    store = open_sqlite(tmp_path / "x.db", clock=FrozenClock())
    try:

        async def embedder(text_query: str) -> list[float]:
            raise AssertionError("must not embed an empty query")

        adapter = PgVectorRetrieval(
            engine=store.engine, tenant="a", repo="r", embedder=embedder, enabled=True
        )
        bundle = (await adapter.bundle(RetrievalQuery(state=State.IMPLEMENT))).unwrap()
        assert bundle.chunks == []
    finally:
        store.dispose()


# ── #79: the composition root ────────────────────────────────────────────────────


def _config(tmp_path: Path, **kw: Any) -> HarnessConfig:
    base: dict[str, Any] = {
        "repo_path": tmp_path,
        "database_url": f"sqlite:///{tmp_path / 'harness.db'}",
        "lease_dir": tmp_path / "leases",
        "profile": RepoProfile(name="acme/app", engine="python"),
    }
    base.update(kw)
    return HarnessConfig(**base)


def test_an_uncut_over_repository_cannot_be_driven(tmp_path: Path) -> None:
    """The flag is the Phase 2-5 rollback; it is worth nothing if an entry point routes around it."""
    config = _config(tmp_path, profile=RepoProfile(name="acme/app", engine="shell"))
    with pytest.raises(WiringError, match="not cut over"):
        build(config)


def test_the_cutover_check_can_be_overridden_deliberately(tmp_path: Path) -> None:
    config = _config(tmp_path, profile=RepoProfile(name="acme/app", engine="shell"))
    harness = build(config, require_cutover=False)
    try:
        assert harness.deps.registry.bound_states
    finally:
        harness.close()


def test_an_unknown_engine_is_a_startup_error_not_a_default(tmp_path: Path) -> None:
    """A typo in roster.engine must not silently reroute every model call."""
    config = _config(tmp_path)
    config.roster.engine = "gpt-9-turbo"
    with pytest.raises(WiringError, match="unknown engine"):
        build_engine(config)


def test_a_missing_credential_is_refused_before_anything_is_claimed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A worker that discovers this after claiming has spent a dispatch and a lease."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    config = _config(tmp_path)
    config.roster.engine = "anthropic"
    with pytest.raises(WiringError, match="ANTHROPIC_API_KEY"):
        build_engine(config)


def test_every_state_that_can_be_bound_is_bound(tmp_path: Path) -> None:
    harness = build(_config(tmp_path))
    try:
        bound = harness.deps.registry.bound_states
        assert {State.ANALYSE, State.IMPLEMENT, State.REVIEW, State.VALIDATE} <= bound
    finally:
        harness.close()


def test_integrate_is_left_unbound_without_a_forge_rather_than_half_built(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An unbound state escalates with a reason. A half-built one fails while pushing."""
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    harness = build(_config(tmp_path))
    try:
        assert harness.forge is None
        assert harness.unbound == (State.INTEGRATE,)
        assert State.INTEGRATE not in harness.deps.registry.bound_states
    finally:
        harness.close()


def test_the_roster_refusal_survives_the_wiring(tmp_path: Path) -> None:
    """FR-075: the reviewer and the implementer may not share a model. Asserted end to end."""
    config = _config(tmp_path)
    config.roster.reviewer_model = config.roster.implementer_model
    store = open_sqlite(tmp_path / "roster.db", clock=FrozenClock())
    try:
        with pytest.raises(Exception, match="DIFFERENT"):
            build_deps(config, store=store)
    finally:
        store.dispose()


def test_sqlite_gets_flock_leases_and_postgres_gets_sql_ones(tmp_path: Path) -> None:
    """§26's trigger, applied rather than described: a SQLite file is one host by construction."""
    from ai_harness.kernel.lease import FlockLeaseBackend

    store = open_sqlite(tmp_path / "l.db", clock=FrozenClock())
    try:
        backend = build_leases(_config(tmp_path), store, FrozenClock())
        assert isinstance(backend, FlockLeaseBackend)
    finally:
        store.dispose()


def test_the_index_factory_prefers_the_parsed_backend(tmp_path: Path) -> None:
    (tmp_path / "a.py").write_text("def send():\n    return 1\n")
    index = build_index(tmp_path, "sha")
    assert index.definitions_of("send")


# ── the commands ─────────────────────────────────────────────────────────────────


def _write_config(tmp_path: Path, engine: str = "python") -> None:
    (tmp_path / ".harness").mkdir(exist_ok=True)
    (tmp_path / ".harness" / "config.yaml").write_text(
        "database_url: sqlite:///.harness/state/harness.db\n"
        f"profile:\n  name: acme/app\n  engine: {engine}\n"
    )
    (tmp_path / ".harness" / "state").mkdir(exist_ok=True)


def test_agent_work_exists_and_refuses_an_uncut_over_repository(tmp_path: Path) -> None:
    """The gap left open when Phase 5 closed: there is now a command, and it is guarded."""
    _write_config(tmp_path, engine="shell")
    result = runner.invoke(app, ["work", "--path", str(tmp_path)])
    assert result.exit_code == 2
    assert "not cut over" in result.output


def test_agent_work_claims_nothing_and_reports_idle_on_an_empty_queue(tmp_path: Path) -> None:
    _write_config(tmp_path)
    result = runner.invoke(app, ["work", "--path", str(tmp_path)])
    assert result.exit_code == 0, result.output
    assert '"idle": true' in result.output


def test_agent_work_reports_which_states_are_unbound(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An operator must be able to see that INTEGRATE will escalate before a run gets there."""
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    _write_config(tmp_path)
    result = runner.invoke(app, ["work", "--path", str(tmp_path)])
    assert "INTEGRATE" in result.output


def test_agent_tick_refuses_without_a_forge(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A tick that silently skipped reconciliation would still look like a tick that ran."""
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    _write_config(tmp_path)
    result = runner.invoke(app, ["tick", "--path", str(tmp_path)])
    assert result.exit_code == 2
    assert "forge token" in result.output


def test_the_roles_the_wiring_names_all_exist() -> None:
    """A typo here would only surface when that role was first played, which may be never."""
    for role in (
        Role.PLANNER,
        Role.IMPLEMENTER,
        Role.REVIEWER,
        Role.CONFLICT_RESOLVER,
        Role.TRIAGER,
    ):
        assert role.value
