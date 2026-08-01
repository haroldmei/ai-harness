"""``agent shadow`` — observe, explain, report (#76).

The three verbs the cutover criterion needs, and no more:

* ``observe`` runs the Python reviewer beside the shell one on a pull request and records the
  pair. It writes nothing to the forge; the forge it is handed refuses writes and the runner
  checks rather than trusting.
* ``explain`` writes an account of a disagreement. This is the *human* half of the criterion —
  "every disagreement written up: which engine was right, and why" — and there is deliberately
  no way to bulk-clear it. A command that could mark everything explained would turn the gate
  into a formality.
* ``report`` prints the agreement rate, the observation window, both paths' cost per review, and
  — most usefully — the *reasons* the cutover is still blocked, in words rather than a boolean.

``report --gate`` exits non-zero when the cutover is not permitted, so a nightly job can be the
thing that notices rather than a person remembering to look.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Annotated

import typer

from ai_harness.cli.commands.state import _store
from ai_harness.observability.logging import Logger
from ai_harness.orchestration.shadow import load_comparator, window_start
from ai_harness.orchestration.shadow_runner import ShadowRunner
from ai_harness.schemas.enums import State

shadow_app = typer.Typer(help="Run the two reviewers side by side and compare their decisions.")

EXIT_OK = 0
EXIT_BLOCKED = 1
EXIT_CONFIG = 2


@shadow_app.command("observe")
def observe(
    pr: Annotated[int, typer.Argument(help="Pull request number")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    repo: Annotated[str, typer.Option(help="owner/name")] = "",
    round_: Annotated[int, typer.Option("--round", help="Review round")] = 1,
) -> None:
    """Observe one pull request. The Python path is write-blocked; the shell path is untouched."""
    import asyncio

    from ai_harness.config import load_config
    from ai_harness.wiring import build

    config = load_config(root=path)
    target = repo or config.profile.name
    if not target:
        typer.echo("no repository — set profile.name or pass --repo", err=True)
        raise typer.Exit(EXIT_CONFIG)

    # `require_cutover=False` deliberately: shadow observation is what happens BEFORE a
    # repository is cut over, so requiring the cutover flag would make the tool unusable at
    # exactly the moment it is needed.
    harness = build(config, require_cutover=False)
    try:
        if harness.forge is None:
            typer.echo("shadow observation needs a forge token", err=True)
            raise typer.Exit(EXIT_CONFIG)

        forge = harness.forge
        if not getattr(forge, "writes_blocked", False):
            # Rather than mutate the real adapter, refuse. A flag flipped on a live client is
            # one attribute away from being flipped back by something else in the process.
            typer.echo(
                "refusing: the configured forge can write. Shadow observation requires a "
                "write-blocked client — the shell path owns the label during the comparison.",
                err=True,
            )
            raise typer.Exit(EXIT_CONFIG)

        reviewer = harness.deps.registry.subgraph_for(State.REVIEW)
        runner = ShadowRunner(
            reviewer=reviewer,
            forge=forge,
            store=harness.store,
            repo=target,
            clock=harness.deps.clock,
            logger=Logger(),
        )
        outcome = asyncio.run(runner.observe(pr, round_=round_))
        if outcome.is_err:
            typer.echo(f"could not observe #{pr}: {outcome.error}", err=True)
            raise typer.Exit(EXIT_BLOCKED)
        observation = outcome.unwrap()
        typer.echo(
            json.dumps(
                {
                    "pr": pr,
                    "agreement": observation.comparison.agreement.value,
                    "recorded": observation.recorded,
                },
                indent=2,
            )
        )
    finally:
        harness.close()


@shadow_app.command("explain")
def explain(
    run_id: Annotated[str, typer.Argument(help="The run the disagreement belongs to")],
    head_sha: Annotated[str, typer.Argument(help="Commit the review judged")],
    explanation: Annotated[str, typer.Argument(help="Which engine was right, and why")],
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    round_: Annotated[int, typer.Option("--round")] = 1,
) -> None:
    """Account for one disagreement.

    One at a time, on purpose. The criterion is "every disagreement written up: which engine was
    right, and why", and a bulk-clear would satisfy the letter of it while destroying the point.
    """
    import asyncio

    store = _store(path)
    try:
        written = asyncio.run(store.explain(run_id, head_sha, round_, explanation))
        if not written:
            typer.echo(f"no observation for {run_id} at {head_sha[:12]} round {round_}", err=True)
            raise typer.Exit(EXIT_CONFIG)
        typer.echo("explained")
    finally:
        store.dispose()


@shadow_app.command("report")
def report(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    repo: Annotated[str, typer.Option(help="Restrict to one repository")] = "",
    days: Annotated[int, typer.Option(help="Observation window")] = 7,
    gate: Annotated[
        bool, typer.Option("--gate", help="Exit non-zero unless the cutover is permitted")
    ] = False,
) -> None:
    """The agreement report §24 Phase 2 gates on."""
    import asyncio

    from ai_harness.kernel.clock import SystemClock

    store = _store(path)
    try:
        since = window_start(SystemClock().now(), days=days)
        comparator = asyncio.run(load_comparator(store, repo=repo or None, since=since))
        payload = comparator.report()
        typer.echo(json.dumps(payload, indent=2, default=str))
        if gate and not comparator.may_cut_over():
            # Non-zero so a nightly job notices, rather than a person remembering to look.
            raise typer.Exit(EXIT_BLOCKED)
    finally:
        store.dispose()
