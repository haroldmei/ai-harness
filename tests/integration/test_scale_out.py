"""Phase 5 — issues #61 to #64: the SQL lease, the queue, GitLab, and telemetry export.

Every claim in this file is one the shell harness could not make. It runs one host, one forge,
and a 20-minute staleness heuristic; each section below replaces one of those, and each is
tested against the *same* conformance expectations as the mechanism it replaces — not against a
weaker set that happens to pass.

Postgres is exercised when ``HARNESS_TEST_POSTGRES_URL`` names a reachable database. The
``SKIP LOCKED`` assertions are the ones that genuinely need it: SQLite has no such clause and no
need for one, so a suite that only ever ran on SQLite would be claiming a property it had never
tested.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import Iterator
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx
import pytest

from ai_harness.kernel.budget import DEFAULT_BUDGET, CircuitBreaker, CostTracker
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import LeaseManager, MemoryLeaseBackend, run_lease_key
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.observability.logging import JsonlSpanSink, Logger
from ai_harness.observability.metrics import Metrics, gate_pass_rate
from ai_harness.observability.tracing import OTelSpanSink, Tracer, attributes_for
from ai_harness.orchestration.machine import Deps
from ai_harness.orchestration.registry import Registry
from ai_harness.persistence.leases import SqlLeaseBackend
from ai_harness.persistence.postgres import open_postgres
from ai_harness.persistence.queue import SqlQueue
from ai_harness.persistence.sql import SqlStore
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.providers.forge.gitlab import GitLabForge, _map_response
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.enums import Disposition, GateStatus, RunStatus, Signal, State
from ai_harness.schemas.gates import GateReport, GateResult
from ai_harness.schemas.job import JobRequest
from ai_harness.schemas.run import Run
from ai_harness.schemas.telemetry import Span
from ai_harness.subgraphs.base import SubgraphResult
from ai_harness.workers.runner import Worker

POSTGRES_URL = os.environ.get("HARNESS_TEST_POSTGRES_URL")

TABLES = "runs, checkpoints, leases, fingerprint_ledger, approvals, cost_events, artefacts"

Backend = tuple[SqlStore, FrozenClock]


@pytest.fixture(params=["sqlite", "postgres"])
def backend(request: pytest.FixtureRequest, tmp_path: Path) -> Iterator[Backend]:
    """The same parametrisation as the persistence conformance suite, for the same reason."""
    clock = FrozenClock()
    if request.param == "sqlite":
        store = open_sqlite(tmp_path / "scale.db", clock=clock)
    else:
        if not POSTGRES_URL:
            pytest.skip("set HARNESS_TEST_POSTGRES_URL to run the Postgres pass")
        store = open_postgres(POSTGRES_URL, clock=clock, create=True)
        _truncate(store)
    try:
        yield store, clock
    finally:
        store.dispose()


def _truncate(store: SqlStore) -> None:
    from sqlalchemy import text

    with store.engine.begin() as connection:
        connection.execute(text(f"TRUNCATE {TABLES} RESTART IDENTITY CASCADE"))


async def _new_run(store: SqlStore, **kw: Any) -> Run:
    base: dict[str, Any] = {"repo": "acme/app", "issue": 7, "title": "fix the thing"}
    base.update(kw)
    return await store.create(JobRequest(**base))


async def _move(store: SqlStore, run: Run, seq: int = 0, **update: Any) -> Run:
    """Mutate a run the only way the store allows: through a checkpointed transition."""
    moved = run.model_copy(update=update)
    checkpoint = Checkpoint(run_id=run.run_id, seq=seq, state=run.state, next_state=moved.state)
    return await store.commit_transition(moved, checkpoint)


# ── #61: the lease, with an expiry column instead of a file descriptor ───────────
#
# The expectations here are lifted from tests/unit/test_kernel_lease.py. A backend that passed
# a softer suite would not be a drop-in replacement, and §26's whole premise is that it is one.


async def test_a_held_sql_lease_is_unavailable_but_not_an_error(backend: Backend) -> None:
    store, clock = backend
    leases = SqlLeaseBackend(store.engine, clock=clock)
    assert await leases.acquire("run:1", ttl_s=60, holder="w1") is not None
    assert await leases.acquire("run:1", ttl_s=60, holder="w2") is None


async def test_an_expired_sql_lease_is_reclaimable_by_any_host(backend: Backend) -> None:
    """The point of the column: liveness is a timestamp, not a live file descriptor.

    ``flock`` cannot express this. A host that is unreachable rather than dead still holds its
    file lock and no other host can see that — which is why the shell needs a 20-minute
    staleness guess (``agent-pipeline.sh:370-414``).
    """
    store, clock = backend
    leases = SqlLeaseBackend(store.engine, clock=clock)
    assert await leases.acquire("run:1", ttl_s=60, holder="host-a") is not None
    clock.advance(61)
    assert await leases.acquire("run:1", ttl_s=60, holder="host-b") is not None


async def test_a_takeover_makes_the_old_holders_renew_fail(backend: Backend) -> None:
    """Two holders each believing they own a run is worse than one holder losing it."""
    store, clock = backend
    leases = SqlLeaseBackend(store.engine, clock=clock)
    stale = await leases.acquire("run:1", ttl_s=60, holder="host-a")
    assert stale is not None
    clock.advance(61)
    assert await leases.acquire("run:1", ttl_s=60, holder="host-b") is not None
    assert await leases.renew(stale) is False


async def test_release_only_removes_your_own_lease(backend: Backend) -> None:
    """A late release from a superseded holder must not free the new holder's lease."""
    store, clock = backend
    leases = SqlLeaseBackend(store.engine, clock=clock)
    first = await leases.acquire("run:1", ttl_s=60, holder="host-a")
    assert first is not None
    clock.advance(61)
    second = await leases.acquire("run:1", ttl_s=60, holder="host-b")
    assert second is not None

    await leases.release(first)
    assert await leases.acquire("run:1", ttl_s=60, holder="host-c") is None, "host-b owns it"
    await leases.release(second)
    assert await leases.acquire("run:1", ttl_s=60, holder="host-c") is not None


async def test_the_manager_works_over_the_sql_backend_unchanged(backend: Backend) -> None:
    """The upgrade is mechanical, or it is not an upgrade path."""
    store, clock = backend
    leases = SqlLeaseBackend(store.engine, clock=clock)
    manager = LeaseManager(leases, clock=clock)
    async with manager.hold("run:1", ttl_s=30, holder="w1") as lease:
        assert lease is not None
    assert await leases.acquire("run:1", ttl_s=30, holder="w2") is not None


async def test_hold_releases_the_sql_lease_even_when_the_state_blows_up(
    backend: Backend,
) -> None:
    store, clock = backend
    leases = SqlLeaseBackend(store.engine, clock=clock)
    manager = LeaseManager(leases, clock=clock)
    with pytest.raises(RuntimeError):
        async with manager.hold("run:2", ttl_s=30, holder="w1") as lease:
            assert lease is not None
            raise RuntimeError("the state blew up")
    assert await leases.acquire("run:2", ttl_s=30, holder="w2") is not None


async def test_expired_lists_what_a_reaper_would_collect(backend: Backend) -> None:
    store, clock = backend
    leases = SqlLeaseBackend(store.engine, clock=clock)
    await leases.acquire("run:short", ttl_s=10, holder="w1")
    await leases.acquire("run:long", ttl_s=600, holder="w1")
    clock.advance(11)
    assert await leases.expired() == ["run:short"]


# ── #62: the queue as a query, and the worker that carries no state ──────────────


async def test_the_queue_skips_finished_and_deferred_runs(backend: Backend) -> None:
    store, clock = backend
    queue = SqlQueue(store.engine, clock=clock)

    ready = await _new_run(store, issue=1)
    deferred = await _new_run(store, issue=2)
    done = await _new_run(store, issue=3)

    from datetime import timedelta

    await _move(
        store,
        deferred,
        status=RunStatus.DEFERRED,
        defer_until=clock.now() + timedelta(seconds=600),
    )
    await _move(store, done, state=State.COMPLETE, disposition=Disposition.MERGED)

    claimed = await queue.claim(worker_id="w1", limit=10)
    assert [c.run_id for c in claimed] == [ready.run_id]
    assert await queue.depth() == 1, (
        "depth counts work that is ready. A claim does not remove it — advancing the run does, "
        "which is why depth is what an autoscaler reads and a claim count is not."
    )

    clock.advance(601)
    assert await queue.depth() == 2, "a deferred run becomes ready when its timer expires"


async def test_claiming_touches_the_row_so_one_worker_does_not_spin(backend: Backend) -> None:
    """Without this, a worker re-claims the same run forever between machine advances."""
    store, clock = backend
    queue = SqlQueue(store.engine, clock=clock)
    first = await _new_run(store, issue=1)
    clock.advance(1)
    second = await _new_run(store, issue=2)

    clock.advance(5)  # time passes between creation and dispatch, as it does in a fleet
    one = await queue.claim(worker_id="w1", limit=1)
    two = await queue.claim(worker_id="w1", limit=1)
    assert one[0].run_id == first.run_id, "oldest first — the queue is FIFO by design"
    assert two[0].run_id == second.run_id, "and the touched row went to the back"


async def test_the_queue_filters_by_repo_so_a_fleet_can_shard(backend: Backend) -> None:
    store, clock = backend
    queue = SqlQueue(store.engine, clock=clock)
    await _new_run(store, repo="acme/app", issue=1)
    other = await _new_run(store, repo="acme/infra", issue=2)
    claimed = await queue.claim(worker_id="w1", limit=10, repo="acme/infra")
    assert [c.run_id for c in claimed] == [other.run_id]
    assert await queue.depth(repo="acme/app") == 1, "the other shard's work is not this shard's"


async def test_the_claim_carries_the_per_state_attempt_count(backend: Backend) -> None:
    """Per-state, not summed: the budgets in §10 are per-state budgets."""
    store, clock = backend
    queue = SqlQueue(store.engine, clock=clock)
    run = await _new_run(store, issue=1)
    counters = run.counters.bump("plan_attempts", 2).bump("implement_attempts", 5)
    await _move(store, run, state=State.ANALYSE, counters=counters)

    claimed = await queue.claim(worker_id="w1", limit=1)
    assert claimed[0].attempts == 2, "the ANALYSE budget is not spent by IMPLEMENT attempts"
    assert claimed[0].state is State.ANALYSE


async def test_the_queue_will_not_offer_a_run_another_worker_is_holding(
    backend: Backend,
) -> None:
    """The protocol says "skipping anything another worker is holding". This is that.

    ``SKIP LOCKED`` alone only separates workers whose transactions overlap. Two claims a
    millisecond apart both see an unlocked row, and the second worker burns a whole dispatch
    discovering the lease already belongs to someone else.
    """
    store, clock = backend
    queue = SqlQueue(store.engine, clock=clock)
    leases = SqlLeaseBackend(store.engine, clock=clock)

    held = await _new_run(store, issue=1)
    free = await _new_run(store, issue=2)
    assert await leases.acquire(run_lease_key(held.run_id), ttl_s=900, holder="w1") is not None

    claimed = await queue.claim(worker_id="w2", limit=10)
    assert [c.run_id for c in claimed] == [free.run_id]
    assert await queue.depth() == 1, "a held run is not queue depth — nobody is waiting on it"


async def test_a_run_whose_holder_stopped_renewing_returns_to_the_queue(
    backend: Backend,
) -> None:
    """Exact, not heuristic. The expiry column is what lets the queue re-offer without guessing."""
    store, clock = backend
    queue = SqlQueue(store.engine, clock=clock)
    leases = SqlLeaseBackend(store.engine, clock=clock)

    run = await _new_run(store, issue=1)
    await leases.acquire(run_lease_key(run.run_id), ttl_s=60, holder="w1")
    assert await queue.claim(worker_id="w2", limit=10) == []

    clock.advance(61)
    assert [c.run_id for c in await queue.claim(worker_id="w2", limit=10)] == [run.run_id]


async def test_a_fleet_of_workers_advances_each_run_exactly_once(backend: Backend) -> None:
    """Claim and lease composed, which is the only form in which either is a guarantee.

    This is the shell's rotated-flock dance (``agent-pipeline.sh``) reduced to two mechanisms
    that are each testable on their own — and here, tested together, because the failure mode
    they exist to prevent is two agents pushing to one branch.

    Note what is *not* claimed: that one dispatch round drains the queue. Two workers claiming
    the same run within the same instant is normal, and the loser does nothing and exits. The
    guarantee is "never twice", not "always on the first try" — a scheduler dispatches again.
    """
    store, clock = backend
    subgraphs = {state: _Subgraph(state.value) for state in State}
    registry = Registry()
    for state, subgraph in subgraphs.items():
        registry.bind(state, subgraph)

    runs = [await _new_run(store, issue=n) for n in range(6)]
    leases = LeaseManager(SqlLeaseBackend(store.engine, clock=clock), clock=clock)

    def _worker(name: str) -> Worker:
        deps = Deps(
            store=store,
            registry=registry,
            leases=leases,
            breaker=CircuitBreaker(DEFAULT_BUDGET, CostTracker(clock=clock), clock=clock),
            clock=clock,
        )
        return Worker(deps=deps, queue=SqlQueue(store.engine, clock=clock), worker_id=name, batch=3)

    queue = SqlQueue(store.engine, clock=clock)
    for _ in range(6):  # a scheduler dispatching repeatedly, which is what one does
        if await queue.depth() == 0:
            break
        await asyncio.gather(*(_worker(f"w{n}").work() for n in range(4)))

    seen = subgraphs[State.PREPARE].seen
    assert len(seen) == len(set(seen)), "no run was advanced twice"
    assert sorted(seen) == sorted(r.run_id for r in runs), "and every run was advanced once"
    assert await queue.depth() == 0, "the queue drains"


@pytest.mark.skipif(not POSTGRES_URL, reason="SKIP LOCKED needs a real Postgres")
async def test_skip_locked_steps_over_a_row_another_transaction_holds() -> None:
    """The primitive itself, against a genuinely held row lock — not an incidental race.

    ``SKIP LOCKED`` *is* the work-stealing mechanism the shell builds by hand out of rotated
    per-issue flocks (§25). Without it this call would block on the held row until the other
    transaction ended, which is why the assertion is wrapped in a timeout: a queue that blocks
    behind one slow worker is the failure this clause exists to prevent.
    """
    from sqlalchemy import text

    assert POSTGRES_URL
    clock = FrozenClock()
    store = open_postgres(POSTGRES_URL, clock=clock, create=True)
    _truncate(store)
    try:
        queue = SqlQueue(store.engine, clock=clock)
        assert queue.uses_skip_locked

        locked = await _new_run(store, issue=1)
        free = await _new_run(store, issue=2)

        connection = store.engine.connect()
        transaction = connection.begin()
        try:
            connection.execute(
                text("SELECT run_id FROM runs WHERE run_id = :id FOR UPDATE"),
                {"id": locked.run_id},
            )
            claimed = await asyncio.wait_for(queue.claim(worker_id="w2", limit=10), timeout=15)
            assert [c.run_id for c in claimed] == [free.run_id]
        finally:
            transaction.rollback()
            connection.close()
    finally:
        store.dispose()


def test_sqlite_declares_its_fallback_rather_than_pretending(tmp_path: Path) -> None:
    """A fallback nobody knows about is how "it works on my machine" starts."""
    store = open_sqlite(tmp_path / "q.db")
    try:
        assert SqlQueue(store.engine).uses_skip_locked is False
    finally:
        store.dispose()


@dataclass
class _Subgraph:
    state_name: str
    seen: list[str] = field(default_factory=list)

    async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
        run = getattr(ctx, "run", ctx)
        self.seen.append(run.run_id)
        return Outcome.ok(SubgraphResult(signal=Signal.ADVANCE))


def _deps(store: SqlStore, clock: FrozenClock) -> tuple[Deps, dict[State, _Subgraph]]:
    subgraphs = {state: _Subgraph(state.value) for state in State}
    registry = Registry()
    for state, subgraph in subgraphs.items():
        registry.bind(state, subgraph)
    deps = Deps(
        store=store,
        registry=registry,
        leases=LeaseManager(MemoryLeaseBackend(clock=clock), clock=clock),
        breaker=CircuitBreaker(DEFAULT_BUDGET, CostTracker(clock=clock), clock=clock),
        clock=clock,
    )
    return deps, subgraphs


async def test_a_worker_claims_advances_and_exits(backend: Backend) -> None:
    """Single-pass: no internal loop, no local state, no affinity to a run."""
    store, clock = backend
    deps, subgraphs = _deps(store, clock)
    run = await _new_run(store, issue=1)

    worker = Worker(deps=deps, queue=SqlQueue(store.engine, clock=clock), worker_id="w1")
    report = await worker.work()

    assert report.claimed == [run.run_id]
    assert not report.idle
    assert subgraphs[State.PREPARE].seen == [run.run_id]


async def test_a_worker_with_nothing_to_do_reports_idle_rather_than_failing(
    backend: Backend,
) -> None:
    """An autoscaler reads depth; a worker that errored on an empty queue would read as broken."""
    store, clock = backend
    deps, _ = _deps(store, clock)
    worker = Worker(deps=deps, queue=SqlQueue(store.engine, clock=clock), worker_id="w1")
    report = await worker.work()
    assert report.idle and report.claimed == []


async def test_a_worker_killed_mid_run_leaves_it_resumable_by_any_other(
    backend: Backend,
) -> None:
    """The recovery story, and the reason a worker may hold no local state.

    A killed worker renews nothing. Its lease expires at a time every other host can compute,
    the queue re-offers the run, and the next worker resumes from the last checkpoint — the
    same run, not a fresh one. No reaper, no staleness guess, no operator.
    """
    store, clock = backend
    deps, subgraphs = _deps(store, clock)
    run = await _new_run(store, issue=1)
    queue = SqlQueue(store.engine, clock=clock)

    # A worker that took the lease and then died: acquired, never renewed, never released.
    dead = SqlLeaseBackend(store.engine, clock=clock)
    assert await dead.acquire(run_lease_key(run.run_id), ttl_s=900, holder="w-dead") is not None

    assert await queue.claim(worker_id="w2", limit=10) == [], "not while its holder may return"

    clock.advance(901)
    deps.leases = LeaseManager(SqlLeaseBackend(store.engine, clock=clock), clock=clock)
    report = await Worker(deps=deps, queue=queue, worker_id="w2").work()

    assert report.claimed == [run.run_id]
    assert subgraphs[State.PREPARE].seen == [run.run_id]
    resumed = await store.load(run.run_id)
    assert resumed is not None and resumed.run_id == run.run_id, "the same run, not a new one"


async def test_local_fan_out_is_starting_the_process_more_than_once(tmp_path: Path) -> None:
    """§14.3's job contract: a worker needs a run id and configuration, so this is all it takes.

    Real processes, not mocks — the claim being tested is about process lifecycle, and a mock
    would only prove that ``asyncio`` was called.
    """
    import sys

    from ai_harness.workers.backends.subprocess import SubprocessBackend

    marker = tmp_path / "seen"
    script = tmp_path / "worker.py"
    script.write_text(
        "import sys, pathlib\n"
        "with pathlib.Path(sys.argv[1]).open('a') as fh:\n"
        "    fh.write(sys.argv[2] + '\\n')\n"
    )
    backend = SubprocessBackend(
        command=[sys.executable, str(script), str(marker), "{worker_id}"], workers=3, prefix="w"
    )
    exits = await backend.fan_out()

    assert [e.ok for e in exits] == [True, True, True]
    assert sorted(marker.read_text().split()) == ["w-0", "w-1", "w-2"]


async def test_a_worker_that_dies_is_reported_not_raised() -> None:
    """One worker dying must not take the healthy ones with it — the lease already recovers it."""
    import sys

    from ai_harness.workers.backends.subprocess import SubprocessBackend

    backend = SubprocessBackend(
        command=[sys.executable, "-c", "import sys; sys.exit(3)"], workers=2
    )
    exits = await backend.fan_out()
    assert [e.returncode for e in exits] == [3, 3]
    assert not any(e.ok for e in exits)


async def test_a_command_that_does_not_exist_is_an_exit_code_not_a_traceback() -> None:
    from ai_harness.workers.backends.subprocess import SubprocessBackend

    exits = await SubprocessBackend(command=["/nonexistent/agent", "work"], workers=1).fan_out()
    assert exits[0].returncode == 127 and not exits[0].ok


# ── #63: GitLab — the second forge, and therefore the proof the seam is one ──────


def _gitlab(handler: Any) -> GitLabForge:
    return GitLabForge(
        project="acme/app",
        token="t",
        client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )


def test_the_gitlab_transport_mapping_matches_the_github_one() -> None:
    """Same categories from the same situations, or the router's behaviour forks per provider."""
    assert _map_response(httpx.Response(429, headers={"retry-after": "12"})).category is (
        ErrorCategory.RATE_LIMITED
    )
    assert _map_response(httpx.Response(401)).category is ErrorCategory.AUTH
    assert _map_response(httpx.Response(503)).category is ErrorCategory.TRANSIENT
    assert _map_response(httpx.Response(409, text="conflict")).category is (
        ErrorCategory.REPO_CONFLICT
    )
    assert _map_response(httpx.Response(204)).is_ok


def test_a_gitlab_rate_limit_does_not_consume_budget() -> None:
    limited = _map_response(httpx.Response(429, headers={"retry-after": "12"}))
    assert not limited.budget_consuming
    assert limited.error is not None and limited.error.retry_after_s == 12


def test_a_gitlab_404_carries_its_status_so_callers_can_treat_it_as_absent() -> None:
    outcome = _map_response(httpx.Response(404))
    assert outcome.error is not None and outcome.error.details["status"] == 404


async def test_a_missing_gitlab_token_is_auth_and_never_dispatches() -> None:
    result = await GitLabForge(project="acme/app", token="").get_issue(1)
    assert result.category is ErrorCategory.AUTH


async def test_the_project_path_is_url_encoded() -> None:
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        return httpx.Response(200, json={"iid": 1, "title": "t", "state": "opened"})

    await _gitlab(handler).get_issue(1)
    assert "projects/acme%2Fapp/issues/1" in seen[0]


async def test_gitlab_vocabulary_stops_at_the_adapter() -> None:
    """``iid``, ``opened`` and ``notes`` are GitLab's words. Nothing above this file learns them."""

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.params["state"] == "opened", "the protocol says 'open'"
        return httpx.Response(
            200,
            json=[
                {
                    "iid": 42,
                    "id": 900042,
                    "title": "fix the thing",
                    "description": "body",
                    "labels": ["agent:ready"],
                    "state": "opened",
                    "web_url": "https://gitlab.com/acme/app/-/issues/42",
                }
            ],
        )

    issues = (await _gitlab(handler).list_issues(state="open")).unwrap()
    assert issues[0].number == 42, "the iid is the number a human sees"
    assert issues[0].state == "open"
    assert issues[0].body == "body", "description is a GitLab word too"


async def test_a_lost_gitlab_comment_response_updates_rather_than_duplicates() -> None:
    """The same idempotency contract as GitHub, because it is a harness property."""
    notes: list[dict[str, Any]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(200, json=notes)
        if request.method == "POST":
            import json as _json

            note = {
                "id": 1,
                "body": _json.loads(request.read())["body"],
                "author": {"username": "bot"},
            }
            notes.append(note)
            return httpx.Response(201, json=note)
        import json as _json

        notes[0]["body"] = _json.loads(request.read())["body"]
        return httpx.Response(200, json=notes[0])

    forge = _gitlab(handler)
    await forge.comment(42, "gate report", key="run-1:validate")
    await forge.comment(42, "gate report, round 2", key="run-1:validate")
    assert len(notes) == 1, "a retry after a lost response must not duplicate"
    assert "round 2" in notes[0]["body"], "it updated the note it found"


async def test_an_unkeyed_gitlab_comment_does_duplicate_which_is_why_keys_exist() -> None:
    notes: list[dict[str, Any]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        notes.append({"id": len(notes) + 1})
        return httpx.Response(201, json={"id": len(notes), "body": "x"})

    forge = _gitlab(handler)
    await forge.comment(42, "hello")
    await forge.comment(42, "hello")
    assert len(notes) == 2


async def test_gitlab_merged_ness_is_asked_of_the_refs_not_a_state_string() -> None:
    """A rebase-and-fast-forward leaves no merge commit and no ``merged`` state."""

    def handler(request: httpx.Request) -> httpx.Response:
        assert "repository/compare" in str(request.url)
        return httpx.Response(200, json={"commits": []})

    assert (await _gitlab(handler).is_merged("feat/x", base_ref="main")).unwrap() is True


async def test_gitlab_reports_unmerged_when_the_head_has_commits_the_base_lacks() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"commits": [{"id": "abc"}]})

    assert (await _gitlab(handler).is_merged("feat/x", base_ref="main")).unwrap() is False


async def test_a_gitlab_mr_that_already_exists_is_not_created_twice() -> None:
    posts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal posts
        row = {"iid": 7, "id": 700, "source_branch": "feat/x", "state": "opened"}
        if request.method == "GET":
            return httpx.Response(200, json=[row])
        posts += 1
        return httpx.Response(201, json=row)

    forge = _gitlab(handler)
    created = await forge.create_mr(
        head_ref="feat/x", base_ref="main", title="t", body="b", issue=42
    )
    assert created.unwrap().number == 7
    assert created.unwrap().id == "700", "the global id is preserved alongside the iid"
    assert posts == 0, "it asked before it acted"


async def test_removing_an_absent_gitlab_label_is_not_a_failure() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"message": "404 Not found"})

    assert (await _gitlab(handler).remove_label(42, "agent:ready")).is_ok


def test_the_gitlab_adapter_satisfies_the_same_protocol_as_github() -> None:
    """Structural, not nominal — but a drift here surfaces at runtime, not at import."""
    from ai_harness.providers.forge.protocol import Forge

    forge: Forge = GitLabForge(project="acme/app", token="t")
    assert forge.name == "gitlab"


# ── #64: telemetry that never costs a run ────────────────────────────────────────


def _span(**kw: Any) -> Span:
    base: dict[str, Any] = {
        "span_id": "abc",
        "run_id": "run-1",
        "name": "llm.call",
        "template_id": "reviewer-v1",
        "prompt_sha256": "deadbeef",
        "prompt_bytes": 4096,
        "round": 4,
        "attempt": 1,
    }
    base.update(kw)
    return Span(**base)


def test_no_prompt_text_is_exported() -> None:
    """§21.4. The digest identifies the prompt; the text is the thing that leaks."""
    exported = attributes_for(_span())
    assert exported["harness.template_id"] == "reviewer-v1"
    assert exported["harness.prompt_sha256"] == "deadbeef"
    assert exported["harness.prompt_bytes"] == 4096
    assert "prompt" not in {k.rsplit(".", 1)[-1] for k in exported} - {
        "prompt_sha256",
        "prompt_bytes",
    }
    assert not any(isinstance(v, str) and len(v) > 128 for v in exported.values())


def test_round_and_attempt_stay_separate_axes() -> None:
    """A fourth review round and a fourth attempt at round one are different failures."""
    exported = attributes_for(_span(round=4, attempt=1))
    assert exported["harness.round"] == 4
    assert exported["harness.attempt"] == 1


def test_an_unreachable_collector_degrades_to_the_local_sink() -> None:
    """Losing a span is survivable. Losing a run because a span failed to export is not."""
    fallback = JsonlSpanSink(Logger())
    sink = OTelSpanSink(endpoint="http://127.0.0.1:1/v1/traces", fallback=fallback)
    sink.enabled = False  # whatever the reason: no SDK, no collector, broken exporter
    sink.emit(_span(usd=Decimal("0.60")))
    assert [s.run_id for s in fallback.kept] == ["run-1"]


def test_a_sink_that_raises_cannot_fail_the_caller() -> None:
    @dataclass
    class Exploding:
        def emit(self, span: Span) -> None:
            raise RuntimeError("collector on fire")

    tracer = Tracer(sinks=[Exploding()], run_id="run-1")
    with tracer.span("validate", state="VALIDATE"):
        pass  # the span is emitted on exit; if it propagated, the run would die here


def test_a_span_records_the_failure_and_still_re_raises() -> None:
    captured: list[Span] = []

    @dataclass
    class Capture:
        def emit(self, span: Span) -> None:
            captured.append(span)

    tracer = Tracer(sinks=[Capture()], run_id="run-1")
    with pytest.raises(ValueError), tracer.span("implement", state="IMPLEMENT"):
        raise ValueError("nope")
    assert captured[0].outcome == "error:ValueError"
    assert captured[0].duration_s is not None


def test_the_otel_sink_is_optional_and_its_absence_is_a_supported_state() -> None:
    sink = OTelSpanSink(endpoint="http://127.0.0.1:1/v1/traces")
    assert isinstance(sink.enabled, bool)
    sink.emit(_span())  # no fallback configured either — still must not raise


# ── metrics: the four questions an operator asks ─────────────────────────────────


def _gate(name: str, status: GateStatus, **kw: Any) -> GateResult:
    base: dict[str, Any] = {"name": name, "raw_status": status, "required": True}
    base.update(kw)
    return GateResult(**base)


def _run_row(run_id: str, **kw: Any) -> Run:
    base: dict[str, Any] = {
        "run_id": run_id,
        "request": JobRequest(repo="acme/app", issue=1, title="t"),
        "state": State.REVIEW,
    }
    base.update(kw)
    return Run(**base)


def test_metrics_answer_what_is_stuck() -> None:
    metrics = Metrics()
    metrics.record_runs(
        [
            _run_row("a", status=RunStatus.RUNNING),
            _run_row("b", status=RunStatus.BLOCKED),
            _run_row("c", status=RunStatus.BLOCKED),
            _run_row("d", state=State.COMPLETE, disposition=Disposition.MERGED),
        ]
    )
    snapshot = metrics.snapshot()
    assert snapshot['harness_runs_active{state="REVIEW",status="blocked"}'] == 2
    assert snapshot['harness_runs_finished_total{disposition="merged"}'] == 1
    assert snapshot['harness_runs_active{state="COMPLETE",status="running"}'] == 0, (
        "an empty position is reported as zero, not omitted — absence reads as 'no data'"
    )


def test_cost_is_per_merged_change_not_per_run() -> None:
    """Cost per run flatters whichever engine escalates more: escalation is cheap and useless."""
    runs = [
        _run_row(
            "a", state=State.COMPLETE, disposition=Disposition.MERGED, spend_usd=Decimal("6.00")
        ),
        _run_row(
            "b", state=State.COMPLETE, disposition=Disposition.ESCALATED, spend_usd=Decimal("2.00")
        ),
    ]
    assert Metrics().cost_per_merged(runs) == Decimal("8.00")
    assert Metrics().cost_per_merged([runs[1]]) == Decimal(0), "no merges, no division by zero"


def test_metrics_answer_what_is_flaky() -> None:
    metrics = Metrics()
    metrics.record_gate_report(
        GateReport(
            results=[
                _gate("pytest", GateStatus.PASS, duration_s=30.0),
                _gate("mypy", GateStatus.FAIL),
            ],
            wall_clock_s=42.0,
            gate_time_s=84.0,
        )
    )
    snapshot = metrics.snapshot()
    assert snapshot['harness_gate_results_total{gate="mypy",required="true",status="fail"}'] == 1
    assert snapshot["harness_suite_speedup"] == 2.0

    flaky = GateReport(results=[_gate("pytest", GateStatus.FAIL)], wall_clock_s=1.0)
    green = GateReport(results=[_gate("pytest", GateStatus.PASS)], wall_clock_s=1.0)
    assert gate_pass_rate([green, green, flaky], "pytest") == pytest.approx(2 / 3)
    assert gate_pass_rate([], "pytest") == 0.0


def test_metrics_answer_what_is_broken_upstream() -> None:
    """One glance, instead of a hundred runs deferred for reasons nobody has connected."""
    metrics = Metrics()
    metrics.record_breakers({"forge:github.com": "open", "llm:anthropic": "closed"})
    snapshot = metrics.snapshot()
    assert snapshot['harness_breaker_open{dependency="forge:github.com"}'] == 1.0
    assert snapshot['harness_breaker_open{dependency="llm:anthropic"}'] == 0.0


def test_the_prometheus_rendering_is_parseable() -> None:
    metrics = Metrics()
    metrics.increment("harness_runs_finished_total", disposition="MERGED")
    metrics.record_cost(Decimal("1.25"), repo="acme/app", state="REVIEW", model="opus")
    metrics.record_state_duration(State.REVIEW, 12.0, outcome="ok")
    text = metrics.render_prometheus()
    for line in text.strip().splitlines():
        name, value = line.rsplit(" ", 1)
        assert name and float(value) >= 0
    assert "harness_state_duration_seconds_count" in text
    assert 'harness_cost_usd_total{model="opus",repo="acme/app",state="REVIEW"} 1.25' in text
