"""The verify loop and failure routing, ported off the shell (#108)."""

from __future__ import annotations

import json
from dataclasses import dataclass, field

import pytest

from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.product.state import ProductState
from ai_harness.quality.routing import UNKNOWN, route
from ai_harness.quality.verify import Verdict, VerifyLoop
from ai_harness.schemas.enums import GateSet, GateStatus, Tier
from ai_harness.schemas.gates import GateReport, GateResult

# ── routing: the shell's table, verified against the shell itself ────────────────


@pytest.mark.parametrize(
    ("gate", "owner"),
    [
        ("mutation", "adversarial-tester"),
        ("coverage", "adversarial-tester"),
        ("repro-tests", "adversarial-tester"),
        ("quarantine", "adversarial-tester"),
        ("integration", "backend-developer"),
        ("contract", "backend-developer"),
        ("e2e", "frontend-developer"),
        ("visual", "frontend-developer"),
        ("i18n", "frontend-developer"),
        ("mobile-e2e", "frontend-developer"),
        ("mobile-perf", "perf-tester"),
        ("lighthouse", "perf-tester"),
        ("a11y", "ux-designer"),
        ("docs-refs", "api-docs"),
        ("iteration-immutable", "api-docs"),
        ("migration-drift", "db-migrator"),
        ("seed-integrity", "db-migrator"),
        ("wedge-coverage", "e2e-tester"),
    ],
)
def test_each_gate_routes_to_the_owner_the_shell_names(gate: str, owner: str):
    assert route(gate) == owner


@pytest.mark.parametrize(
    ("gate", "area", "owner"),
    [
        ("typecheck", "src/components/Foo.tsx", "frontend-developer"),
        ("typecheck", "src/api/handler.ts", "backend-developer"),
        ("typecheck", "prisma/schema.prisma", "db-migrator"),
        ("lint", "src/lib/util.ts", "backend-developer"),
        ("lint", "", "frontend-developer"),
        ("unit", "components/Btn.test.tsx", "frontend-developer"),
        ("unit", "jobs/mailer.test.ts", "background-jobs"),
        ("unit", "db/seed.test.ts", "db-migrator"),
        ("unit", "services/api.test.ts", "backend-developer"),
    ],
)
def test_type_lint_and_unit_route_by_where_they_failed(gate: str, area: str, owner: str):
    # Sending every type error to one owner is how a gate becomes somebody else's problem to
    # triage by hand.
    assert route(gate, area=area) == owner


def test_an_unrouted_gate_is_unknown_rather_than_assigned():
    # A default owner would hide the fact that nobody has claimed this gate.
    assert route("a-gate-nobody-owns") == UNKNOWN


# ── the loop ─────────────────────────────────────────────────────────────────────


@dataclass
class StubRunner:
    """A gate runner whose scorecard the test chooses."""

    reports: list[GateReport] = field(default_factory=list)
    calls: int = 0
    error: ErrorCategory | None = None

    async def run(self, *, gate_set: GateSet = GateSet.FULL, **_: object):
        if self.error is not None:
            return Outcome.fail(self.error, "the suite could not run")
        report = self.reports[min(self.calls, len(self.reports) - 1)]
        self.calls += 1
        return Outcome.ok(report)


def _report(*results: GateResult) -> GateReport:
    return GateReport(run_id="r1", tier=Tier.LAUNCH, gate_set=GateSet.FULL, results=list(results))


def _gate(name: str, status: GateStatus, *, reason: str = "") -> GateResult:
    return GateResult(name=name, raw_status=status, required=True, reason=reason)


def _loop(tmp_path, runner: StubRunner, **kwargs: object) -> VerifyLoop:
    state = ProductState(directory=tmp_path / "state", clock=FrozenClock())
    state.init("x")
    return VerifyLoop(runner=runner, state=state, clock=FrozenClock(), **kwargs)  # type: ignore[arg-type]


async def test_green_gates_and_no_findings_is_a_pass(tmp_path):
    runner = StubRunner(reports=[_report(_gate("unit", GateStatus.PASS))])
    result = (await _loop(tmp_path, runner).run(tier="launch")).unwrap()

    assert result.verdict is Verdict.PASS
    assert result.green
    assert result.failed_gates == []


async def test_green_gates_with_open_findings_is_not_done(tmp_path):
    loop = _loop(tmp_path, StubRunner(reports=[_report(_gate("unit", GateStatus.PASS))]))
    loop.state.set(".open_issues", [{"title": "a known bug"}])

    result = (await loop.run(tier="launch")).unwrap()
    # A suite that passes while known bugs are open is measuring the wrong thing.
    assert result.verdict is Verdict.ISSUES_OPEN
    assert result.open_issues_blocking == 1


async def test_a_failure_is_routed_and_the_attempt_is_counted_durably(tmp_path):
    runner = StubRunner(
        reports=[_report(_gate("coverage", GateStatus.FAIL, reason="below the floor"))]
    )
    loop = _loop(tmp_path, runner)

    result = (await loop.run(tier="launch")).unwrap()
    assert result.verdict is Verdict.ROUTED
    assert [r.render() for r in result.routes] == ["coverage → adversarial-tester (attempt 1)"]

    # Durable, because a loop bounded only by rounds lets one gate consume the whole budget
    # while another is never attempted.
    reopened = ProductState(directory=loop.state.directory, clock=FrozenClock())
    assert reopened.get('.testing.gate_attempts."coverage"') == 1


async def test_the_attempt_budget_is_per_gate_and_exhausting_it_says_so(tmp_path):
    runner = StubRunner(reports=[_report(_gate("unit", GateStatus.FAIL))])
    loop = _loop(tmp_path, runner, max_attempts=2)

    for _ in range(2):
        await loop.run(tier="launch")
    result = (await loop.run(tier="launch")).unwrap()

    assert result.verdict is Verdict.EXHAUSTED
    assert result.routes[0].attempt == 3
    assert result.routes[0].exhausted


async def test_the_verdict_is_a_value_the_next_caller_can_read(tmp_path):
    runner = StubRunner(
        reports=[_report(_gate("e2e", GateStatus.FAIL), _gate("unit", GateStatus.PASS))]
    )
    loop = _loop(tmp_path, runner)
    result = (await loop.run(tier="launch")).unwrap()

    written = json.loads((loop.state.directory / "verdict.json").read_text())
    assert written["verdict"] == "ROUTED"
    assert written["failed_gates"] == ["e2e"]
    assert written["routes"] == ["e2e → frontend-developer (attempt 1)"]
    assert written["generated_by"] == "agent verify"
    # A caller that only knows "non-zero" has to re-derive what went wrong from logs.
    assert result.as_document() == written


async def test_the_run_is_recorded_on_the_testing_shard(tmp_path):
    loop = _loop(tmp_path, StubRunner(reports=[_report(_gate("unit", GateStatus.PASS))]))
    await loop.run(tier="launch")

    assert loop.state.get(".testing.last_verdict") == "PASS"
    assert loop.state.get(".testing.open_issues_drained") is True
    assert loop.state.get(".testing.last_run_at")


async def test_report_only_runs_the_gates_once(tmp_path):
    runner = StubRunner(reports=[_report(_gate("unit", GateStatus.FAIL))])
    await _loop(tmp_path, runner).run(tier="launch", max_rounds=5)

    # Looping without a fixer would run identical gates against an identical tree and call the
    # repetition progress.
    assert runner.calls == 1


async def test_looping_stops_as_soon_as_the_gates_go_green(tmp_path):
    runner = StubRunner(
        reports=[_report(_gate("unit", GateStatus.FAIL)), _report(_gate("unit", GateStatus.PASS))]
    )
    result = (
        await _loop(tmp_path, runner).run(tier="launch", report_only=False, max_rounds=5)
    ).unwrap()

    assert runner.calls == 2
    assert result.verdict is Verdict.PASS
    assert result.rounds == 2


async def test_a_suite_that_cannot_run_is_an_environment_failure_not_a_verdict(tmp_path):
    runner = StubRunner(error=ErrorCategory.ENVIRONMENT)
    outcome = await _loop(tmp_path, runner).run(tier="launch")

    # "The tooling could not run" is not "the code is broken" — conflating them accuses an
    # innocent base.
    assert outcome.category is ErrorCategory.ENVIRONMENT
