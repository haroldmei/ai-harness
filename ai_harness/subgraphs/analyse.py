"""``ANALYSE`` — turn an issue, a gate failure or review findings into a typed plan.

§9.2. This is the *only* state where a model makes a routing-relevant judgement, and every one
of those judgements is constrained: the model fills in a :class:`WorkPlan`, and this module
decides what the plan means. The model never picks the next state.

Read-only access is enforced by the broker, not requested in the prompt (§9.2's "no writes, no
execution"). When a prior failure is present the triager runs **first**, because whether a red
gate is even the branch's problem is an evidence question, not a planning one.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ai_harness.agents.planner import PlanBrief, Planner
from ai_harness.agents.triager import TriageInput, Triager
from ai_harness.kernel.ids import idempotency_key
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.schemas.enums import Risk, Signal, TriageClass
from ai_harness.schemas.gates import GateReport
from ai_harness.schemas.plan import WorkPlan
from ai_harness.subgraphs.base import SubgraphResult

RISK_ORDER = {Risk.LOW: 0, Risk.MEDIUM: 1, Risk.HIGH: 2}


@dataclass
class AnalyseContext:
    """What ANALYSE is given."""

    run_id: str
    repo: str
    base_sha: str = ""
    issue_title: str = ""
    issue_body: str = ""
    issue_number: int | None = None
    attempt: int = 1
    max_attempts: int = 3
    approval_threshold: Risk = Risk.HIGH
    protected_paths: tuple[str, ...] = ()
    prior_failure: str = ""
    prior_findings: tuple[str, ...] = ()
    gate_report: GateReport | None = None
    live_base_sha: str = ""
    """If this differs from ``base_sha``, the base moved under us and PREPARE must re-pin."""
    cached_plan: WorkPlan | None = None
    triage_input: TriageInput | None = None
    run_spend: Any = None


@dataclass
class AnalyseSubgraph:
    """The ANALYSE state."""

    planner: Planner
    triager: Triager = field(default_factory=Triager)
    state_name: str = "ANALYSE"

    async def execute(self, ctx: AnalyseContext) -> Outcome[SubgraphResult]:
        # The base moving is not a planning problem: re-pin before spending anything.
        if ctx.live_base_sha and ctx.base_sha and ctx.live_base_sha != ctx.base_sha:
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.REPIN,
                    reason=(
                        f"the base moved from {ctx.base_sha[:12]} to {ctx.live_base_sha[:12]} "
                        "while we were working"
                    ),
                    base_sha=ctx.live_base_sha,
                )
            )

        # A red gate is first an evidence question — is it even ours?
        if ctx.triage_input is not None:
            routed = await self._triage(ctx)
            if routed is not None:
                return routed

        if ctx.attempt > ctx.max_attempts:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"planning attempted {ctx.attempt - 1} times without a usable plan",
                remedy="the issue may be underspecified in a way the planner cannot articulate",
            )

        brief = PlanBrief(
            issue_title=ctx.issue_title,
            issue_body=ctx.issue_body,
            issue_number=ctx.issue_number,
            repo=ctx.repo,
            base_sha=ctx.base_sha,
            protected_paths=ctx.protected_paths,
            prior_failure=ctx.prior_failure,
            prior_findings=ctx.prior_findings,
        )
        key = idempotency_key("analyse", run=ctx.run_id, inputs=brief.input_hash())

        if ctx.cached_plan is not None:
            return Outcome.ok(self._route_plan(ctx.cached_plan, ctx, key, reused=True))

        outcome = await self.planner.plan(brief, run=ctx.run_spend, attempt=ctx.attempt)
        if outcome.is_err:
            assert outcome.error is not None
            return Outcome.of(outcome.error)

        call = outcome.unwrap()
        plan = call.value
        assert isinstance(plan, WorkPlan)
        decided = self._route_plan(plan, ctx, key)
        return Outcome.ok(
            SubgraphResult(
                signal=decided.signal,
                reason=decided.reason,
                payload={**decided.payload, "repairs": call.repairs},
                base_sha=ctx.base_sha,
                usd=call.usd,
                input_tokens=call.input_tokens,
                output_tokens=call.output_tokens,
                cache_read_tokens=call.cache_read_tokens,
                model=call.model,
                template_id=call.template_id,
                prompt_sha256=call.prompt_sha256,
                prompt_bytes=call.prompt_bytes,
            )
        )

    async def _triage(self, ctx: AnalyseContext) -> Outcome[SubgraphResult] | None:
        """Classify the failure. ``None`` means "carry on and plan a fix"."""
        assert ctx.triage_input is not None
        decision = (await self.triager.classify(ctx.triage_input)).unwrap()
        # The caller supplies the ledger counts and performs the write; the subgraph reports
        # what it decided. Fetching here would put durable state behind a judgement.
        attempts = ctx.triage_input.attempts + 1

        payload = {
            "record_attempt": decision.fingerprint,
            "triage_class": decision.triage_class.value,
            "fingerprint": decision.fingerprint,
            "why": decision.reason,
            "remedy": decision.remedy,
            "attempts": attempts,
        }

        if decision.triage_class in (TriageClass.TRANSIENT, TriageClass.DEPS):
            if not self.triager.within_budget(decision, attempts=attempts):
                return Outcome.fail(
                    ErrorCategory.NEEDS_HUMAN,
                    f"{decision.triage_class.value} retried {attempts} times without clearing",
                    remedy=decision.remedy,
                )
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                decision.reason,
                remedy=decision.remedy,
                details=payload,
            )

        if decision.triage_class is TriageClass.STALE_BASE:
            return Outcome.ok(
                SubgraphResult(signal=Signal.REPIN, reason=decision.reason, payload=payload)
            )

        if decision.triage_class in (TriageClass.INFRA, TriageClass.UNRELATED):
            may_file = self.triager.may_file(
                decision,
                attempts=attempts,
                open_blockers=ctx.triage_input.open_blockers,
            )
            payload["files_blocker"] = may_file
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.BLOCKED,
                    reason=(
                        decision.reason
                        + ("" if may_file else " — the blocker cap is reached, filing nothing")
                    ),
                    payload=payload,
                )
            )

        # SELF: the branch owns it. Plan a fix, with the failure in the brief.
        return None

    def _route_plan(
        self, plan: WorkPlan, ctx: AnalyseContext, key: str, *, reused: bool = False
    ) -> SubgraphResult:
        """What the plan *means*. The model filled in the fields; this decides the edge."""
        payload: dict[str, Any] = {
            "idempotency_key": key,
            "plan_hash": plan.plan_hash(),
            "summary": plan.summary,
            "risk": plan.risk.value,
            "files": [c.path for c in plan.changes],
            # The whole plan, because IMPLEMENT runs in a later dispatch and cannot be handed a
            # summary and asked to build from it. The ledger is the only thing that crosses a
            # state boundary, so what the next state needs has to be *in* it.
            "plan": plan.model_dump(mode="json"),
            "reused": reused,
        }

        if plan.is_epic or plan.underspecified or not plan.in_scope:
            why = (
                "the issue is an epic"
                if plan.is_epic
                else "the issue is underspecified"
                if plan.underspecified
                else "the change is out of policy scope"
            )
            return SubgraphResult(
                signal=Signal.ESCALATE,
                reason=f"{why}: {plan.escalation_reason or plan.summary}",
                payload=payload,
            )

        touched_protected = [
            path
            for path in [c.path for c in plan.changes]
            if any(_matches(path, pattern) for pattern in ctx.protected_paths)
        ] + list(plan.touches_protected_paths)

        if RISK_ORDER[plan.risk] >= RISK_ORDER[ctx.approval_threshold] or touched_protected:
            payload["protected"] = touched_protected
            return SubgraphResult(
                signal=Signal.NEEDS_APPROVAL,
                reason=(
                    f"risk={plan.risk.value}"
                    + (f", touches {', '.join(touched_protected)}" if touched_protected else "")
                    + " — parked before any code is written"
                ),
                payload=payload,
            )

        return SubgraphResult(
            signal=Signal.ADVANCE,
            reason=f"plan accepted: {plan.summary}",
            payload=payload,
        )


def _matches(path: str, pattern: str) -> bool:
    import fnmatch

    return fnmatch.fnmatch(path, pattern) or fnmatch.fnmatch(path, pattern.replace("**/", ""))
