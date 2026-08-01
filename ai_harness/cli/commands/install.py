"""``agent install`` and ``agent preflight`` (#79).

The shell harness's `*-setup.sh` scripts did this, and their header says the important part:
*SAFE to re-run (idempotent)*. That property is what makes an install script usable at all — an
operator who is unsure whether it ran should be able to just run it again.

Idempotency here is stronger than "does not crash on a second run": nothing is *written* the
second time. Every action reports `created`, `updated` or `unchanged`, and running twice yields
all-unchanged. That is testable in a tmp directory with no systemd and no forge, which is why it
is asserted rather than believed.

`preflight` exists because §24 Phase 4's checklist says *"`agent ls --status running` is empty
before each flip, checked by script rather than by eye"*. A person reading a list and deciding
it looks empty is exactly the step that gets skipped at 6pm on a Friday.

Three things this command deliberately does **not** do:

* It never starts the timer for a repository that is not cut over. A timer that drives runs
  nobody has watched against a real PR is the wrong order, and #76 is the gate.
* It never disables the shell timer. §24 Phase 4 keeps the shell merger installed and disabled
  for one release, and doing that automatically would remove the rollback while installing the
  thing that might need it.
* It never writes outside the unit directory and the forge's label set.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated

import typer

from ai_harness.deploy.units import LABELS, render

install_app = typer.Typer(help="Install the timers, labels and units the loop needs.")

EXIT_OK = 0
EXIT_NOT_READY = 1
EXIT_CONFIG = 2

CREATED = "created"
UPDATED = "updated"
UNCHANGED = "unchanged"


@dataclass
class Plan:
    """What an install would do, or did. Every entry carries its outcome."""

    actions: list[dict[str, str]] = field(default_factory=list)

    def note(self, kind: str, target: str, outcome: str, detail: str = "") -> None:
        self.actions.append(
            {
                "kind": kind,
                "target": target,
                "outcome": outcome,
                **({"detail": detail} if detail else {}),
            }
        )

    @property
    def changed(self) -> bool:
        return any(action["outcome"] != UNCHANGED for action in self.actions)

    def as_dict(self) -> dict[str, object]:
        return {"changed": self.changed, "actions": self.actions}


def write_if_different(path: Path, content: str, plan: Plan, *, dry_run: bool) -> None:
    """The whole idempotency mechanism, in one function.

    Comparing content rather than existence is what makes a re-run a no-op *and* still lets a
    template change land. Writing unconditionally would touch mtimes, which makes
    ``systemctl daemon-reload`` necessary every time and makes "did anything change?"
    unanswerable.
    """
    if path.exists() and path.read_text() == content:
        plan.note("unit", str(path), UNCHANGED)
        return
    outcome = UPDATED if path.exists() else CREATED
    if not dry_run:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    plan.note("unit", str(path), outcome)


@install_app.command("install")
def install(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    repo: Annotated[str, typer.Option(help="owner/name")] = "",
    unit_dir: Annotated[
        Path | None, typer.Option("--unit-dir", help="Where units are written")
    ] = None,
    interval: Annotated[str, typer.Option(help="Timer cadence")] = "2min",
    labels_only: Annotated[bool, typer.Option("--labels-only")] = False,
    units_only: Annotated[bool, typer.Option("--units-only")] = False,
    enable: Annotated[
        bool, typer.Option("--enable", help="Also enable and start the timers")
    ] = False,
    dry_run: Annotated[
        bool, typer.Option("--dry-run", help="Print the plan, change nothing")
    ] = False,
) -> None:
    """Install labels and units. Idempotent: a second run writes nothing."""
    import asyncio

    from ai_harness.config import load_config

    config = load_config(root=path)
    target = repo or config.profile.name
    if not target:
        typer.echo("no repository — set profile.name or pass --repo", err=True)
        raise typer.Exit(EXIT_CONFIG)

    plan = Plan()
    root = path.resolve()

    if not labels_only:
        directory = unit_dir or Path.home() / ".config" / "systemd" / "user"
        agent_bin = shutil.which("agent") or str(Path(sys.executable).parent / "agent")
        for kind in ("tick", "work"):
            spec = render(
                kind,
                repo=target,
                working_dir=str(root),
                agent_bin=agent_bin,
                interval=interval,
            )
            write_if_different(
                directory / spec.service_filename, spec.service, plan, dry_run=dry_run
            )
            write_if_different(directory / spec.timer_filename, spec.timer, plan, dry_run=dry_run)

        if enable and not dry_run:
            if config.profile.engine != "python":
                # Refused, not warned. Enabling a timer against an uncut-over repository is the
                # one action here that could start driving runs nobody has watched (#76).
                typer.echo(
                    "refusing to enable the timers: profile.engine is "
                    f"{config.profile.engine!r}. Install the units, then enable them once the "
                    "shadow comparison closes (#76).",
                    err=True,
                )
                raise typer.Exit(EXIT_NOT_READY)
            _systemctl(plan, ["daemon-reload"])
            for kind in ("tick", "work"):
                name = render(
                    kind, repo=target, working_dir=str(root), agent_bin=agent_bin
                ).timer_filename
                _systemctl(plan, ["enable", "--now", name])
            _linger(plan)

    if not units_only:
        asyncio.run(_labels(config, target, plan, dry_run=dry_run))

    typer.echo(json.dumps(plan.as_dict(), indent=2))


async def _labels(config: object, repo: str, plan: Plan, *, dry_run: bool) -> None:
    """Create the labels the loop projects onto. Absent forge ⇒ reported, not fatal."""
    from ai_harness.wiring import build_forge

    forge = build_forge(config)  # type: ignore[arg-type]
    if forge is None:
        plan.note("labels", repo, UNCHANGED, "no forge token configured")
        return
    for name, _colour, description in LABELS:
        if dry_run:
            plan.note("label", name, CREATED, description)
            continue
        # The forge protocol has no create-label verb — labels are created lazily by the
        # adapters when first applied. Recording the intent keeps the plan honest rather than
        # claiming an action that did not happen.
        plan.note("label", name, UNCHANGED, "created on first use by the forge adapter")


def _systemctl(plan: Plan, args: list[str]) -> None:
    if shutil.which("systemctl") is None:
        plan.note("systemd", " ".join(args), UNCHANGED, "systemctl is not on PATH")
        return
    result = subprocess.run(
        ["systemctl", "--user", *args], capture_output=True, text=True, check=False
    )
    plan.note(
        "systemd",
        " ".join(args),
        UPDATED if result.returncode == 0 else UNCHANGED,
        result.stderr.strip()[-200:],
    )


def _linger(plan: Plan) -> None:
    """So the timer survives a logout. A failure here is reported, never fatal."""
    if shutil.which("loginctl") is None:
        plan.note("linger", os.environ.get("USER", ""), UNCHANGED, "loginctl is not on PATH")
        return
    user = os.environ.get("USER", "")
    result = subprocess.run(
        ["loginctl", "enable-linger", user], capture_output=True, text=True, check=False
    )
    plan.note(
        "linger",
        user,
        UPDATED if result.returncode == 0 else UNCHANGED,
        result.stderr.strip()[-200:] or "run with sudo if this did not take",
    )


@install_app.command("preflight")
def preflight(
    path: Annotated[Path, typer.Option("--path", help="Repository root")] = Path(),
    repo: Annotated[str, typer.Option(help="Restrict to one repository")] = "",
) -> None:
    """Is it safe to flip the engine flag right now?

    §24 Phase 4: *"`agent ls --status running` is empty before each flip, checked by script
    rather than by eye."* Exits non-zero if any run is mid-flight, so the flip can be gated on
    this rather than on somebody deciding a list looked empty.
    """
    import asyncio

    from ai_harness.cli.commands.state import _store
    from ai_harness.schemas.enums import RunStatus

    store = _store(path)
    try:
        runs = asyncio.run(store.list_runs(repo=repo or None, status=RunStatus.RUNNING))
        payload = {
            "running": [{"run_id": run.run_id, "state": run.state.value} for run in runs],
            "safe_to_flip": not runs,
        }
        typer.echo(json.dumps(payload, indent=2))
        if runs:
            # Flipping the engine mid-run means one run advanced by two engines: the shell path
            # holds a label the Python path does not know about, and both believe they own it.
            raise typer.Exit(EXIT_NOT_READY)
    finally:
        store.dispose()
