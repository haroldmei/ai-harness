"""Global fixtures.

Two properties are enforced here rather than trusted:

**Zero network.** ``socket.socket`` is blocked for the whole default suite. A test that wants
a network must be marked ``live`` and is excluded from the default run. This is the Python
form of the shell suites' "stubbed ``gh``, stubbed ``claude``, zero network, zero LLM cost".

**No ambient configuration.** ``lib/test-env.sh`` exists because ``AGENT_SLOT=1`` inherited
from a systemd unit made a suite red on lanes 1–2 and green on lane 0. Every ``AGENT_*``,
``HARNESS_*``, ``PR_*``, ``QG_*`` and provider key is scrubbed from the environment for every
test, globally — not per test, because the one that forgets is the one that breaks.
"""

from __future__ import annotations

import os
import socket
import subprocess
from collections.abc import Iterator
from pathlib import Path

import pytest

_AMBIENT_PREFIXES = ("AGENT_", "HARNESS_", "PR_", "QG_", "PIPELINE_", "TRIAGE_", "MERGER_")
_AMBIENT_EXACT = (
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GITLAB_TOKEN",
    "REQUIRED_GATES",
    "TIER",
)


@pytest.fixture(autouse=True)
def _scrub_ambient_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in list(os.environ):
        if key.startswith(_AMBIENT_PREFIXES) or key in _AMBIENT_EXACT:
            monkeypatch.delenv(key, raising=False)


@pytest.fixture(autouse=True)
def _no_network(request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Block outbound connections, not socket creation.

    asyncio's own event loop builds a self-pipe from a socketpair, so forbidding
    ``socket.socket`` outright would forbid ``async`` tests. What must be impossible is
    *reaching another host*: AF_UNIX is allowed, everything else raises.
    """
    if request.node.get_closest_marker("live"):
        yield
        return

    real_connect = socket.socket.connect
    real_connect_ex = socket.socket.connect_ex

    def _guard(self: socket.socket, address: object) -> None:
        if self.family is socket.AF_UNIX:
            real_connect(self, address)  # type: ignore[arg-type]
            return
        raise RuntimeError(
            f"the default suite is hermetic: no test may connect to {address!r} (mark it 'live')"
        )

    monkeypatch.setattr(socket.socket, "connect", _guard)
    monkeypatch.setattr(socket.socket, "connect_ex", _guard)
    monkeypatch.setattr(
        socket,
        "create_connection",
        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("hermetic suite: no network")),
    )
    yield
    monkeypatch.setattr(socket.socket, "connect_ex", real_connect_ex)


@pytest.fixture
def bare_origin(tmp_path: Path) -> Path:
    """A real bare git repository with one commit on ``main``, to serve as ``origin``.

    Real git, never a mock. Every isolation, resume and rebase behaviour the harness depends
    on is a property of git itself (a linked worktree's ``.git`` is a *pointer file*; ``-B``
    refuses to force-update a checked-out branch), and a fake would agree with whatever the
    code did. The shell suites made the same choice for the same reason.
    """
    origin = tmp_path / "origin.git"
    work = tmp_path / "seed"
    subprocess.run(
        ["git", "init", "--bare", "-b", "main", str(origin)], check=True, capture_output=True
    )
    subprocess.run(["git", "init", "-b", "main", str(work)], check=True, capture_output=True)
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "harness",
        "GIT_AUTHOR_EMAIL": "harness@example.invalid",
        "GIT_COMMITTER_NAME": "harness",
        "GIT_COMMITTER_EMAIL": "harness@example.invalid",
    }
    (work / "README.md").write_text("seed\n")
    for argv in (
        ["git", "-C", str(work), "add", "."],
        ["git", "-C", str(work), "commit", "-m", "seed"],
        ["git", "-C", str(work), "remote", "add", "origin", str(origin)],
        ["git", "-C", str(work), "push", "-q", "origin", "main"],
    ):
        subprocess.run(argv, check=True, capture_output=True, env=env)
    return origin
