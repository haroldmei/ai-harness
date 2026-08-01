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
