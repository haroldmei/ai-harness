"""Isolated environments — the port of `lib/ephemeral-pg.sh`, incident by incident.

Every rule here was learned the expensive way, and the shell file says so in its own header.
What changes in the port is that they stop being conventions a caller must remember and become
properties of an allocated object:

* **The project name is private per run.** Compose namespaces containers, networks and volumes
  by project, so a private project name is the isolation. The shell requires a `-` infix
  distinct from the developer's own project name so the volume reaper can never match the dev
  stack's `<project>_postgres_data`; here the namespace is derived, not typed, so it cannot be
  got wrong.

* **Ports are offset, never probed.** `epg_pick_port` bumps on conflict, which is racy by
  construction: two runs probing from a shared base both see the same port free and both take
  it. A band per slot has no race because nothing is checked.

* **Volume reaping is name-scoped.** Never `docker system prune`, which reaches the developer's
  dev stack and other repositories' data. :meth:`Environment.reap_pattern` is anchored at both
  ends, and there is a test that an unrelated volume survives.

* **The e2e database has no named volume at all.** Three incidents: a volume surviving from a
  prior branch carried a stale alembic revision, and the stack failed to boot with a generic
  "dependency failed to start". tmpfs cannot carry anything between runs.

* **One lock per project.** Distinct projects are genuinely parallel; the same project
  serialises, so two runs never share a database mid-migration.

* **A TTL on everything.** ``tick`` reaps expired environments, so a crashed run leaks nothing.
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.lease import FlockLeaseBackend, LeaseHandle
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.observability.logging import Logger
from ai_harness.schemas.deploy import Deployment, EnvironmentSpec
from ai_harness.schemas.deploy import Environment as EnvironmentName

PORT_BASE = 30000
"""Deliberately above the shell's bands (dev 5432/3000, itest 25432, seedcheck 35432 aside) and
above the gate runner's 20000, so a deployment never contends with a gate on the same host."""

PORT_BAND = 1000

DEFAULT_TTL_S = 3 * 3600

_SLUG = re.compile(r"[^a-z0-9]+")


def slug(value: str, *, limit: int = 12) -> str:
    """Compose project names are restricted; run ids are not. Normalise once, here."""
    cleaned = _SLUG.sub("-", value.lower()).strip("-")
    return cleaned[:limit] or "run"


@dataclass(frozen=True, slots=True)
class Environment:
    """An allocated environment: a name, a band, and the strings a reaper needs."""

    spec: EnvironmentSpec
    lock_path: Path

    @property
    def project(self) -> str:
        return self.spec.project

    @property
    def reap_pattern(self) -> re.Pattern[str]:
        """Volumes this environment may remove — and *only* these.

        Anchored at both ends and rooted at the private project name. A dev stack's
        ``<project>_postgres_data`` cannot match ``harness-run-abc123_...`` at either end,
        which is the entire safety argument.
        """
        return re.compile(rf"^{re.escape(self.spec.volume_namespace)}[a-z0-9_-]*_data$")

    def owns_volume(self, name: str) -> bool:
        return bool(self.reap_pattern.match(name))

    def env(self) -> dict[str, str]:
        """The variables a compose file reads. Ports are *derived* from the band."""
        base = self.spec.port_base
        values = {
            "COMPOSE_PROJECT_NAME": self.project,
            "HARNESS_ENVIRONMENT": self.spec.environment,
            "HARNESS_PORT_BASE": str(base),
            "SF_PG_PORT": str(base + 432),
            "SF_REDIS_PORT": str(base + 379),
            "SF_API_PORT": str(base + 800),
            "SF_FRONTEND_PORT": str(base + 300),
        }
        if self.spec.tmpfs_database:
            # Read by the compose overlay. The database gets tmpfs, so nothing survives the run.
            values["HARNESS_DB_TMPFS"] = "1"
        values.update(self.spec.env)
        return values


@dataclass
class EnvironmentAllocator:
    """Hands out isolated environments, and reaps them by name.

    ``docker`` is injected as argv so the whole module is testable without docker, and so a
    host that spells it ``podman`` needs no code change.
    """

    root: Path
    prefix: str = "harness"
    docker: list[str] = field(default_factory=lambda: ["docker"])
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)
    lock_dir: Path | None = None
    ttl_s: float = DEFAULT_TTL_S

    def allocate(
        self,
        run_id: str,
        *,
        slot: int = 0,
        environment: EnvironmentName = "dev",
        compose_files: list[str] | None = None,
        env: dict[str, str] | None = None,
    ) -> Environment:
        project = f"{self.prefix}-{slug(run_id)}-{slot}"
        spec = EnvironmentSpec(
            run_id=run_id,
            environment=environment,
            project=project,
            port_base=PORT_BASE + PORT_BAND * slot,
            volume_namespace=project,
            ttl_s=self.ttl_s,
            env=env or {},
            compose_files=compose_files or [],
        )
        directory = self.lock_dir or Path("/tmp")
        return Environment(spec=spec, lock_path=directory / f"{project}.lock")

    async def hold(
        self, environment: Environment, *, timeout_s: float = 1800
    ) -> LeaseHandle | None:
        """Serialise same-project runs. Distinct projects never contend."""
        backend = FlockLeaseBackend(directory=environment.lock_path.parent, clock=self.clock)
        return await backend.acquire(
            environment.lock_path.stem, ttl_s=timeout_s, holder=environment.spec.run_id
        )

    async def reap(self, environment: Environment) -> Outcome[list[str]]:
        """Remove this environment's volumes, and nothing else.

        The listing is filtered in Python against :meth:`Environment.owns_volume` rather than
        handed to docker as a glob, because a glob is one typo away from matching a dev volume
        and a compiled anchored pattern is not.
        """
        listed = await self._docker("volume", "ls", "-q")
        if listed.is_err:
            return Outcome.of(listed.error)  # type: ignore[arg-type]

        names = [line.strip() for line in listed.unwrap().splitlines() if line.strip()]
        mine = [name for name in names if environment.owns_volume(name)]
        removed: list[str] = []
        for name in mine:
            outcome = await self._docker("volume", "rm", "-f", name)
            if outcome.is_ok:
                removed.append(name)
        self.logger.info(
            "reaped volumes", project=environment.project, removed=len(removed), seen=len(names)
        )
        return Outcome.ok(removed)

    async def expired(self, deployments: list[Deployment]) -> list[Deployment]:
        """What ``tick`` should tear down. A crashed run leaks nothing because of this."""
        now = self.clock.now()
        return [deployment for deployment in deployments if deployment.expired(now)]

    def expires_at(self, ttl_s: float | None = None) -> object:
        return self.clock.now() + timedelta(seconds=ttl_s if ttl_s is not None else self.ttl_s)

    async def _docker(self, *args: str) -> Outcome[str]:
        try:
            process = await asyncio.create_subprocess_exec(
                *self.docker,
                *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(self.root),
            )
        except OSError as exc:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"docker is not runnable: {exc}",
                remedy="deployment is optional; this skips rather than fails the run",
            )
        stdout, stderr = await process.communicate()
        if process.returncode != 0:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"docker {' '.join(args)} exited {process.returncode}: "
                f"{stderr.decode(errors='replace')[:300]}",
            )
        return Outcome.ok(stdout.decode(errors="replace"))
