"""The compose provider — `local-deploy.sh` and `run-e2e.sh`'s bring-up, as one adapter.

Three behaviours are carried over verbatim because each one is load-bearing:

* **`--wait`, not a sleep.** Compose's own healthchecks gate readiness. Polling a port tells you
  something is listening, which a database mid-migration also is.
* **An explicit `-f` set**, which disables the auto-loaded `docker-compose.override.yml`. The
  dev override carries bind mounts and `--reload`; a deploy that picked those up would be
  testing the developer's working tree rather than the pinned revision.
* **One self-heal, then fail.** `epg_boot_db` scrubs the project's volumes and retries exactly
  once when the database comes up unhealthy or rejecting credentials, because that is almost
  always a stale volume — and then fails loudly rather than looping.

Teardown is `down -v` scoped to the project. `-v` here removes *this project's* anonymous and
named volumes only; it is not `docker volume prune`, and the distinction is the entire safety
argument (`lib/ephemeral-pg.sh`).
"""

from __future__ import annotations

import asyncio
import shutil
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.ids import new_run_id
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.schemas.deploy import (
    Artefact,
    DeployCapability,
    Deployment,
    DeploySpec,
    EnvironmentSpec,
    SmokeCheck,
    SmokeReport,
)

COMPOSE_FILES = ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")
OVERLAYS = ("docker-compose.deploy.yml", "docker-compose.e2e.yml")


@dataclass
class ComposeProvider:
    """Deploys with ``docker compose`` into a project private to the run."""

    name: str = "compose"
    docker: list[str] = field(default_factory=lambda: ["docker", "compose"])
    clock: Clock = field(default_factory=SystemClock)
    timeout_s: float = 900.0
    ttl_s: float = 3 * 3600
    smoker: object | None = None
    """Injected :class:`~ai_harness.deploy.smoke.Smoker`. Absent ⇒ smoke reports nothing ran."""

    # ── detect ───────────────────────────────────────────────────────────────────

    async def detect(self, workspace: Path) -> Outcome[DeployCapability]:
        """Unsupported is an *answer*. Deployment is optional and must never block a run."""
        files = [name for name in COMPOSE_FILES if (workspace / name).is_file()]
        if not files:
            return Outcome.ok(
                DeployCapability(
                    supported=False, provider=self.name, reason="no compose file in the repository"
                )
            )
        if shutil.which(self.docker[0]) is None:
            return Outcome.ok(
                DeployCapability(
                    supported=False,
                    provider=self.name,
                    reason=f"{self.docker[0]} is not on PATH",
                )
            )
        overlays = [name for name in OVERLAYS if (workspace / name).is_file()]
        return Outcome.ok(
            DeployCapability(
                supported=True,
                provider=self.name,
                compose_files=[files[0], *overlays],
                reason=f"compose file {files[0]}",
            )
        )

    # ── build ────────────────────────────────────────────────────────────────────

    async def build(self, workspace: Path, spec: DeploySpec) -> Outcome[Artefact]:
        if not spec.build:
            return Outcome.ok(Artefact(kind="compose", reference=spec.revision))
        outcome = await self._compose(workspace, EnvironmentSpec(run_id=spec.run_id), "build")
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        return Outcome.ok(
            Artefact(kind="compose", reference=spec.revision, logs=[outcome.unwrap()[-2000:]])
        )

    # ── deploy ───────────────────────────────────────────────────────────────────

    async def deploy(
        self, workspace: Path, artefact: Artefact, env: EnvironmentSpec
    ) -> Outcome[Deployment]:
        booted = await self._boot(workspace, env)
        if booted.is_err:
            return Outcome.of(booted.error)  # type: ignore[arg-type]

        now = self.clock.now()
        port = env.port_base + 800
        return Outcome.ok(
            Deployment(
                deployment_id=new_run_id(),
                provider=self.name,
                environment=env.environment,
                url=f"http://127.0.0.1:{port}",
                revision=artefact.reference,
                project=env.project,
                volume_namespace=env.volume_namespace,
                created_at=now,
                expires_at=now + timedelta(seconds=env.ttl_s or self.ttl_s),
                metadata={"port_base": str(env.port_base)},
            )
        )

    async def _boot(self, workspace: Path, env: EnvironmentSpec) -> Outcome[str]:
        """Up, and exactly one scrub-and-retry — the `epg_boot_db` recovery, no more.

        A second retry would be a loop that hides a genuinely broken stack behind latency; the
        shell stops here too, and prints the last 40 log lines rather than guessing.
        """
        first = await self._compose(workspace, env, "up", "-d", "--build", "--wait")
        if first.is_ok:
            return first

        # No logger here: providers and observability are peers, and the import contract says
        # so. The recovery is reported in the returned text instead, which is what a caller
        # records anyway — a log line nobody reads is not evidence.
        await self._compose(workspace, env, "down", "-v")
        second = await self._compose(workspace, env, "up", "-d", "--build", "--wait")
        if second.is_err:
            logs = await self._compose(workspace, env, "logs", "--tail", "40")
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"the stack did not come up after one recovery attempt: "
                f"{second.error.message if second.error else 'unknown'}",
                remedy="this is an environment failure, not a code defect; it blames nobody",
                details={"logs": logs.unwrap()[-2000:] if logs.is_ok else ""},
            )
        return Outcome.ok("recovered after scrubbing this project's volumes\n" + second.unwrap())

    # ── smoke ────────────────────────────────────────────────────────────────────

    async def smoke(self, deployment: Deployment, checks: list[SmokeCheck]) -> Outcome[SmokeReport]:
        """Smoke the *deployed* URL. The provider never invents a local one."""
        if self.smoker is None:
            return Outcome.ok(SmokeReport(url=deployment.url or ""))
        smoker = self.smoker
        result = await smoker.run(deployment.url or "", checks)  # type: ignore[attr-defined]
        return Outcome.ok(result)

    # ── teardown ─────────────────────────────────────────────────────────────────

    async def teardown(self, deployment: Deployment) -> Outcome[None]:
        """Idempotent: the TTL reaper calls this on stacks that may already be gone."""
        env = EnvironmentSpec(
            run_id="", project=deployment.project, volume_namespace=deployment.volume_namespace
        )
        await self._compose(Path.cwd(), env, "down", "-v")
        return Outcome.ok(None)

    # ── the one place a subprocess is started ────────────────────────────────────

    async def _compose(self, workspace: Path, env: EnvironmentSpec, *args: str) -> Outcome[str]:
        argv = [*self.docker, "-p", env.project or "harness"]
        for name in env.compose_files:
            argv += ["-f", name]
        argv += list(args)

        import os

        environ = {**os.environ, **env.env, "COMPOSE_PROJECT_NAME": env.project or "harness"}
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                cwd=str(workspace),
                env=environ,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except OSError as exc:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{self.docker[0]} is not runnable: {exc}",
                remedy="deployment is optional; an absent docker skips it rather than failing",
            )
        try:
            stdout, _ = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except TimeoutError:
            process.kill()
            await process.wait()
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"compose {' '.join(args)} exceeded {self.timeout_s:.0f}s",
            )
        text = stdout.decode(errors="replace")
        if process.returncode != 0:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"compose {' '.join(args)} exited {process.returncode}",
                details={"output": text[-2000:]},
            )
        return Outcome.ok(text)
