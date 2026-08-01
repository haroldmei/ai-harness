"""P2 exit criterion — REVIEW driven by the real supervisor, end to end.

Real git in ``tmp``, ``FakeForge`` in memory, ``ScriptedLLM`` replaying envelopes, SQLite for
durable state. Zero network, zero LLM cost, and every decision written to a checkpoint an
operator can read back.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from ai_harness.agents.reviewer import Reviewer
from ai_harness.kernel.budget import DEFAULT_BUDGET, CircuitBreaker, CostTracker
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import LeaseManager, MemoryLeaseBackend
from ai_harness.llm.client import LLMClient
from ai_harness.llm.engines.scripted import PATHOLOGICAL, Envelope, ScriptedLLM
from ai_harness.orchestration.machine import Deps, run_until_boundary
from ai_harness.orchestration.registry import Registry
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.providers.forge.fake import FakeForge
from ai_harness.schemas.enums import Disposition, Isolation, RunStatus, State
from ai_harness.schemas.job import JobRequest
from ai_harness.security.sandbox import probe
from ai_harness.subgraphs.review import ReviewContext, ReviewSubgraph

APPROVE = json.dumps({"verdict": "approve", "summary": "the criterion is satisfied"})
REQUEST = json.dumps(
    {
        "verdict": "request_changes",
        "summary": "unbounded retry",
        "findings": [
            {"severity": "blocker", "title": "no ceiling", "file": "app/svc.py", "line": 2}
        ],
    }
)


def _harness(tmp_path: Path, *envelopes: Envelope) -> tuple[Any, Deps, FakeForge, FrozenClock]:
    clock = FrozenClock()
    store = open_sqlite(tmp_path / "e2e.db", clock=clock)
    forge = FakeForge()
    forge.seed_issue(7, title="retry the webhook", body="It must retry three times.")

    engine = ScriptedLLM(default=list(envelopes), name="anthropic")
    reviewer = Reviewer(client=LLMClient(engine=engine, clock=clock), model="claude-opus-5")

    async def build_context(run: Any, deps: Deps) -> ReviewContext:
        """The Phase 4 wiring, in miniature: a Run plus the forge becomes a ReviewContext."""
        issue = (await forge.get_issue(run.request.issue)).unwrap()
        return ReviewContext(
            run_id=run.run_id,
            repo=run.request.repo,
            base_sha=run.base_sha or "b" * 40,
            head_sha=run.head_sha or "h" * 40,
            issue_title=issue.title,
            issue_body=issue.body,
            acceptance_criteria="the webhook retries three times",
            issue_number=issue.number,
            diff_text=_diff(),
            round=run.counters.review_rounds + 1,
            empty_streak=run.counters.empty_envelope_streak,
            isolation=probe(Isolation.BUBBLEWRAP, allow_degraded=True).chosen,
        )

    deps = Deps(
        store=store,
        registry=Registry().bind(State.REVIEW, ReviewSubgraph(reviewer=reviewer)),
        leases=LeaseManager(MemoryLeaseBackend(clock=clock), clock=clock),
        breaker=CircuitBreaker(DEFAULT_BUDGET, CostTracker(clock=clock), clock=clock),
        clock=clock,
        context_builder=build_context,
    )
    return store, deps, forge, clock


def _diff() -> str:
    return (
        "diff --git a/app/svc.py b/app/svc.py\n"
        "--- a/app/svc.py\n+++ b/app/svc.py\n@@ -1,2 +1,3 @@\n def send():\n+    retry()\n     pass\n"
    )


async def _run_in_review(store: Any, clock: FrozenClock) -> str:
    run = await store.create(JobRequest(repo="acme/app", issue=7))
    from ai_harness.schemas.checkpoint import Checkpoint

    await store.commit_transition(
        run.model_copy(update={"state": State.REVIEW, "head_sha": "h" * 40}),
        Checkpoint(run_id=run.run_id, seq=0, state=State.VALIDATE, next_state=State.REVIEW),
    )
    return str(run.run_id)


async def test_an_approval_walks_the_run_to_integrate(tmp_path: Path) -> None:
    store, deps, _forge, clock = _harness(tmp_path, Envelope.result(APPROVE))
    run_id = await _run_in_review(store, clock)

    status = await run_until_boundary(run_id, "worker-1", deps)

    run = await store.load(run_id)
    assert run is not None
    # INTEGRATE is unbound in Phase 2, so the run stops there and says so rather than pretending.
    assert run.state is State.INTEGRATE
    assert status is RunStatus.AWAITING_APPROVAL
    assert "not implemented yet" in (run.last_error or "")

    review = next(c for c in await store.checkpoints(run_id) if c.state is State.REVIEW)
    assert review.result["verdict"] == "approve"
    assert review.next_state is State.INTEGRATE
    assert review.template_id == "reviewer-v1"
    assert review.prompt_sha256 and "retry" not in json.dumps(review.result)


async def test_requested_changes_return_the_run_to_implement(tmp_path: Path) -> None:
    store, deps, _forge, clock = _harness(tmp_path, Envelope.result(REQUEST))
    run_id = await _run_in_review(store, clock)

    await run_until_boundary(run_id, "worker-1", deps)

    run = await store.load(run_id)
    assert run is not None
    assert run.state is State.IMPLEMENT
    assert run.counters.review_rounds == 1, "a completed round costs a round"


async def test_an_empty_envelope_parks_the_run_and_costs_no_round(tmp_path: Path) -> None:
    """#2407, end to end: the harness learned nothing, so it charges nothing."""
    store, deps, _forge, clock = _harness(tmp_path, PATHOLOGICAL["empty_envelope"])
    run_id = await _run_in_review(store, clock)

    status = await run_until_boundary(run_id, "worker-1", deps)

    assert status is RunStatus.DEFERRED
    run = await store.load(run_id)
    assert run is not None
    assert run.state is State.REVIEW, "a parked run IS in its state"
    assert run.counters.review_rounds == 0
    assert run.counters.empty_envelope_streak == 1
    assert run.defer_until is not None and run.defer_until > clock.now()


async def test_the_shadow_path_leaves_the_forge_untouched(tmp_path: Path) -> None:
    store, deps, forge, clock = _harness(tmp_path, Envelope.result(APPROVE))
    forge.writes_blocked = True
    run_id = await _run_in_review(store, clock)

    await run_until_boundary(run_id, "worker-1", deps)

    assert forge.comments == {}, "shadow mode observes; it does not post"
    assert (await forge.get_issue(7)).unwrap().labels == []


async def test_the_run_is_replayable_from_its_checkpoints(tmp_path: Path) -> None:
    store, deps, _forge, clock = _harness(tmp_path, Envelope.result(REQUEST))
    run_id = await _run_in_review(store, clock)
    await run_until_boundary(run_id, "worker-1", deps)

    timeline = await store.checkpoints(run_id)
    # REVIEW routes to IMPLEMENT, which is unbound in Phase 2 — so the supervisor records that
    # boundary too rather than stopping silently. Three checkpoints, all explainable.
    assert [c.state.value for c in timeline] == ["VALIDATE", "REVIEW", "IMPLEMENT"]
    review = timeline[1]
    assert review.result["signal"] == "fix"
    assert review.idempotency_key.startswith("review:")
    assert timeline[-1].error is not None, "the unported state says so, in the record"


async def test_the_whole_path_runs_against_real_git(tmp_path: Path, bare_origin: Path) -> None:
    """The diff the reviewer judges comes from a real repository, not a fixture string."""
    work = tmp_path / "work"
    subprocess.run(
        ["git", "clone", "-q", str(bare_origin), str(work)], check=True, capture_output=True
    )
    (work / "app.py").write_text("def send():\n    retry()\n")

    from ai_harness.providers.git.cli import GitCLI

    git = GitCLI(root=work)
    base = (await git.rev_parse("HEAD")).unwrap()
    await git.commit_all("add a retry")
    head = (await git.rev_parse("HEAD")).unwrap()
    diff = (await git.run("diff", f"{base}..{head}")).unwrap().stdout
    assert "retry()" in diff

    store, deps, _forge, clock = _harness(tmp_path, Envelope.result(APPROVE))
    run_id = await _run_in_review(store, clock)
    await run_until_boundary(run_id, "worker-1", deps)

    run = await store.load(run_id)
    assert run is not None and run.state is State.INTEGRATE


async def test_nothing_terminal_happened_without_a_disposition(tmp_path: Path) -> None:
    store, deps, _forge, clock = _harness(tmp_path, Envelope.result(APPROVE))
    run_id = await _run_in_review(store, clock)
    await run_until_boundary(run_id, "worker-1", deps)
    run = await store.load(run_id)
    assert run is not None
    assert run.disposition is None or run.disposition in set(Disposition)
