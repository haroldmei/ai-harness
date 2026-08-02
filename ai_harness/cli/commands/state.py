"""``agent record | ls | inspect | cost | replay`` — Phase 1's command surface.

``record`` is the shell's dual-write helper. Everything else is read-only and answers the two
questions §24 says must become answerable within a week of rollout, before any behaviour moves:
**why is this PR stuck**, and **what has this cost**.

``record`` exits **zero no matter what**. It is invoked from the production shell stages, and an
observability helper that can fail the pipeline is worse than no helper at all.
"""

from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Annotated, Any

import typer

from ai_harness.config import ConfigError, load_config
from ai_harness.persistence.recorder import Recorder, record_safely
from ai_harness.persistence.sql import SqlStore, open_store
from ai_harness.schemas.enums import RunStatus, State
from ai_harness.schemas.run import Run

state_app = typer.Typer(help="Inspect durable run state.")


def _store(path: Path, *, create: bool = True) -> SqlStore:
    """Open the store, creating the schema if it is absent.

    Creation is idempotent and cheap, and it means `agent ls` on a fresh checkout answers
    "no runs recorded" rather than "no such table: runs" — a reader should never have to know
    whether a writer has run yet.
    """
    config = load_config(root=path)
    url = config.database_url
    if url.startswith("sqlite:///") and not url.startswith("sqlite:///:"):
        relative = url.removeprefix("sqlite:///")
        if not Path(relative).is_absolute():
            url = f"sqlite:///{(path / relative).resolve()}"
    return open_store(url, create=create)


# ── the dual-write helper ────────────────────────────────────────────────────────


def record(
    repo: Annotated[str, typer.Option(help="owner/name")],
    stage: Annotated[str, typer.Option(help="inbox | reviewer | fixer | merger | gates | triage")],
    issue: Annotated[int | None, typer.Option(help="Issue number")] = None,
    outcome: Annotated[str, typer.Option(help="merged | escalated | blocked | …")] = "",
    branch: Annotated[str, typer.Option()] = "",
    base_sha: Annotated[str, typer.Option()] = "",
    head_sha: Annotated[str, typer.Option()] = "",
    mr: Annotated[str | None, typer.Option(help="MR/PR id")] = None,
    error: Annotated[str | None, typer.Option()] = None,
    path: Annotated[Path, typer.Option(help="Repository root")] = Path(),
) -> None:
    """Record one shell stage boundary as shadow state. **Always exits zero.**"""
    try:
        store = _store(path)
        run = asyncio.run(
            record_safely(
                Recorder(store=store),
                repo=repo,
                issue=issue,
                stage=stage,
                outcome=outcome,
                branch=branch,
                base_sha=base_sha,
                head_sha=head_sha,
                mr_id=mr,
                error=error,
            )
        )
        if run is not None:
            typer.echo(run.run_id)
    except Exception as exc:
        typer.echo(f"harness-record: {type(exc).__name__}: {exc}", err=True)
    raise typer.Exit(0)


# ── inspection ───────────────────────────────────────────────────────────────────


@state_app.command("ls")
def list_runs(
    repo: Annotated[str | None, typer.Option()] = None,
    status: Annotated[str | None, typer.Option(help="running | deferred | blocked | …")] = None,
    state: Annotated[str | None, typer.Option(help="PREPARE | REVIEW | …")] = None,
    limit: Annotated[int, typer.Option()] = 25,
    as_json: Annotated[bool, typer.Option("--json")] = False,
    path: Annotated[Path, typer.Option(help="Repository root")] = Path(),
) -> None:
    """Every run and its ``(state, status)``."""
    store = _store(path)
    runs = asyncio.run(
        store.list_runs(
            repo=repo,
            state=State(state) if state else None,
            status=RunStatus(status) if status else None,
            limit=limit,
        )
    )
    if as_json:
        typer.echo(json.dumps([_summarise(r) for r in runs], indent=2, default=str))
        return
    if not runs:
        typer.echo("no runs recorded")
        return
    typer.echo(f"{'run':<10} {'repo':<22} {'issue':>6} {'state':<10} {'status':<18} why")
    for run in runs:
        typer.echo(
            f"{run.run_id[:8]:<10} {run.request.repo[:22]:<22} "
            f"{run.request.issue or '':>6} {run.state.value:<10} "
            f"{(run.disposition.value if run.disposition else run.status.value):<18} "
            f"{_why(run)}"
        )


@state_app.command("inspect")
def inspect(
    run_id: Annotated[str, typer.Argument()],
    as_json: Annotated[bool, typer.Option("--json")] = False,
    path: Annotated[Path, typer.Option(help="Repository root")] = Path(),
) -> None:
    """Why is this run where it is: the checkpoint timeline and the last error."""
    store = _store(path)
    run = asyncio.run(store.load(run_id))
    if run is None:
        typer.secho(f"no run {run_id}", fg="red", err=True)
        raise typer.Exit(1)
    checkpoints = asyncio.run(store.checkpoints(run_id))
    spend = asyncio.run(store.run_total(run_id))

    if as_json:
        typer.echo(
            json.dumps(
                {
                    "run": _summarise(run),
                    "why": _why(run),
                    "spend_usd": str(spend),
                    "checkpoints": [c.model_dump(mode="json") for c in checkpoints],
                },
                indent=2,
                default=str,
            )
        )
        return

    typer.echo(f"run      : {run.run_id}")
    typer.echo(f"repo     : {run.request.repo}#{run.request.issue or '-'}")
    typer.echo(f"position : {run.state.value} / {run.status.value}")
    typer.echo(f"why      : {_why(run)}")
    typer.echo(f"branch   : {run.branch or '-'}  base {run.base_sha[:12] or '-'}")
    typer.echo(f"spend    : ${spend}")
    if run.last_error:
        typer.echo(f"error    : {run.last_error}")
    typer.echo("")
    typer.echo("timeline:")
    for checkpoint in checkpoints:
        stage = checkpoint.result.get("stage", "")
        typer.echo(
            f"  {checkpoint.seq:>3}. {checkpoint.state.value:<10} → {checkpoint.next_state.value:<10}"
            f" {stage:<10} {checkpoint.result.get('outcome', '')}"
        )
        # The error's own evidence, which was written to the ledger from the first checkpoint
        # ever recorded and rendered by nothing. `call_structured` stores the exact validation
        # complaint and the head of the model's output; this printed "error: validation" and
        # dropped both, so the most common failure in the system was diagnosable only by
        # hand-rolling a reproduction. It was never missing — it was never shown.
        if checkpoint.error is not None:
            typer.secho(f"       {checkpoint.error.message}", fg="red")
            if checkpoint.error.remedy:
                typer.echo(f"       remedy: {checkpoint.error.remedy}")
            for key, value in sorted(checkpoint.error.details.items()):
                rendered = str(value).replace("\n", "\n" + " " * 15)
                typer.echo(f"       {key}: {rendered[:1500]}")


@state_app.command("cost")
def cost(
    repo: Annotated[str | None, typer.Option()] = None,
    days: Annotated[int, typer.Option(help="Look back this many days")] = 7,
    path: Annotated[Path, typer.Option(help="Repository root")] = Path(),
) -> None:
    """What has this cost — per run, per repo, per template."""
    store = _store(path)
    since = datetime.now(UTC) - timedelta(days=days)
    summary = asyncio.run(store.summary(repo=repo, since=since))
    typer.echo(json.dumps(summary, indent=2, default=str))


@state_app.command("replay")
def replay(
    run_id: Annotated[str, typer.Argument()],
    path: Annotated[Path, typer.Option(help="Repository root")] = Path(),
) -> None:
    """Reconstruct the decision sequence from checkpoints. No side effects."""
    store = _store(path)
    checkpoints = asyncio.run(store.checkpoints(run_id))
    if not checkpoints:
        typer.secho(f"no checkpoints for {run_id}", fg="yellow", err=True)
        raise typer.Exit(1)
    for checkpoint in checkpoints:
        typer.echo(
            json.dumps(
                {
                    "seq": checkpoint.seq,
                    "state": checkpoint.state.value,
                    "next_state": checkpoint.next_state.value,
                    "attempt": checkpoint.attempt,
                    "round": checkpoint.round,
                    "idempotency_key": checkpoint.idempotency_key,
                    "error": checkpoint.error.category.value if checkpoint.error else None,
                    "result": checkpoint.result,
                },
                default=str,
            )
        )


# ── rendering ────────────────────────────────────────────────────────────────────


def _why(run: Run) -> str:
    """One line that answers "why is this stuck" without opening a log."""
    if run.disposition is not None:
        return f"finished: {run.disposition.value}"
    if run.status is RunStatus.BLOCKED:
        return f"blocked on {run.blocked_on or 'an unnamed blocker'}"
    if run.status is RunStatus.AWAITING_APPROVAL:
        return f"awaiting approval {run.pending_approval_id or ''}".strip()
    if run.status is RunStatus.DEFERRED:
        return (
            f"deferred until {run.defer_until.isoformat() if run.defer_until else 'the next tick'}"
        )
    if run.last_error:
        return f"running after: {run.last_error[:60]}"
    return f"running in {run.state.value}"


def _summarise(run: Run) -> dict[str, Any]:
    return {
        "run_id": run.run_id,
        "repo": run.request.repo,
        "issue": run.request.issue,
        "state": run.state.value,
        "status": run.status.value,
        "disposition": run.disposition.value if run.disposition else None,
        "branch": run.branch,
        "mr_url": run.mr_url,
        "counters": run.counters.model_dump(),
        "why": _why(run),
    }


__all__ = ["ConfigError", "record", "state_app"]
