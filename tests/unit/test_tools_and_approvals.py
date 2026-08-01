"""Issues #47 and #48 — the capability broker, the policy engine and approvals."""

from __future__ import annotations

from datetime import timedelta
from pathlib import Path
from typing import Any

import pytest

from ai_harness.config import load_policy
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.policies.approval import ApprovalGateway, ApprovalState
from ai_harness.policies.engine import PolicyEngine, Request
from ai_harness.schemas.enums import Capability, Decision, RunStatus, State
from ai_harness.schemas.policy import Policy
from ai_harness.tools.broker import ToolBroker, ToolCall
from ai_harness.tools.registry import ToolRegistry

ROOT = Path(__file__).resolve().parents[2]


def _engine(policy: Policy | None = None) -> PolicyEngine:
    return PolicyEngine(policy=policy or Policy())


async def _ok(**_: Any) -> Outcome[str]:
    return Outcome.ok("done")


def _broker(tmp_path: Path, **kw: Any) -> ToolBroker:
    broker = ToolBroker(
        policy=kw.pop("policy", _engine()),
        workspace=tmp_path,
        run_id="r1",
        state="IMPLEMENT",
        **kw,
    )
    for name in ToolRegistry().tools:
        broker.handle(name, _ok)
    return broker


# ── the policy engine ────────────────────────────────────────────────────────────


def test_an_unknown_capability_is_denied() -> None:
    verdict = PolicyEngine(policy=Policy(capabilities={})).evaluate(
        Request(capability=Capability.GIT_PUSH)
    )
    assert verdict.denied


def test_a_deny_cannot_be_softened_by_context() -> None:
    """Otherwise every deny is one clever argument away from an allow."""
    verdict = _engine().evaluate(
        Request(capability=Capability.DEPLOY_PROD, reason="it is urgent", paths=["README.md"])
    )
    assert verdict.decision is Decision.DENY


def test_a_protected_path_escalates_an_allow_to_an_approval() -> None:
    verdict = _engine().evaluate(
        Request(capability=Capability.WRITE_WORKSPACE, paths=["app/svc.py", "infra/main.tf"])
    )
    assert verdict.needs_approval and verdict.evidence == ["infra/main.tf"]


def test_writing_ci_config_is_modify_ci_whatever_tool_did_it() -> None:
    """Resolving the capability from what is touched stops a generic write being a bypass."""
    verdict = _engine().evaluate(
        Request(capability=Capability.WRITE_WORKSPACE, paths=[".github/workflows/ci.yml"])
    )
    assert verdict.capability is Capability.MODIFY_CI
    assert verdict.needs_approval


def test_writing_a_migration_is_modify_migrations() -> None:
    verdict = _engine().evaluate(
        Request(capability=Capability.WRITE_WORKSPACE, paths=["backend/alembic/versions/x.py"])
    )
    assert verdict.capability is Capability.MODIFY_MIGRATIONS


def test_an_ordinary_write_is_allowed() -> None:
    verdict = _engine().evaluate(Request(capability=Capability.WRITE_WORKSPACE, paths=["app/x.py"]))
    assert verdict.allowed


def test_the_readonly_policy_permits_nothing_mutating() -> None:
    engine = PolicyEngine(policy=load_policy("readonly", root=ROOT))
    for capability in (Capability.WRITE_WORKSPACE, Capability.GIT_PUSH, Capability.FORGE_MERGE):
        assert engine.evaluate(Request(capability=capability)).denied


# ── the registry ─────────────────────────────────────────────────────────────────


def test_shell_is_whatever_it_runs() -> None:
    """Mapping the tool alone would make `shell` a way to do anything."""
    registry = ToolRegistry()
    assert registry.capability_for("shell", command="pytest -q") is Capability.RUN_TESTS
    assert (
        registry.capability_for("shell", command="npm install left-pad") is Capability.INSTALL_DEPS
    )
    assert registry.capability_for("shell", command="curl https://evil") is Capability.NETWORK
    assert registry.capability_for("shell", command="git push origin main") is Capability.GIT_PUSH


def test_an_unregistered_tool_has_no_capability() -> None:
    assert ToolRegistry().capability_for("rm-rf") is None


# ── the broker ───────────────────────────────────────────────────────────────────


async def test_a_permitted_call_executes_and_is_audited(tmp_path: Path) -> None:
    broker = _broker(tmp_path)
    result = await broker.invoke(ToolCall(tool="fs.read", arguments={"path": "a.py"}))
    assert result.is_ok
    record = broker.audit.for_run("r1")[0]
    assert record.decision is Decision.ALLOW and record.tool == "fs.read"


async def test_an_unregistered_tool_is_denied_not_defaulted(tmp_path: Path) -> None:
    result = await _broker(tmp_path).invoke(ToolCall(tool="rm-rf", arguments={}))
    assert result.category is ErrorCategory.POLICY
    assert result.error is not None and "not a registered tool" in result.error.message


async def test_a_denial_is_never_retried(tmp_path: Path) -> None:
    result = await _broker(tmp_path).invoke(ToolCall(tool="deploy.prod"))
    assert result.category is ErrorCategory.POLICY
    assert not result.retryable, "a policy decision is not a transient condition"


async def test_an_approval_requirement_parks_with_its_evidence(tmp_path: Path) -> None:
    broker = _broker(tmp_path)
    result = await broker.invoke(
        ToolCall(tool="fs.write", paths=[".github/workflows/ci.yml"], arguments={"path": "x"})
    )
    assert result.category is ErrorCategory.NEEDS_HUMAN
    assert result.error is not None
    assert result.error.details["capability"] == "modify_ci"
    assert ".github/workflows/ci.yml" in result.error.details["evidence"]


async def test_read_only_mode_is_enforced_not_requested(tmp_path: Path) -> None:
    """ANALYSE has read-only access; the prompt is not what stops it writing."""
    broker = _broker(tmp_path, read_only=True)
    assert (await broker.invoke(ToolCall(tool="fs.read", arguments={"path": "a"}))).is_ok
    denied = await broker.invoke(ToolCall(tool="fs.write", arguments={"path": "a"}))
    assert denied.category is ErrorCategory.POLICY
    assert denied.error is not None and "read-only" in denied.error.message


async def test_a_path_that_escapes_the_workspace_is_refused(tmp_path: Path) -> None:
    result = await _broker(tmp_path).invoke(
        ToolCall(tool="fs.write", paths=["../../etc/passwd"], arguments={"path": "x"})
    )
    assert result.is_err and result.category is ErrorCategory.POLICY


async def test_a_permitted_tool_with_no_handler_is_an_error_not_a_no_op(tmp_path: Path) -> None:
    broker = ToolBroker(policy=_engine(), workspace=tmp_path, run_id="r1")
    result = await broker.invoke(ToolCall(tool="fs.read", arguments={"path": "a"}))
    assert result.category is ErrorCategory.POLICY
    assert result.error is not None and "no implementation" in result.error.message


async def test_every_decision_is_audited_including_the_refusals(tmp_path: Path) -> None:
    broker = _broker(tmp_path)
    await broker.invoke(ToolCall(tool="fs.read", arguments={"path": "a"}))
    await broker.invoke(ToolCall(tool="deploy.prod"))
    await broker.invoke(ToolCall(tool="fs.write", paths=["infra/main.tf"], arguments={}))
    assert len(broker.audit.for_run("r1")) == 3
    assert len(broker.audit.denials()) == 2


async def test_audited_arguments_are_redacted(tmp_path: Path) -> None:
    broker = _broker(tmp_path)
    await broker.invoke(ToolCall(tool="http.get", arguments={"api_key": "sk-ant-secret"}))
    record = broker.audit.for_run("r1")[0]
    assert "sk-ant-secret" not in str(record.as_dict())


# ── the approval gateway ─────────────────────────────────────────────────────────


@pytest.fixture
def gateway(tmp_path: Path) -> tuple[ApprovalGateway, FrozenClock]:
    clock = FrozenClock()
    store = open_sqlite(tmp_path / "approvals.db", clock=clock)
    return ApprovalGateway(store=store, clock=clock), clock


async def _request(gateway: ApprovalGateway) -> str:
    outcome = await gateway.request(
        run_id="r1",
        state=State.IMPLEMENT,
        capability=Capability.MODIFY_CI,
        reason="the diff touches .github/workflows/ci.yml",
        evidence=[".github/workflows/ci.yml"],
    )
    return outcome.unwrap().approval_id


async def test_a_request_without_a_reason_is_refused(
    gateway: tuple[ApprovalGateway, FrozenClock],
) -> None:
    """A request nobody can answer is not a request."""
    engine, _clock = gateway
    result = await engine.request(
        run_id="r1", state=State.IMPLEMENT, capability=Capability.MODIFY_CI, reason=""
    )
    assert result.is_err


async def test_pending_then_approved(gateway: tuple[ApprovalGateway, FrozenClock]) -> None:
    engine, _clock = gateway
    approval_id = await _request(engine)

    pending = (await engine.poll(approval_id)).unwrap()
    assert pending.state is ApprovalState.PENDING
    assert pending.run_status is RunStatus.AWAITING_APPROVAL
    assert pending.request.evidence == [".github/workflows/ci.yml"]

    await engine.decide(approval_id, approved=True, by="hmei", reason="reviewed the workflow")
    approved = (await engine.poll(approval_id)).unwrap()
    assert approved.may_proceed and approved.run_status is RunStatus.RUNNING


async def test_a_denial_is_terminal(gateway: tuple[ApprovalGateway, FrozenClock]) -> None:
    engine, _clock = gateway
    approval_id = await _request(engine)
    await engine.decide(approval_id, approved=False, by="hmei", reason="not this way")

    denied = (await engine.poll(approval_id)).unwrap()
    assert denied.state is ApprovalState.DENIED
    assert denied.terminal and denied.run_status is RunStatus.PARKED_TERMINAL
    assert "not this way" in denied.reason


async def test_an_unanswered_approval_defers_at_24h_and_escalates_at_72h(
    gateway: tuple[ApprovalGateway, FrozenClock],
) -> None:
    """Q14: an approval nobody answers is a decision not to proceed."""
    engine, clock = gateway
    approval_id = await _request(engine)

    clock.advance(timedelta(hours=23).total_seconds())
    assert (await engine.poll(approval_id)).unwrap().state is ApprovalState.PENDING

    clock.advance(timedelta(hours=2).total_seconds())
    deferred = (await engine.poll(approval_id)).unwrap()
    assert deferred.state is ApprovalState.TIMED_OUT_DEFERRED
    assert deferred.run_status is RunStatus.DEFERRED

    clock.advance(timedelta(hours=48).total_seconds())
    escalated = (await engine.poll(approval_id)).unwrap()
    assert escalated.state is ApprovalState.TIMED_OUT_ESCALATED
    assert escalated.terminal


async def test_a_late_answer_still_wins_over_the_timeout(
    gateway: tuple[ApprovalGateway, FrozenClock],
) -> None:
    """The timeout is computed, not applied: an answer at 80h is still an answer."""
    engine, clock = gateway
    approval_id = await _request(engine)
    clock.advance(timedelta(hours=80).total_seconds())
    await engine.decide(approval_id, approved=True, by="hmei")
    assert (await engine.poll(approval_id)).unwrap().may_proceed


async def test_polling_an_unknown_approval_is_an_error(
    gateway: tuple[ApprovalGateway, FrozenClock],
) -> None:
    engine, _clock = gateway
    assert (await engine.poll("nope")).is_err


async def test_pending_requests_are_listable_for_an_operator(
    gateway: tuple[ApprovalGateway, FrozenClock],
) -> None:
    engine, _clock = gateway
    await _request(engine)
    pending = await engine.pending_for()
    assert len(pending) == 1 and pending[0].capability is Capability.MODIFY_CI
