"""``agent serving`` — the model as infrastructure, inspectable before it is trusted.

Five verbs, each answering a question an operator otherwise answers by reading logs:

* ``ls``     — what can this box serve, and does it fit the card?
* ``args``   — what flags would this model be started with, and *why* those flags?
* ``unit``   — the systemd unit, rendered from the same arithmetic rather than hand-written.
* ``check``  — is the running server serving the pinned revision, and can it return a token?
* ``bench``  — what are this box's real prefill and decode rates, written where later defaults
  can cite them.

Nothing here starts or stops anything. Installing the unit is `agent install`'s job, and the
separation is deliberate: a command that both renders and starts is one people run before they
have read what it renders.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Annotated

import typer

from ai_harness.deploy.units import render_serving, resolve_binary, serving_unit_name
from ai_harness.llm.serving.bench import DEFAULT_PROMPT_SIZES, measure
from ai_harness.llm.serving.health import HealthClient
from ai_harness.llm.serving.models import ModelRegistry, RegistryError, load_registry

serving_app = typer.Typer(help="Inspect the local model serving stack.")

EXIT_OK = 0
EXIT_UNHEALTHY = 1
EXIT_CONFIG = 2


def _registry(path: Path, file: Path | None) -> ModelRegistry:
    try:
        return load_registry(file, root=path)
    except RegistryError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_CONFIG) from exc


@serving_app.command("ls")
def serving_ls(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    file: Annotated[Path | None, typer.Option("--file", help="Registry path")] = None,
    as_json: Annotated[bool, typer.Option("--json", help="Machine-readable output")] = False,
) -> None:
    """List the registry, with the derived window and whether each model fits the card."""
    registry = _registry(path, file)
    rows = []
    for spec in registry.models:
        plan = spec.plan(registry.gpu)
        rows.append(
            {
                "name": spec.name,
                "repo_id": spec.repo_id,
                "revision": spec.revision[:12],
                "weights_gb": spec.weights_gb,
                "max_model_len": plan.max_model_len,
                "port": spec.port,
                "roles": list(spec.roles),
                "fits": spec.fits(registry.gpu),
            }
        )

    if as_json:
        typer.echo(json.dumps({"gpu": registry.gpu.model_dump(), "models": rows}, indent=2))
    else:
        typer.echo(
            f"{registry.gpu.name}: {registry.gpu.vram_gb:.1f} GB "
            f"({registry.gpu.usable_gb:.1f} GB usable)"
        )
        for row in rows:
            mark = "ok " if row["fits"] else "NO "
            typer.echo(
                f"  {mark}{row['name']:<20} {row['revision']}  window {row['max_model_len']:>7}  "
                f"port {row['port']}  {', '.join(row['roles']) or 'any role'}"  # type: ignore[arg-type]
            )
        for spec, why in registry.unservable():
            typer.secho(f"  {spec.name}: {why}", fg=typer.colors.RED)

    if registry.unservable():
        raise typer.Exit(EXIT_CONFIG)


@serving_app.command("args")
def serving_args(
    model: Annotated[str, typer.Argument(help="Served model name")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    file: Annotated[Path | None, typer.Option("--file", help="Registry path")] = None,
    explain: Annotated[bool, typer.Option("--explain", help="Show the arithmetic")] = False,
) -> None:
    """Print the vLLM command line derived from the registry."""
    registry = _registry(path, file)
    try:
        plan = registry.plan(model)
    except RegistryError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_CONFIG) from exc

    if explain:
        for line in plan.workings:
            typer.echo(f"# {line}")
    binary = resolve_binary(registry.vllm_bin, root=path) or registry.vllm_bin
    typer.echo(" ".join(plan.argv(binary=binary)))


@serving_app.command("unit")
def serving_unit(
    model: Annotated[str, typer.Argument(help="Served model name")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    file: Annotated[Path | None, typer.Option("--file", help="Registry path")] = None,
) -> None:
    """Render the systemd unit — including what it must not run beside (L2)."""
    registry = _registry(path, file)
    try:
        plan = registry.plan(model)
    except RegistryError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_CONFIG) from exc

    others = tuple(spec.name for spec in registry.models if spec.name != model)
    binary = resolve_binary(registry.vllm_bin, root=path)
    if binary is None:
        # Rendered anyway — an operator may legitimately be preparing a unit for another box.
        # But said out loud, because the alternative is a unit that fails 203/EXEC and a journal
        # line that reads as though the model were at fault.
        typer.secho(
            f"warning: {registry.vllm_bin!r} is not on PATH and is not a file under "
            f"{path.resolve()}. A systemd *user* unit does not inherit conda or a virtualenv, so "
            "this unit will fail with 203/EXEC. Set `vllm_bin` in the registry to the path of "
            "the vLLM you installed.",
            fg=typer.colors.YELLOW,
            err=True,
        )
    name, service = render_serving(
        plan,
        working_dir=str(path.resolve()),
        vllm_bin=binary or registry.vllm_bin,
        conflicts=others,
    )
    typer.echo(f"# {name}.service")
    typer.echo(service)


@serving_app.command("check")
def serving_check(
    model: Annotated[str, typer.Argument(help="Served model name")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    file: Annotated[Path | None, typer.Option("--file", help="Registry path")] = None,
    ready: Annotated[bool, typer.Option("--ready", help="Also demand a token back")] = True,
) -> None:
    """Reachable, serving the pinned revision, and able to answer. All three, or a failure."""
    registry = _registry(path, file)
    try:
        plan = registry.plan(model)
    except RegistryError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_CONFIG) from exc

    client = HealthClient(base_url=plan.base_url)
    outcome = asyncio.run(client.ready(plan.spec) if ready else client.check(plan.spec))
    if outcome.is_err:
        error = outcome.error
        assert error is not None
        typer.secho(f"{model}: {error.message}", fg=typer.colors.RED, err=True)
        if error.remedy:
            typer.echo(f"  remedy: {error.remedy}", err=True)
        raise typer.Exit(EXIT_UNHEALTHY)

    health = outcome.unwrap()
    typer.echo(f"{model}: {'ready' if health.ready else 'reachable'} at {health.base_url}")
    typer.echo(f"  revision : {health.revision or '—'}")
    typer.echo(f"  window   : {health.max_model_len or plan.max_model_len}")
    if health.latency_s:
        typer.echo(f"  first token in {health.latency_s:.2f}s")


@serving_app.command("probe")
def serving_probe(
    model: Annotated[str, typer.Argument(help="Served model name")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    file: Annotated[Path | None, typer.Option("--file", help="Registry path")] = None,
) -> None:
    """Measure what this server can do, and cache it against the loaded revision (L4)."""
    from ai_harness.config import load_config
    from ai_harness.llm.serving.probe import ProbeCache, check_window, probe
    from ai_harness.wiring import probe_cache_path

    registry = _registry(path, file)
    try:
        plan = registry.plan(model)
    except RegistryError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_CONFIG) from exc

    outcome = asyncio.run(
        probe(base_url=plan.base_url, model=plan.spec.name, revision=plan.spec.revision)
    )
    if outcome.is_err:
        error = outcome.error
        assert error is not None
        typer.secho(f"{model}: {error.message}", fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_UNHEALTHY)

    result = outcome.unwrap()
    ProbeCache(probe_cache_path(load_config(root=path))).store(result)

    typer.echo(f"{model}:")
    typer.echo(f"  guided decoding : {'yes' if result.guided_decoding else 'NO'}")
    typer.echo(f"  window          : {result.max_model_len or '—'} (planned {plan.max_model_len})")
    typer.echo(f"  tokenizer       : {'yes' if result.tokenizer_available else 'NO'}")
    typer.echo(
        "  prefix caching  : "
        + ("observed" if result.prefix_caching else "not yet observed — learned from traffic")
    )
    for note in result.notes:
        typer.secho(f"  note: {note}", fg=typer.colors.YELLOW)

    window = check_window(result, required=plan.max_model_len)
    if window.is_err and window.error is not None:
        typer.secho(f"  {window.error.message}", fg=typer.colors.RED, err=True)
        typer.echo(f"  remedy: {window.error.remedy}", err=True)
        raise typer.Exit(EXIT_UNHEALTHY)


@serving_app.command("conformance")
def serving_conformance(
    model: Annotated[str, typer.Argument(help="Served model name")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    file: Annotated[Path | None, typer.Option("--file", help="Registry path")] = None,
    out: Annotated[Path | None, typer.Option("--out", help="Append the table here")] = None,
    repeats: Annotated[int, typer.Option(help="How many times to run each case")] = 3,
) -> None:
    """Ask this model for structured output repeatedly, and score what comes back (#90)."""
    from ai_harness.agents.templates import template_for
    from ai_harness.llm.conformance import ConformanceCase, render, run_conformance
    from ai_harness.llm.engines.vllm import VLLMEngine
    from ai_harness.llm.serving.probe import ProbeCache
    from ai_harness.schemas.plan import WorkPlan
    from ai_harness.schemas.review import ReviewResult
    from ai_harness.wiring import probe_cache_path

    registry = _registry(path, file)
    try:
        plan = registry.plan(model)
    except RegistryError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_CONFIG) from exc

    engine = VLLMEngine(base_url=plan.base_url, max_model_len=plan.max_model_len)
    from ai_harness.config import load_config

    cached = ProbeCache(probe_cache_path(load_config(root=path))).load(
        base_url=plan.base_url, model=model, revision=plan.spec.revision
    )
    if cached is not None:
        # Guided decoding changes the answer entirely, so the row records which it was.
        engine.capabilities = cached.capabilities()

    roles = plan.spec.roles or ("reviewer",)
    cases: list[ConformanceCase] = []
    for _ in range(max(repeats, 1)):
        if "reviewer" in roles:
            cases.append(
                ConformanceCase(
                    name="review",
                    template_id=template_for("reviewer-v1", model),
                    prompt=_REVIEW_PROMPT,
                    model_type=ReviewResult,
                )
            )
        else:
            cases.append(
                ConformanceCase(
                    name="plan",
                    template_id=template_for("planner-v1", model),
                    prompt=_PLAN_PROMPT,
                    model_type=WorkPlan,
                )
            )

    report = asyncio.run(run_conformance(engine, cases, model=model))
    table = render([report], title=f"Conformance — {model}")
    typer.echo(table)
    if out is not None:
        out.parent.mkdir(parents=True, exist_ok=True)
        existing = out.read_text() if out.exists() else "# Conformance baselines\n"
        out.write_text(existing.rstrip("\n") + "\n\n" + table)
        typer.echo(f"appended to {out}")


_REVIEW_PROMPT = """\
Review this change against the acceptance criterion "a retried charge must write one row".

diff --git a/billing/charge.py b/billing/charge.py
@@ -10,7 +10,8 @@ def charge(account, amount):
-    key = uuid4().hex
     for attempt in range(3):
+        key = uuid4().hex
         write_charge(account, amount, idempotency_key=key)
"""

_PLAN_PROMPT = """\
Issue: retried charges are billed twice. billing/charge.py generates its idempotency key inside
the retry loop, so the second attempt writes a second row. Plan the fix.
"""


@serving_app.command("bench")
def serving_bench(
    model: Annotated[str, typer.Argument(help="Served model name")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    file: Annotated[Path | None, typer.Option("--file", help="Registry path")] = None,
    out: Annotated[Path | None, typer.Option("--out", help="Write the table here")] = None,
    output_tokens: Annotated[int, typer.Option(help="Tokens to generate per point")] = 256,
) -> None:
    """Measure prefill and decode rates. Every later default cites this, so it is committed."""
    registry = _registry(path, file)
    try:
        plan = registry.plan(model)
    except RegistryError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_CONFIG) from exc

    sizes = tuple(size for size in DEFAULT_PROMPT_SIZES if size < plan.max_model_len)
    outcome = asyncio.run(
        measure(
            base_url=plan.base_url,
            model=plan.spec.name,
            prompt_sizes=sizes,
            output_tokens=output_tokens,
        )
    )
    if outcome.is_err:
        error = outcome.error
        assert error is not None
        typer.secho(f"{model}: {error.message}", fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_UNHEALTHY)

    result = outcome.unwrap()
    typer.echo(result.as_markdown())
    if out is not None:
        out.parent.mkdir(parents=True, exist_ok=True)
        existing = out.read_text() if out.exists() else "# Measured serving rates\n\n"
        out.write_text(existing.rstrip("\n") + "\n\n" + result.as_markdown())
        typer.echo(f"written to {out}")


__all__ = ["serving_app", "serving_unit_name"]
