"""Run ids, repository namespaces and idempotency keys — derived in exactly one place.

``repo_key`` replaces the five byte-identical ``<repo-ns>`` derivations of §3.14
(``agent_repo_ns``, ``pr_repo_ns``, ``scout_repo_ns``, ``_pr_lock_ns`` and triage's ``ns``).
It exists so two checkouts on one host never share a lock, a log directory or a worktree
base, and the algorithm is kept byte-compatible with the shell so a mixed-engine rollout
addresses the same namespaces:

    git rev-parse --git-common-dir | realpath | sha1sum | cut -c1-12

Idempotency keys are the other half of §9: every state declares one, and re-entering a
state with the same key must be safe. They are derived here so a state cannot invent its
own shape.
"""

from __future__ import annotations

import hashlib
import subprocess
import uuid
from pathlib import Path


def new_run_id() -> str:
    """A fresh run id. Hex rather than a UUID string: it appears in branch and tag names."""
    return uuid.uuid4().hex


def repo_key(git_common_dir: str | Path) -> str:
    """Stable 12-character namespace for a checkout.

    Takes the *resolved* git common directory, so a worktree and its primary checkout share
    one namespace while two clones of the same remote do not.
    """
    resolved = Path(git_common_dir).resolve()
    return hashlib.sha1(str(resolved).encode(), usedforsecurity=False).hexdigest()[:12]


def repo_key_for(path: str | Path) -> str | None:
    """``repo_key`` for the repository containing ``path``; ``None`` outside a repository."""
    try:
        proc = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    common = proc.stdout.strip()
    if not common:
        return None
    candidate = Path(common)
    if not candidate.is_absolute():
        candidate = Path(path) / candidate
    return repo_key(candidate)


def idempotency_key(state: str, **parts: object) -> str:
    """``state:part=value:part=value`` with parts sorted, so callers cannot vary the order.

    The values are the ones §9 names: repo, issue, base_sha, commit_sha, plan_hash, round,
    attempt, gate_set. Anything falsy is dropped rather than rendered as an empty segment,
    because ``review:run=x:round=`` and ``review:run=x`` must not be different keys.
    """
    rendered = ":".join(f"{k}={v}" for k, v in sorted(parts.items()) if v not in (None, ""))
    return f"{state}:{rendered}" if rendered else state


def artefact_id(kind: str, payload: bytes) -> str:
    """Content-addressed artefact id. The same evidence stored twice is stored once."""
    return f"{kind}:{hashlib.sha256(payload).hexdigest()[:16]}"


def digest(text: str) -> str:
    """Full sha256 of a prompt or template. Spans carry this — never the text (§21.4)."""
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()
