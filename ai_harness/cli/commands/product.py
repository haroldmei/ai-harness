"""``agent product`` — the product build's state, without `jq` (#106).

The four verbs `scripts/state-init.sh`, `state-set.sh` and `state-decide.sh` provide, and one
more (`show`) that the skills currently get by running `jq` over the shards themselves.

Output is deliberately quiet: `set` prints the file it changed, because a caller that cannot tell
which shard took its write cannot debug the one case that matters — a key whose owner it guessed
wrong. `get` prints raw JSON so a skill can pipe it.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Annotated, Any

import typer

from ai_harness.product.shards import PathError
from ai_harness.product.state import ProductState, StateError

product_app = typer.Typer(help="The product build's sharded state.")

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2


def _state(path: Path) -> ProductState:
    return ProductState(directory=path / "state")


@product_app.command("init")
def product_init(
    idea: Annotated[str, typer.Argument(help="The product idea")] = "",
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
) -> None:
    """Create the shards, or fill in fields a previous version did not have.

    The existing document always wins: defaults fill what is missing and never overwrite what a
    build has already decided.
    """
    state = _state(path)
    existing = state.index.exists()
    document = state.init(idea) if idea else state.init()

    if existing:
        typer.echo(f"state.json upgraded in place ({len(document)} top-level fields)")
    else:
        typer.echo(f"initialised {state.directory}")


@product_app.command("set")
def product_set(
    key: Annotated[str, typer.Argument(help='A path: .scale_tier, .testing.gate_attempts."e2e"')],
    value: Annotated[str, typer.Argument(help="A JSON value")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
) -> None:
    """Set one field, in whichever shard owns it."""
    try:
        parsed: Any = json.loads(value)
    except ValueError as exc:
        typer.secho(f"not JSON: {value!r} ({exc})", fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_USAGE) from exc

    try:
        written = _state(path).set(key, parsed)
    except PathError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_USAGE) from exc
    except StateError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_ERROR) from exc

    typer.echo(str(written))


@product_app.command("get")
def product_get(
    key: Annotated[str, typer.Argument(help="A path")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
) -> None:
    """Read one field, as JSON."""
    try:
        typer.echo(json.dumps(_state(path).get(key), ensure_ascii=False))
    except PathError as exc:
        typer.secho(str(exc), fg=typer.colors.RED, err=True)
        raise typer.Exit(EXIT_USAGE) from exc


@product_app.command("decide")
def product_decide(
    phase: Annotated[str, typer.Argument()],
    decision: Annotated[str, typer.Argument()],
    reason: Annotated[str, typer.Argument()],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
) -> None:
    """Record a decision in both places that read it: `decisions.md` and `.decisions`."""
    typer.echo(_state(path).decide(phase, decision, reason))


@product_app.command("show")
def product_show(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
) -> None:
    """Every shard, merged, for reading."""
    typer.echo(json.dumps(_state(path).show(), indent=2, ensure_ascii=False))


# ── iterations (#109) ────────────────────────────────────────────────────────────

iteration_app = typer.Typer(help="The iteration log: count, index, immutability.")


def _iterations(path: Path):  # type: ignore[no-untyped-def]
    """Paths come from the profile, never from a constant.

    Where a repository keeps its iterations and whether it generates an index are that
    repository's conventions, and a package that hard-codes them has assumed the one project it
    was supposed to be able to target (Q2).
    """
    from ai_harness.config import load_config
    from ai_harness.product.iterations import Iterations

    profile = load_config(root=path).profile
    return Iterations(
        directory=path / profile.iterations_dir,
        state=_state(path),
        index_file=(path / profile.iteration_index) if profile.iteration_index else None,
    )


@iteration_app.command("count")
def iteration_count(
    mode: Annotated[str, typer.Argument(help="current | next | peek")] = "current",
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
) -> None:
    """The iteration number. `next` claims and persists it; `peek` does not."""
    iterations = _iterations(path)
    if mode == "current":
        typer.echo(iterations.current())
    elif mode == "peek":
        typer.echo(iterations.peek_next())
    elif mode == "next":
        typer.echo(iterations.take_next())
    else:
        typer.secho(f"unknown mode {mode!r}; expected current, next or peek", fg="red", err=True)
        raise typer.Exit(EXIT_USAGE)


@iteration_app.command("index")
def iteration_index(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    check: Annotated[bool, typer.Option("--check", help="Fail if the index is stale")] = False,
) -> None:
    """Regenerate the iteration index from the iteration files."""
    iterations = _iterations(path)
    if iterations.index_file is None:
        typer.secho(
            "no iteration index is configured for this repository — set profile.iteration_index "
            "in .harness/config.yaml if it keeps one",
            fg="yellow",
            err=True,
        )
        raise typer.Exit(EXIT_USAGE)
    rendered = iterations.render_index()
    target = iterations.index_file

    if check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != rendered:
            typer.secho(f"{target} is stale — run `agent iteration index`", fg="red", err=True)
            raise typer.Exit(EXIT_ERROR)
        typer.echo(f"{target} is current")
        return

    written = iterations.write_index()
    for note in iterations.notes:
        typer.secho(f"note: {note}", fg="yellow", err=True)
    typer.echo(str(written))


@iteration_app.command("check")
def iteration_check(
    base: Annotated[str, typer.Option(help="Base to compare against")] = "origin/main",
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
) -> None:
    """Fail if this branch modified or deleted a past iteration."""
    outcome = _iterations(path).check_immutable(base, root=path)
    if outcome.is_err:
        error = outcome.error
        assert error is not None
        typer.secho(error.message, fg="red", err=True)
        for violation in error.details.get("violations", []):
            typer.echo(f"  {violation}", err=True)
        typer.echo(f"  remedy: {error.remedy}", err=True)
        raise typer.Exit(EXIT_ERROR)
    typer.echo("iteration-immutable: no past iteration was modified")
