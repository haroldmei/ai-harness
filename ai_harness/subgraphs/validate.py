"""``VALIDATE`` — run the gates, then decide **whose fault** a red result is.

§9.4. Running gates is the easy half. The hard half is attribution, and getting it wrong is
expensive in both directions: blaming the branch for a broken base burns the fix budget on
innocent tests (#2124), and blaming the base for the branch's own defect ships it.

The order is fixed, and each step exists because the one after it would otherwise draw the
wrong conclusion:

1. **The anti-weakening check**, before anything else can make a green result look fine. Tests
   deleted to pass a gate park the run *regardless* of how green it is (§19.5).
2. **The baseline**, so the branch is judged by what it *adds* (invariant 9).
3. **Flake confirmation** — a re-run of the failed gates only, never a blanket retry, and the
   result is recorded rather than hidden.
4. **Triage**, which distinguishes "the tooling could not run" from "the code is broken"
   (invariant 10).

Unknown fault fails closed (§7.4). Environmental deferrals are bounded and blame nobody.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.agents.triager import TriageInput, Triager
from ai_harness.deploy.subgraph import DeployContext
from ai_harness.kernel.ids import idempotency_key
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.quality import integrity
from ai_harness.quality.baseline import BaselineStatus, BaselineStore
from ai_harness.schemas.enums import Fault, GateSet, Signal, TriageClass
from ai_harness.schemas.gates import GateReport, GateResult
from ai_harness.subgraphs.base import SubgraphResult

MAX_ENV_DEFERS = 3


@dataclass
class ValidateContext:
    """What VALIDATE is given. The gate profile and the runner arrive assembled."""

    run_id: str
    repo: str
    workspace: Path
    base_sha: str
    head_sha: str = ""
    gate_set: GateSet = GateSet.FULL
    diff_text: str = ""
    env_defers: int = 0
    self_repairs: int = 0
    max_self_repair: int = 3
    baseline_dir: Path | None = None
    base_is_green: bool | None = None
    on_base: bool = False
    """True when this run *is* the base: it RECORDS a baseline rather than consulting one."""
    cached_report: GateReport | None = None
    confirm_flakes: bool = True
    deploy: DeployContext | None = None
    """§20.2's optional stage. Absent ⇒ no deployment, and no run is blocked by that."""
    adversarial: bool = False
    """Loop-until-dry, opt-in per repository. Advisory: it reports, it never fails the run."""


@dataclass
class ValidateSubgraph:
    """The VALIDATE state."""

    runner: Any
    """Anything with ``run(...)`` and ``rerun(...)`` — the shell adapter or the Python runner."""
    triager: Triager = field(default_factory=Triager)
    deployer: Any = None
    """An optional :class:`~ai_harness.deploy.subgraph.DeployStage`. Absent ⇒ never deployed."""
    adversary: Any = None
    """An optional :class:`~ai_harness.quality.adversarial.AdversarialLoop`."""
    state_name: str = "VALIDATE"

    async def execute(self, ctx: ValidateContext) -> Outcome[SubgraphResult]:
        key = idempotency_key("validate", run=ctx.run_id, sha=ctx.head_sha, set=ctx.gate_set.value)

        # 1. Anti-weakening, before any verdict. A green suite with a deleted test is worse
        #    than a red one, because it looks finished.
        if ctx.diff_text:
            found = integrity.check(ctx.diff_text)
            if not found.clean:
                return Outcome.ok(
                    SubgraphResult(
                        signal=Signal.NEEDS_APPROVAL,
                        reason="the change weakens the tests that judge it",
                        payload={
                            "idempotency_key": key,
                            "integrity": found.model_dump(),
                            "evidence": found.evidence(),
                        },
                        head_sha=ctx.head_sha,
                        base_sha=ctx.base_sha,
                    )
                )

        report = ctx.cached_report
        if report is None:
            outcome = await self.runner.run(
                gate_set=ctx.gate_set, commit_sha=ctx.head_sha, base_sha=ctx.base_sha
            )
            if outcome.is_err:
                # The runner itself failed: an environment problem, bounded and blameless.
                return self._environmental(ctx, outcome.error)
            report = outcome.unwrap()

        if report.no_gates_discovered:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                "no gates were discovered — this repository cannot be delivered into ungated",
                remedy="add .harness/gates.yaml or a gate entry point (§19.2 rung 5)",
            )

        # 2. A run ON the base records; it never consults. A red base cannot forgive itself.
        if ctx.on_base and ctx.baseline_dir is not None:
            store = BaselineStore(ctx.baseline_dir)
            for result in report.failures:
                store.record(result.name, ctx.base_sha, "\n".join(result.failing_tests))
            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.ADVANCE if report.green else Signal.ESCALATE,
                    reason="baseline recorded for this base sha",
                    payload={"idempotency_key": key, "recorded": len(report.failures)},
                    base_sha=ctx.base_sha,
                )
            )

        report = self._forgive_inherited(report, ctx)
        if report.green:
            return await self._green_path(report, ctx, key)

        # 3. Flake confirmation: only the gates that failed, and the answer is recorded.
        if ctx.confirm_flakes:
            report = await self._confirm(report, ctx)
            if report.green:
                return await self._green_path(report, ctx, key, flaky=True)

        # 4. Attribution.
        return await self._attribute(report, ctx, key)

    def _forgive_inherited(self, report: GateReport, ctx: ValidateContext) -> GateReport:
        """Mark failures already red on this exact base. Forgiven, never hidden."""
        if ctx.baseline_dir is None:
            return report
        store = BaselineStore(ctx.baseline_dir)
        results = []
        for result in report.results:
            verdict = store.evaluate(result.name, ctx.base_sha, "\n".join(result.failing_tests))
            inherited = verdict.status is BaselineStatus.FORGIVEN
            results.append(result.model_copy(update={"inherited": inherited or result.inherited}))
        return report.model_copy(update={"results": results})

    async def _confirm(self, report: GateReport, ctx: ValidateContext) -> GateReport:
        """Re-run the failed gates once. Green on the confirmation ⇒ flake, and it is reported."""
        names = [r.name for r in report.failures]
        if not names:
            return report
        rerun = await self.runner.rerun(report, names)
        if rerun.is_err:
            return report
        second = rerun.unwrap()
        merged = []
        for result in report.results:
            replacement = second.by_name(result.name)
            if replacement is not None and replacement.green and not result.green:
                # Rebuilt, not model_copy'd: `status` is computed by a validator (skip→fail
                # promotion, timeout→fail), and model_copy does NOT re-run validators — the
                # raw status would change while the computed one silently did not.
                merged.append(
                    GateResult(
                        **{
                            **result.model_dump(),
                            "raw_status": replacement.raw_status,
                            "flake_confirmed": True,
                            "reason": f"flake: failed then passed ({result.reason})",
                        }
                    )
                )
            else:
                merged.append(result)
        return report.model_copy(update={"results": merged})

    async def _green_path(
        self, report: GateReport, ctx: ValidateContext, key: str, *, flaky: bool = False
    ) -> Outcome[SubgraphResult]:
        """Green — then, optionally, deploy.

        Both green paths come through here, including the one a confirmed flake produced. A
        deployment that only happened when the suite was green *first time* would make the
        stage's coverage depend on flakiness, which is the opposite of what either mechanism is
        for.
        """
        deployed = await self._deploy(ctx)
        if deployed is not None and deployed.is_err:
            return self._deploy_failed(ctx, deployed, key)
        deployment = deployed.unwrap() if deployed is not None else None
        adversarial = await self._adversarial(ctx)
        return Outcome.ok(
            self._green(
                report,
                ctx,
                key,
                flaky=flaky,
                deployment=deployment,
                adversarial=adversarial,
            )
        )

    async def _adversarial(self, ctx: ValidateContext) -> Any:
        """Loop-until-dry, and *advisory* — it never turns a green suite red on its own.

        A stage that could fail a build on an adversarial opinion would make every model
        tantrum a red build. What it produces is evidence, carried into REVIEW, where a human
        or the reviewer decides what it is worth.
        """
        if self.adversary is None or not ctx.adversarial:
            return None
        return await self.adversary.run()

    async def _deploy(self, ctx: ValidateContext) -> Outcome[Any] | None:
        """The stage runs only when both a deployer and a context are present.

        Two conditions rather than one because they mean different things: no deployer is a
        harness that was not configured to deploy, and no context is a repository that opted
        out. Neither is a failure, and neither should look like one in the payload.
        """
        if self.deployer is None or ctx.deploy is None:
            return None
        outcome: Outcome[Any] = await self.deployer.execute(ctx.deploy)
        return outcome

    def _deploy_failed(
        self, ctx: ValidateContext, outcome: Outcome[Any], key: str
    ) -> Outcome[SubgraphResult]:
        """A red deployment does not become a red *branch* without attribution.

        An environment failure defers — the same treatment as a gate suite that could not run,
        and for the same reason: docker being down is not this branch's doing. Anything else is
        a smoke check the code failed, which is the branch's own to fix.
        """
        error = outcome.error
        if error is not None and error.category is ErrorCategory.ENVIRONMENT:
            return self._environmental(ctx, error)
        return Outcome.ok(
            SubgraphResult(
                signal=Signal.FIX,
                reason=error.message if error is not None else "the deployment failed",
                payload={
                    "idempotency_key": key,
                    "fault": Fault.SELF.value,
                    "deployment": (error.details if error is not None else {}),
                },
                head_sha=ctx.head_sha,
                base_sha=ctx.base_sha,
            )
        )

    def _green(
        self,
        report: GateReport,
        ctx: ValidateContext,
        key: str,
        *,
        flaky: bool = False,
        deployment: Any = None,
        adversarial: Any = None,
    ) -> SubgraphResult:
        flakes = [r.name for r in report.results if r.flake_confirmed]
        payload: dict[str, Any] = {
            "idempotency_key": key,
            "report": report.model_dump(mode="json"),
            "flakes": flakes,
            "inherited": [r.name for r in report.results if r.inherited],
        }
        if deployment is not None:
            payload["deployment"] = deployment.model_dump(mode="json")
        if adversarial is not None:
            payload["adversarial"] = adversarial.model_dump(mode="json")
        return SubgraphResult(
            signal=Signal.ADVANCE,
            reason=(
                "required gates green"
                + (f" (flake confirmed on {', '.join(flakes)})" if flaky and flakes else "")
                + (
                    f" · deployed to {deployment.url}"
                    if deployment is not None and deployment.url
                    else ""
                )
            ),
            payload=payload,
            head_sha=ctx.head_sha,
            base_sha=ctx.base_sha,
        )

    async def _attribute(
        self, report: GateReport, ctx: ValidateContext, key: str
    ) -> Outcome[SubgraphResult]:
        decision = (
            await self.triager.classify(
                TriageInput(
                    repo=ctx.repo,
                    gate_report=report,
                    log_text="\n".join(r.reason for r in report.failures),
                    base_is_green=ctx.base_is_green,
                )
            )
        ).unwrap()

        payload = {
            "idempotency_key": key,
            "report": report.model_dump(mode="json"),
            "triage_class": decision.triage_class.value,
            "why": decision.reason,
            "remedy": decision.remedy,
            "failures": [r.name for r in report.failures],
        }

        if decision.triage_class in (TriageClass.INFRA, TriageClass.TRANSIENT, TriageClass.DEPS):
            payload["fault"] = Fault.ENVIRONMENT.value
            return self._environmental(ctx, None, payload=payload, reason=decision.reason)

        if decision.triage_class is TriageClass.STALE_BASE:
            payload["fault"] = Fault.BASE.value
            return Outcome.ok(
                SubgraphResult(signal=Signal.REPIN, reason=decision.reason, payload=payload)
            )

        if decision.triage_class is TriageClass.UNRELATED:
            # Base-red: confirmed by the baseline or by an explicit base state, never guessed.
            payload["fault"] = Fault.BASE.value
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                "the base is red and this branch did not cause it",
                remedy="file one blocker against the base rather than one per branch",
                details=payload,
            )

        payload["fault"] = Fault.SELF.value
        if ctx.self_repairs >= ctx.max_self_repair:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"self-repair exhausted after {ctx.self_repairs} attempts",
                remedy=decision.remedy,
                details=payload,
            )
        return Outcome.ok(
            SubgraphResult(
                signal=Signal.FIX,
                reason=decision.reason,
                payload=payload,
                head_sha=ctx.head_sha,
                base_sha=ctx.base_sha,
            )
        )

    def _environmental(
        self,
        ctx: ValidateContext,
        error: Any,
        *,
        payload: dict[str, Any] | None = None,
        reason: str = "",
    ) -> Outcome[SubgraphResult]:
        """Bounded, and it blames nobody. After the cap it escalates with a cause-specific remedy."""
        message = reason or (error.message if error is not None else "the gate suite could not run")
        if ctx.env_defers >= MAX_ENV_DEFERS:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"deferred {ctx.env_defers} times for environmental reasons: {message}",
                remedy=(
                    error.remedy
                    if error is not None and error.remedy
                    else "the tooling has not run successfully once; this is not a code defect"
                ),
                details=payload or {},
            )
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            message,
            remedy="retried next tick; this consumes no fix budget and blames nobody",
            details=payload or {},
        )
