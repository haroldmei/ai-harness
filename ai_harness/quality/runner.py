"""Parallel gate execution — two resource classes, real timeouts, and no port races.

Ports the execution semantics of ``quality-gates.sh``'s dispatcher for repositories without a
shell spine, and gives the ones that have a spine the same kill discipline. Four properties,
each with an incident behind it:

* **Two resource classes.** ``cpu`` gates and ``stack`` gates get separate semaphores, because
  a stack gate boots containers and binds ports; running three of those concurrently starves
  the host in a way three test processes do not.
* **Port bands are offset, not probed.** Two runs probing from a shared base select the same
  "free" port before either binds it. Slot *n* gets base + 1000·n, and the arithmetic cannot
  race.
* **A timeout kills the process GROUP.** A bare ``kill`` orphans the vitest worker pool and the
  compose children — exactly the processes that wedge a gate in the first place.
* **``after`` edges are honoured, and artefacts hand off.** ``coverage`` waits for ``unit`` and
  reuses its report rather than re-running 3,489 tests twice.
"""

from __future__ import annotations

import asyncio
import os
import signal
import time
from collections.abc import Coroutine
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.quality.reason import looks_environmental, reason_summary
from ai_harness.quality.registry import required_names, select
from ai_harness.schemas.enums import GateSelection, GateSet, GateStatus
from ai_harness.schemas.gates import GateProfile, GateReport, GateResult, GateSpec

STACK_PORT_BASE = 20000
STACK_PORT_BAND = 1000


@dataclass
class Slot:
    """A stack slot: a private compose project and a port band that cannot collide."""

    index: int
    project_prefix: str = "harness"

    @property
    def project(self) -> str:
        return f"{self.project_prefix}-{self.index}"

    @property
    def port_base(self) -> int:
        return STACK_PORT_BASE + STACK_PORT_BAND * self.index

    def env(self) -> dict[str, str]:
        return {
            "COMPOSE_PROJECT_NAME": self.project,
            "HARNESS_PORT_BASE": str(self.port_base),
        }


@dataclass
class GateRunner:
    """Runs a gate profile, in parallel, bounded, and interpreting what comes back."""

    root: Path
    profile: GateProfile
    clock: Clock = field(default_factory=SystemClock)
    env: dict[str, str] = field(default_factory=dict)
    suite_timeout_s: float = 7200.0
    project_prefix: str = "harness"

    async def run(
        self,
        *,
        gate_set: GateSet = GateSet.FULL,
        only: list[str] | None = None,
        skip: list[str] | None = None,
        commit_sha: str = "",
        base_sha: str = "",
    ) -> Outcome[GateReport]:
        requested = only if only is not None else self.profile.names_for(gate_set)
        specs = {spec.name: spec for spec in self.profile.gates}
        selection = select(list(specs), only=only, skip=skip)
        required = required_names(self.profile.tier)

        cpu = asyncio.Semaphore(max(self.profile.cpu_jobs, 1))
        stack = asyncio.Semaphore(max(self.profile.stack_jobs, 1))
        slots = asyncio.Queue[Slot]()
        for index in range(max(self.profile.stack_jobs, 1)):
            slots.put_nowait(Slot(index=index, project_prefix=self.project_prefix))

        done: dict[str, GateResult] = {}
        started = self.clock.monotonic()

        async def run_one(spec: GateSpec) -> GateResult:
            # `after` edges: wait for what this gate consumes, and refuse to run if it failed.
            for dependency in spec.after:
                while dependency not in done and dependency in specs:
                    await asyncio.sleep(0)
                upstream = done.get(dependency)
                if upstream is not None and upstream.status is GateStatus.FAIL:
                    return GateResult(
                        name=spec.name,
                        raw_status=GateStatus.SKIP,
                        required=spec.name in required,
                        selection=GateSelection.RAN,
                        reason=f"not run: {dependency} failed and this consumes its output",
                    )

            semaphore = stack if spec.resource == "stack" else cpu
            async with semaphore:
                slot = await slots.get() if spec.resource == "stack" else None
                try:
                    return await self._exec_gate(spec, slot, required)
                finally:
                    if slot is not None:
                        slots.put_nowait(slot)

        runnable = [
            spec
            for name, spec in specs.items()
            if name in requested and selection.get(name) is GateSelection.RAN
        ]
        try:
            results = await asyncio.wait_for(
                asyncio.gather(
                    *(self._record(run_one(spec), spec.name, done) for spec in runnable)
                ),
                timeout=self.suite_timeout_s,
            )
        except TimeoutError:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"the gate suite exceeded {self.suite_timeout_s:.0f}s",
                remedy="a suite that will not finish is an environment failure, not a defect",
            )

        # Gates that were not selected are honest skips; a required one is NOT promoted (§19.3).
        for name, spec in specs.items():
            if name in {r.name for r in results}:
                continue
            results.append(
                GateResult(
                    name=name,
                    raw_status=GateStatus.SKIP,
                    required=name in required,
                    selection=selection.get(name, GateSelection.NOT_SELECTED),
                    reason="filtered out",
                )
            )
            _ = spec

        wall_clock = self.clock.monotonic() - started
        return Outcome.ok(
            GateReport(
                commit_sha=commit_sha,
                base_sha=base_sha,
                tier=self.profile.tier,
                gate_set=gate_set,
                results=results,
                wall_clock_s=wall_clock,
                gate_time_s=sum(r.duration_s or 0 for r in results),
                profile_discovered=self.profile.discovered,
                no_gates_discovered=self.profile.no_gates_discovered,
            )
        )

    async def _record(
        self, coro: Coroutine[Any, Any, GateResult], name: str, done: dict[str, GateResult]
    ) -> GateResult:
        """Publish each result as it lands, so `after` edges can see it."""
        result = await coro
        done[name] = result
        return result

    async def _exec_gate(self, spec: GateSpec, slot: Slot | None, required: set[str]) -> GateResult:
        if not spec.command:
            # A named gate with no implementation FAILS. It is one omission away on every new
            # gate, and a silent drop is indistinguishable from a pass.
            return GateResult(
                name=spec.name,
                raw_status=GateStatus.FAIL,
                required=spec.name in required,
                reason=f"gate {spec.name!r} is named but has no command",
            )

        env = {**os.environ, **self.env, **spec.env, **(slot.env() if slot else {})}
        started = time.monotonic()
        try:
            process = await asyncio.create_subprocess_exec(
                *spec.command,
                cwd=str(self.root / spec.workdir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=env,
                start_new_session=True,  # its own group, so the whole tree is killable
            )
        except (FileNotFoundError, NotADirectoryError) as exc:
            return GateResult(
                name=spec.name,
                raw_status=GateStatus.SKIP,
                required=spec.name in required,
                reason=f"tooling unavailable: {exc}",
                duration_s=0.0,
            )

        try:
            out, _ = await asyncio.wait_for(process.communicate(), timeout=spec.timeout_s)
        except TimeoutError:
            _kill_tree(process)
            await _reap(process)
            return GateResult(
                name=spec.name,
                raw_status=GateStatus.TIMEOUT,
                required=spec.name in required,
                reason=f"exceeded {spec.timeout_s}s and the process group was killed",
                duration_s=time.monotonic() - started,
            )

        duration = time.monotonic() - started
        text = out.decode("utf-8", "replace")
        code = process.returncode or 0

        if code == 77:
            # Exit 77 is "the tooling or inputs are absent". The schema promotes it to FAIL when
            # the gate is required at this tier — a skipped required check is a failure.
            return GateResult(
                name=spec.name,
                raw_status=GateStatus.SKIP,
                required=spec.name in required,
                reason=reason_summary(text) if text.strip() else "skipped (77)",
                duration_s=duration,
                exit_code=code,
            )
        if code == 0:
            return GateResult(
                name=spec.name,
                raw_status=GateStatus.PASS,
                required=spec.name in required,
                duration_s=duration,
                exit_code=code,
            )
        return GateResult(
            name=spec.name,
            raw_status=GateStatus.ERROR if looks_environmental(text) else GateStatus.FAIL,
            required=spec.name in required,
            reason=reason_summary(text),
            duration_s=duration,
            exit_code=code,
            failing_tests=_failing(text),
        )

    async def rerun(self, report: GateReport, names: list[str]) -> Outcome[GateReport]:
        """Re-run **only** the named gates — the flake confirmation of §19.4.

        Never a blanket retry: re-running everything hides which gate was unstable and costs
        the full suite to learn one bit.
        """
        return await self.run(
            only=names,
            gate_set=report.gate_set,
            commit_sha=report.commit_sha,
            base_sha=report.base_sha,
        )


def _failing(text: str) -> list[str]:
    from ai_harness.quality.reason import failing_test_ids

    return failing_test_ids(text)


def _kill_tree(process: asyncio.subprocess.Process) -> None:
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        try:
            process.kill()
        except ProcessLookupError:
            return


async def _reap(process: asyncio.subprocess.Process) -> None:
    try:
        await asyncio.wait_for(process.wait(), timeout=5)
    except (TimeoutError, ProcessLookupError):
        return
