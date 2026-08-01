"""The deployment provider seam (§20.1).

Five verbs, in the order they happen: ``detect``, ``build``, ``deploy``, ``smoke``, ``teardown``.
Adapters exist here for compose and for an arbitrary repo-provided script; kubernetes, cloud_run,
vercel and the rest fit the same shape without anything above this file changing.

``script`` is the escape hatch that keeps the abstraction honest. A repository with an
idiosyncratic deploy does not need an adapter written for it — it prints a ``DeploymentResult``
as JSON and the harness consumes that. An abstraction with no escape hatch grows the special
cases *inside* itself instead, which is how the shell ended up with deploy logic threaded
through four scripts.

``detect`` returning *unsupported* is a normal answer, not a failure. Deployment is optional
inside ``VALIDATE``, and a repository that cannot be deployed must not be blocked by that.
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol

from ai_harness.kernel.outcome import Outcome
from ai_harness.schemas.deploy import (
    Artefact,
    DeployCapability,
    Deployment,
    DeploySpec,
    EnvironmentSpec,
    SmokeCheck,
    SmokeReport,
)


class DeploymentProvider(Protocol):
    """One way of getting a revision running somewhere it can be smoked."""

    name: str

    async def detect(self, workspace: Path) -> Outcome[DeployCapability]:
        """Can this provider deploy this repository, and if not, why not?"""
        ...

    async def build(self, workspace: Path, spec: DeploySpec) -> Outcome[Artefact]: ...

    async def deploy(
        self, workspace: Path, artefact: Artefact, env: EnvironmentSpec
    ) -> Outcome[Deployment]: ...

    async def smoke(
        self, deployment: Deployment, checks: list[SmokeCheck]
    ) -> Outcome[SmokeReport]: ...

    async def teardown(self, deployment: Deployment) -> Outcome[None]:
        """Idempotent by contract: the TTL reaper calls this on stacks that may already be gone."""
        ...
