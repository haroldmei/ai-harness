"""One card, one resident model, and an honest bill for the difference (L2).

24 GB holds one 4-bit 30B model or one 4-bit 24B model, and not both. The roster demands two,
because ``reviewer ≠ implementer`` is a refusal rather than a preference — so something has to
own the GPU, decide who is resident, and be impossible to route around. Without that, the first
concurrent call OOMs the server in the middle of a review and loses generation that was already
paid for in wall-clock.

:mod:`ai_harness.kernel.lease` is already the right primitive: a resource with exactly one
holder, released by the kernel if the process dies. What is new is that acquiring it may require
*evicting* the current occupant, which costs a model load — and that cost is real enough to
change decisions, so it is:

* **charged to the run that caused it**, rather than folded into whichever call happened to be
  next — so the price of ``reviewer ≠ implementer`` on one card is a line in the report;
* **capped per run**, because alternating roles round-robin would spend the phase's whole
  wall-clock budget on loading weights;
* **watched for thrash**, with the alternation named in the warning.

Batching a role's calls before yielding the card is deliberately *not* enforced here. A minimum
hold would stall a serial agent that must alternate to make progress at all, and the real fix
for thrash is upstream — a subgraph that makes its three calls together. What this module owes
is the evidence that it is happening, which is the warning and the per-run swap seconds.

The degraded path is stated once here: if the second model cannot be served at all, the run
**escalates**. It never falls back to a self-review — that would turn an infrastructure problem
into an approval, which is the one outcome the roster refusal exists to prevent.
"""

from __future__ import annotations

import asyncio
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Protocol

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.lease import LeaseHandle, LeaseManager
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.serving.health import HealthClient
from ai_harness.llm.serving.models import ModelRegistry, ModelSpec
from ai_harness.observability.logging import Logger

GPU_SLOT_KEY = "gpu:0"
"""One key, because there is one card. A second card would be a second key, and the swap policy
below would become a placement policy — which is Stage 2 of `selfhost.md`, not this phase."""


class UnitController(Protocol):
    """Whatever actually starts and stops a serving unit — systemd here, a fake in tests."""

    async def start(self, unit: str) -> Outcome[None]: ...

    async def stop(self, unit: str) -> Outcome[None]: ...


@dataclass(frozen=True, slots=True)
class SwapEvent:
    """One eviction and load, with what it cost and who caused it."""

    from_model: str | None
    to_model: str
    seconds: float
    run_id: str = ""
    at: float = 0.0


@dataclass(frozen=True, slots=True)
class ResidencyPolicy:
    """The three numbers that keep swapping from eating the run."""

    max_swaps_per_run: int = 6
    """Six is three full REVIEW⇄IMPLEMENT alternations. A run needing more is thrashing, and
    the honest response is to escalate rather than to keep paying."""
    thrash_window_s: float = 600.0
    thrash_swaps: int = 4
    """More than this in the window is logged with the alternation named, because the fix is
    usually a batching bug rather than a policy number."""
    lease_ttl_s: float = 1800.0
    """Long: a swap plus a generation is minutes, and a lease that expires mid-generation is a
    lost run — which is precisely the class of failure a week-long soak finds and a unit test
    does not."""


@dataclass(frozen=True, slots=True)
class SlotHandle:
    """The GPU, held. The model named here is resident until this is released."""

    model: str
    lease: LeaseHandle
    swapped: bool = False
    swap_seconds: float = 0.0


@dataclass
class ModelSlot:
    """The owner of the card. Every local call goes through here or does not happen."""

    registry: ModelRegistry
    leases: LeaseManager
    units: UnitController
    unit_name: Callable[[str], str]
    """Model name to unit name. Injected, so the systemd naming stays in
    :mod:`ai_harness.deploy.units` rather than existing in two places that can disagree."""
    health: Callable[[ModelSpec], HealthClient] | None = None
    """How to ask a model whether it is ready. ``None`` skips the wait, which is only correct
    in tests — in production a swap that does not wait for a token has not finished."""
    policy: ResidencyPolicy = field(default_factory=ResidencyPolicy)
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)
    resident: str | None = None
    swaps: list[SwapEvent] = field(default_factory=list)
    _recent: deque[SwapEvent] = field(default_factory=deque, repr=False)
    _swaps_by_run: dict[str, int] = field(default_factory=dict)

    # ── the public surface ───────────────────────────────────────────────────────

    def swap_seconds(self, run_id: str) -> float:
        return sum(event.seconds for event in self.swaps if event.run_id == run_id)

    def swap_count(self, run_id: str) -> int:
        return self._swaps_by_run.get(run_id, 0)

    async def acquire(
        self, model: str, *, run_id: str = "", holder: str = "worker"
    ) -> Outcome[SlotHandle]:
        """Take the card for ``model``, swapping if something else is resident.

        A caller that holds this may make exactly one model call at a time. That is not a
        convention — the lease is the only way to be resident, so a second in-flight call would
        have to acquire a lease it cannot get.
        """
        spec = self.registry.get(model)

        if self.resident is not None and self.resident != model:
            capped = self._check_cap(run_id, model)
            if capped is not None:
                return capped

        lease = await self.leases.acquire(
            GPU_SLOT_KEY, ttl_s=self.policy.lease_ttl_s, holder=f"{holder}:{model}"
        )
        if lease is None:
            # Someone else holds the card. Not an error — it is the normal outcome of two
            # workers on one box, and the reason a local host advertises concurrency 1 (#89).
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"the GPU is held by another holder; {model} cannot be made resident yet",
                remedy="this host serves one model call at a time; the queue should not have dispatched a second",
                dependency="serving",
            )

        if self.resident == model:
            return Outcome.ok(SlotHandle(model=model, lease=lease))

        swapped = await self._swap_to(spec, run_id=run_id)
        if swapped.is_err:
            await self.leases.release(lease)
            assert swapped.error is not None
            return Outcome.of(swapped.error)

        seconds = swapped.unwrap()
        return Outcome.ok(SlotHandle(model=model, lease=lease, swapped=True, swap_seconds=seconds))

    async def release(self, handle: SlotHandle) -> None:
        """Give the card back. The model stays resident — the *next* acquire decides."""
        await self.leases.release(handle.lease)

    # ── the swap ─────────────────────────────────────────────────────────────────

    def _check_cap(self, run_id: str, model: str) -> Outcome[SlotHandle] | None:
        used = self._swaps_by_run.get(run_id, 0)
        if run_id and used >= self.policy.max_swaps_per_run:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"this run has already swapped models {used} times; refusing a further swap to {model}",
                remedy=(
                    "the roles are alternating faster than they are batching. Either the run is "
                    "thrashing, or max_swaps_per_run is too low for this workload — both are "
                    "decisions, and neither should be made by continuing to pay for loads"
                ),
                details={"swaps": used, "cap": self.policy.max_swaps_per_run},
            )
        return None

    async def _swap_to(self, spec: ModelSpec, *, run_id: str) -> Outcome[float]:
        started = self.clock.monotonic()
        previous = self.resident

        if previous is not None:
            stopped = await self.units.stop(self._unit(previous))
            if stopped.is_err:
                assert stopped.error is not None
                return Outcome.of(stopped.error)
            self.resident = None

        started_unit = await self.units.start(self._unit(spec.name))
        if started_unit.is_err:
            assert started_unit.error is not None
            # The degraded path, stated once: a model that cannot be served escalates. It never
            # becomes "review it with the model that IS loaded".
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"{spec.name} could not be made resident: {started_unit.error.message}",
                remedy=(
                    "the run escalates rather than continuing with the other model — an "
                    "implementer reviewing its own work is the one outcome the roster refusal "
                    "exists to prevent"
                ),
            )

        ready = await self._await_ready(spec)
        if ready.is_err:
            assert ready.error is not None
            return Outcome.of(ready.error)

        self.resident = spec.name
        seconds = self.clock.monotonic() - started
        event = SwapEvent(
            from_model=previous,
            to_model=spec.name,
            seconds=seconds,
            run_id=run_id,
            at=self.clock.monotonic(),
        )
        self._record(event)
        return Outcome.ok(seconds)

    async def _await_ready(self, spec: ModelSpec) -> Outcome[None]:
        if self.health is None:
            return Outcome.ok(None)
        outcome = await self.health(spec).ready(spec)
        if outcome.is_err:
            assert outcome.error is not None
            return Outcome.of(outcome.error)
        return Outcome.ok(None)

    def _record(self, event: SwapEvent) -> None:
        self.swaps.append(event)
        if event.run_id:
            self._swaps_by_run[event.run_id] = self._swaps_by_run.get(event.run_id, 0) + 1

        self._recent.append(event)
        while self._recent and event.at - self._recent[0].at > self.policy.thrash_window_s:
            self._recent.popleft()

        self.logger.info(
            "model swap",
            from_model=event.from_model or "-",
            to_model=event.to_model,
            seconds=round(event.seconds, 1),
            run_id=event.run_id,
        )
        if len(self._recent) > self.policy.thrash_swaps:
            alternation = " -> ".join(e.to_model for e in self._recent)
            self.logger.warning(
                "the GPU is thrashing between models",
                alternation=alternation,
                window_s=self.policy.thrash_window_s,
                effect="swap time is being spent instead of generation time",
                remedy="batch a role's calls before yielding the card",
            )

    def _unit(self, model: str) -> str:
        return self.unit_name(model)


async def hold_for(
    slot: ModelSlot, model: str, *, run_id: str = "", holder: str = "worker"
) -> Outcome[SlotHandle]:
    """Acquire with one bounded retry, because a swap by another holder is normal, not an error."""
    first = await slot.acquire(model, run_id=run_id, holder=holder)
    if first.is_ok or first.category is not ErrorCategory.TRANSIENT:
        return first
    await asyncio.sleep(0)
    return await slot.acquire(model, run_id=run_id, holder=holder)


@dataclass
class SystemdUnits:
    """``systemctl --user`` — the controller that actually moves 17 GB of weights.

    ``stop`` is synchronous by design: systemd returns when the unit is down, and starting the
    next model before the previous one released its VRAM is precisely the OOM this class exists
    to prevent.
    """

    user: bool = True
    binary: str = "systemctl"
    timeout_s: float = 300.0

    async def start(self, unit: str) -> Outcome[None]:
        return await self._run("start", unit)

    async def stop(self, unit: str) -> Outcome[None]:
        return await self._run("stop", unit)

    async def _run(self, verb: str, unit: str) -> Outcome[None]:
        argv = [self.binary, *(["--user"] if self.user else []), verb, unit]
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{self.binary} is not on PATH, so serving units cannot be controlled",
                remedy="install the units with `agent install`, or run the servers by hand",
            )
        try:
            _, stderr = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except TimeoutError:
            process.kill()
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"`systemctl {verb} {unit}` did not finish within {self.timeout_s:.0f}s",
                remedy="a model that will not load in five minutes is not going to load",
            )
        if process.returncode != 0:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"`systemctl {verb} {unit}` failed: {stderr.decode('utf-8', 'replace')[:200]}",
                dependency="serving",
            )
        return Outcome.ok(None)
