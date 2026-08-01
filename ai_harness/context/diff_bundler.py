"""Diffs are **bundled, not truncated**.

The shell reviewer does ``gh pr diff | head -c 60000``. That silently removes whole files with
no marker, so the reviewer approves a change it never saw and nothing in the transcript says so.

Bundling instead: split per file, rank by relevance to the acceptance criteria and the failing
tests, include whole hunks, and emit an explicit ``… N files elided …`` marker naming the
artefact that holds the rest. The model is then always able to say what it could not see —
which is the difference between a bounded review and a false one.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

_FILE_HEADER = re.compile(r"^diff --git a/(?P<a>.+?) b/(?P<b>.+?)$", re.MULTILINE)
_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@", re.MULTILINE)

CHARS_PER_TOKEN = 4
"""A deliberate over-estimate. Budgeting optimistically is how you exceed a context window."""


@dataclass(frozen=True, slots=True)
class FileDiff:
    path: str
    text: str
    hunks: int = 0

    @property
    def tokens(self) -> int:
        return max(len(self.text) // CHARS_PER_TOKEN, 1)


@dataclass(frozen=True, slots=True)
class DiffBundle:
    """What the model gets, plus an honest account of what it did not."""

    included: list[FileDiff] = field(default_factory=list)
    elided: list[str] = field(default_factory=list)
    artefact_id: str | None = None

    @property
    def complete(self) -> bool:
        return not self.elided

    def render(self) -> str:
        parts = [f.text.rstrip() for f in self.included]
        if self.elided:
            where = f" (see artefact {self.artefact_id})" if self.artefact_id else ""
            parts.append(
                f"… {len(self.elided)} file(s) elided{where}: {', '.join(sorted(self.elided))} …\n"
                "You have NOT seen these files. Do not draw conclusions about them, and say so "
                "if a verdict would depend on them."
            )
        return "\n\n".join(parts)

    @property
    def tokens(self) -> int:
        return sum(f.tokens for f in self.included)


def split_by_file(diff: str) -> list[FileDiff]:
    """Split a unified diff into per-file pieces, keeping each file's hunks intact."""
    matches = list(_FILE_HEADER.finditer(diff))
    if not matches:
        return (
            [FileDiff(path="(unknown)", text=diff, hunks=len(_HUNK.findall(diff)))]
            if diff.strip()
            else []
        )
    files: list[FileDiff] = []
    for index, match in enumerate(matches):
        start = match.start()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(diff)
        text = diff[start:end]
        files.append(FileDiff(path=match.group("b"), text=text, hunks=len(_HUNK.findall(text))))
    return files


def rank(
    files: list[FileDiff],
    *,
    acceptance_terms: list[str] | None = None,
    failing_tests: list[str] | None = None,
) -> list[FileDiff]:
    """Most relevant first: named by a failing test, then by the acceptance criteria, then size.

    Seeding relevance from *precise* inputs — a stack trace names a file, the criteria name
    symbols — is both cheaper and more accurate than similarity search over prose (§17.2).
    """
    terms = [t.lower() for t in (acceptance_terms or []) if t]
    tests = [t.lower() for t in (failing_tests or []) if t]

    # A failing test id is "<file>::<name>" (or "<file> > <name>"). Compare against the FILE
    # part only: a substring match on the basename makes `app/svc.py` look like it was named by
    # `tests/test_svc.py::test_send`, which ranks the wrong file first.
    test_files = {_test_file(test) for test in tests}

    def score(file: FileDiff) -> tuple[int, int, int]:
        path = file.path.lower()
        named_by_test = path in test_files or _basename(path) in {_basename(f) for f in test_files}
        named_by_criteria = any(term in path or term in file.text.lower() for term in terms)
        # Smaller files first within a tier: more files seen for the same budget.
        return (0 if named_by_test else 1, 0 if named_by_criteria else 1, file.tokens)

    return sorted(files, key=score)


def bundle(
    diff: str,
    *,
    max_tokens: int = 60_000,
    acceptance_terms: list[str] | None = None,
    failing_tests: list[str] | None = None,
    artefact_id: str | None = None,
) -> DiffBundle:
    """Fit a diff into a budget without ever silently dropping a file."""
    ranked = rank(
        split_by_file(diff), acceptance_terms=acceptance_terms, failing_tests=failing_tests
    )
    included: list[FileDiff] = []
    elided: list[str] = []
    spent = 0
    for file in ranked:
        if spent + file.tokens <= max_tokens:
            included.append(file)
            spent += file.tokens
        else:
            elided.append(file.path)
    return DiffBundle(included=included, elided=elided, artefact_id=artefact_id if elided else None)


def _basename(path: str) -> str:
    return path.rsplit("/", 1)[-1]


def _test_file(test_id: str) -> str:
    """The file part of a runner's test id, whatever separator it used."""
    for separator in ("::", " > ", " \u203a ", ":"):  # vitest uses ›
        if separator in test_id:
            return test_id.split(separator, 1)[0].strip()
    return test_id.strip()
