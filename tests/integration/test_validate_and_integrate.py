"""Issues #51–#56, #59, #78 — the runner, integrity, VALIDATE, INTEGRATE, tick, evidence."""

from __future__ import annotations

import json
import os
import subprocess
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest

from ai_harness.agents.implementer import (
    Implementer,
    ImplementerBrief,
    filesystem_handlers,
)
from ai_harness.agents.implementer import (
    build_prompt as implementer_prompt,
)
from ai_harness.kernel.budget import DEFAULT_BUDGET, CircuitBreaker, CostTracker
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import LeaseManager, MemoryLeaseBackend
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.client import LLMClient
from ai_harness.llm.engines.scripted import Envelope, ScriptedLLM
from ai_harness.observability.reports import EvidenceBlock, may_enable_ff_only
from ai_harness.orchestration.machine import Deps
from ai_harness.orchestration.reconcile import Reconciler
from ai_harness.orchestration.registry import Registry
from ai_harness.persistence.sqlite import open_sqlite
from ai_harness.policies.engine import PolicyEngine
from ai_harness.providers.forge.fake import FakeForge
from ai_harness.providers.git.cli import GitCLI
from ai_harness.quality import integrity
from ai_harness.quality.runner import GateRunner, Slot
from ai_harness.schemas.enums import (
    GateStatus,
    MergeStrategy,
    RunStatus,
    Signal,
    State,
    Tier,
    Verdict,
)
from ai_harness.schemas.gates import GateProfile, GateReport, GateResult, GateSpec
from ai_harness.schemas.job import JobRequest
from ai_harness.schemas.policy import Policy
from ai_harness.schemas.review import ReviewResult
from ai_harness.subgraphs.integrate import ConflictResolver, IntegrateContext, IntegrateSubgraph
from ai_harness.subgraphs.validate import ValidateContext, ValidateSubgraph
from ai_harness.tools.broker import ToolBroker
from ai_harness.workers.tick import Ticker, drained

ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "harness",
    "GIT_AUTHOR_EMAIL": "harness@example.invalid",
    "GIT_COMMITTER_NAME": "harness",
    "GIT_COMMITTER_EMAIL": "harness@example.invalid",
}


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True, env=ENV
    ).stdout.strip()


def _result(name: str, status: GateStatus = GateStatus.PASS, **kw: Any) -> GateResult:
    return GateResult(name=name, raw_status=status, required=True, **kw)


def _report(*results: GateResult, **kw: Any) -> GateReport:
    return GateReport(results=list(results), **kw)


# ── the runner (#51) ─────────────────────────────────────────────────────────────


def _profile(*specs: GateSpec, **kw: Any) -> GateProfile:
    return GateProfile(tier=Tier.LAUNCH, gates=list(specs), full_set=[s.name for s in specs], **kw)


async def test_gates_run_and_are_interpreted(tmp_path: Path) -> None:
    profile = _profile(
        GateSpec(name="typecheck", command=["true"], required_from_tier=Tier.TOY),
        GateSpec(name="lint", command=["false"], required_from_tier=Tier.TOY),
    )
    report = (await GateRunner(root=tmp_path, profile=profile).run()).unwrap()
    assert report.by_name("typecheck").status is GateStatus.PASS  # type: ignore[union-attr]
    assert report.by_name("lint").status is GateStatus.FAIL  # type: ignore[union-attr]
    assert not report.green


async def test_exit_77_on_a_required_gate_is_promoted(tmp_path: Path) -> None:
    profile = _profile(
        GateSpec(name="unit", command=["sh", "-c", "exit 77"], required_from_tier=Tier.TOY)
    )
    report = (await GateRunner(root=tmp_path, profile=profile).run()).unwrap()
    assert report.by_name("unit").promoted  # type: ignore[union-attr]


async def test_a_wedged_gate_is_killed_with_its_process_group(tmp_path: Path) -> None:
    """A bare kill orphans exactly the children that wedged the gate."""
    profile = _profile(
        GateSpec(
            name="e2e",
            command=["sh", "-c", "sleep 300 & sleep 300"],
            timeout_s=1,
            required_from_tier=Tier.TOY,
        )
    )
    report = (await GateRunner(root=tmp_path, profile=profile).run()).unwrap()
    result = report.by_name("e2e")
    assert result is not None and result.status is GateStatus.FAIL
    assert "process group was killed" in result.reason


async def test_a_named_gate_with_no_command_fails_loudly(tmp_path: Path) -> None:
    profile = _profile(GateSpec(name="contract", required_from_tier=Tier.TOY))
    report = (await GateRunner(root=tmp_path, profile=profile).run()).unwrap()
    assert report.by_name("contract").status is GateStatus.FAIL  # type: ignore[union-attr]


async def test_an_after_edge_skips_a_gate_whose_input_failed(tmp_path: Path) -> None:
    profile = _profile(
        GateSpec(name="unit", command=["false"], required_from_tier=Tier.TOY),
        GateSpec(name="coverage", command=["true"], after=["unit"], required_from_tier=Tier.TOY),
    )
    report = (await GateRunner(root=tmp_path, profile=profile).run()).unwrap()
    coverage = report.by_name("coverage")
    assert coverage is not None and "unit failed" in coverage.reason


def test_stack_slots_get_offset_port_bands_not_probed_ones() -> None:
    """Two runs probing from a shared base pick the same "free" port before either binds."""
    assert Slot(0).port_base == 20000
    assert Slot(1).port_base == 21000
    assert Slot(0).project != Slot(1).project
    assert Slot(2).env()["COMPOSE_PROJECT_NAME"] == "harness-2"


async def test_a_rerun_touches_only_the_named_gates(tmp_path: Path) -> None:
    marker = tmp_path / "ran"
    profile = _profile(
        GateSpec(name="unit", command=["false"], required_from_tier=Tier.TOY),
        GateSpec(
            name="lint",
            command=["sh", "-c", f"echo x >> {marker}; true"],
            required_from_tier=Tier.TOY,
        ),
    )
    runner = GateRunner(root=tmp_path, profile=profile)
    report = (await runner.run()).unwrap()
    before = marker.read_text().count("x")
    await runner.rerun(report, ["unit"])
    assert marker.read_text().count("x") == before, "a flake check is not a blanket retry"


# ── the anti-weakening check (#52) ───────────────────────────────────────────────


def test_a_deleted_test_is_detected() -> None:
    diff = (
        "diff --git a/tests/test_auth.py b/tests/test_auth.py\n"
        "--- a/tests/test_auth.py\n+++ b/tests/test_auth.py\n"
        "-def test_token_expiry():\n-    assert expired(token)\n"
    )
    found = integrity.check(diff)
    assert not found.clean
    assert "tests/test_auth.py::test_token_expiry" in found.deleted_tests


def test_a_newly_skipped_test_is_detected() -> None:
    diff = (
        "diff --git a/tests/test_auth.py b/tests/test_auth.py\n"
        "+@pytest.mark.skip(reason='flaky')\n+def test_token_expiry():\n"
    )
    assert integrity.check(diff).skipped_tests


def test_weakened_assertions_are_detected() -> None:
    diff = (
        "diff --git a/tests/test_svc.py b/tests/test_svc.py\n"
        "-    assert a == 1\n-    assert b == 2\n-    assert c == 3\n+    assert True\n"
    )
    assert integrity.check(diff).weakened_assertions


def test_a_lowered_coverage_floor_is_detected_but_a_raised_one_is_not() -> None:
    lowered = integrity.check(
        "diff --git a/pyproject.toml b/pyproject.toml\n-fail_under = 80\n+fail_under = 40\n"
    )
    raised = integrity.check(
        "diff --git a/pyproject.toml b/pyproject.toml\n-fail_under = 40\n+fail_under = 80\n"
    )
    assert lowered.loosened_config and not raised.loosened_config


def test_ci_modification_is_flagged_even_when_it_looks_innocent() -> None:
    diff = "diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml\n+  # tidy\n"
    assert integrity.check(diff).ci_modified


def test_a_legitimate_refactor_does_not_trip_the_check() -> None:
    """A false positive costs thirty seconds; the rule still has to be usable."""
    diff = (
        "diff --git a/tests/test_svc.py b/tests/test_svc.py\n"
        "-def test_old_name():\n-    assert send() == 1\n"
        "+def test_old_name():\n+    assert send() == 1\n+    assert retries() == 3\n"
    )
    assert integrity.check(diff).clean


def test_a_change_that_touches_no_tests_is_clean() -> None:
    assert integrity.check("diff --git a/app/svc.py b/app/svc.py\n+x = 1\n").clean


# ── VALIDATE (#53) ───────────────────────────────────────────────────────────────


class _Runner:
    def __init__(self, *reports: GateReport) -> None:
        self.reports = list(reports)
        self.calls = 0
        self.rerun_names: list[str] = []

    async def run(self, **_: Any) -> Outcome[GateReport]:
        self.calls += 1
        return Outcome.ok(self.reports[min(self.calls - 1, len(self.reports) - 1)])

    async def rerun(self, report: GateReport, names: list[str]) -> Outcome[GateReport]:
        self.rerun_names = names
        return Outcome.ok(self.reports[-1])


def _vctx(**kw: Any) -> ValidateContext:
    base: dict[str, Any] = {
        "run_id": "r1",
        "repo": "acme/app",
        "workspace": Path("/tmp"),
        "base_sha": "b" * 40,
        "head_sha": "h" * 40,
    }
    base.update(kw)
    return ValidateContext(**base)


async def test_green_gates_advance_to_review() -> None:
    runner = _Runner(_report(_result("unit")))
    result = await ValidateSubgraph(runner=runner).execute(_vctx())
    assert result.unwrap().signal is Signal.ADVANCE


async def test_a_weakened_test_parks_even_when_the_gates_are_green() -> None:
    """§19.5: any non-empty field blocks, regardless of how green the suite is."""
    runner = _Runner(_report(_result("unit")))
    diff = (
        "diff --git a/tests/test_auth.py b/tests/test_auth.py\n"
        "-def test_token_expiry():\n-    assert expired(token)\n"
    )
    result = await ValidateSubgraph(runner=runner).execute(_vctx(diff_text=diff))
    assert result.unwrap().signal is Signal.NEEDS_APPROVAL
    assert runner.calls == 0, "the gates need not even run to know this parks"


async def test_a_flake_is_confirmed_by_re_running_only_the_failed_gate() -> None:
    red = _report(_result("unit", GateStatus.FAIL, failing_tests=["a::b"]), _result("lint"))
    green = _report(_result("unit"), _result("lint"))
    runner = _Runner(red, green)
    result = await ValidateSubgraph(runner=runner).execute(_vctx())
    assert result.unwrap().signal is Signal.ADVANCE
    assert runner.rerun_names == ["unit"], "only the failure is re-run"
    assert "flake confirmed" in result.unwrap().reason


async def test_a_real_failure_on_a_green_base_routes_to_the_fixer() -> None:
    red = _report(_result("unit", GateStatus.FAIL, reason="E   AssertionError: expected 3"))
    result = await ValidateSubgraph(runner=_Runner(red, red)).execute(
        _vctx(base_is_green=True, confirm_flakes=False)
    )
    assert result.unwrap().signal is Signal.FIX
    assert result.unwrap().payload["fault"] == "self"


async def test_an_environmental_failure_defers_and_blames_nobody() -> None:
    red = _report(
        _result("integration", GateStatus.FAIL, reason="Cannot connect to the Docker daemon")
    )
    result = await ValidateSubgraph(runner=_Runner(red, red)).execute(_vctx(confirm_flakes=False))
    assert result.category is ErrorCategory.ENVIRONMENT
    assert not result.budget_consuming


async def test_environmental_deferral_is_bounded() -> None:
    red = _report(_result("integration", GateStatus.FAIL, reason="no space left on device"))
    result = await ValidateSubgraph(runner=_Runner(red, red)).execute(
        _vctx(env_defers=3, confirm_flakes=False)
    )
    assert result.category is ErrorCategory.NEEDS_HUMAN


async def test_self_repair_is_bounded() -> None:
    red = _report(_result("unit", GateStatus.FAIL, reason="E   AssertionError"))
    result = await ValidateSubgraph(runner=_Runner(red, red)).execute(
        _vctx(base_is_green=True, self_repairs=3, confirm_flakes=False)
    )
    assert result.category is ErrorCategory.NEEDS_HUMAN
    assert result.error is not None and "self-repair exhausted" in result.error.message


async def test_no_discovered_gates_escalates_rather_than_passing() -> None:
    result = await ValidateSubgraph(runner=_Runner(_report(no_gates_discovered=True))).execute(
        _vctx()
    )
    assert result.category is ErrorCategory.NEEDS_HUMAN


async def test_a_run_on_the_base_records_rather_than_consults(tmp_path: Path) -> None:
    """A red base can never forgive itself."""
    red = _report(_result("unit", GateStatus.FAIL, failing_tests=["a.py::t"]))
    result = await ValidateSubgraph(runner=_Runner(red)).execute(
        _vctx(on_base=True, baseline_dir=tmp_path)
    )
    assert result.unwrap().payload["recorded"] == 1
    assert (tmp_path / ("b" * 40) / "unit.json").exists()


async def test_an_inherited_failure_is_forgiven_but_still_shown(tmp_path: Path) -> None:
    from ai_harness.quality.baseline import BaselineStore

    BaselineStore(tmp_path).record("unit", "b" * 40, "FAILED a.py::t")
    red = _report(_result("unit", GateStatus.FAIL, failing_tests=["FAILED a.py::t"]))
    result = await ValidateSubgraph(runner=_Runner(red)).execute(_vctx(baseline_dir=tmp_path))
    assert result.unwrap().signal is Signal.ADVANCE
    assert result.unwrap().payload["inherited"] == ["unit"]


# ── the implementer (#78) ────────────────────────────────────────────────────────


def _broker(tmp_path: Path) -> ToolBroker:
    broker = ToolBroker(
        policy=PolicyEngine(policy=Policy()), workspace=tmp_path, run_id="r1", state="IMPLEMENT"
    )
    for name, handler in filesystem_handlers(tmp_path).items():
        broker.handle(name, handler)  # type: ignore[arg-type]
    return broker


def _implementer(tmp_path: Path, *envelopes: Envelope) -> Implementer:
    return Implementer(
        client=LLMClient(engine=ScriptedLLM(default=list(envelopes)), clock=FrozenClock()),
        model="claude-sonnet-5",
        broker=_broker(tmp_path),
        workspace=tmp_path,
        repo="acme/app",
    )


async def test_the_implementer_writes_through_the_broker(tmp_path: Path) -> None:
    envelope = Envelope.result(
        json.dumps(
            {
                "summary": "bound the retry",
                "edits": [{"path": "app/svc.py", "content": "x = 1\n", "intent": "cap it"}],
            }
        )
    )
    result = await _implementer(tmp_path, envelope).implement(ImplementerBrief())
    assert result.is_ok
    assert (tmp_path / "app" / "svc.py").read_text() == "x = 1\n"


async def test_an_edit_outside_the_workspace_is_refused(tmp_path: Path) -> None:
    """The broker refuses it; the prompt merely discourages it."""
    envelope = Envelope.result(
        json.dumps({"summary": "escape", "edits": [{"path": "../../etc/passwd", "content": "x"}]})
    )
    result = await _implementer(tmp_path, envelope).implement(ImplementerBrief())
    assert result.is_err and result.category is ErrorCategory.POLICY


async def test_editing_ci_config_parks_for_approval(tmp_path: Path) -> None:
    envelope = Envelope.result(
        json.dumps(
            {
                "summary": "tweak ci",
                "edits": [{"path": ".github/workflows/ci.yml", "content": "on: push\n"}],
            }
        )
    )
    result = await _implementer(tmp_path, envelope).implement(ImplementerBrief())
    assert result.category is ErrorCategory.NEEDS_HUMAN
    assert not (tmp_path / ".github").exists(), "nothing was written before the approval"


async def test_a_blocked_implementer_says_so_rather_than_half_doing_it(tmp_path: Path) -> None:
    envelope = Envelope.result(
        json.dumps({"summary": "cannot", "blocked": True, "blocked_reason": "the file is gone"})
    )
    result = await _implementer(tmp_path, envelope).implement(ImplementerBrief())
    assert result.category is ErrorCategory.NEEDS_HUMAN
    assert result.error is not None and "the file is gone" in result.error.message


def test_the_prompt_carries_the_harness_contract_verbatim() -> None:
    rendered = implementer_prompt(ImplementerBrief(), repo="acme/app").render()
    assert "LEAVE YOUR EDITS UNCOMMITTED" in rendered
    assert "git commit" in rendered and "git push" in rendered
    assert "may **not** delete, skip, weaken" in rendered


def test_all_three_briefs_share_one_prompt_family() -> None:
    from ai_harness.schemas.enums import Brief

    rendered = {
        brief: implementer_prompt(ImplementerBrief(brief=brief), repo="r").render()
        for brief in Brief
    }
    contract = "LEAVE YOUR EDITS UNCOMMITTED"
    assert all(contract in text for text in rendered.values())
    assert len(set(rendered.values())) == 3, "the brief is the only difference"


# ── INTEGRATE (#54, #55) ─────────────────────────────────────────────────────────


@pytest.fixture
def integration(tmp_path: Path, bare_origin: Path) -> tuple[Path, GitCLI, FakeForge, str]:
    work = tmp_path / "work"
    subprocess.run(
        ["git", "clone", "-q", str(bare_origin), str(work)], check=True, capture_output=True
    )
    base = _git(work, "rev-parse", "HEAD")
    return work, GitCLI(root=work), FakeForge(), base


def _ictx(work: Path, base: str, **kw: Any) -> IntegrateContext:
    defaults: dict[str, Any] = {
        "run_id": "r1",
        "repo": "acme/app",
        "workspace": work,
        "branch": "agent/issue-7",
        "base_ref": "main",
        "base_sha": base,
        "head_sha": "h" * 40,
        "gate_report": _report(_result("unit")),
        "review": ReviewResult(verdict=Verdict.APPROVE),
        "gates_were_discovered": True,
        "base_is_green": True,
    }
    defaults.update(kw)
    return IntegrateContext(**defaults)


async def test_mr_only_opens_a_request_and_stops(
    integration: tuple[Path, GitCLI, FakeForge, str],
) -> None:
    """Q1: the shipped default proposes; it does not land."""
    work, git, forge, base = integration
    result = await IntegrateSubgraph(git=git, forge=forge).execute(_ictx(work, base))
    assert result.unwrap().signal is Signal.DELIVERED
    assert len(forge.mrs) == 1


async def test_integration_is_idempotent_on_the_head_ref(
    integration: tuple[Path, GitCLI, FakeForge, str],
) -> None:
    """The provider-side MR id is the token: ask before acting, always."""
    work, git, forge, base = integration
    subgraph = IntegrateSubgraph(git=git, forge=forge)
    first = await subgraph.execute(_ictx(work, base))
    second = await subgraph.execute(_ictx(work, base))
    assert first.unwrap().payload["mr_number"] == second.unwrap().payload["mr_number"]
    assert len(forge.mrs) == 1


async def test_a_red_gate_report_refuses_to_integrate(
    integration: tuple[Path, GitCLI, FakeForge, str],
) -> None:
    work, git, forge, base = integration
    result = await IntegrateSubgraph(git=git, forge=forge).execute(
        _ictx(work, base, gate_report=_report(_result("unit", GateStatus.FAIL)))
    )
    assert result.category is ErrorCategory.NEEDS_HUMAN


async def test_conflict_markers_block_the_push(
    integration: tuple[Path, GitCLI, FakeForge, str],
) -> None:
    """Invariant 18 — a `main` was once fast-forwarded onto markers while logging MERGED."""
    work, git, forge, base = integration
    (work / "conflicted.py").write_text("<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n")
    _git(work, "add", "-A")
    result = await IntegrateSubgraph(git=git, forge=forge).execute(
        _ictx(work, base, strategy=MergeStrategy.FF_ONLY)
    )
    assert result.category is ErrorCategory.NEEDS_HUMAN
    assert result.error is not None and "conflict markers" in result.error.message


async def test_ff_only_is_refused_when_the_gates_were_inferred(
    integration: tuple[Path, GitCLI, FakeForge, str],
) -> None:
    work, git, forge, base = integration
    result = await IntegrateSubgraph(git=git, forge=forge).execute(
        _ictx(work, base, strategy=MergeStrategy.FF_ONLY, gates_were_discovered=False)
    )
    assert result.unwrap().signal is Signal.DELIVERED
    assert "inferred" in result.unwrap().payload["auto_merge_refused"]


async def test_ff_only_is_refused_without_an_approving_review(
    integration: tuple[Path, GitCLI, FakeForge, str],
) -> None:
    work, git, forge, base = integration
    result = await IntegrateSubgraph(git=git, forge=forge).execute(
        _ictx(work, base, strategy=MergeStrategy.FF_ONLY, review=None)
    )
    assert "no approving review" in result.unwrap().payload["auto_merge_refused"]


async def test_a_moved_base_re_gates_rather_than_forcing(
    integration: tuple[Path, GitCLI, FakeForge, str], tmp_path: Path, bare_origin: Path
) -> None:
    work, git, forge, base = integration
    other = tmp_path / "other"
    subprocess.run(
        ["git", "clone", "-q", str(bare_origin), str(other)], check=True, capture_output=True
    )
    (other / "theirs.py").write_text("t = 1\n")
    _git(other, "add", "-A")
    _git(other, "commit", "-m", "theirs")
    _git(other, "push", "-q", "origin", "main")

    (work / "ours.py").write_text("o = 1\n")
    await git.commit_all("ours")
    result = await IntegrateSubgraph(git=git, forge=forge).execute(
        _ictx(work, base, strategy=MergeStrategy.FF_ONLY)
    )
    assert result.unwrap().signal is Signal.REGATE
    assert _git(bare_origin, "rev-parse", "main") != (await git.rev_parse("HEAD")).unwrap()


async def test_the_resolver_is_not_believed_without_the_tree_agreeing(
    integration: tuple[Path, GitCLI, FakeForge, str],
) -> None:
    """A resolver that claims success while markers remain is overruled."""
    work, git, forge, base = integration  # noqa: RUF059

    async def lying_agent(ctx: Any, conflicts: list[str], attempt: int) -> Outcome[bool]:
        (work / "still_conflicted.py").write_text("<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n")
        _git(work, "add", "-A")
        return Outcome.ok(True)

    resolver = ConflictResolver(git=git, agent=lying_agent, max_attempts=2)
    resolved = await resolver.resolve(_ictx(work, base), ["app.py"])
    assert resolved.unwrap() is False, "the tree is the evidence, not the verdict"


async def test_a_resolver_with_no_agent_gives_up_cleanly(
    integration: tuple[Path, GitCLI, FakeForge, str],
) -> None:
    work, git, _forge, base = integration
    assert (await ConflictResolver(git=git).resolve(_ictx(work, base), ["a.py"])).unwrap() is False


# ── the evidence block and FF_ONLY (#59) ─────────────────────────────────────────


def test_the_evidence_block_shows_promotions_and_forgiveness() -> None:
    report = _report(
        _result("unit"),
        _result("integration", GateStatus.SKIP),
        _result("e2e", GateStatus.FAIL, inherited=True),
        wall_clock_s=512,
        gate_time_s=1847,
    )
    rendered = EvidenceBlock(
        run_id="0193f2a1",
        report=report,
        review=ReviewResult(
            verdict=Verdict.APPROVE,
            findings=[],
        ),
        spend_usd=Decimal("2.29"),
        models={"reviewer": "claude-opus-5", "implementer": "claude-sonnet-5"},
        isolation="bubblewrap",
    ).render()
    assert "3.6x parallel" in rendered
    assert "promoted" in rendered and "inherited from the base" in rendered
    assert "claude-opus-5" in rendered and "$2.29" in rendered


def test_the_block_names_what_the_reviewer_could_not_see() -> None:
    rendered = EvidenceBlock(
        run_id="r1",
        report=_report(_result("unit")),
        diff_complete=False,
        elided_files=["app/huge.py"],
    ).render()
    assert "partial review" in rendered and "app/huge.py" in rendered


def test_the_block_flags_an_unisolated_run() -> None:
    rendered = EvidenceBlock(
        run_id="r1", report=_report(_result("unit")), isolation="none"
    ).render()
    assert "no isolation" in rendered


def test_the_block_redacts_secrets_that_reached_a_gate_log() -> None:
    report = _report(_result("unit", GateStatus.FAIL, reason="failed with ghp_" + "A" * 36))
    rendered = EvidenceBlock(run_id="r1", report=report).render()
    assert "ghp_A" not in rendered


def test_the_regression_comparison_names_only_added_failures() -> None:
    base = _report(_result("unit", GateStatus.FAIL))
    head = _report(_result("unit", GateStatus.FAIL), _result("lint", GateStatus.FAIL))
    rendered = EvidenceBlock(run_id="r1", report=head, base_report=base).render()
    assert "ADDS: `lint`" in rendered


def test_ff_only_requires_declared_gates_and_a_green_base() -> None:
    green = _report(_result("unit"))
    assert may_enable_ff_only(green, base_is_green=True) is None
    assert may_enable_ff_only(green, base_is_green=None) is not None
    inferred = _report(_result("unit"), profile_discovered=True)
    assert may_enable_ff_only(inferred, base_is_green=True) is not None


# ── tick and reconcile (#56) ─────────────────────────────────────────────────────


@pytest.fixture
def ticker(tmp_path: Path) -> tuple[Ticker, Any, FakeForge, FrozenClock]:
    clock = FrozenClock()
    store = open_sqlite(tmp_path / "tick.db", clock=clock)
    forge = FakeForge()
    leases = LeaseManager(MemoryLeaseBackend(clock=clock), clock=clock)
    deps = Deps(
        store=store,
        registry=Registry(),
        leases=leases,
        breaker=CircuitBreaker(DEFAULT_BUDGET, CostTracker(clock=clock), clock=clock),
        clock=clock,
    )
    reconciler = Reconciler(store=store, forge=forge, leases=leases, clock=clock)
    return Ticker(deps=deps, reconciler=reconciler, clock=clock), store, forge, clock


async def test_a_tick_on_an_empty_repository_changes_nothing(
    ticker: tuple[Ticker, Any, FakeForge, FrozenClock],
) -> None:
    tick, _store, _forge, _clock = ticker
    report = await tick.tick("acme/app")
    assert not report.reconciled.changed and report.dispatched == []


async def test_the_sweep_closes_an_issue_whose_branch_landed_out_of_band(
    ticker: tuple[Ticker, Any, FakeForge, FrozenClock],
) -> None:
    """Invariant 13 — a human merged it, and the sweep notices without being told."""
    tick, _store, forge, _clock = ticker
    forge.seed_issue(7)
    forge.merged_refs.add("agent/issue-7")
    report = await tick.tick("acme/app")
    assert report.reconciled.closed_issues == [7]
    assert (await forge.get_issue(7)).unwrap().closed


async def test_the_sweep_is_idempotent(
    ticker: tuple[Ticker, Any, FakeForge, FrozenClock],
) -> None:
    tick, _store, forge, _clock = ticker
    forge.seed_issue(7)
    forge.merged_refs.add("agent/issue-7")
    await tick.tick("acme/app")
    second = await tick.tick("acme/app")
    assert second.reconciled.closed_issues == [], "running it twice changes nothing"


async def test_a_blocked_run_is_unblocked_when_its_blocker_closes(
    ticker: tuple[Ticker, Any, FakeForge, FrozenClock],
) -> None:
    tick, store, forge, clock = ticker  # noqa: RUF059
    forge.seed_issue(412)
    await forge.close_issue(412)
    run = await store.create(JobRequest(repo="acme/app", issue=7))
    from ai_harness.schemas.checkpoint import Checkpoint

    await store.commit_transition(
        run.model_copy(update={"status": RunStatus.BLOCKED, "blocked_on": "#412"}),
        Checkpoint(run_id=run.run_id, seq=0, state=State.ANALYSE, next_state=State.ANALYSE),
    )
    report = await tick.tick("acme/app")
    assert run.run_id in report.reconciled.unblocked


async def test_a_run_parked_too_long_escalates(
    ticker: tuple[Ticker, Any, FakeForge, FrozenClock],
) -> None:
    tick, store, _forge, clock = ticker
    run = await store.create(JobRequest(repo="acme/app", issue=7))
    from ai_harness.schemas.checkpoint import Checkpoint

    await store.commit_transition(
        run.model_copy(update={"status": RunStatus.DEFERRED}),
        Checkpoint(run_id=run.run_id, seq=0, state=State.REVIEW, next_state=State.REVIEW),
    )
    clock.advance(7 * 3600)
    report = await tick.tick("acme/app")
    assert run.run_id in report.reconciled.escalated


async def test_the_drain_check_is_a_command_not_a_judgement(
    ticker: tuple[Ticker, Any, FakeForge, FrozenClock],
) -> None:
    """§24.1: "cut over only when no run is in flight" needs to be checkable."""
    tick, store, _forge, _clock = ticker  # noqa: RUF059
    assert await drained(store, "acme/app") is True
    await store.create(JobRequest(repo="acme/app", issue=7))
    assert await drained(store, "acme/app") is False


async def test_the_ceiling_limits_starting_work_not_draining_it(
    ticker: tuple[Ticker, Any, FakeForge, FrozenClock],
) -> None:
    tick, store, _forge, _clock = ticker
    tick.max_open_runs = 1
    for issue in (1, 2, 3):
        await store.create(JobRequest(repo="acme/app", issue=issue))
    report = await tick.tick("acme/app")
    assert report.skipped_at_ceiling >= 1
