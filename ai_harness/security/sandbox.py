"""Execution isolation — probed, never assumed, and loud when it degrades.

Principle §7.7: *isolation is enforced by the runtime, never asserted in a prompt.* The shell
harness's own comment says it: a comment is not an enforcement mechanism. Only its reviewer is
sandboxed, and a ``bypassPermissions`` model once ``cd``'d out of its worktree into the primary
checkout — which is exactly the failure a prompt cannot prevent.

Three levels, in preference order, **probed at startup rather than declared**: a container, then
bubblewrap, then none. The level actually obtained is recorded on the run and shown by
``agent inspect``, because a run that silently degraded to no isolation is a run whose safety
claims are false.

Credentials never enter the sandbox (§25). Git runs in the harness; the model gets a filesystem
and no way to push — a guarantee that is only real if the token is not sitting in its
environment, which is why :meth:`Sandbox.environment` scrubs rather than filters.
"""

from __future__ import annotations

import asyncio
import os
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.schemas.enums import Isolation

_SCRUBBED_PREFIXES = ("GITHUB_", "GH_", "GITLAB_", "AWS_", "ANTHROPIC_", "OPENAI_", "HARNESS_")
_SCRUBBED_EXACT = ("SSH_AUTH_SOCK", "GIT_ASKPASS", "AWS_PROFILE", "GOOGLE_APPLICATION_CREDENTIALS")

_SCRUBBED_SHAPE = re.compile(
    r"(?i)(^|_)(TOKEN|KEY|SECRET|PASSWORD|PASSWD|CREDENTIAL|CREDENTIALS|AUTH|APIKEY|PAT)($|_)"
)
"""Scrub by the *shape* of the name, not by a list of vendors somebody remembered.

A prefix denylist fails open for every provider nobody thought of — this host alone carries
``XAI_API_KEY``, ``SUPABASE_ACCESS_TOKEN``, ``POSTHOG_API_KEY``, ``EXPO_TOKEN`` and
``CLOUDFLARE_API_TOKEN``, none of which the original list matched. The security suite found
that, and a denylist would have needed extending again on the next machine.
"""

ORDER = (Isolation.CONTAINER, Isolation.BUBBLEWRAP, Isolation.NONE)


@dataclass(frozen=True, slots=True)
class SandboxProbe:
    """What this host can actually do, as opposed to what the configuration hoped for."""

    available: tuple[Isolation, ...]
    chosen: Isolation
    degraded: bool
    reason: str

    @property
    def isolated(self) -> bool:
        return self.chosen is not Isolation.NONE


def probe(
    preferred: Isolation = Isolation.BUBBLEWRAP, *, allow_degraded: bool = False
) -> SandboxProbe:
    """Find the strongest available isolation at or below ``preferred``.

    Returning a *probe* rather than a boolean is deliberate: the caller needs to know both what
    it got and whether that is worse than what it asked for, because the second fact belongs in
    the checkpoint and in the evidence block.
    """
    available: list[Isolation] = []
    if shutil.which("docker") or shutil.which("podman"):
        available.append(Isolation.CONTAINER)
    if shutil.which("bwrap"):
        available.append(Isolation.BUBBLEWRAP)
    available.append(Isolation.NONE)

    for candidate in ORDER[ORDER.index(preferred) :]:
        if candidate not in available:
            continue
        if candidate is Isolation.NONE and not allow_degraded:
            # Running unisolated must be a decision someone made, not a fallback they got.
            break
        return SandboxProbe(
            available=tuple(available),
            chosen=candidate,
            degraded=candidate is not preferred,
            reason=(
                f"{preferred.value} unavailable; running under {candidate.value}"
                if candidate is not preferred
                else f"{candidate.value} available"
            ),
        )
    return SandboxProbe(
        available=tuple(available),
        chosen=Isolation.NONE,
        degraded=True,
        reason=(
            f"no isolation at or below {preferred.value} is available, and running without it "
            "has not been explicitly allowed"
        ),
    )


@dataclass
class Sandbox:
    """Runs a command with the filesystem and environment the policy permits."""

    workspace: Path
    isolation: Isolation = Isolation.BUBBLEWRAP
    allow_network: bool = False
    read_only_paths: list[Path] = field(default_factory=list)
    extra_env: dict[str, str] = field(default_factory=dict)
    timeout_s: float = 1800.0

    def command(self, argv: list[str]) -> list[str]:
        """Wrap ``argv`` in the chosen isolation."""
        if self.isolation is not Isolation.BUBBLEWRAP:
            return argv
        wrapped = [
            "bwrap",
            "--die-with-parent",
            "--unshare-pid",
            "--unshare-ipc",
            "--unshare-uts",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--tmpfs",
            "/tmp",
            # The workspace is the only writable thing the model gets.
            "--bind",
            str(self.workspace),
            str(self.workspace),
            "--chdir",
            str(self.workspace),
        ]
        for system_path in ("/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt"):
            if Path(system_path).exists():
                wrapped += ["--ro-bind", system_path, system_path]
        for extra in self.read_only_paths:
            wrapped += ["--ro-bind", str(extra), str(extra)]
        if not self.allow_network:
            wrapped.append("--unshare-net")
        return [*wrapped, "--", *argv]

    def environment(self) -> dict[str, str]:
        """The environment the sandboxed process sees: no credentials, ever."""
        scrubbed = {
            key: value
            for key, value in os.environ.items()
            if not (
                key.startswith(_SCRUBBED_PREFIXES)
                or key in _SCRUBBED_EXACT
                or _SCRUBBED_SHAPE.search(key)
            )
        }
        scrubbed["HOME"] = str(self.workspace)
        scrubbed["GIT_TERMINAL_PROMPT"] = "0"
        scrubbed.update(self.extra_env)
        return scrubbed

    async def run(self, argv: list[str]) -> Outcome[tuple[int, str]]:
        """Execute inside the sandbox. Failures are outcomes, as everywhere else."""
        try:
            process = await asyncio.create_subprocess_exec(
                *self.command(argv),
                cwd=str(self.workspace),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=self.environment(),
                start_new_session=True,
            )
        except FileNotFoundError as exc:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"cannot start the sandboxed process: {exc}",
                remedy="install the isolation tool, or configure a weaker level explicitly",
            )
        try:
            out, _ = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except TimeoutError:
            process.kill()
            await process.wait()
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT, f"sandboxed command exceeded {self.timeout_s:.0f}s"
            )
        return Outcome.ok((process.returncode or 0, out.decode("utf-8", "replace")))
