"""Where the Hub keeps weights, and which directory a pin resolves to.

The registry pins a ``(repo_id, revision)``; the *files* live in the Hub's cache, and the serving
unit runs with ``HF_HUB_OFFLINE=1`` — so at start time the cache is the only place weights can
come from. That makes "which directory is this pin" a fact the harness needs twice, for two
different reasons:

* the **preflight** answers "are the weights here at all", before a start that would otherwise
  load for a minute and then fail;
* the **unit** serves that directory *by path* rather than by repo id, which is what makes the
  running server able to say which revision it loaded. vLLM's OpenAI-compatible ``/v1/models``
  has no revision field — ``root`` carries whatever it was started with — so pointing it at
  ``…/snapshots/<sha>`` is the difference between a server whose identity is attributable and one
  that can only be taken on trust. ``--revision`` decides which weights are *loaded*; it does not
  make them *reportable*.

Host I/O, deliberately kept out of :mod:`ai_harness.llm.serving.models`: the arithmetic there is
pure and testable on any box, and the moment it reads a filesystem it stops being either.
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from pathlib import Path

from ai_harness.llm.serving.models import ModelSpec

SNAPSHOT_SEGMENT = "snapshots"

_SHA = re.compile(r"^[0-9a-f]{7,64}$")


def hub_cache_root(environ: Mapping[str, str] | None = None) -> Path:
    """Where the Hub keeps weights, by the Hub's own precedence.

    Resolved rather than assumed: an operator who moved the cache with ``HF_HOME`` did it because
    the default disk was too small, and a preflight that looks in the default one would report
    every model missing on exactly the box that took the most care.
    """
    env = environ if environ is not None else os.environ
    if explicit := env.get("HF_HUB_CACHE"):
        return Path(explicit)
    if home := env.get("HF_HOME"):
        return Path(home) / "hub"
    base = env.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "huggingface" / "hub"


def repo_folder(repo_id: str) -> str:
    """``org/name`` → ``models--org--name``, the Hub's own on-disk naming."""
    return f"models--{repo_id.replace('/', '--')}"


def cached_snapshot(root: Path, spec: ModelSpec) -> Path | None:
    """The snapshot directory holding this exact revision, or ``None``.

    Prefix-matched because :func:`~ai_harness.llm.serving.models.check_revision` accepts a short
    digest for the same commit, and a pin an operator shortened by hand should not read as absent.

    An *empty* directory is not evidence: an interrupted download leaves one behind, and "the
    folder exists" is the same class of claim as "``npm ci`` exited 0".
    """
    folder = root / repo_folder(spec.repo_id) / SNAPSHOT_SEGMENT
    if not folder.is_dir():
        return None
    for candidate in sorted(folder.iterdir()):
        if candidate.name.startswith(spec.revision) and any(candidate.iterdir()):
            return candidate
    return None


def revision_from_path(value: str) -> str | None:
    """The digest in ``…/models--org--name/snapshots/<sha>``, or ``None``.

    This is the other half of serving by path: the unit points vLLM at a snapshot directory, and
    the server echoes that path back as ``root``, so the revision the harness pinned comes back
    from the process that actually loaded it rather than from the configuration that hoped to.
    """
    parts = Path(value).parts
    if SNAPSHOT_SEGMENT not in parts:
        return None
    index = len(parts) - 1 - tuple(reversed(parts)).index(SNAPSHOT_SEGMENT)
    if index + 1 >= len(parts):
        return None
    candidate = parts[index + 1]
    return candidate if _SHA.match(candidate) else None
