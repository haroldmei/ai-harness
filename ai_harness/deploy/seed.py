"""Seed data — one implementation, two callers (§20.3).

`seed-integrity.sh` already gets this right, and the semantics are ported exactly rather than
improved. Its four properties, each of which exists because the obvious shortcut is wrong:

1. **Seeding and verifying are separate steps.** A seed command exiting 0 is not evidence the
   rows landed, for exactly the reason `npm ci` exiting 0 is not evidence the install landed
   (invariant 12). Separate steps also produce separate failures, so "the seed crashed" and
   "the seed ran and produced nothing" are distinguishable without reading a log.

2. **Minimum rows per table**, so a silently-empty seed fails loudly instead of handing an
   empty database to a smoke check that then tests nothing.

3. **Idempotency is asserted, not assumed.** Re-run the seed and assert the row counts have not
   moved. This is the property that makes a seed safe to run on *every* deployment, and it is
   cheap enough that not checking it is indefensible.

4. **Never production.** The DSN is validated against the run's own ephemeral environment
   before any command runs, and anything ambiguous fails closed. This is the one place in the
   harness where a mistake is unrecoverable, so it is the one place that refuses to guess.

A failed seed is ``ENVIRONMENT``, never a code defect: the branch under test did not cause the
database to be unreachable, and blaming it burns the fix budget on innocent code (#2124).

The same object serves the ``seed-integrity`` gate and the dev deployment. Two implementations
would be two sets of semantics, and the shell's own history is what that looks like.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.observability.logging import Logger
from ai_harness.schemas.deploy import EnvironmentSpec
from ai_harness.schemas.enums import GateSelection, GateStatus
from ai_harness.schemas.gates import GateResult
from ai_harness.schemas.seed import SeedResult

PRODUCTION_MARKERS = (
    "prod",
    "production",
    "live",
    ".rds.amazonaws.com",
    ".supabase.co",
    "neon.tech",
    "cloudsql",
)
"""Substrings that make a DSN *not obviously ephemeral*. Matching any of them fails closed."""

LOCAL_HOSTS = ("127.0.0.1", "localhost", "::1", "postgres", "db")
"""Hosts an ephemeral stack actually uses. Anything else is refused rather than interpreted."""


class SeedRefused(Exception):
    """Raised only inside this module, and converted to a typed failure at the boundary."""


@dataclass(frozen=True, slots=True)
class SeedManifest:
    """The repo's own description of its seed. Read, never inferred."""

    boot_command: list[str] = field(default_factory=list)
    """Migrate + seed + verify, as the repository defines it."""
    seed_command: list[str] = field(default_factory=list)
    """Re-runnable on its own. This is what idempotency is asserted against."""
    verify_command: list[str] = field(default_factory=list)
    tables: dict[str, int] = field(default_factory=dict)
    """table → minimum rows."""
    count_queries: dict[str, str] = field(default_factory=dict)
    idempotent: bool = True
    version: str = ""
    deterministic_seed: int = 1337

    @classmethod
    def load(cls, path: Path) -> SeedManifest:
        raw: dict[str, Any] = json.loads(path.read_text())
        expectations = raw.get("seed_expectations") or {}
        tables = {}
        queries = {}
        for entry in expectations.get("tables") or []:
            name = entry.get("name")
            if not name:
                continue
            tables[name] = int(entry.get("min_rows") or 0)
            if entry.get("count_query"):
                queries[name] = str(entry["count_query"])
        return cls(
            boot_command=_argv(raw.get("boot_command")),
            seed_command=_argv(raw.get("seed_command")),
            verify_command=_argv(raw.get("verify_command")),
            tables=tables,
            count_queries=queries,
            idempotent=bool(expectations.get("idempotent", True)),
            version=str(raw.get("version") or ""),
        )


def _argv(value: object) -> list[str]:
    if value is None or value == "":
        return []
    if isinstance(value, list):
        return [str(part) for part in value]
    # The manifest in the wild carries a shell string. Honour it, explicitly and visibly.
    return ["bash", "-c", str(value)]


def dsn_is_ephemeral(dsn: str, environment: EnvironmentSpec) -> tuple[bool, str]:
    """Is this DSN unambiguously the run's own throwaway database?

    Fails closed on everything it does not positively recognise. A permissive answer here is
    the only unrecoverable mistake in the harness, so "I am not sure" and "no" are the same
    answer.
    """
    if not dsn:
        return False, "no DSN was provided"
    lowered = dsn.lower()
    for marker in PRODUCTION_MARKERS:
        if marker in lowered:
            return False, f"the DSN contains {marker!r}, which is not an ephemeral database"

    host = re.search(r"@([^/:?]+)", lowered)
    if host is None:
        return False, "the DSN has no host to check"
    if host.group(1) not in LOCAL_HOSTS:
        return False, f"host {host.group(1)!r} is not one this run brought up"

    port = re.search(r"@[^/:?]+:(\d+)", lowered)
    if port is not None and environment.port_base:
        expected = str(environment.port_base + 432)
        if port.group(1) != expected:
            return False, (
                f"port {port.group(1)} is not this environment's database port ({expected}) — "
                "a matching host with a foreign port is somebody else's stack"
            )
    return True, "the DSN is this run's own ephemeral database"


@dataclass
class Seeder:
    """Boots, seeds, verifies, and asserts idempotency. Used by the gate and by the deploy."""

    counter: Any = None
    """``async (table, query) -> int``. Injected so the row counts come from the real database."""
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)
    timeout_s: float = 1800.0
    env: dict[str, str] = field(default_factory=dict)

    async def run(
        self,
        workspace: Path,
        *,
        manifest: Path | SeedManifest,
        environment: EnvironmentSpec,
        dsn: str = "",
    ) -> SeedResult:
        loaded = manifest if isinstance(manifest, SeedManifest) else SeedManifest.load(manifest)
        result = SeedResult(expected_min_rows=dict(loaded.tables))

        # 0. Never production. Before any command runs, and it fails closed.
        target = dsn or self.env.get("DATABASE_URL") or environment.env.get("DATABASE_URL", "")
        ok, why = dsn_is_ephemeral(target, environment)
        if not ok:
            return result.model_copy(
                update={"failures": [f"refusing to seed: {why}"], "seeded": False}
            )

        # 1. Seed.
        boot = loaded.boot_command or loaded.seed_command
        if boot:
            ran = await self._exec(workspace, boot, environment, target)
            if ran.is_err:
                message = ran.error.message if ran.error else "the seed command failed"
                return result.model_copy(update={"failures": [message]})
        result = result.model_copy(update={"seeded": True})

        # 2. Verify — a separate step, with its own failure.
        if loaded.verify_command:
            verified = await self._exec(workspace, loaded.verify_command, environment, target)
            if verified.is_err:
                message = verified.error.message if verified.error else "verification failed"
                return result.model_copy(update={"failures": [f"seed did not land: {message}"]})

        counts = await self._counts(loaded)
        short = [
            f"{table}: {counts.get(table, 0)} rows < min_rows={minimum}"
            for table, minimum in loaded.tables.items()
            if counts.get(table, 0) < minimum
        ]
        result = result.model_copy(update={"row_counts": counts, "verified": not short})
        if short:
            return result.model_copy(update={"failures": short})

        # 3. Idempotency: re-run, and assert nothing moved.
        if not (loaded.idempotent and loaded.seed_command):
            return result
        again = await self._exec(workspace, loaded.seed_command, environment, target)
        if again.is_err:
            message = again.error.message if again.error else "the second seed run failed"
            return result.model_copy(
                update={"idempotent": False, "failures": [f"re-running the seed failed: {message}"]}
            )
        after = await self._counts(loaded)
        moved = [
            f"{table}: {counts.get(table, 0)} → {after.get(table, 0)}"
            for table in loaded.tables
            if counts.get(table, 0) != after.get(table, 0)
        ]
        if moved:
            return result.model_copy(
                update={
                    "idempotent": False,
                    "row_counts": after,
                    "failures": [
                        "the seed is not idempotent — row counts changed: " + "; ".join(moved)
                    ],
                }
            )
        return result.model_copy(update={"idempotent": True})

    async def gate(
        self,
        workspace: Path,
        *,
        manifest: Path | SeedManifest,
        environment: EnvironmentSpec,
        dsn: str = "",
        name: str = "seed-integrity",
        required: bool = True,
    ) -> GateResult:
        """The **same** run, projected as a gate result.

        This is the second caller, and it is one method rather than one module: the gate and the
        dev deployment must not be able to disagree about what a good seed is. `seed-integrity.sh`
        exits 77 when its tooling is absent, and that is preserved — an absent database is not a
        failing seed, and calling it one would fail branches for the state of the host.
        """
        started = self.clock.monotonic()
        result = await self.run(workspace, manifest=manifest, environment=environment, dsn=dsn)
        duration = self.clock.monotonic() - started

        unavailable = any("refusing to seed" in failure for failure in result.failures)
        status = (
            GateStatus.SKIP if unavailable else (GateStatus.PASS if result.ok else GateStatus.FAIL)
        )
        return GateResult(
            name=name,
            raw_status=status,
            required=required,
            selection=GateSelection.NOT_SELECTED if unavailable else GateSelection.RAN,
            reason="; ".join(result.failures) or "rows and idempotency verified",
            duration_s=duration,
            failing_tests=sorted(result.row_counts),
        )

    async def _counts(self, manifest: SeedManifest) -> dict[str, int]:
        if self.counter is None:
            return {}
        counts: dict[str, int] = {}
        for table in manifest.tables:
            query = manifest.count_queries.get(table, "")
            counts[table] = int(await self.counter(table, query))
        return counts

    async def _exec(
        self, workspace: Path, argv: list[str], environment: EnvironmentSpec, dsn: str
    ) -> Outcome[str]:
        environ = {
            **os.environ,
            **self.env,
            **environment.env,
            "DATABASE_URL": dsn,
            "ENVIRONMENT": "development",
        }
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                cwd=str(workspace),
                env=environ,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except OSError as exc:
            return Outcome.fail(ErrorCategory.ENVIRONMENT, f"{argv[0]} is not runnable: {exc}")
        try:
            stdout, _ = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except TimeoutError:
            process.kill()
            await process.wait()
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT, f"the seed exceeded {self.timeout_s:.0f}s"
            )
        text = stdout.decode(errors="replace")
        if process.returncode != 0:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{' '.join(argv[:2])} exited {process.returncode}: {text.strip()[-300:]}",
                remedy="a failed seed is an environment failure, not a defect in the branch",
            )
        return Outcome.ok(text)
