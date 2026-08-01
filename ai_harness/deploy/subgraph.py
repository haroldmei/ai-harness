"""The deployment stage — optional inside ``VALIDATE`` (§20.2).

It is a *stage*, not a state. States are the seven of §9 and adding an eighth for something
that is optional, absent in most repositories, and never routing-relevant would make the machine
harder to reason about for no gain. So this returns a ``DeploymentResult``, and ``VALIDATE``
decides what a failed deployment means for the run.

The order below is the one from the flowchart, and each step is where it is because the step
after it would otherwise draw a wrong conclusion:

1. **Policy first, before anything is built.** ``DEPLOY_PROD`` is ``DENY`` in the standard
   policy, so production is not reachable by approval alone — it takes a policy edit *and* an
   approval. Checking after the build would mean the denial arrived having already spent money.
2. **Detect**, and treat *unsupported* as a skip with a reason. A repository that cannot be
   deployed must not be blocked by that.
3. **Build**, then **allocate** an isolated environment — never the other way round, so a
   failed build does not leave a stack allocated.
4. **Seed**, because smoking an empty database tests nothing.
5. **Smoke the deployed URL.** Not the local one, not the live one (`canary-deploy.sh`).
6. **Preserve on failure, tear down on success** — evidence first, cleanup last (§16.4). A
   torn-down failure is unexaminable, and the TTL reaper collects it later regardless.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.deploy.environments import EnvironmentAllocator
from ai_harness.deploy.smoke import Smoker
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.observability.logging import Logger
from ai_harness.policies.engine import PolicyEngine, Request
from ai_harness.schemas.deploy import (
    Deployment,
    DeploymentResult,
    DeploySpec,
    Environment,
    SmokeCheck,
)
from ai_harness.schemas.enums import Capability
from ai_harness.schemas.policy import Policy

CAPABILITY_FOR: dict[str, Capability] = {
    "dev": Capability.DEPLOY_DEV,
    "preview": Capability.DEPLOY_PROD,
    "staging": Capability.DEPLOY_PROD,
    "production": Capability.DEPLOY_PROD,
}
"""Anything past ``dev`` resolves to ``DEPLOY_PROD``.

Not an approximation — a deliberate refusal to add gradations nobody has justified. A staging
environment usually holds production-shaped data and production-shaped credentials, so treating
it as "nearly dev" is how a dev-grade mistake reaches production-grade data.
"""


@dataclass(frozen=True, slots=True)
class DeployContext:
    """What the stage is given."""

    run_id: str
    repo: str
    workspace: Path
    revision: str = ""
    environment: Environment = "dev"
    policy: Policy = field(default_factory=Policy)
    checks: list[SmokeCheck] = field(default_factory=list)
    slot: int = 0
    seed_manifest: Path | None = None
    preserve_on_failure: bool = True


@dataclass
class DeployStage:
    """Runs a provider through detect → build → deploy → seed → smoke."""

    provider: Any
    """Any :class:`~ai_harness.providers.deploy.protocol.DeploymentProvider`."""
    allocator: EnvironmentAllocator
    smoker: Smoker = field(default_factory=Smoker)
    seeder: Any = None
    """An optional :class:`~ai_harness.deploy.seed.Seeder`. Absent ⇒ the stack is not seeded."""
    logger: Logger = field(default_factory=Logger)
    name: str = "deploy"

    async def execute(self, ctx: DeployContext) -> Outcome[DeploymentResult]:
        # 1. Policy, before anything is built or allocated.
        capability = CAPABILITY_FOR.get(ctx.environment, Capability.DEPLOY_PROD)
        verdict = PolicyEngine(policy=ctx.policy).evaluate(
            Request(capability=capability, reason=f"deploy to {ctx.environment}")
        )
        if verdict.denied:
            return Outcome.fail(
                ErrorCategory.POLICY,
                f"deploying to {ctx.environment} is denied by the {ctx.policy.name} policy",
                remedy=(
                    "production is out of scope by default (§2); reaching it takes a policy "
                    "override AND an approval, which is two deliberate human acts"
                ),
            )
        if verdict.needs_approval:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"deploying to {ctx.environment} requires an approval",
                remedy=verdict.reason,
                details={"capability": capability.value},
            )

        # 2. Detect. "No" is an answer.
        detected = await self.provider.detect(ctx.workspace)
        if detected.is_err:
            return Outcome.of(detected.error)
        capability_report = detected.unwrap()
        if not capability_report.supported:
            return Outcome.ok(
                DeploymentResult(
                    environment=ctx.environment,
                    provider=self.provider.name,
                    skipped=True,
                    reason=capability_report.skip_reason,
                )
            )

        # 3. Build first, then allocate: a failed build leaves nothing to reap.
        spec = DeploySpec(run_id=ctx.run_id, repo=ctx.repo, revision=ctx.revision)
        built = await self.provider.build(ctx.workspace, spec)
        if built.is_err:
            return Outcome.of(built.error)

        environment = self.allocator.allocate(
            ctx.run_id,
            slot=ctx.slot,
            environment=ctx.environment,
            compose_files=capability_report.compose_files,
        )
        env_spec = environment.spec.model_copy(update={"env": environment.env()})

        deployed = await self.provider.deploy(ctx.workspace, built.unwrap(), env_spec)
        if deployed.is_err:
            return Outcome.of(deployed.error)
        deployment = deployed.unwrap()

        result = DeploymentResult(
            environment=ctx.environment,
            provider=self.provider.name,
            project=deployment.project,
            url=deployment.url,
            port_band=env_spec.port_base,
            deployed_sha=deployment.revision,
            deployment_id=deployment.deployment_id,
            healthy=True,
        )

        # 4. Seed, because smoking an empty database tests nothing.
        if self.seeder is not None and ctx.seed_manifest is not None:
            seeded = await self.seeder.run(
                ctx.workspace, manifest=ctx.seed_manifest, environment=env_spec
            )
            result = result.model_copy(update={"seed": seeded.model_dump(mode="json")})
            if not seeded.ok:
                return await self._failed(
                    ctx,
                    deployment,
                    result,
                    ErrorCategory.ENVIRONMENT,
                    "the seed did not land — the stack is up but has no data to smoke",
                    remedy="a failed seed is an environment failure, not a code defect",
                )

        # 5. Smoke the *deployed* URL.
        report = await self.smoker.run(deployment.url or "", ctx.checks or None)
        result = result.model_copy(
            update={"smoke_passed": report.passed, "logs": [c.reason for c in report.failures]}
        )
        if not report.passed:
            return await self._failed(
                ctx,
                deployment,
                result,
                ErrorCategory.TOOL_FAILURE,
                "the deployment came up but did not answer its smoke checks",
                remedy="; ".join(f"{c.name}: {c.reason}" for c in report.failures),
            )

        # 6. Success: tear down. There is nothing left to examine.
        await self.provider.teardown(deployment)
        await self.allocator.reap(environment)
        return Outcome.ok(result)

    async def _failed(
        self,
        ctx: DeployContext,
        deployment: Deployment,
        result: DeploymentResult,
        category: ErrorCategory,
        message: str,
        *,
        remedy: str = "",
    ) -> Outcome[DeploymentResult]:
        """Evidence first, cleanup last (§16.4).

        A failed stack torn down immediately cannot be examined, and the TTL reaper will collect
        it anyway — so preserving costs a bounded amount of disk and buys the only chance anyone
        has to see what happened.
        """
        if ctx.preserve_on_failure:
            self.logger.warning(
                "preserving the failed stack for inspection",
                project=deployment.project,
                url=deployment.url,
                expires_at=str(deployment.expires_at),
            )
        else:
            await self.provider.teardown(deployment)
        return Outcome.fail(
            category, message, remedy=remedy, details={"result": result.model_dump(mode="json")}
        )
