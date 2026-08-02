"""Run the repository's own gate spine and consume its scorecard.

This is not a migration compromise, it is the permanent design (§19.1). ``quality-gates.sh``
is 1,492 tuned lines that already emit ``{gate, status, reason, duration_s}`` from ``--json``,
so **no change to the shell is required** for the port to consume it.

Two behaviours are the adapter's own, and both matter:

* **Process-group kill on timeout.** A bare ``kill`` orphans the vitest worker pool and the
  compose children — exactly the processes that wedge a gate. The child is started in its own
  process group and the whole group is signalled.
* **Requiredness is resolved here, not trusted from the scorecard.** The shell promotes a
  required skip to a failure internally; the adapter re-derives requiredness from the tier so
  that a scorecard produced with a different ``--tier`` cannot smuggle a weaker contract in.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import signal
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.quality.reason import looks_environmental
from ai_harness.quality.registry import required_names, select
from ai_harness.schemas.enums import GateSelection, GateSet, GateStatus, Tier
from ai_harness.schemas.gates import GateProfile, GateReport, GateResult

_STATUS_MAP = {
    "pass": GateStatus.PASS,
    "ok": GateStatus.PASS,
    "fail": GateStatus.FAIL,
    "skip": GateStatus.SKIP,
    "timeout": GateStatus.TIMEOUT,
    "error": GateStatus.ERROR,
}


@dataclass
class ShellGateAdapter:
    """Invokes a discovered entry point and maps its scorecard onto a :class:`GateReport`."""

    root: Path
    profile: GateProfile
    timeout_s: float = 7200.0
    env: dict[str, str] = field(default_factory=dict)
    clock: Clock = field(default_factory=SystemClock)

    async def run(
        self,
        *,
        gate_set: GateSet = GateSet.FULL,
        only: list[str] | None = None,
        skip: list[str] | None = None,
        commit_sha: str = "",
        base_sha: str = "",
    ) -> Outcome[GateReport]:
        if self.profile.entry_point is None:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                "no gate entry point was discovered",
                remedy="add .harness/gates.yaml, or a scripts/quality-gates.sh / make check target",
            )

        requested = only if only is not None else self.profile.names_for(gate_set)
        with tempfile.TemporaryDirectory() as tmp:
            scorecard = Path(tmp) / "gates.json"
            argv = [
                *self.profile.entry_point,
                "--tier",
                self.profile.tier.value,
                "--json",
                str(scorecard),
            ]
            if requested:
                argv += ["--only", ",".join(requested)]
            if skip:
                argv += ["--skip", ",".join(skip)]

            started = self.clock.monotonic()
            outcome = await self._exec(argv)
            wall_clock = self.clock.monotonic() - started

            if outcome.is_err:
                assert outcome.error is not None
                return Outcome.of(outcome.error)
            stdout, _exit_code = outcome.unwrap()

            if not scorecard.exists():
                # The spine writes its scorecard last; its absence means the run died, which
                # is an environment problem, not a red gate. Blaming the code here is how a
                # merge queue wedges accusing an innocent base.
                return Outcome.fail(
                    ErrorCategory.ENVIRONMENT,
                    "the gate runner produced no scorecard",
                    remedy="check the runner's own output; no gate verdict can be inferred",
                    details={"argv": argv, "stdout_tail": stdout[-2000:]},
                )
            try:
                rows = json.loads(scorecard.read_text())
            except json.JSONDecodeError as exc:
                return Outcome.fail(
                    ErrorCategory.ENVIRONMENT,
                    f"the scorecard was not valid JSON: {exc}",
                )

        return Outcome.ok(
            self.to_report(
                rows,
                requested=requested,
                only=only,
                skip=skip,
                gate_set=gate_set,
                commit_sha=commit_sha,
                base_sha=base_sha,
                wall_clock_s=wall_clock,
            )
        )

    def to_report(
        self,
        rows: list[dict[str, Any]],
        *,
        requested: list[str],
        only: list[str] | None = None,
        skip: list[str] | None = None,
        gate_set: GateSet = GateSet.FULL,
        commit_sha: str = "",
        base_sha: str = "",
        wall_clock_s: float = 0.0,
    ) -> GateReport:
        """Map scorecard rows onto typed results, re-deriving requiredness from the tier.

        The selection map must cover **every** name in the scorecard, not just the requested
        ones. The spine reports its whole registry with the unselected gates marked skipped, so
        deriving selection from ``requested`` alone made every unselected required gate look
        like a gate that ran and returned 77 — and promoted it to a failure. A required gate
        absent from ``--only`` is an honest skip; only a deny-listed or 77-returning one fails.
        """
        required = required_names(self.profile.tier)
        scorecard_names = [str(row.get("gate", "")).strip() for row in rows]
        selection = select([*requested, *(n for n in scorecard_names if n)], only=only, skip=skip)
        results: list[GateResult] = []
        gate_time = 0.0

        for row in rows:
            name = str(row.get("gate", "")).strip()
            if not name:
                continue
            duration = row.get("duration_s")
            duration_f = float(duration) if duration is not None else None
            gate_time += duration_f or 0.0
            status = _STATUS_MAP.get(str(row.get("status", "")).lower(), GateStatus.ERROR)
            results.append(
                GateResult(
                    name=name,
                    raw_status=status,
                    # A spine that reports `fail` has already applied its OWN requiredness — it
                    # is the repository's contract, and this harness's tier table is a
                    # transcription of a *different* repository's spine. Where they disagree the
                    # repository wins, and it may only ever add requirements: demoting a gate the
                    # spine failed produced "RESULT: all required gates pass" on a report whose
                    # own reason line read "REQUIRED for tier 'launch' but unavailable".
                    required=name in required or status is GateStatus.FAIL,
                    selection=selection.get(name, GateSelection.RAN),
                    reason=str(row.get("reason", "")),
                    duration_s=duration_f,
                )
            )

        # A gate that was asked for and is missing from the scorecard did not silently pass.
        reported = {r.name for r in results}
        for name in requested:
            if name in reported:
                continue
            results.append(
                GateResult(
                    name=name,
                    raw_status=GateStatus.SKIP,
                    required=name in required,
                    selection=selection.get(name, GateSelection.RAN),
                    reason="requested but absent from the scorecard",
                )
            )

        return GateReport(
            commit_sha=commit_sha,
            base_sha=base_sha,
            tier=self.profile.tier,
            gate_set=gate_set,
            results=results,
            wall_clock_s=wall_clock_s,
            gate_time_s=gate_time,
            profile_discovered=self.profile.discovered,
            no_gates_discovered=self.profile.no_gates_discovered,
        )

    async def _exec(self, argv: list[str]) -> Outcome[tuple[str, int]]:
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                cwd=self.root,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env={**os.environ, **self.env},
                start_new_session=True,  # its own process group, so the whole tree is killable
            )
        except FileNotFoundError as exc:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"cannot execute the gate entry point: {exc}",
            )

        try:
            stdout_bytes, _ = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except TimeoutError:
            _kill_tree(process)
            await _reap(process)
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"the gate suite exceeded {self.timeout_s:.0f}s and was killed",
                remedy="a wedged suite is an environment failure, not a code defect",
            )

        stdout = stdout_bytes.decode("utf-8", "replace")
        if process.returncode not in (0, 1) and looks_environmental(stdout):
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                "the gate runner failed for an environmental reason",
                details={"exit_code": process.returncode, "stdout_tail": stdout[-2000:]},
            )
        return Outcome.ok((stdout, process.returncode or 0))


def _kill_tree(process: asyncio.subprocess.Process) -> None:
    """SIGKILL the whole process group.

    A bare ``kill`` leaves the vitest worker pool and the compose children running — and those
    are precisely the processes that wedged the gate in the first place.
    """
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        # The group is gone or not ours; fall back to the single process rather than nothing.
        with contextlib.suppress(ProcessLookupError):
            process.kill()


async def _reap(process: asyncio.subprocess.Process) -> None:
    try:
        await asyncio.wait_for(process.wait(), timeout=5)
    except (TimeoutError, ProcessLookupError):
        return


def tier_from(value: str | None, default: Tier = Tier.LAUNCH) -> Tier:
    """Parse a ``--tier`` argument. An unknown value raises rather than weakening the run."""
    from ai_harness.quality.registry import parse_tier

    return parse_tier(value) if value else default
