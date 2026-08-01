"""Deployment contracts (§20.1).

Optional inside ``VALIDATE`` and **out of scope by default beyond `dev`** (§2). That is not a
disclaimer, it is encoded: ``DEPLOY_PROD`` is ``DENY`` in the standard policy, so reaching
production takes editing policy *and* answering an approval — two deliberate human acts.

The isolation decisions of `lib/ephemeral-pg.sh` and `local-deploy.sh` appear here as *fields*
rather than as conventions, because each was learned from an incident: a project name private
per run, a port band that is offset rather than probed, a volume namespace that scopes reaping,
and a TTL that lets ``tick`` collect what a crashed run left behind.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, model_validator

Environment = Literal["dev", "preview", "staging", "production"]

NON_DEV: frozenset[str] = frozenset({"preview", "staging", "production"})
"""Anything past ``dev`` needs an approval; ``production`` needs a policy override as well."""


class DeployCapability(BaseModel):
    """What ``detect`` found. "No" is a first-class answer, and it carries a reason."""

    supported: bool = False
    provider: str = ""
    reason: str = ""
    compose_files: list[str] = Field(default_factory=list)
    services: list[str] = Field(default_factory=list)

    @property
    def skip_reason(self) -> str:
        return self.reason or f"{self.provider or 'this provider'} found nothing to deploy"


class DeploySpec(BaseModel):
    """What to build, and from where."""

    run_id: str = ""
    repo: str = ""
    revision: str = ""
    """The pinned sha. A deploy is from a pinned checkout, never from the live worktree."""
    build: bool = True
    build_args: dict[str, str] = Field(default_factory=dict)
    services: list[str] = Field(default_factory=list)


class EnvironmentSpec(BaseModel):
    """One isolated environment. Every field here derives from the run, by construction."""

    run_id: str
    environment: Environment = "dev"
    project: str = ""
    """The compose project name — private per run, so two runs never share a stack."""
    port_base: int = 30000
    """Offset per slot, never probed: two runs probing from a shared base pick the same port."""
    volume_namespace: str = ""
    """The prefix a reaper may match. Reaping is name-scoped — never an unscoped prune."""
    ttl_s: float = 3 * 3600
    tmpfs_database: bool = True
    """No named volume for the e2e database (three incidents of a stale revision surviving)."""
    env: dict[str, str] = Field(default_factory=dict)
    compose_files: list[str] = Field(default_factory=list)

    @property
    def beyond_dev(self) -> bool:
        return self.environment in NON_DEV


class Artefact(BaseModel):
    """What ``build`` produced: an image reference, a bundle path, or nothing at all."""

    kind: str = "compose"
    reference: str = ""
    digest: str = ""
    logs: list[str] = Field(default_factory=list)


class SmokeCheck(BaseModel):
    """One assertion against a *deployed* URL."""

    name: str = "root"
    path: str = "/"
    expect_status: int = 200
    expect_body: str = ""
    timeout_s: float = 15.0
    retries: int = 6
    delay_s: float = 5.0


class SmokeOutcome(BaseModel):
    name: str
    passed: bool = False
    status: int | None = None
    attempts: int = 0
    url: str = ""
    reason: str = ""


class SmokeReport(BaseModel):
    checks: list[SmokeOutcome] = Field(default_factory=list)
    url: str = ""

    @property
    def passed(self) -> bool:
        """An empty report is **not** a pass: a deployment nobody checked is not a healthy one."""
        return bool(self.checks) and all(check.passed for check in self.checks)

    @property
    def failures(self) -> list[SmokeOutcome]:
        return [check for check in self.checks if not check.passed]


class Deployment(BaseModel):
    """A live environment, and enough to reap it without the run that created it."""

    deployment_id: str
    provider: str = "compose"
    environment: Environment = "dev"
    url: str | None = None
    revision: str = ""
    project: str = ""
    volume_namespace: str = ""
    created_at: datetime | None = None
    expires_at: datetime | None = None
    """Drives the TTL reaper in ``tick``, so a crashed run cannot leak a stack."""
    metadata: dict[str, str] = Field(default_factory=dict)

    def expired(self, now: datetime) -> bool:
        return self.expires_at is not None and now >= self.expires_at


class DeploymentResult(BaseModel):
    """What was deployed, where, and whether it answered.

    This is what a ``script`` provider must print as JSON and what the run checkpoints. The two
    health fields stay separate on purpose: ``healthy`` means the stack came up, ``smoke_passed``
    means it answered *correctly*, and a stack that boots while serving 500s is precisely the
    case where conflating them ships a broken build.
    """

    environment: Environment = "dev"
    provider: str = "compose"
    project: str = ""
    """The compose project name — private per run, so two runs never share a stack."""
    url: str | None = None
    port_band: int | None = None
    """Offset per slot, never probed: two runs probing from a shared base pick the same port."""
    deployed_sha: str = ""
    healthy: bool = False
    smoke_passed: bool = False
    skipped: bool = False
    reason: str = ""
    seed: dict[str, object] = Field(default_factory=dict)
    deployment_id: str = ""
    logs: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _smoke_implies_healthy(self) -> DeploymentResult:
        """A passing smoke against an unhealthy stack is a contradiction, so it is corrected.

        Same rule as an approving review that carries blocking findings: a schema-valid but
        self-contradicting result is fixed in code, not argued about at the call site.
        """
        if self.smoke_passed and not self.healthy:
            object.__setattr__(self, "healthy", True)
        return self

    @property
    def ok(self) -> bool:
        return self.skipped or (self.healthy and self.smoke_passed)
