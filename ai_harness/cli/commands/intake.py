"""``agent run`` — the entry point that turns an issue into a run.

Every other command in this package advances, inspects or reconciles work that already exists.
Nothing created it: ``tick`` reconciles and dispatches, ``work`` claims, and the scout is
forbidden by import contract from starting anything. So the queue could only ever be filled by
the shell pipeline calling ``agent record``, and a repository cut over to the Python engine had
no way to be given work at all.

Three properties, each of which is the reason a line here exists:

* **Intake is explicit.** A human names the issue, or a label sweep does — see ``--label``. The
  harness does not decide for itself what to build, and the scout that *proposes* work still
  cannot start it.
* **One run per issue.** Re-running the command for an issue that already has a live run returns
  that run rather than forking a second one onto the same branch. Two runs on one branch is the
  race the worktree lock exists to prevent, and creating it deliberately would be worse than
  losing it.
* **The issue's text is fetched once, here, and stored on the request.** A run whose title
  changed under it mid-flight would review one thing and merge another.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Annotated

import typer

from ai_harness.config import ConfigError, load_config
from ai_harness.schemas.enums import Tier
from ai_harness.schemas.job import JobRequest
from ai_harness.wiring import WiringError, build

intake_app = typer.Typer(help="Turn an issue into a run.")

EXIT_OK = 0
EXIT_NOT_FOUND = 1
EXIT_CONFIG = 2


@intake_app.command("run")
def run_issue(
    issue: Annotated[int | None, typer.Option(help="Issue number to build")] = None,
    label: Annotated[str, typer.Option(help="Admit every open issue carrying this label")] = "",
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    repo: Annotated[str, typer.Option(help="owner/name")] = "",
    tier: Annotated[str | None, typer.Option(help="Gate tier for this run")] = None,
    limit: Annotated[int, typer.Option(help="Cap on issues admitted by --label")] = 3,
    dry_run: Annotated[
        bool, typer.Option("--dry-run", help="Say what would be admitted, create nothing")
    ] = False,
    force: Annotated[
        bool, typer.Option("--force", help="Admit into a repository that is not cut over")
    ] = False,
) -> None:
    """Create a run for one issue, or for every issue carrying a label."""
    if issue is None and not label:
        typer.echo("name an issue with --issue N, or a label with --label agent", err=True)
        raise typer.Exit(EXIT_CONFIG)

    try:
        config = load_config(root=path)
        harness = build(config, require_cutover=not force)
    except (ConfigError, WiringError) as exc:
        typer.echo(f"refusing to start: {exc}", err=True)
        raise typer.Exit(EXIT_CONFIG) from exc

    try:
        target = repo or config.profile.name
        if not target:
            typer.echo("no repository — set profile.name or pass --repo", err=True)
            raise typer.Exit(EXIT_CONFIG)
        if harness.forge is None:
            typer.echo(
                "intake needs a forge token (GITHUB_TOKEN or GITLAB_TOKEN): the issue's title "
                "and body are what the plan is built from, and a run without them would be "
                "asked to implement a number",
                err=True,
            )
            raise typer.Exit(EXIT_CONFIG)

        admitted = asyncio.run(
            _admit(
                harness,
                repo=target,
                issue=issue,
                label=label,
                tier=Tier(tier) if tier else None,
                limit=limit,
                dry_run=dry_run,
            )
        )
        typer.echo(json.dumps({"admitted": admitted, "dry_run": dry_run}, indent=2))
        if not admitted:
            raise typer.Exit(EXIT_NOT_FOUND)
    finally:
        harness.close()


async def _admit(
    harness: object,
    *,
    repo: str,
    issue: int | None,
    label: str,
    tier: Tier | None,
    limit: int,
    dry_run: bool,
) -> list[dict[str, object]]:
    forge = harness.forge  # type: ignore[attr-defined]
    store = harness.store  # type: ignore[attr-defined]
    config = harness.config  # type: ignore[attr-defined]

    numbers: list[int] = []
    if issue is not None:
        numbers = [issue]
    else:
        listed = await forge.list_issues(state="open", labels=[label] if label else None)
        if listed.is_err:
            return []
        numbers = [item.number for item in listed.unwrap()][:limit]

    admitted: list[dict[str, object]] = []
    for number in numbers:
        fetched = await forge.get_issue(number)
        if fetched.is_err:
            admitted.append({"issue": number, "skipped": "could not be read from the forge"})
            continue
        found = fetched.unwrap()

        existing = await _live_run_for(store, repo, number)
        if existing is not None:
            # Not an error: the answer to "build this" when it is already being built is the run
            # that is building it.
            admitted.append(
                {"issue": number, "run_id": existing, "created": False, "why": "already in flight"}
            )
            continue

        if dry_run:
            admitted.append({"issue": number, "title": found.title[:80], "created": False})
            continue

        run = await store.create(
            JobRequest(
                repo=repo,
                issue=number,
                title=found.title,
                # Untrusted: it reaches a prompt only through the trust-fencing layer.
                body=found.body,
                forge=config.forge,
                profile=config.profile,
                policy=config.policy,
                tier=tier,
                requested_by="cli",
            )
        )
        admitted.append(
            {"issue": number, "run_id": run.run_id, "created": True, "title": found.title[:80]}
        )
    return admitted


async def _live_run_for(store: object, repo: str, issue: int) -> str | None:
    """The run already building this issue, if there is one."""
    runs = await store.list_runs(repo=repo, limit=200)  # type: ignore[attr-defined]
    for run in runs:
        if run.request.issue == issue and run.disposition is None:
            return str(run.run_id)
    return None
