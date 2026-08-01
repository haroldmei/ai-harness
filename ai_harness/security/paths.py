"""Path containment — traversal and symlink safety.

A workspace is only a boundary if every path that claims to be inside it actually resolves
inside it. Three ways that fails, all of them tested: ``..`` segments, an absolute path, and a
symlink that points out. The third is the one people forget, and it is also the one the shell
harness hit from the other direction — a directory-only ``.gitignore`` does not match a
*symlink* named ``node_modules``, so provisioned symlinks got committed.
"""

from __future__ import annotations

from pathlib import Path

from ai_harness.kernel.outcome import ErrorCategory, Outcome


def contained(root: Path, candidate: str | Path) -> Outcome[Path]:
    """Resolve ``candidate`` and prove it is inside ``root``, or refuse it."""
    base = root.resolve()
    target = Path(candidate)

    # `~` is not an ordinary path component. Python treats it literally, so `~/.ssh/id_rsa`
    # resolves happily *inside* the workspace — but a shell, a config loader or anything else
    # downstream expands it to $HOME. Refusing it removes the disagreement entirely.
    if any(part.startswith("~") for part in target.parts):
        return Outcome.fail(
            ErrorCategory.POLICY,
            f"{candidate} contains a `~` component, which means different things to different "
            "readers; the workspace is addressed literally",
        )
    absolute = target if target.is_absolute() else base / target
    try:
        resolved = absolute.resolve()
    except (OSError, RuntimeError) as exc:  # RuntimeError: symlink loop
        return Outcome.fail(ErrorCategory.POLICY, f"cannot resolve {candidate}: {exc}")

    if resolved == base or base in resolved.parents:
        return Outcome.ok(resolved)
    return Outcome.fail(
        ErrorCategory.POLICY,
        f"{candidate} resolves outside the workspace ({resolved})",
        remedy="the workspace is the boundary; a path that leaves it is refused, not clamped",
    )


def escaping_symlinks(root: Path) -> list[Path]:
    """Every symlink under ``root`` whose target leaves it.

    Reported rather than followed: the harness wants to *know* that a tree contains an escape
    hatch, and deleting someone's symlink silently is its own kind of surprise.
    """
    base = root.resolve()
    offenders: list[Path] = []
    for path in base.rglob("*"):
        if not path.is_symlink():
            continue
        try:
            resolved = path.resolve()
        except (OSError, RuntimeError):
            offenders.append(path)
            continue
        if resolved != base and base not in resolved.parents:
            offenders.append(path)
    return offenders
