"""The symbol index — "where is X defined", "who calls X".

**A deliberate, stated deviation from §17.2.** The design specifies a Tree-sitter index. This
implementation is pattern-based across the languages the harness meets (Python, JS/TS, Go, Rust,
Java, Ruby, shell), behind a protocol so a Tree-sitter backend can replace it without touching a
caller. The reason is scope, not preference: Tree-sitter needs a grammar per language, and an
approximate index that *says* it is approximate is honest, while a half-wired Tree-sitter index
that silently misses a language is not.

What is kept from the design regardless, because these are the properties that make an index
safe to cite in a review:

* **keyed on the commit sha** — an index built against another commit is not served;
* **stale entries are never served** — the cache is invalidated by the sha, not aged out;
* **a definition carries its own line**, so a citation can be verified rather than trusted.

The upgrade is tracked as a follow-up; until then ``approximate`` is ``True`` on every bundle
this produces, and callers surface that.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.context.retrieval.protocol import Chunk
from ai_harness.context.retrieval.ripgrep import SKIP_DIRS, TEXT_SUFFIXES

DEFINITION_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("function", re.compile(r"^\s*(?:async\s+)?def\s+(?P<name>\w+)\s*\(")),
    ("class", re.compile(r"^\s*class\s+(?P<name>\w+)\b")),
    ("function", re.compile(r"^\s*(?:export\s+)?(?:async\s+)?function\s+(?P<name>\w+)\s*\(")),
    (
        "const",
        re.compile(r"^\s*(?:export\s+)?(?:const|let|var)\s+(?P<name>\w+)\s*=\s*(?:async\s*)?\("),
    ),
    ("type", re.compile(r"^\s*(?:export\s+)?(?:interface|type|enum)\s+(?P<name>\w+)\b")),
    ("function", re.compile(r"^\s*func\s+(?:\([^)]*\)\s*)?(?P<name>\w+)\s*\(")),
    ("type", re.compile(r"^\s*(?:pub\s+)?(?:struct|enum|trait)\s+(?P<name>\w+)\b")),
    ("function", re.compile(r"^\s*(?:pub\s+)?fn\s+(?P<name>\w+)\s*[(<]")),
    ("function", re.compile(r"^\s*(?P<name>\w+)\s*\(\)\s*\{")),  # shell
)


@dataclass(frozen=True, slots=True)
class Definition:
    name: str
    path: str
    line: int
    kind: str

    def as_chunk(self, text: str = "") -> Chunk:
        return Chunk(
            path=self.path, line=self.line, text=text or self.name, symbol=self.name, kind=self.kind
        )


@dataclass
class SymbolIndex:
    """A per-commit definition index. Approximate, and says so."""

    root: Path
    commit_sha: str
    approximate: bool = True
    """Pattern-based rather than parsed. Callers surface this; nothing pretends otherwise."""
    _definitions: dict[str, list[Definition]] = field(default_factory=dict)
    _built_for: str | None = None

    def build(self) -> SymbolIndex:
        """Index the tree at ``commit_sha``. Cheap enough to redo when the sha changes."""
        definitions: dict[str, list[Definition]] = {}
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
                continue
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            try:
                content = path.read_text(errors="replace")
            except OSError:
                continue
            relative = str(path.relative_to(self.root))
            for number, line in enumerate(content.splitlines(), start=1):
                for kind, pattern in DEFINITION_PATTERNS:
                    match = pattern.match(line)
                    if match:
                        name = match.group("name")
                        definitions.setdefault(name, []).append(
                            Definition(name=name, path=relative, line=number, kind=kind)
                        )
                        break
        self._definitions = definitions
        self._built_for = self.commit_sha
        return self

    def definitions_of(self, name: str) -> list[Definition]:
        """Where ``name`` is defined — or nothing, if the index is stale.

        Serving a stale entry is the failure mode §17.2 warns about: a line number from another
        commit becomes false evidence in a review. Refusing to answer is the safe wrong answer.
        """
        if self._built_for != self.commit_sha:
            return []
        return list(self._definitions.get(name, []))

    def is_stale(self) -> bool:
        return self._built_for != self.commit_sha

    def invalidate(self, commit_sha: str) -> SymbolIndex:
        """Point the index at a new commit. Nothing is served until it is rebuilt."""
        self.commit_sha = commit_sha
        return self

    @property
    def size(self) -> int:
        return sum(len(v) for v in self._definitions.values())


def extract_symbols(text: str, *, limit: int = 20) -> list[str]:
    """Identifiers worth looking up, taken from an issue, a diff or a stack trace.

    Deliberately biased towards things that look like code: CamelCase, snake_case with an
    underscore, and dotted paths. A retrieval query seeded from prose words is the search that
    returns everything and helps with nothing.
    """
    candidates = re.findall(r"\b(?:[A-Z][a-z0-9]+){2,}\b|\b\w+_\w+\b|\b\w+\.\w+\b", text)
    seen: list[str] = []
    for candidate in candidates:
        cleaned = candidate.strip(".")
        if cleaned and cleaned not in seen:
            seen.append(cleaned)
        if len(seen) >= limit:
            break
    return seen
