"""systemd unit and timer templates (#79).

§2 notes the shell harness's units were never in this repository — they lived on the host, which
is why "install it" was always a manual step somebody remembered differently each time. These
templates are in the package so the install is reproducible, and so `agent install --dry-run`
can show exactly what would be written before anything is.

Three decisions carried over from the shell units, each for a reason:

* **`Type=oneshot`, driven by a timer.** The single-pass rule (§14.1). A long-running service
  would need its own health checks, its own back-pressure and its own shutdown story, and would
  still be a worse version of what systemd already does.
* **`Persistent=true`.** A laptop that was asleep at 09:02 runs the missed tick on wake. Without
  it, a suspended host silently stops reconciling and nothing says so.
* **`RandomizedDelaySec`.** Several repositories on one host would otherwise fire simultaneously
  every two minutes and contend for the same worktree locks and gate slots.

`AGENT_BIN` and `WORKING_DIR` are substituted at install time rather than left as `%i`
specifiers, because the failure mode of a wrong path here is a timer that fires every two
minutes into a non-existent binary, which is noisy in exactly the way nobody reads.
"""

from __future__ import annotations

from dataclasses import dataclass

TICK_SERVICE = """\
[Unit]
Description=ai-harness tick for {repo} — reconcile, admit, dispatch, sweep
Documentation=https://github.com/haroldmei/ai-harness
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory={working_dir}
ExecStart={agent_bin} tick --path {working_dir} --repo {repo}
# A tick that hangs must not block the next one forever. The dispatch inside it already
# bounds each state; this bounds the process.
TimeoutStartSec=1800
Environment=PYTHONUNBUFFERED=1
{environment}
[Install]
WantedBy=default.target
"""

TICK_TIMER = """\
[Unit]
Description=Run the ai-harness tick for {repo} every {interval}

[Timer]
OnBootSec=2min
OnUnitActiveSec={interval}
# A host that was asleep runs the missed tick on wake, rather than silently stopping.
Persistent=true
# Several repositories on one host must not fire simultaneously and contend for the same
# worktree locks and gate slots.
RandomizedDelaySec=30
Unit={unit_name}.service

[Install]
WantedBy=timers.target
"""

WORKER_SERVICE = """\
[Unit]
Description=ai-harness worker for {repo} — claim, advance one boundary, exit
Documentation=https://github.com/haroldmei/ai-harness
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory={working_dir}
ExecStart={agent_bin} work --path {working_dir} --repo {repo} --worker-id %H-%i
TimeoutStartSec=3600
Environment=PYTHONUNBUFFERED=1
{environment}
[Install]
WantedBy=default.target
"""

WORKER_TIMER = """\
[Unit]
Description=Dispatch an ai-harness worker for {repo} every {interval}

[Timer]
OnBootSec=3min
OnUnitActiveSec={interval}
Persistent=true
RandomizedDelaySec=30
Unit={unit_name}.service

[Install]
WantedBy=timers.target
"""

LABELS: tuple[tuple[str, str, str], ...] = (
    ("agent", "1f6feb", "the harness should build this"),
    ("wip", "fbca04", "claimed and in progress"),
    ("done", "0e8a16", "a merge request is open"),
    ("needs-human", "d73a4a", "escalated — a human must decide"),
    ("harness-shadow", "8250df", "observed in shadow mode; the shell path still governs"),
    ("proposed", "c5def5", "filed by the scout; relabel to accept"),
    ("proposed-speculative", "e4e669", "filed by the scout, low confidence"),
)
"""The labels the loop projects onto. Kept here rather than in the setup script so the same
list serves the install, the forge adapters and the tests."""


@dataclass(frozen=True, slots=True)
class UnitSpec:
    """One unit pair, rendered."""

    name: str
    service: str
    timer: str

    @property
    def service_filename(self) -> str:
        return f"{self.name}.service"

    @property
    def timer_filename(self) -> str:
        return f"{self.name}.timer"


def unit_name(kind: str, repo: str) -> str:
    """``ai-harness-tick-owner-name``. Deterministic, so a re-install targets the same files."""
    slug = repo.replace("/", "-").replace("_", "-").lower()
    return f"ai-harness-{kind}-{slug}"


def render(
    kind: str,
    *,
    repo: str,
    working_dir: str,
    agent_bin: str,
    interval: str = "2min",
    environment: dict[str, str] | None = None,
) -> UnitSpec:
    """Render one service/timer pair. Pure — nothing is written here."""
    if kind not in ("tick", "work"):
        raise ValueError(f"unknown unit kind {kind!r}; expected tick or work")

    name = unit_name(kind, repo)
    lines = "".join(
        f"Environment={key}={value}\n" for key, value in sorted((environment or {}).items())
    )
    service_template = TICK_SERVICE if kind == "tick" else WORKER_SERVICE
    timer_template = TICK_TIMER if kind == "tick" else WORKER_TIMER
    return UnitSpec(
        name=name,
        service=service_template.format(
            repo=repo, working_dir=working_dir, agent_bin=agent_bin, environment=lines
        ),
        timer=timer_template.format(repo=repo, interval=interval, unit_name=name),
    )
