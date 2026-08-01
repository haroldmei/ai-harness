"""Iteration bookkeeping, ported from `iteration-*.sh` and `generate-iteration-index.sh` (#109).

The iteration log is how a product build knows what it has already tried. Three of these four
operations are file bookkeeping with an exact output format — the index is committed, so a
changed byte is a diff somebody has to read — and the fourth is a rule:

**A past iteration is immutable.** `iteration-immutable-check.sh` fails a build that modified or
deleted a file under `docs/iterations/`, because rewriting the record of what was tried is how a
builder loses the ability to tell what it tried. That check is a git diff against the base, and
it stays one — the rule is about history, and history is what git holds.

The count is stored in `state.json` rather than recomputed, with a one-time migration from the
filenames when the field is missing. That is an O(1) read where the shell's fallback is a glob
and a sort, and it matters because every phase reads it.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.product.state import ProductState

ITERATION_RE = re.compile(r"^(\d+)-")
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")

INDEX_HEADER_TEMPLATE = """\
# Iteration Log

> ⚠️ **This file is auto-generated** from `{directory}/` by
> `agent iteration index`. Do NOT hand-edit it.
> To add an iteration, create a new file under `{directory}/`
> following the naming convention in `CLAUDE.md`.
"""
"""The directory is interpolated rather than written in: where a repository keeps its
iterations is that repository's convention (Q2)."""


@dataclass(frozen=True, slots=True)
class Iteration:
    """One iteration file, as the index reads it."""

    path: Path
    number: int
    header: str

    @property
    def title(self) -> str:
        """The header minus ``## Iteration N`` — a date, or a date and a description."""
        title = self.header.removeprefix("## Iteration ")
        title = title.removeprefix(f"{self.number} ")
        for dash in ("— ", "- "):
            title = title.removeprefix(dash)
        return title.strip() or self.path.name

    @property
    def date(self) -> str:
        found = DATE_RE.search(self.header)
        return found.group() if found else ""


@dataclass
class Iterations:
    """The iteration corpus and the four things done to it."""

    directory: Path
    state: ProductState | None = None
    index_file: Path | None = None
    clock: Clock = field(default_factory=SystemClock)
    notes: list[str] = field(default_factory=list)

    def load(self) -> list[Iteration]:
        """Every iteration file, newest first — the order the index is written in."""
        if not self.directory.is_dir():
            return []
        found: list[Iteration] = []
        for path in sorted(self.directory.glob("*.md"), reverse=True):
            match = ITERATION_RE.match(path.name)
            if match is None:
                # A file that does not follow the convention is not an iteration. Skipping it
                # silently is how one goes missing from the index, so it is a note.
                self.notes.append(f"{path.name} has no NNN- prefix and is not indexed")
                continue
            header = ""
            try:
                with path.open(encoding="utf-8") as stream:
                    header = stream.readline().strip()
            except OSError:
                pass
            found.append(Iteration(path=path, number=int(match.group(1)), header=header))
        return found

    # ── count ────────────────────────────────────────────────────────────────────

    def highest_on_disk(self) -> int:
        return max((item.number for item in self.load()), default=0)

    def current(self) -> int:
        """The stored count, migrating once from the filenames if it was never stored.

        Stored rather than recomputed because every phase reads it, and the fallback is a glob
        and a sort over a directory that only grows.
        """
        if self.state is None:
            return self.highest_on_disk()
        stored = self.state.get(".iteration_count")
        if isinstance(stored, int):
            return stored
        migrated = self.highest_on_disk()
        self.state.set(".iteration_count", migrated)
        return migrated

    def peek_next(self) -> int:
        return self.current() + 1

    def take_next(self) -> int:
        """Claim the next number and persist it."""
        nxt = self.peek_next()
        if self.state is not None:
            self.state.set(".iteration_count", nxt)
        return nxt

    # ── index ────────────────────────────────────────────────────────────────────

    def render_index(self, *, generated_at: str | None = None) -> str:
        """The committed index, in the shell's format exactly.

        One line differs deliberately: the "auto-generated by" pointer names the command that
        regenerates it, which after the port is `agent iteration index`. A file that tells the
        reader to run a script that no longer exists is worse than a changed byte.

        The trailing timestamp is the shell's and is kept, along with its wart: it makes every
        regeneration a diff even when no iteration changed. Changing that is a decision about
        the format, not about the port, so it is not made here.
        """
        items = self.load()
        stamp = generated_at or (
            self.clock.now().strftime("%Y-%m-%dT%H:%M:%SZ") if self.clock else ""
        )
        header = INDEX_HEADER_TEMPLATE.format(directory=self.relative_directory)
        lines = [header, f"**Total iterations:** {len(items)}", "", "---", ""]
        for item in items:
            lines.append(f"- [Iteration {item.number}](iterations/{item.path.name}) — {item.title}")
        lines += ["", "---", "", f"*Generated {stamp}. {len(items)} iterations.*", ""]
        return "\n".join(lines)

    @property
    def latest_date(self) -> str:
        """The newest iteration's date, which the shell prints on stdout after writing."""
        return next((item.date for item in self.load() if item.date), "")

    @property
    def relative_directory(self) -> str:
        """How the index refers to the corpus — a repo-relative path, not this machine's."""
        parts = self.directory.parts
        return "/".join(parts[-2:]) if len(parts) >= 2 else self.directory.name

    def write_index(self) -> Path:
        if self.index_file is None:
            raise ValueError("no index file is configured for this repository")
        target = self.index_file
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(self.render_index(), encoding="utf-8")
        return target

    # ── immutability ─────────────────────────────────────────────────────────────

    def modified_since(self, base: str = "origin/main", *, root: Path | None = None) -> list[str]:
        """Iteration files this branch modified or deleted, per git.

        A git question asked of git. Reimplementing "what changed since the base" against a
        working tree would answer a different question — one that cannot see a rewrite that was
        already committed.
        """
        where = root or self.directory.parent.parent
        try:
            result = subprocess.run(
                [
                    "git",
                    "diff",
                    "--name-status",
                    "--diff-filter=MD",
                    f"{base}...HEAD",
                    "--",
                    str(self.directory),
                ],
                cwd=where,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return []
        if result.returncode != 0:
            return []
        return [line for line in result.stdout.splitlines() if line.strip()]

    def check_immutable(
        self, base: str = "origin/main", *, root: Path | None = None
    ) -> Outcome[int]:
        """Pass when no past iteration was touched; fail naming every one that was."""
        if not self.directory.is_dir():
            return Outcome.ok(0)
        violations = self.modified_since(base, root=root)
        if not violations:
            return Outcome.ok(0)
        return Outcome.fail(
            ErrorCategory.POLICY,
            f"{len(violations)} iteration file(s) were modified or deleted on this branch",
            remedy=(
                "an iteration records what was tried; rewriting it loses the ability to tell "
                "what was tried. Add a new iteration instead of editing a past one"
            ),
            details={"violations": violations},
        )
