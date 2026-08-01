"""``agent`` — the command surface as far as Phase 1.

Nothing here writes to a forge or a branch. Phase 0's commands discover and run the
repository's *own* gates and print resolved configuration; Phase 1 adds ``record``, which the
shell stages call to write shadow state, and the read commands that make that state useful.

``record`` is the only command that writes anything, it writes only to the harness's own
database, and it cannot fail its caller. That is what keeps Phase 1's rollback at "stop calling
the helper".

The commands that drive work — ``run``, ``resume``, ``retry``, ``cancel``, ``approve``,
``tick`` — arrive with the states that back them, in Phases 2–4.
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path
from typing import Annotated

import typer

from ai_harness.cli.commands.doctor import doctor_app
from ai_harness.cli.commands.drive import drive_app
from ai_harness.cli.commands.install import install_app
from ai_harness.cli.commands.serving import serving_app
from ai_harness.cli.commands.shadow import shadow_app
from ai_harness.cli.commands.state import record, state_app
from ai_harness.config import ConfigError, HarnessConfig, load_config, load_policy
from ai_harness.quality.adapters.shell import ShellGateAdapter
from ai_harness.quality.discovery import describe, discover
from ai_harness.quality.registry import UnknownTierError, parse_tier
from ai_harness.quality.runner import GateRunner
from ai_harness.schemas.enums import GateSet, GateStatus, Tier
from ai_harness.schemas.gates import GateReport

app = typer.Typer(
    name="agent",
    help="An FSM-routed software-engineering worker. Phase 0: gate discovery and execution.",
    no_args_is_help=True,
    add_completion=False,
)
gates_app = typer.Typer(help="Discover and run the repository's own quality gates.")
config_app = typer.Typer(help="Show the effective configuration, profile and policy.")
app.add_typer(gates_app, name="gates")
app.add_typer(config_app, name="config")
app.add_typer(shadow_app, name="shadow")
# Phase 7: the model is a process on this box now, so it is inspectable like one.
app.add_typer(serving_app, name="serving")
app.registered_commands.extend(doctor_app.registered_commands)

# Phase 1: durable state is written (by the shell, via `record`) and readable, but nothing
# reads it to make a decision yet — that is Phase 4.
app.command("record")(record)
# Phase 6: the composition root exists, so the commands that DRIVE runs can too. Both refuse
# to start against a repository whose profile.engine is still `shell` — that flag is the
# rollback for Phases 2-5, and it is worth nothing if an entry point can route around it.
app.registered_commands.extend(drive_app.registered_commands)
app.registered_commands.extend(install_app.registered_commands)
for _name in ("ls", "inspect", "cost", "replay"):
    app.registered_commands.extend([c for c in state_app.registered_commands if c.name == _name])

EXIT_OK = 0
EXIT_RED = 1
EXIT_NO_GATES = 3
"""A distinct code: "nothing was discovered" is not the same as "a gate failed"."""
EXIT_ENVIRONMENT = 4
EXIT_CONFIG = 2


@gates_app.command("discover")
def gates_discover(
    path: Annotated[Path, typer.Argument(help="Repository root")] = Path(),
    tier: Annotated[str | None, typer.Option(help="Gate tier")] = None,
    as_json: Annotated[bool, typer.Option("--json", help="Machine-readable output")] = False,
) -> None:
    """Walk the discovery ladder and report which rung matched, and why the others did not."""
    resolved_tier = _tier(tier)
    found = discover(path, tier=resolved_tier)
    described = describe(found)

    if as_json:
        typer.echo(json.dumps(described, indent=2))
    else:
        typer.echo(f"rung        : {described['rung']}")
        typer.echo(f"entry point : {described['entry_point'] or '—'}")
        typer.echo(f"inferred    : {'yes' if described['inferred'] else 'no'}")
        typer.echo(f"gates       : {', '.join(described['gates']) or '—'}")
        for note in described["considered"]:
            typer.echo(f"  considered: {note}")
        for note in described["notes"]:
            typer.echo(f"  note      : {note}")
        if found.escalates:
            typer.secho(
                "no gates discovered — a run against this repository escalates rather than "
                "merging ungated (§19.2 rung 5)",
                fg="yellow",
            )

    raise typer.Exit(EXIT_NO_GATES if found.escalates else EXIT_OK)


@gates_app.command("run")
def gates_run(
    path: Annotated[Path, typer.Argument(help="Repository root")] = Path(),
    only: Annotated[str | None, typer.Option(help="Comma-separated allow-list")] = None,
    skip: Annotated[str | None, typer.Option(help="Comma-separated deny-list")] = None,
    tier: Annotated[str | None, typer.Option(help="Gate tier")] = None,
    fast: Annotated[bool, typer.Option("--fast", help="Run the fast set")] = False,
    as_json: Annotated[bool, typer.Option("--json", help="Emit a GateReport")] = False,
) -> None:
    """Run the repository's own gates through its own entry point, and interpret the result."""
    resolved_tier = _tier(tier)
    found = discover(path, tier=resolved_tier)
    if found.escalates:
        typer.secho("no gate entry point was discovered", fg="red", err=True)
        raise typer.Exit(EXIT_NO_GATES)

    # Two profiles, two runners, and the difference is not cosmetic. A *discovered* spine is
    # somebody's `quality-gates.sh` or `make check`: the adapter calls it and consumes its
    # scorecard, because §19.1 says the repository owns its gates. A *declared* profile
    # (`.harness/gates.yaml`, rung 1) has no entry point to call, so the native runner executes
    # the specs directly. Until now only the first path was reachable from here, which meant a
    # repository that declared its gates could not have them run — including this one.
    runner: ShellGateAdapter | GateRunner = (
        ShellGateAdapter(root=path, profile=found.profile)
        if found.profile.entry_point is not None
        else GateRunner(root=path, profile=found.profile)
    )
    outcome = asyncio.run(
        runner.run(
            gate_set=GateSet.FAST if fast else GateSet.FULL,
            only=_split(only),
            skip=_split(skip),
        )
    )

    if outcome.is_err:
        assert outcome.error is not None
        payload = {
            "error": outcome.error.category.value,
            "message": outcome.error.message,
            "remedy": outcome.error.remedy,
        }
        typer.echo(
            json.dumps(payload, indent=2)
            if as_json
            else f"{payload['error']}: {payload['message']}",
            err=not as_json,
        )
        raise typer.Exit(EXIT_ENVIRONMENT)

    report = outcome.unwrap()
    typer.echo(report.model_dump_json(indent=2) if as_json else _render(report))
    raise typer.Exit(EXIT_OK if report.green else EXIT_RED)


@gates_app.command("adopt")
def gates_adopt(
    path: Annotated[Path, typer.Argument(help="Repository root")] = Path(),
    spine: Annotated[Path | None, typer.Option(help="Path to the shell spine")] = None,
    scorecard: Annotated[Path | None, typer.Option(help="A --json scorecard, for timeouts")] = None,
    out: Annotated[Path | None, typer.Option("--out", help="Write here instead of stdout")] = None,
    tier: Annotated[str | None, typer.Option(help="Tier for the emitted profile")] = None,
) -> None:
    """Read a shell spine and PROPOSE the equivalent `.harness/gates.yaml`.

    Writes nothing without `--out`. A gate declaration is the contract by which the harness is
    allowed to merge, so a human reads this before it becomes one (Q9).
    """
    from ai_harness.quality.adopt import adopt

    source = spine or (path / "scripts/quality-gates.sh")
    if not source.exists():
        typer.secho(f"no shell spine at {source}", fg="red", err=True)
        raise typer.Exit(EXIT_NO_GATES)

    adoption = adopt(source, scorecard=scorecard, root=path)
    rendered = adoption.as_yaml(tier=_tier(tier))

    if out is None:
        typer.echo(rendered)
    else:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(rendered)
        typer.echo(f"written to {out}", err=True)

    for item in adoption.unexpressible:
        typer.secho(f"not adopted: {item.name} — {item.why}", fg="yellow", err=True)
    if not adoption.gates:
        raise typer.Exit(EXIT_NO_GATES)


@gates_app.command("compare")
def gates_compare(
    path: Annotated[Path, typer.Argument(help="Repository root")] = Path(),
    declared: Annotated[Path | None, typer.Option(help="The declaration to test")] = None,
    commit: Annotated[str, typer.Option(help="Commit the comparison belongs to")] = "",
    repo: Annotated[str, typer.Option(help="owner/name, for the record")] = "",
    explain: Annotated[str | None, typer.Option(help="gate=why, to account for one")] = None,
    report: Annotated[bool, typer.Option("--report", help="Read the record, run nothing")] = False,
) -> None:
    """Run both spines on this commit and diff them, or report what is still unexplained.

    Exits non-zero while any disagreement is unexplained, so a nightly job is the thing that
    notices rather than a person remembering to look (#43's rule, one layer down).
    """
    import yaml as _yaml

    from ai_harness.cli.commands.state import _store
    from ai_harness.quality.compare import compare_spines
    from ai_harness.quality.compare import render as render_comparison
    from ai_harness.schemas.gates import GateProfile

    store = _store(path)

    if explain is not None:
        gate, _, why = explain.partition("=")
        if not why:
            typer.secho("--explain takes gate=why", fg="red", err=True)
            raise typer.Exit(EXIT_CONFIG)
        touched = asyncio.run(store.explain_spine(repo, gate.strip(), why.strip()))
        typer.echo(f"explained {gate.strip()} across {touched} comparison(s)")
        raise typer.Exit(EXIT_OK)

    if report:
        recorded = asyncio.run(store.spine_comparisons(repo=repo or None))
        unexplained = [d for c in recorded for d in c.unexplained]
        for comparison in recorded:
            typer.echo(render_comparison(comparison))
        typer.echo(f"{len(recorded)} commit(s) compared, {len(unexplained)} unexplained")
        raise typer.Exit(EXIT_RED if unexplained else EXIT_OK)

    spine = path / "scripts/quality-gates.sh"
    if not spine.exists():
        typer.secho(f"no shell spine at {spine}", fg="red", err=True)
        raise typer.Exit(EXIT_NO_GATES)
    declaration = declared or (path / ".harness/gates.yaml")
    if not declaration.exists():
        typer.secho(
            f"no declaration at {declaration} — `agent gates adopt` first", fg="red", err=True
        )
        raise typer.Exit(EXIT_NO_GATES)

    found = discover(path)
    shell_profile = found.profile.model_copy(
        update={"entry_point": ["bash", "scripts/quality-gates.sh"]}
    )
    declared_profile = GateProfile(**_yaml.safe_load(declaration.read_text()))

    shell_report = asyncio.run(ShellGateAdapter(root=path, profile=shell_profile).run())
    declared_report = asyncio.run(GateRunner(root=path, profile=declared_profile).run())
    if shell_report.is_err or declared_report.is_err:
        failed = shell_report if shell_report.is_err else declared_report
        assert failed.error is not None
        typer.secho(f"could not run both spines: {failed.error.message}", fg="red", err=True)
        raise typer.Exit(EXIT_ENVIRONMENT)

    comparison = compare_spines(
        shell_report.unwrap(), declared_report.unwrap(), repo=repo, commit_sha=commit
    )
    asyncio.run(store.record_spine(comparison))
    typer.echo(render_comparison(comparison))
    raise typer.Exit(EXIT_RED if comparison.unexplained else EXIT_OK)


@config_app.command("show")
def config_show(
    path: Annotated[Path, typer.Argument(help="Repository root")] = Path(),
) -> None:
    """Print the *effective* configuration — the resolved values, not the file's contents."""
    typer.echo(json.dumps(_load(path).describe(), indent=2, default=str))


@config_app.command("shell-env")
def config_shell_env(
    path: Annotated[Path, typer.Argument(help="Repository root")] = Path(),
) -> None:
    """Emit the knobs the existing shell stages read, so both engines share one source.

    Usage: ``eval "$(agent config shell-env)"`` before invoking a shell stage.
    """
    for name, value in sorted(_load(path).shell_env().items()):
        typer.echo(f"export {name}={value}")


@config_app.command("policy")
def config_policy(
    name: Annotated[
        str, typer.Argument(help="standard | permissive | readonly | path")
    ] = "standard",
) -> None:
    """Print a shipped policy, with its capability decisions resolved."""
    try:
        policy = load_policy(name)
    except ConfigError as exc:
        typer.secho(str(exc), fg="red", err=True)
        raise typer.Exit(EXIT_CONFIG) from exc
    typer.echo(policy.model_dump_json(indent=2))


def _load(path: Path) -> HarnessConfig:
    try:
        return load_config(root=path)
    except ConfigError as exc:
        typer.secho(str(exc), fg="red", err=True)
        raise typer.Exit(EXIT_CONFIG) from exc


def _tier(value: str | None) -> Tier:
    try:
        return parse_tier(value) if value else Tier.LAUNCH
    except UnknownTierError as exc:
        # Fail closed: guessing downward is the one interpretation that can ship red code.
        typer.secho(str(exc), fg="red", err=True)
        raise typer.Exit(EXIT_CONFIG) from exc


def _split(value: str | None) -> list[str] | None:
    if value is None:
        return None
    return [item.strip() for item in value.split(",") if item.strip()]


_MARK = {
    GateStatus.PASS: "✅",
    GateStatus.FAIL: "❌",
    GateStatus.SKIP: "·",
    GateStatus.TIMEOUT: "⏱",
    GateStatus.ERROR: "❌",
}


def _render(report: GateReport) -> str:
    lines = [f"── gates (tier {report.tier.value}, {report.gate_set.value} set) ──"]
    for result in report.results:
        duration = f"{result.duration_s:.0f}s" if result.duration_s is not None else ""
        flags = []
        if result.promoted:
            flags.append("promoted: a skipped required check is a failure")
        if result.inherited:
            flags.append("inherited from the base — forgiven")
        note = f"  [{'; '.join(flags)}]" if flags else ""
        lines.append(
            f"  {_MARK[result.status]} {result.name:<20} {duration:>6}  {result.reason}{note}"
        )
    lines.append("")
    lines.append(
        f"wall-clock {report.wall_clock_s:.0f}s · gate-time {report.gate_time_s:.0f}s "
        f"({report.speedup:.1f}x parallel)"
    )
    if report.no_gates_discovered:
        lines.append("no_gates_discovered — this repository cannot be delivered into ungated")
    lines.append("RESULT: all required gates pass" if report.green else "RESULT: red")
    return "\n".join(lines)


def main() -> None:
    try:
        app()
    except ConfigError as exc:  # a bad setting must never look like a crash
        print(str(exc), file=sys.stderr)
        raise SystemExit(EXIT_CONFIG) from exc


if __name__ == "__main__":
    main()
