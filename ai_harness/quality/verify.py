"""The verify loop — gates, route, account, decide (#108).

`verify-loop.sh` is what a product build runs to get from red to green: run the gates, route each
failure to its owner, count the attempt, and stop with a verdict. It is not the harness's
review⇄fix loop — that is `orchestration/` — and the difference is who fixes: there, a model
inside a run; here, a phase of a product build that the orchestrator schedules.

Four properties are ports, and each was a defect before it was a rule:

* **Attempts are counted per gate, durably.** A loop bounded by rounds lets one gate consume the
  whole budget while another is never attempted. The count lives in `state/testing.json` and
  survives the process.
* **The verdict is a value, not an exit code.** `state/verdict.json` names the failing gates, the
  routes and the round count, because a caller that only knows "non-zero" has to re-derive what
  went wrong from logs.
* **Routing comes from a table.** Never from grepping gate output for a filename — W13, and the
  reason `routing.py` exists.
* **Report-only is a mode, not an accident.** The loop can route without fixing, which is what
  the orchestrator wants when *it* owns spawning the fixers.

The one thing deliberately not ported is the shell's `claude -p` fixer spawn. In the Python
engine an agent is spawned by the orchestrator through the roster and the broker — a loop that
shells out to a model would bypass the budget, the policy engine and the audit trail, which is
most of what the port is for.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import Outcome
from ai_harness.product.state import ProductState
from ai_harness.quality.routing import route
from ai_harness.schemas.enums import GateSet
from ai_harness.schemas.gates import GateReport


class Verdict(StrEnum):
    """How the loop ended. Every value is actionable by a different caller."""

    PASS = "PASS"
    """Every required gate is green and nothing is open."""
    ISSUES_OPEN = "ISSUES_OPEN"
    """Gates are green but adversarial findings remain — green is not done."""
    ROUTED = "ROUTED"
    """Failures were routed to owners; the caller applies the fixes (report-only)."""
    EXHAUSTED = "EXHAUSTED"
    """A gate used its whole attempt budget. A human decides what happens next."""


@dataclass(frozen=True, slots=True)
class Route:
    """One failing gate, its owner, and how many attempts it has had."""

    gate: str
    owner: str
    attempt: int
    exhausted: bool = False

    def render(self) -> str:
        return f"{self.gate} → {self.owner} (attempt {self.attempt})"


@dataclass(frozen=True, slots=True)
class VerifyResult:
    """The verdict, as a value. Written to `state/verdict.json` and returned."""

    verdict: Verdict
    tier: str
    rounds: int
    failed_gates: list[str] = field(default_factory=list)
    routes: list[Route] = field(default_factory=list)
    open_issues_blocking: int = 0
    mutation_score: float | None = None
    generated_at: str = ""

    @property
    def green(self) -> bool:
        return self.verdict is Verdict.PASS

    def as_document(self) -> dict[str, Any]:
        """`verdict.json`'s shape, kept — the skills read these fields."""
        return {
            "verdict": self.verdict.value,
            "tier": self.tier,
            "generated_at": self.generated_at,
            "rounds": self.rounds,
            "failed_gates": list(self.failed_gates),
            "open_issues_blocking": self.open_issues_blocking,
            "mutation_score": self.mutation_score,
            "routes": [r.render() for r in self.routes],
            "generated_by": "agent verify",
        }


@dataclass
class VerifyLoop:
    """Runs gates until they pass, the attempts run out, or the caller is asked to fix."""

    runner: Any
    """Anything with ``run(gate_set=…, only=…)`` — the `GateRunner` or the shell adapter."""
    state: ProductState
    max_attempts: int = 3
    clock: Clock = field(default_factory=SystemClock)

    async def run(
        self,
        *,
        tier: str = "",
        gate_set: GateSet = GateSet.FULL,
        report_only: bool = True,
        max_rounds: int = 1,
    ) -> Outcome[VerifyResult]:
        """One pass by default: run, route, account, decide.

        `max_rounds` is 1 because report-only is the default — the orchestrator applies fixes
        between rounds, and a loop that iterated without a fixer would run identical gates
        against an identical tree and call the repetition progress.
        """
        rounds = 0
        failed: list[str] = []
        routes: list[Route] = []

        while rounds < max(max_rounds, 1):
            rounds += 1
            outcome = await self.runner.run(gate_set=gate_set)
            if outcome.is_err:
                assert outcome.error is not None
                return Outcome.of(outcome.error)

            report: GateReport = outcome.unwrap()
            failed = [r.name for r in report.results if r.required and not r.green]
            if not failed:
                break
            routes = self._route_all(failed, report)
            if report_only or any(r.exhausted for r in routes):
                break

        result = self._decide(tier=tier, rounds=rounds, failed=failed, routes=routes)
        self._record(result)
        return Outcome.ok(result)

    # ── the parts ────────────────────────────────────────────────────────────────

    def _route_all(self, failed: list[str], report: GateReport) -> list[Route]:
        """Route each failure and count its attempt durably.

        Per gate rather than per round: a loop bounded only by rounds lets one gate consume the
        whole budget while another is never attempted at all.
        """
        routes: list[Route] = []
        reasons = {r.name: (r.reason or "") for r in report.results}
        for gate in failed:
            attempts = self._attempt(gate) + 1
            self.state.set(f'.testing.gate_attempts."{gate}"', attempts)
            routes.append(
                Route(
                    gate=gate,
                    owner=route(gate, area=reasons.get(gate, "")),
                    attempt=attempts,
                    exhausted=attempts > self.max_attempts,
                )
            )
        return routes

    def _attempt(self, gate: str) -> int:
        recorded = self.state.get(f'.testing.gate_attempts."{gate}"')
        return recorded if isinstance(recorded, int) else 0

    def _open_issues(self) -> int:
        issues = self.state.get(".open_issues")
        return len(issues) if isinstance(issues, list) else 0

    def _decide(
        self, *, tier: str, rounds: int, failed: list[str], routes: list[Route]
    ) -> VerifyResult:
        open_issues = self._open_issues()
        if failed:
            verdict = Verdict.EXHAUSTED if any(r.exhausted for r in routes) else Verdict.ROUTED
        elif open_issues:
            # Green gates and open findings is not done. The shell says so and it is right:
            # a suite that passes while known bugs are open is measuring the wrong thing.
            verdict = Verdict.ISSUES_OPEN
        else:
            verdict = Verdict.PASS

        return VerifyResult(
            verdict=verdict,
            tier=tier,
            rounds=rounds,
            failed_gates=failed,
            routes=routes,
            open_issues_blocking=open_issues,
            generated_at=self.clock.now().strftime("%Y-%m-%dT%H:%M:%SZ"),
        )

    def _record(self, result: VerifyResult) -> None:
        """Write the verdict where both the skills and the next round read it."""
        from ai_harness.product.state import _atomic_write, dumps

        _atomic_write(self.state.directory / "verdict.json", dumps(result.as_document()))
        self.state.set(".testing.last_verdict", result.verdict.value)
        self.state.set(".testing.last_run_at", result.generated_at)
        self.state.set(".testing.open_issues_drained", result.open_issues_blocking == 0)
