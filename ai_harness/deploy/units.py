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

Phase 7 adds the one unit that is *not* a oneshot: the model server. It is long-running by
nature, it takes its flags from the registry's arithmetic rather than from a copied command
line, and it `Conflicts` with every other model's unit — because L2's "one resident model" has
to hold against a hand-typed `systemctl start`, which is the path no lease inside the harness
can see.
"""

from __future__ import annotations

import shutil
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from ai_harness.llm.serving.models import ServingPlan

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

SERVING_SERVICE = """\
[Unit]
Description=vLLM serving {model} ({repo_id}@{revision_short}) for ai-harness
Documentation=https://github.com/haroldmei/ai-harness
After=network-online.target
# L2: one resident model per card. The residency lease enforces this inside the harness;
# systemd enforces the same rule against a hand-typed `systemctl start`, which is the path
# the lease cannot see.
{conflicts}# A crash loop must not quietly hold the GPU: five failures in ten minutes stops the unit
# rather than restarting into the same OOM forever.
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=exec
WorkingDirectory={working_dir}
ExecStart={exec_start}
# Weights are pinned by digest, so a start that would DOWNLOAD something is a start nobody
# reviewed. Offline is the enforcement; --revision is only the intent.
Environment=HF_HUB_OFFLINE=1
Environment=PYTHONUNBUFFERED=1
Environment=CUDA_VISIBLE_DEVICES=0
{environment}# Loading a 4-bit 30B and compiling its graphs takes tens of seconds. systemd's notion of
# "started" is a bound port; the harness's is a returned token, and only the second one is
# worth acting on.
TimeoutStartSec={start_timeout_s}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
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


UNIT_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
"""What a systemd **user** unit gets when nothing sets ``PATH`` — no conda, no virtualenv.
Written down because every failure in this file's neighbourhood comes from assuming otherwise."""


def resolve_binary(
    configured: str,
    *,
    root: Path,
    which: Callable[[str], str | None] = shutil.which,
) -> str | None:
    """The absolute path a unit must name, or ``None`` when there is nothing to name.

    systemd requires an absolute ``ExecStart``, and a *user* unit's ``PATH`` excludes conda and
    every virtualenv. So a bare name is resolved here, at render time, on the box that will run
    it — the same thing `agent install` does for its own binary (``install.py``), applied to the
    one executable whose absence is otherwise reported as ``203/EXEC`` twenty seconds after a
    start nobody watched.

    ``None`` rather than the bare name, because "I could not find it" and "here it is" are
    different answers and only the caller knows whether to warn or to refuse.
    """
    candidate = Path(configured)
    if len(candidate.parts) > 1:
        absolute = candidate if candidate.is_absolute() else (root / candidate)
        resolved = absolute.resolve()
        return str(resolved) if resolved.exists() else None
    found = which(configured)
    return str(Path(found).resolve()) if found else None


def serving_unit_name(model: str) -> str:
    """``ai-harness-serve-qwen3-coder-30b``. Deterministic, so a re-install targets one file."""
    slug = model.replace("/", "-").replace("_", "-").lower()
    return f"ai-harness-serve-{slug}"


def render_serving(
    plan: ServingPlan,
    *,
    working_dir: str,
    vllm_bin: str = "vllm",
    conflicts: tuple[str, ...] = (),
    environment: dict[str, str] | None = None,
    start_timeout_s: int = 600,
) -> tuple[str, str]:
    """Render the serving unit for one model. Returns ``(unit_name, service_text)``.

    ``conflicts`` are the other models in the registry, not a hand-maintained list: the point of
    L2 is that the *set* of things that must not run together is derived from what exists.

    An absolute ``vllm_bin`` also contributes its directory to ``PATH``. An absolute
    ``ExecStart`` is enough for *systemd* and not enough for **vLLM**, which shells out by name
    to the build tools beside it — ``ninja`` first, when it compiles a kernel. Naming the binary
    and then leaving its siblings unreachable produces a start that gets as far as loading the
    weights and then dies on ``FileNotFoundError: 'ninja'``, which reads as a broken model and is
    a broken ``PATH``.
    """
    argv = plan.argv(binary=vllm_bin)
    conflict_lines = "".join(
        f"Conflicts={serving_unit_name(other)}.service\n" for other in conflicts
    )
    binary = Path(vllm_bin)
    resolved_env = dict(environment or {})
    if binary.is_absolute():
        resolved_env.setdefault("PATH", f"{binary.parent}:{UNIT_PATH}")
    lines = "".join(f"Environment={key}={value}\n" for key, value in sorted(resolved_env.items()))
    service = SERVING_SERVICE.format(
        model=plan.spec.name,
        repo_id=plan.spec.repo_id,
        revision_short=plan.spec.revision[:12],
        conflicts=conflict_lines,
        working_dir=working_dir,
        exec_start=" ".join(argv),
        environment=lines,
        start_timeout_s=start_timeout_s,
    )
    return serving_unit_name(plan.spec.name), service
