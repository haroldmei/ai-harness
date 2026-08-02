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
import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated

import httpx
import typer

from ai_harness.deploy.units import resolve_binary
from ai_harness.llm.serving.models import ModelRegistry, ModelSpec, RegistryError, load_registry
from ai_harness.observability.gpu import read_gpu, read_serving

doctor_app = typer.Typer(help="Check that this box can actually serve models.")

EXIT_OK = 0
EXIT_UNHEALTHY = 1
EXIT_CONFIG = 2

MB_PER_GB = 1024


def hub_cache_root(environ: Mapping[str, str] | None = None) -> Path:
    """Where the Hub keeps weights, by the Hub's own precedence.

    Resolved rather than assumed because the serving unit sets ``HF_HUB_OFFLINE=1``: the cache is
    the *only* place weights can come from at start time, so "which cache" is part of the
    diagnosis and not a detail.
    """
    env = environ if environ is not None else os.environ
    if explicit := env.get("HF_HUB_CACHE"):
        return Path(explicit)
    if home := env.get("HF_HOME"):
        return Path(home) / "hub"
    base = env.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "huggingface" / "hub"


def cached_snapshot(root: Path, spec: ModelSpec) -> Path | None:
    """The snapshot directory holding this exact revision, or ``None``.

    Prefix-matched because :func:`check_revision` accepts a short digest for the same commit,
    and a pin an operator shortened by hand should not read as absent.
    """
    folder = root / f"models--{spec.repo_id.replace('/', '--')}" / "snapshots"
    if not folder.is_dir():
        return None
    for candidate in sorted(folder.iterdir()):
        if candidate.name.startswith(spec.revision) and any(candidate.iterdir()):
            return candidate
    return None


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
    root: Path | None = None,
    hub_cache: Path | None = None,
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

    # The two conditions that make a start fail *before* the model is ever loaded, and that
    # nothing here used to look at: the binary, and the weights. Both are fatal because neither
    # degrades — a unit with no executable and a unit with nothing to serve both exit in under a
    # second, and the journal blames the model in each case.
    binary = resolve_binary(registry.vllm_bin, root=root or Path())
    diagnosis.add(
        Check(
            name="vllm",
            ok=binary is not None,
            detail=(
                binary
                if binary is not None
                else f"{registry.vllm_bin!r} is neither on PATH nor a file in the repository"
            ),
            remedy=(
                "install vLLM and point `vllm_bin` in the registry at it. A systemd *user* unit "
                "does not inherit conda or a virtualenv, so a bare name that works in your shell "
                "still fails the unit with 203/EXEC"
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

    cache = hub_cache if hub_cache is not None else hub_cache_root()

    for spec in registry.models:
        if models and spec.name not in models:
            continue
        plan = registry.plan(spec.name)
        snapshot = cached_snapshot(cache, spec)
        diagnosis.add(
            Check(
                name=f"weights:{spec.name}",
                ok=snapshot is not None,
                detail=(
                    f"{spec.revision[:12]} is cached at {snapshot}"
                    if snapshot is not None
                    else f"{spec.repo_id}@{spec.revision[:12]} is not in {cache}"
                ),
                remedy=(
                    f"fetch it: `hf download {spec.repo_id} --revision {spec.revision}` — the "
                    "unit runs with HF_HUB_OFFLINE=1, so a start that would download something "
                    "is a start nobody reviewed, and an unfetched pin cannot serve"
                ),
            )
        )
        # What vLLM will actually demand, not what the weights weigh. `--gpu-memory-utilization`
        # is a fraction of the card's **total**, and vLLM refuses to start when *free* memory is
        # below it — so the number that decides whether a start survives is this product, and
        # `weights + activations` is the smaller, more optimistic quantity that says nothing.
        requested_gb = plan.utilisation * registry.gpu.vram_gb
        free_gb = (reading.memory_free_mb or 0) / MB_PER_GB if reading.available else 0.0

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
                # Its own server being up is what makes the shortfall benign — that memory is
                # this model's. The previous form treated *any* shortfall as "it looks resident
                # already", which made the check unfalsifiable: it could not fail while the card
                # was readable, which is the only time it had anything to say.
                ok=(not reading.available) or metrics.available or free_gb >= requested_gb,
                detail=(
                    f"{spec.name} will request {requested_gb:.1f} GB "
                    f"({plan.utilisation:.3f} of {registry.gpu.vram_gb:.1f} GB); "
                    f"{free_gb:.1f} GB free"
                    + (" (its own server holds it)" if metrics.available else "")
                ),
                remedy=(
                    "vLLM refuses to start when free memory is below --gpu-memory-utilization "
                    "times total, so stop the other model's unit — or raise `gpu.reserve_gb` in the "
                    "registry, which is what the arithmetic subtracts for everything already on "
                    "the card. A desktop session is usually more than 1 GB of it"
                ),
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

    diagnosis = asyncio.run(diagnose(registry, models=[model] if model else None, root=path))
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
