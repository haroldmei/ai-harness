"""``agent work`` and ``agent tick`` — the commands that actually drive runs.

These are the first commands in the package that can change a repository, which is why the
guards around them live in :mod:`ai_harness.wiring` rather than here: a check in a CLI handler
protects that handler, and a check in the composition root protects every entry point that will
ever exist, including the ones a scheduler invokes.

Both are single-pass (§14.1). The process exits; systemd, Kubernetes or a person decides whether
to start another. `agent-inbox.sh:15` states the same rule and gives the reason — the cadence
belongs to the scheduler, and a binary that loops internally needs its own health checks, its own
back-pressure and its own shutdown story, and is still a worse version of what a supervisor
already provides.

Exit codes are distinct on purpose, because a timer reads them: ``0`` did work, ``0`` with an
idle report is also fine, and a configuration refusal is ``2`` so a unit that starts every two
minutes fails visibly rather than looping on a missing token.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Annotated

import typer

from ai_harness.config import ConfigError, load_config
from ai_harness.observability.logging import Logger
from ai_harness.orchestration.reconcile import Reconciler
from ai_harness.wiring import Harness, WiringError, build
from ai_harness.workers.runner import Worker
from ai_harness.workers.tick import Ticker

EXIT_OK = 0
EXIT_CONFIG = 2

drive_app = typer.Typer(help="Drive runs: claim work, advance it, reconcile.")


def _harness(path: Path, *, allow_uncutover: bool) -> Harness:
    try:
        # `root=`, not the first positional: that one names the config FILE, and passing a
        # directory there fails with an unhelpful 'Is a directory'.
        config = load_config(root=path)
        return build(config, require_cutover=not allow_uncutover)
    except (ConfigError, WiringError) as exc:
        # Refused before anything was claimed. The message names what is missing, because a
        # timer's failure mode is a log line nobody reads unless it says what to fix.
        typer.echo(f"refusing to start: {exc}", err=True)
        raise typer.Exit(EXIT_CONFIG) from exc


@drive_app.command("work")
def work(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    worker_id: Annotated[str, typer.Option(help="This worker's identity, for the lease")] = "",
    batch: Annotated[int, typer.Option(help="How many runs to claim in one pass")] = 1,
    repo: Annotated[str, typer.Option(help="Restrict to one repository")] = "",
    force: Annotated[
        bool, typer.Option("--force", help="Drive a repository that is not cut over")
    ] = False,
) -> None:
    """Claim ready work, advance each run to its next boundary, and exit.

    A worker holds no local state and has no affinity to a run (§14.3): one that dies is replaced
    by any other, and the run resumes from its last checkpoint. That is what makes the fleet
    story a matter of starting the process more than once.
    """
    harness = _harness(path, allow_uncutover=force)
    logger = Logger()
    try:
        identity = worker_id or f"worker-{harness.config.profile.name or 'local'}"
        report = asyncio.run(
            Worker(deps=harness.deps, queue=harness.queue, worker_id=identity, batch=batch).work(
                repo=repo or None
            )
        )
        typer.echo(
            json.dumps(
                {
                    "worker": report.worker_id,
                    "claimed": report.claimed,
                    "statuses": report.statuses,
                    "idle": report.idle,
                    "unbound_states": [state.value for state in harness.unbound],
                },
                indent=2,
            )
        )
        if harness.unbound:
            logger.warning(
                "some states are unbound and will escalate rather than run",
                states=[state.value for state in harness.unbound],
            )
    finally:
        harness.close()


@drive_app.command("tick")
def tick(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    repo: Annotated[str, typer.Option(help="Repository, as owner/name")] = "",
    force: Annotated[
        bool, typer.Option("--force", help="Drive a repository that is not cut over")
    ] = False,
) -> None:
    """One pass: reconcile, admit, dispatch, sweep.

    Safe to call every two minutes: two overlapping ticks do no double work, because dispatch
    takes a lease per run and a held lease is a no-op rather than an error.
    """
    harness = _harness(path, allow_uncutover=force)
    try:
        target = repo or harness.config.profile.name
        if not target:
            typer.echo(
                "refusing to start: no repository — set profile.name or pass --repo", err=True
            )
            raise typer.Exit(EXIT_CONFIG)
        if harness.forge is None:
            # Reconciliation asks the forge what landed and what is still blocked. Without one
            # it would silently skip every check it exists to perform, which is worse than
            # refusing: a tick that does nothing still looks like a tick that ran.
            typer.echo(
                "refusing to start: tick needs a forge token (GITHUB_TOKEN or GITLAB_TOKEN) — "
                "reconciliation asks the forge what landed, and without it every check it "
                "performs would silently pass",
                err=True,
            )
            raise typer.Exit(EXIT_CONFIG)

        ticker = Ticker(
            deps=harness.deps,
            reconciler=Reconciler(
                store=harness.store,
                forge=harness.forge,
                leases=harness.deps.leases,
                clock=harness.deps.clock,
            ),
            clock=harness.deps.clock,
        )
        report = asyncio.run(ticker.tick(target))
        typer.echo(json.dumps(report.as_dict(), indent=2))
    finally:
        harness.close()
