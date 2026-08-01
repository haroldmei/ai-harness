"""Dependency provisioning — and, separately, **verification**.

Invariant 16: *``npm ci`` exiting 0 is not evidence the install landed.* In #2124 and #2438 an
install that left a workspace unresolvable exited zero, 154 suites died at load time, and the
failure was read as a code defect — so the fix budget was spent on innocent tests. Three shell
callers trusted the exit code; ``lib/deps-verify.sh`` exists because of it.

So provisioning has two steps that cannot be collapsed:

1. **install** — run the ecosystem's install command;
2. **verify** — ask the ecosystem to *resolve* what the manifest declares, and read that answer.

The result of step 2 then splits two ways, and the split decides where the run goes next:

* a **declared** dependency that will not resolve is an environment problem — a registry
  outage, a lockfile/registry mismatch, a broken toolchain. Bounded retry, then escalate with
  a cause-specific remedy;
* an **undeclared** import is a *code defect* the agent can fix, so it routes to ``ANALYSE``.

Q8 governs installation itself: with a lockfile present the install runs with ``--ignore-scripts``
and no approval; without one, adding a dependency is a supply-chain decision and is gated.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path

from ai_harness.kernel.outcome import ErrorCategory, Outcome


class Ecosystem(StrEnum):
    NPM = "npm"
    PNPM = "pnpm"
    YARN = "yarn"
    PIP = "pip"
    POETRY = "poetry"
    UV = "uv"
    GO = "go"
    CARGO = "cargo"


@dataclass(frozen=True, slots=True)
class EcosystemSpec:
    """How one ecosystem installs, verifies, and proves it has a lockfile."""

    ecosystem: Ecosystem
    manifest: str
    lockfiles: tuple[str, ...]
    install: tuple[str, ...]
    install_no_lock: tuple[str, ...]
    verify: tuple[str, ...]
    ignore_scripts_flag: str | None = None


SPECS: tuple[EcosystemSpec, ...] = (
    EcosystemSpec(
        ecosystem=Ecosystem.PNPM,
        manifest="pnpm-workspace.yaml",
        lockfiles=("pnpm-lock.yaml",),
        install=("pnpm", "install", "--frozen-lockfile"),
        install_no_lock=("pnpm", "install"),
        verify=("pnpm", "list", "--depth", "0", "--json"),
        ignore_scripts_flag="--ignore-scripts",
    ),
    EcosystemSpec(
        ecosystem=Ecosystem.NPM,
        manifest="package.json",
        lockfiles=("package-lock.json", "npm-shrinkwrap.json"),
        install=("npm", "ci"),
        install_no_lock=("npm", "install"),
        # `npm ls` is the question `npm ci`'s exit code does not answer: it resolves the tree
        # and fails when a declared dependency is missing or unmet.
        verify=("npm", "ls", "--all", "--json"),
        ignore_scripts_flag="--ignore-scripts",
    ),
    EcosystemSpec(
        ecosystem=Ecosystem.UV,
        manifest="pyproject.toml",
        lockfiles=("uv.lock",),
        install=("uv", "sync", "--frozen"),
        install_no_lock=("uv", "sync"),
        verify=("uv", "pip", "check"),
    ),
    EcosystemSpec(
        ecosystem=Ecosystem.POETRY,
        manifest="pyproject.toml",
        lockfiles=("poetry.lock",),
        install=("poetry", "install", "--no-interaction"),
        install_no_lock=("poetry", "install", "--no-interaction"),
        verify=("poetry", "check", "--lock"),
    ),
    EcosystemSpec(
        ecosystem=Ecosystem.PIP,
        manifest="requirements.txt",
        lockfiles=("requirements.lock", "requirements.txt"),
        install=("pip", "install", "-r", "requirements.txt"),
        install_no_lock=("pip", "install", "-r", "requirements.txt"),
        verify=("pip", "check"),
    ),
    EcosystemSpec(
        ecosystem=Ecosystem.GO,
        manifest="go.mod",
        lockfiles=("go.sum",),
        install=("go", "mod", "download"),
        install_no_lock=("go", "mod", "download"),
        verify=("go", "mod", "verify"),
    ),
    EcosystemSpec(
        ecosystem=Ecosystem.CARGO,
        manifest="Cargo.toml",
        lockfiles=("Cargo.lock",),
        install=("cargo", "fetch", "--locked"),
        install_no_lock=("cargo", "fetch"),
        verify=("cargo", "metadata", "--format-version", "1", "--offline"),
    ),
)

_UNDECLARED_PATTERNS = (
    re.compile(r"(?:ModuleNotFoundError|ImportError): No module named ['\"]([\w.]+)['\"]"),
    re.compile(r"Cannot find module ['\"]([^'\"]+)['\"]"),
    re.compile(r"Module not found: Error: Can't resolve ['\"]([^'\"]+)['\"]"),
    re.compile(r"error: failed to load manifest for dependency `([^`]+)`"),
)

_ENVIRONMENT_PATTERNS = (
    re.compile(r"ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN", re.I),
    re.compile(r"network is unreachable|temporary failure in name resolution", re.I),
    re.compile(r"ENOSPC|no space left on device", re.I),
    re.compile(r"registry.*(?:5\d\d|timed out)", re.I),
)


@dataclass(frozen=True, slots=True)
class DepsReport:
    """What happened, and — when it failed — whose problem it is."""

    ecosystem: Ecosystem | None = None
    installed: bool = False
    verified: bool = False
    lockfile_present: bool = False
    unresolved: list[str] = field(default_factory=list)
    undeclared: list[str] = field(default_factory=list)
    """Imports nothing declares. A code defect the agent can fix, not an environment problem."""
    log_tail: str = ""
    remedy: str | None = None

    @property
    def ok(self) -> bool:
        return self.installed and self.verified

    @property
    def is_code_defect(self) -> bool:
        return bool(self.undeclared)


@dataclass
class DepsProvisioner:
    """Detects the ecosystems in a workspace, installs them, and verifies the result."""

    root: Path
    workspaces: list[str] = field(default_factory=list)
    allow_install_without_lockfile: bool = False
    """Q8: without a lockfile, installing is a supply-chain decision — approval-gated."""
    timeout_s: float = 900.0
    env: dict[str, str] = field(default_factory=dict)

    def detect(self, directory: Path | None = None) -> list[EcosystemSpec]:
        base = directory or self.root
        found: list[EcosystemSpec] = []
        seen: set[str] = set()
        for spec in SPECS:
            if not (base / spec.manifest).exists() or spec.manifest in seen:
                continue
            # pyproject.toml serves several ecosystems; the lockfile decides which.
            if spec.manifest == "pyproject.toml" and not any(
                (base / lock).exists() for lock in spec.lockfiles
            ):
                continue
            found.append(spec)
            seen.add(spec.manifest)
        return found

    async def provision(self, directory: Path | None = None) -> Outcome[DepsReport]:
        base = directory or self.root
        specs = self.detect(base)
        if not specs:
            return Outcome.ok(DepsReport(installed=True, verified=True))

        spec = specs[0]
        has_lock = any((base / lock).exists() for lock in spec.lockfiles)
        if not has_lock and not self.allow_install_without_lockfile:
            return Outcome.fail(
                ErrorCategory.POLICY,
                f"{spec.ecosystem} has no lockfile ({', '.join(spec.lockfiles)})",
                remedy=(
                    "installing without a lockfile is a supply-chain decision (Q8) — "
                    "commit a lockfile or approve INSTALL_DEPS"
                ),
            )

        argv = list(spec.install if has_lock else spec.install_no_lock)
        if spec.ignore_scripts_flag:
            argv.append(spec.ignore_scripts_flag)

        install = await self._exec(argv, cwd=base)
        if install.is_err:
            return Outcome.of(install.error)  # type: ignore[arg-type]
        install_code, install_log = install.unwrap()

        # The exit code is recorded but never trusted on its own: verification is what decides.
        verify = await self._exec(list(spec.verify), cwd=base)
        if verify.is_err:
            return Outcome.of(verify.error)  # type: ignore[arg-type]
        verify_code, verify_log = verify.unwrap()

        combined = f"{install_log}\n{verify_log}"
        if install_code == 0 and verify_code == 0:
            return Outcome.ok(
                DepsReport(
                    ecosystem=spec.ecosystem,
                    installed=True,
                    verified=True,
                    lockfile_present=has_lock,
                    log_tail=combined[-2000:],
                )
            )

        return Outcome.ok(
            DepsReport(
                ecosystem=spec.ecosystem,
                installed=install_code == 0,
                verified=False,
                lockfile_present=has_lock,
                unresolved=_unresolved(verify_log),
                undeclared=undeclared_imports(combined),
                log_tail=combined[-2000:],
                remedy=remedy_for(combined, spec.ecosystem),
            )
        )

    async def _exec(self, argv: list[str], *, cwd: Path) -> Outcome[tuple[int, str]]:
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                cwd=str(cwd),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env={**os.environ, "CI": "1", **self.env},
            )
        except FileNotFoundError:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{argv[0]} is not installed",
                remedy=f"install the {argv[0]} toolchain on this host",
                dependency=f"toolchain:{argv[0]}",
            )
        try:
            out, _ = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except TimeoutError:
            process.kill()
            await process.wait()
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{argv[0]} exceeded {self.timeout_s:.0f}s",
                dependency=f"toolchain:{argv[0]}",
            )
        return Outcome.ok((process.returncode or 0, out.decode("utf-8", "replace")))


def undeclared_imports(log: str) -> list[str]:
    """Modules nothing declares — the signature of a code defect rather than a bad install."""
    found: list[str] = []
    for pattern in _UNDECLARED_PATTERNS:
        found += pattern.findall(log)
    return sorted(set(found))


def _unresolved(verify_log: str) -> list[str]:
    """Declared-but-unmet dependencies, from whatever shape the verifier reports."""
    names: list[str] = []
    for line in verify_log.splitlines():
        if "UNMET DEPENDENCY" in line or "missing:" in line:
            names.append(line.strip())
    try:
        payload = json.loads(verify_log)
    except json.JSONDecodeError:
        return names
    problems = payload.get("problems") if isinstance(payload, dict) else None
    if isinstance(problems, list):
        names += [str(p) for p in problems]
    return names


def remedy_for(log: str, ecosystem: Ecosystem) -> str:
    """A *cause-specific* remedy.

    The shell merger picks different escalation text for Docker starvation and for an
    unresolved npm workspace, because "telling a human to chase the wrong one wastes the
    escalation". The same reasoning applies here.
    """
    if undeclared_imports(log):
        return (
            "an import resolves to nothing the manifest declares — this is a code defect the "
            "agent can fix, not an environment problem"
        )
    for pattern in _ENVIRONMENT_PATTERNS:
        if pattern.search(log):
            return (
                "the registry or the network is unavailable — retry is bounded, and this is "
                "never counted against the fix budget"
            )
    return (
        f"the {ecosystem} install exited cleanly but the tree does not resolve; check the "
        "lockfile against the manifest before blaming any test"
    )
