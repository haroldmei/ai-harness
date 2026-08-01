"""The ``script`` provider — the escape hatch that keeps the abstraction honest.

A repository with an idiosyncratic deploy prints a ``DeploymentResult`` as JSON; the harness
consumes that and nothing else. No adapter is written for it, and — the part that matters —
**no caller parses a log line**. The shell driver learns what a stage did by grepping its output
(W13), which is why rewording a message breaks it. Here the contract is a JSON object on stdout.

Also used to wrap the periphery scripts of §3.16 (`release-train.sh`, `cut-release.sh`,
`local-deploy.sh`): these are independent of the issue→merge path, so per the *wrap temporarily*
disposition they are invoked as subprocesses behind a typed result rather than ported. Wrapping
is not a compromise here — it is what lets them be replaced one at a time, or never.

The JSON is read from the **last** well-formed object on stdout, so a script that logs before it
prints its result is not punished for logging.
"""

from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.ids import new_run_id
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.schemas.deploy import (
    Artefact,
    DeployCapability,
    Deployment,
    DeploymentResult,
    DeploySpec,
    EnvironmentSpec,
    SmokeCheck,
    SmokeReport,
)

SKIP_EXIT = 77
"""The gate spine's "tooling or inputs absent" code, reused here for the same reason: a deploy
that could not run is not a deploy that failed."""


@dataclass(frozen=True, slots=True)
class ScriptRun:
    """What one wrapped script did. Typed, so no caller greps."""

    argv: list[str]
    returncode: int
    stdout: str = ""
    stderr: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    @property
    def skipped(self) -> bool:
        return self.returncode == SKIP_EXIT

    def payload(self) -> dict[str, Any] | None:
        return last_json_object(self.stdout)


@dataclass
class ScriptProvider:
    """Runs a repo-provided command and reads a ``DeploymentResult`` from its stdout."""

    command: list[str]
    """argv. ``{run_id}``, ``{project}``, ``{revision}`` and ``{environment}`` are substituted."""
    name: str = "script"
    detect_paths: list[str] = field(default_factory=list)
    """Files whose presence means this repository has such a script. Empty ⇒ always supported."""
    clock: Clock = field(default_factory=SystemClock)
    timeout_s: float = 1800.0
    ttl_s: float = 3 * 3600
    env: dict[str, str] = field(default_factory=dict)

    async def detect(self, workspace: Path) -> Outcome[DeployCapability]:
        if self.detect_paths and not any((workspace / p).exists() for p in self.detect_paths):
            return Outcome.ok(
                DeployCapability(
                    supported=False,
                    provider=self.name,
                    reason=f"none of {', '.join(self.detect_paths)} is present",
                )
            )
        return Outcome.ok(
            DeployCapability(
                supported=True, provider=self.name, reason=f"script: {' '.join(self.command[:2])}"
            )
        )

    async def build(self, workspace: Path, spec: DeploySpec) -> Outcome[Artefact]:
        """The script owns its own build. Splitting it would be inventing a contract for it."""
        return Outcome.ok(Artefact(kind="script", reference=spec.revision))

    async def deploy(
        self, workspace: Path, artefact: Artefact, env: EnvironmentSpec
    ) -> Outcome[Deployment]:
        run = await self.invoke(
            workspace,
            run_id=env.run_id,
            project=env.project,
            revision=artefact.reference,
            environment=env.environment,
            extra_env=env.env,
        )
        if run.skipped:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                "the deploy script reported its tooling or inputs were absent (77)",
                remedy="deployment is optional; this skips rather than failing the run",
            )
        if not run.ok:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"the deploy script exited {run.returncode}",
                details={"stderr": run.stderr[-2000:]},
            )

        payload = run.payload()
        if payload is None:
            return Outcome.fail(
                ErrorCategory.TOOL_FAILURE,
                "the deploy script printed no JSON result",
                remedy=("print a DeploymentResult object on stdout; nothing here parses log lines"),
                details={"stdout": run.stdout[-2000:]},
            )
        try:
            result = DeploymentResult.model_validate(payload)
        except Exception as exc:
            return Outcome.fail(
                ErrorCategory.TOOL_FAILURE,
                f"the deploy script's JSON is not a DeploymentResult: {exc}",
                details={"stdout": run.stdout[-2000:]},
            )

        now = self.clock.now()
        return Outcome.ok(
            Deployment(
                deployment_id=result.deployment_id or new_run_id(),
                provider=self.name,
                environment=env.environment,
                url=result.url,
                revision=result.deployed_sha or artefact.reference,
                project=result.project or env.project,
                volume_namespace=env.volume_namespace,
                created_at=now,
                expires_at=now + timedelta(seconds=env.ttl_s or self.ttl_s),
                metadata={"healthy": str(result.healthy).lower()},
            )
        )

    async def smoke(self, deployment: Deployment, checks: list[SmokeCheck]) -> Outcome[SmokeReport]:
        """Deliberately empty: an unchecked deployment reports *nothing ran*, never a pass.

        The caller supplies a :class:`~ai_harness.deploy.smoke.Smoker` against the URL this
        provider returned. A provider that self-reported "smoked fine" would be marking its own
        homework, which is the failure mode the canary script exists to prevent.
        """
        return Outcome.ok(SmokeReport(url=deployment.url or ""))

    async def teardown(self, deployment: Deployment) -> Outcome[None]:
        return Outcome.ok(None)

    # ── the subprocess ───────────────────────────────────────────────────────────

    async def invoke(
        self,
        workspace: Path,
        *,
        run_id: str = "",
        project: str = "",
        revision: str = "",
        environment: str = "dev",
        extra_env: dict[str, str] | None = None,
        argv: list[str] | None = None,
    ) -> ScriptRun:
        """Run the wrapped command. Never raises — a broken script is a typed result."""
        substitutions = {
            "{run_id}": run_id,
            "{project}": project,
            "{revision}": revision,
            "{environment}": environment,
        }
        rendered = []
        for part in argv if argv is not None else self.command:
            for token, value in substitutions.items():
                part = part.replace(token, value)
            rendered.append(part)

        environ = {**os.environ, **self.env, **(extra_env or {})}
        try:
            process = await asyncio.create_subprocess_exec(
                *rendered,
                cwd=str(workspace),
                env=environ,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except OSError as exc:
            return ScriptRun(argv=rendered, returncode=127, stderr=str(exc))
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except TimeoutError:
            process.kill()
            await process.wait()
            return ScriptRun(
                argv=rendered, returncode=124, stderr=f"exceeded {self.timeout_s:.0f}s"
            )
        return ScriptRun(
            argv=rendered,
            returncode=process.returncode or 0,
            stdout=stdout.decode(errors="replace"),
            stderr=stderr.decode(errors="replace"),
        )


def last_json_object(text: str) -> dict[str, Any] | None:
    """The last well-formed JSON object in the output.

    Scripts log. A contract that demanded stdout be *only* JSON would make every wrapped script
    fragile in a way that has nothing to do with deploying, so the result is the last object and
    the noise before it is ignored.
    """
    best: dict[str, Any] | None = None
    for line in text.splitlines():
        candidate = line.strip()
        if not candidate.startswith("{"):
            continue
        try:
            parsed = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(parsed, dict):
            best = parsed
    if best is not None:
        return best

    # A pretty-printed object spans lines: find the last balanced {...} block.
    start = text.rfind("{")
    while start != -1:
        try:
            parsed = json.loads(text[start:])
        except ValueError:
            start = text.rfind("{", 0, start)
            continue
        return parsed if isinstance(parsed, dict) else None
    return None
