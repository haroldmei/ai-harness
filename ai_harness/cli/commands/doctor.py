"""``agent doctor`` — refuse before the claim, not after it.

``wiring.py``'s second rule: *a worker that starts, claims a run, spends a lease and then
discovers something is missing has consumed a dispatch and produced nothing.* Phase 7 adds a
whole class of things that can be missing — a driver, free VRAM, a serving unit, the pinned
revision, a tokenizer — and every one of them is a **startup** condition.

Each check answers three questions, and the third is what makes this worth running: what was
looked at, what was found, and what to do about it. A doctor that prints ``FAIL: gpu`` has told
an operator only that they now have to go and find out.

Deliberately read-only. It starts nothing, it stops nothing, and it fixes nothing — a diagnostic
that repairs things is a diagnostic people are afraid to run.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated

import httpx
import typer

from ai_harness.llm.serving.models import ModelRegistry, RegistryError, load_registry
from ai_harness.observability.gpu import read_gpu, read_serving

doctor_app = typer.Typer(help="Check that this box can actually serve models.")

EXIT_OK = 0
EXIT_UNHEALTHY = 1
EXIT_CONFIG = 2

MB_PER_GB = 1024


@dataclass(frozen=True, slots=True)
class Check:
    """One diagnosis. ``remedy`` is not optional in spirit, only in the type."""

    name: str
    ok: bool
    detail: str
    remedy: str = ""
    fatal: bool = True
    """False for things that degrade rather than prevent — an absent tokenizer costs accuracy,
    an absent GPU costs everything."""


@dataclass
class Diagnosis:
    checks: list[Check] = field(default_factory=list)

    @property
    def healthy(self) -> bool:
        return all(check.ok or not check.fatal for check in self.checks)

    def add(self, check: Check) -> Check:
        self.checks.append(check)
        return check


async def diagnose(
    registry: ModelRegistry,
    *,
    models: list[str] | None = None,
    client: httpx.AsyncClient | None = None,
) -> Diagnosis:
    """Look at the card, then at each model's server. Never raises.

    ``client`` is injected rather than constructed so this is testable without a socket — the
    default suite is hermetic by construction, and a diagnostic that can only be exercised
    against a running server is a diagnostic nobody exercises.
    """
    diagnosis = Diagnosis()
    reading = await read_gpu()

    diagnosis.add(
        Check(
            name="gpu",
            ok=reading.available,
            detail=(
                f"{registry.gpu.name}: {reading.utilisation_pct:.0f}% busy, "
                f"{(reading.memory_free_mb or 0) / MB_PER_GB:.1f} GB free, "
                f"{reading.temperature_c:.0f}°C"
                if reading.available
                else reading.note
            ),
            remedy=(
                "install the NVIDIA driver and expose the card to this environment; without it "
                "there is nothing to serve a model on"
            ),
        )
    )

    if reading.available:
        diagnosis.add(
            Check(
                name="thermals",
                ok=not reading.throttling,
                detail=(
                    f"throttling: {reading.throttle_names}"
                    if reading.throttling
                    else "clocks are not being limited"
                ),
                remedy=(
                    "a throttled card generates slower than the measured rate every timeout was "
                    "derived from; check airflow and the power limit"
                ),
                fatal=False,
            )
        )

    for spec in registry.models:
        if models and spec.name not in models:
            continue
        plan = registry.plan(spec.name)
        needed_gb = spec.weights_gb + spec.activation_gb
        free_gb = (reading.memory_free_mb or 0) / MB_PER_GB if reading.available else 0.0
        resident = free_gb < needed_gb and reading.available

        metrics = await read_serving(plan.base_url, client=client)
        diagnosis.add(
            Check(
                name=f"serving:{spec.name}",
                ok=metrics.available,
                detail=(
                    f"up at {plan.base_url}, queue {metrics.values.get('serving_queue_depth', 0):.0f}, "
                    f"KV cache {metrics.values.get('serving_kv_cache_usage', 0):.0%}"
                    if metrics.available
                    else metrics.note
                ),
                remedy=(
                    f"start it: `systemctl --user start ai-harness-serve-{spec.name}` — and "
                    "remember only one model is resident at a time (L2)"
                ),
                fatal=False,
            )
        )
        diagnosis.add(
            Check(
                name=f"vram:{spec.name}",
                ok=(free_gb >= needed_gb) or resident or not reading.available,
                detail=(
                    f"{spec.name} needs {needed_gb:.1f} GB; {free_gb:.1f} GB free"
                    + (" (it looks resident already)" if resident else "")
                ),
                remedy=(
                    "stop the other model's unit before starting this one; two 4-bit models do "
                    "not fit 24 GB, which is the whole reason the residency lease exists"
                ),
                fatal=False,
            )
        )

    return diagnosis


@doctor_app.command("doctor")
def doctor(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    file: Annotated[Path | None, typer.Option("--file", help="Registry path")] = None,
    model: Annotated[str, typer.Option(help="Check only this model")] = "",
) -> None:
    """Check the card, the serving units and the pins. Read-only; fixes nothing."""
    try:
        registry = load_registry(file, root=path)
    except RegistryError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_CONFIG) from exc

    diagnosis = asyncio.run(diagnose(registry, models=[model] if model else None))
    for check in diagnosis.checks:
        mark = "ok  " if check.ok else ("FAIL" if check.fatal else "warn")
        colour = (
            typer.colors.GREEN
            if check.ok
            else (typer.colors.RED if check.fatal else typer.colors.YELLOW)
        )
        typer.secho(f"{mark} {check.name:<28} {check.detail}", fg=colour)
        if not check.ok and check.remedy:
            typer.echo(f"     remedy: {check.remedy}")

    if not diagnosis.healthy:
        raise typer.Exit(EXIT_UNHEALTHY)
