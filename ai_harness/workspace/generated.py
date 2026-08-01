"""Generated files — resolved by policy, never by a model.

A generated file's branch-side content carries no information worth merging: the build
regenerates it. Taking the base copy and regenerating is therefore both correct and cheap,
and it keeps a whole class of conflict away from the conflict resolver.

The path list is data on ``RepoProfile``. That matters: the shell has this list in **three**
places and they have already drifted (the inbox carries four paths, the pipeline and the merger
three), so a conflict that auto-resolves in one stage escalates in another.
"""

from __future__ import annotations

import fnmatch
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class ConflictPolicy:
    """Which paths regenerate, and what regenerates them."""

    generated_paths: list[str] = field(default_factory=list)
    regenerate_command: list[str] | None = None

    def is_generated(self, path: str) -> bool:
        return any(fnmatch.fnmatch(path, pattern) for pattern in self.generated_paths)

    def partition(self, paths: list[str]) -> tuple[list[str], list[str]]:
        """``(generated, product)``. Only an empty product list may be auto-resolved."""
        generated = [p for p in paths if self.is_generated(p)]
        product = [p for p in paths if not self.is_generated(p)]
        return generated, product

    def auto_resolvable(self, paths: list[str]) -> bool:
        if not paths:
            return False
        return all(self.is_generated(p) for p in paths)
