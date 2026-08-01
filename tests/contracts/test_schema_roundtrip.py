"""Issue #8 — every contract round-trips, and malformed payloads are rejected, not coerced."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from pydantic import BaseModel, ValidationError

from ai_harness.kernel.outcome import ErrorCategory, ErrorRecord
from ai_harness.schemas.approval import ApprovalDecision, ApprovalRequest
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.deploy import DeploymentResult
from ai_harness.schemas.enums import Capability, GateStatus, Severity, State, TriageClass, Verdict
from ai_harness.schemas.errors import ErrorInfo
from ai_harness.schemas.gates import GateProfile, GateReport, GateResult, GateSpec
from ai_harness.schemas.job import JobRequest
from ai_harness.schemas.plan import PlannedChange, TriageDecision, WorkPlan
from ai_harness.schemas.policy import Policy
from ai_harness.schemas.profile import RepoProfile
from ai_harness.schemas.review import Finding, ReviewResult
from ai_harness.schemas.run import Counters, Run
from ai_harness.schemas.seed import SeedResult
from ai_harness.schemas.telemetry import Span

SAMPLES: list[BaseModel] = [
    JobRequest(repo="acme/app", issue=7, title="fix the thing"),
    RepoProfile(name="acme/app", workspaces=["backend"]),
    Policy(),
    Counters(review_rounds=2),
    Run(run_id="r1", request=JobRequest(repo="acme/app")),
    GateSpec(name="unit"),
    GateProfile(gates=[GateSpec(name="unit")]),
    GateResult(name="unit", raw_status=GateStatus.PASS),
    GateReport(results=[GateResult(name="unit", raw_status=GateStatus.PASS)]),
    Finding(severity=Severity.MINOR, title="typo", file="a.py", line=3),
    ReviewResult(verdict=Verdict.COMMENT),
    WorkPlan(summary="do the thing", changes=[PlannedChange(path="a.py", intent="add guard")]),
    TriageDecision(triage_class=TriageClass.SELF),
    Checkpoint(run_id="r1", seq=0, state=State.PREPARE, next_state=State.ANALYSE),
    ErrorInfo(category=ErrorCategory.TRANSIENT, message="blip"),
    Span(span_id="s1", run_id="r1", name="review"),
    DeploymentResult(),
    SeedResult(),
    ApprovalRequest(
        approval_id="a1",
        run_id="r1",
        state=State.IMPLEMENT,
        capability=Capability.MODIFY_CI,
        reason="touched .github/workflows",
        requested_at=datetime(2026, 1, 1, tzinfo=UTC),
    ),
    ApprovalDecision(approval_id="a1", approved=False, decided_by="hmei"),
]


@pytest.mark.parametrize("model", SAMPLES, ids=lambda m: type(m).__name__)
def test_every_contract_round_trips(model: BaseModel) -> None:
    restored = type(model).model_validate_json(model.model_dump_json())
    assert restored.model_dump() == model.model_dump()


def test_error_record_survives_the_kernel_boundary() -> None:
    record = ErrorRecord(
        category=ErrorCategory.ENVIRONMENT,
        message="docker daemon unreachable",
        remedy="start docker",
        dependency="container:docker",
    )
    restored = ErrorInfo.from_record(record).to_record()
    assert restored == record


@settings(max_examples=100, deadline=None)
@given(payload=st.dictionaries(st.text(max_size=8), st.integers(), max_size=5))
def test_malformed_payloads_raise_rather_than_coerce(payload: dict[str, int]) -> None:
    with pytest.raises(ValidationError):
        GateResult.model_validate(payload)


def test_unknown_enum_values_are_rejected() -> None:
    with pytest.raises(ValidationError):
        GateResult.model_validate({"name": "unit", "raw_status": "greenish"})
    with pytest.raises(ValidationError):
        ReviewResult.model_validate({"verdict": "lgtm"})


def test_checkpoints_are_immutable() -> None:
    checkpoint = Checkpoint(run_id="r1", seq=1, state=State.REVIEW, next_state=State.INTEGRATE)
    with pytest.raises(ValidationError):
        checkpoint.seq = 2  # type: ignore[misc]


def test_checkpoints_never_carry_prompt_text() -> None:
    fields = set(Checkpoint.model_fields)
    assert "prompt" not in fields and "prompt_text" not in fields
    assert {"prompt_sha256", "prompt_bytes", "template_id"} <= fields
