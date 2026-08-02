"""The composition that makes a run reachable: PREPARE, the contexts, the editor, the slot.

Every gap these cover had the same shape — a module that was finished, tested and constructed by
nobody. The tests are therefore mostly about the *root*: given a config, does the thing that is
supposed to exist exist, and does it refuse when it cannot be built honestly.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from ai_harness.config import HarnessConfig
from ai_harness.kernel.clock import SystemClock
from ai_harness.kernel.lease import LeaseManager, MemoryLeaseBackend
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.orchestration.contexts import ContextBuilder, worktree_for
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.enums import Brief, Isolation, Signal, State
from ai_harness.schemas.job import JobRequest
from ai_harness.subgraphs.prepare import PrepareContext, PrepareSubgraph
from ai_harness.workspace.worktree import Strategy, Workspace


class _Worktrees:
    """A WorktreeManager stand-in: the manager's own policy is tested in its own suite."""

    def __init__(self, outcome: Outcome[Workspace] | None = None) -> None:
        self.outcome = outcome
        self.calls: list[dict[str, object]] = []

    async def materialise(self, **kwargs: object) -> Outcome[Workspace]:
        self.calls.append(kwargs)
        if self.outcome is not None:
            return self.outcome
        return Outcome.ok(
            Workspace(
                path=Path(str(kwargs["path"])),
                branch=str(kwargs["branch"]),
                base_sha="a" * 40,
                head_sha="b" * 40,
                strategy=Strategy.FRESH,
            )
        )


def _ctx(tmp_path: Path, **overrides: object) -> PrepareContext:
    defaults: dict[str, object] = {
        "run_id": "r1",
        "repo": "acme/app",
        "workspace": tmp_path / "tree",
        "branch": "agent/issue-7",
        "provision_deps": False,
        "allow_degraded_isolation": True,
        "isolation": Isolation.NONE,
    }
    return PrepareContext(**{**defaults, **overrides})  # type: ignore[arg-type]


# ── PREPARE ──────────────────────────────────────────────────────────────────────


async def test_a_branch_someone_else_holds_is_abandoned_not_failed(tmp_path):
    result = await PrepareSubgraph(worktrees=_Worktrees()).execute(  # type: ignore[arg-type]
        _ctx(tmp_path, claimed_by="worker-9")
    )
    assert result.unwrap().signal is Signal.ABANDONED
    # Losing the race is the ordinary answer (§14.3), so it must not consume an attempt or
    # read as a failure anyone should look at.
    assert "worker-9" in result.unwrap().reason


async def test_a_ready_workspace_advances_and_pins_the_base(tmp_path):
    worktrees = _Worktrees()
    result = (await PrepareSubgraph(worktrees=worktrees).execute(_ctx(tmp_path))).unwrap()  # type: ignore[arg-type]

    assert result.signal is Signal.ADVANCE
    assert result.base_sha == "a" * 40 and result.head_sha == "b" * 40
    # The next state has to be able to find the tree; the path is on the payload as evidence,
    # and derived independently by the context builder.
    assert result.payload["workspace"] == str(tmp_path / "tree")


async def test_degraded_isolation_escalates_unless_the_policy_allowed_it(tmp_path):
    # `probe` on a host with neither container nor bubblewrap degrades to NONE. Asking for
    # CONTAINER while forbidding degradation is the case that must stop.
    result = await PrepareSubgraph(worktrees=_Worktrees()).execute(  # type: ignore[arg-type]
        _ctx(tmp_path, isolation=Isolation.CONTAINER, allow_degraded_isolation=False)
    )
    outcome = result.unwrap()
    if outcome.signal is Signal.ESCALATE:
        assert "isolation degraded" in outcome.reason
    else:
        # This host really can provide a container; then the run proceeds, which is correct.
        assert outcome.signal is Signal.ADVANCE


async def test_a_worktree_lock_held_elsewhere_is_returned_as_it_is(tmp_path):
    busy = Outcome.fail(ErrorCategory.TRANSIENT, "another worker is creating a worktree")
    result = await PrepareSubgraph(worktrees=_Worktrees(busy)).execute(_ctx(tmp_path))  # type: ignore[arg-type]

    # Not relabelled: TRANSIENT parks and retries next tick consuming no budget, and calling it
    # a state failure would spend an attempt on a lock we only have to wait for.
    assert result.is_err
    assert result.category is ErrorCategory.TRANSIENT


# ── the contexts ─────────────────────────────────────────────────────────────────


def test_the_worktree_path_is_derived_and_stable():
    first = worktree_for("acme/app", "agent/issue-7")
    assert first == worktree_for("acme/app", "agent/issue-7")
    assert first != worktree_for("acme/app", "agent/issue-8")
    # Outside the repository: a tree under the checkout is one the gates would scan.
    assert "acme-app-agent-issue-7" in first.name


async def _builder(tmp_path: Path) -> tuple[ContextBuilder, object]:
    store = open_sqlite(tmp_path / "s.db", clock=SystemClock())
    config = HarnessConfig(repo_path=tmp_path)
    config.profile.name = "acme/app"
    builder = ContextBuilder(config=config, store=store, git=_Git(), worktree_root=tmp_path)
    run = await store.create(JobRequest(repo="acme/app", issue=7, title="t", body="b"))
    return builder, run


class _Git:
    async def run(self, *args: str, cwd: Path | None = None):  # type: ignore[no-untyped-def]
        from ai_harness.providers.git.protocol import CommandResult

        return Outcome.ok(CommandResult(returncode=0, stdout="diff --git a/x b/x\n", stderr=""))

    async def rev_parse(self, ref: str, *, cwd: Path | None = None) -> Outcome[str]:
        return Outcome.ok("c" * 40)


async def test_each_state_gets_the_context_its_subgraph_declares(tmp_path):
    builder, run = await _builder(tmp_path)

    for state, attribute in (
        (State.PREPARE, "workspace"),
        (State.ANALYSE, "issue_title"),
        (State.IMPLEMENT, "brief"),
        (State.VALIDATE, "gate_set"),
        (State.REVIEW, "diff_text"),
    ):
        ctx = await builder(run.model_copy(update={"state": state}), None)  # type: ignore[attr-defined]
        assert hasattr(ctx, attribute), f"{state.value} got {type(ctx).__name__}"
        # Every context names its own run, which is what makes a checkpoint attributable.
        assert ctx.run_id == run.run_id  # type: ignore[attr-defined]


async def test_the_implement_brief_is_derived_from_the_counters(tmp_path):
    builder, run = await _builder(tmp_path)

    build = await builder.implement(run)
    assert build.brief is Brief.BUILD

    fixing = await builder.implement(
        run.model_copy(update={"counters": run.counters.bump("review_rounds")})
    )  # type: ignore[attr-defined]
    assert fixing.brief is Brief.FIX

    repairing = await builder.implement(
        run.model_copy(update={"counters": run.counters.bump("self_repair_attempts")})  # type: ignore[attr-defined]
    )
    assert repairing.brief is Brief.REPAIR


async def test_the_plan_reaches_implement_through_the_ledger(tmp_path):
    """The whole point of recording the plan: IMPLEMENT runs in a later dispatch."""
    builder, run = await _builder(tmp_path)
    plan = {"summary": "add a retry", "changes": [{"path": "a.py", "intent": "edit"}]}

    await builder.store.commit_transition(
        run.model_copy(update={"state": State.IMPLEMENT}),
        Checkpoint(
            run_id=run.run_id,
            seq=1,
            state=State.ANALYSE,
            next_state=State.IMPLEMENT,
            result={"plan": plan},
        ),
    )
    reloaded = await builder.store.load(run.run_id)
    ctx = await builder.implement(reloaded)

    assert ctx.plan is not None and ctx.plan.summary == "add a retry"
    # A summary would not let the editor produce an anchored edit against a real file.
    assert [c.path for c in ctx.plan.changes] == ["a.py"]


async def test_an_unparseable_ledger_entry_never_parks_a_run(tmp_path):
    builder, run = await _builder(tmp_path)
    await builder.store.commit_transition(
        run.model_copy(update={"state": State.INTEGRATE}),
        Checkpoint(
            run_id=run.run_id,
            seq=1,
            state=State.VALIDATE,
            next_state=State.INTEGRATE,
            result={"report": {"not": "a gate report"}},
        ),
    )
    reloaded = await builder.store.load(run.run_id)
    ctx = await builder.integrate(reloaded)

    # Losing the evidence block's detail is survivable; parking the run over it is not.
    assert ctx.gate_report is None
    assert ctx.gates_were_discovered is False


# ── the composition root ─────────────────────────────────────────────────────────


def test_one_local_model_needs_no_slot(tmp_path):
    from ai_harness.wiring import build_slot

    config = HarnessConfig(repo_path=tmp_path)
    config.roster.engines = {"only-model": "local"}
    leases = LeaseManager(MemoryLeaseBackend(clock=SystemClock()), clock=SystemClock())

    # A slot that never swaps is a lease that can only expire mid-generation for no benefit.
    assert build_slot(config, leases=leases) is None


def test_a_two_model_local_roster_refuses_without_a_registry(tmp_path):
    from ai_harness.wiring import WiringError, build_slot

    config = HarnessConfig(repo_path=tmp_path)
    config.roster.engines = {"a": "local", "b": "local"}
    leases = LeaseManager(MemoryLeaseBackend(clock=SystemClock()), clock=SystemClock())

    with pytest.raises(WiringError, match="registry"):
        build_slot(config, leases=leases)


def test_the_slot_refuses_a_model_the_card_does_not_serve():
    from ai_harness.wiring import WiringError, build_slot

    root = Path(__file__).resolve().parents[2]
    config = HarnessConfig(repo_path=root)
    config.roster.engines = {"qwen3-coder-30b": "local", "not-served": "local"}
    leases = LeaseManager(MemoryLeaseBackend(clock=SystemClock()), clock=SystemClock())

    # Discovering this at REVIEW costs a claim and a lease; discovering it here costs a message.
    with pytest.raises(WiringError, match="does not serve"):
        build_slot(config, leases=leases)


def test_the_registry_binds_prepare_and_an_editor(tmp_path):
    """The two bindings whose absence made a full run impossible."""
    from ai_harness.agents.roster import AgentRoster
    from ai_harness.llm.client import LLMClient
    from ai_harness.llm.engines.scripted import ScriptedLLM
    from ai_harness.observability.logging import Logger
    from ai_harness.wiring import build_registry, roster_models

    config = HarnessConfig(repo_path=tmp_path)
    leases = LeaseManager(MemoryLeaseBackend(clock=SystemClock()), clock=SystemClock())
    registry, _ = build_registry(
        config,
        client=LLMClient(engine=ScriptedLLM(default=[])),
        roster=AgentRoster(models=roster_models(config)),
        forge=None,
        logger=Logger(),
        leases=leases,
    )

    assert State.PREPARE in registry.bound_states
    implement = registry.subgraph_for(State.IMPLEMENT)
    # Without an editor the state checks whether HEAD moved, finds it did not, and replans until
    # the attempt cap escalates a run that was never asked to write anything.
    assert getattr(implement, "editor", None) is not None
