"""The Tree-sitter symbol index (#77) — §17.2's index, actually parsed.

Phase 2 shipped a pattern-based index and said so: every bundle reported ``approximate = True``,
and the properties that make an index *safe to cite* were kept regardless (keyed on the commit
sha, never serving a stale entry, every definition carrying its own line). What was missing was
precision, and precision has two halves:

**Definitions the regex cannot see.** A decorated function, a nested class, and a signature that
spans lines are all invisible to a line-anchored pattern — the first because the ``def`` is one
node below a decorator, the second because indentation is not structure, the third because the
pattern needs the ``(`` on the same line. Each has a test that fails against the pattern index.

**References at all.** "Who calls X" is not a question a regex can answer. It can find where the
string ``X`` appears, which is a different question with a different answer: an import, a
docstring, a variable named after it, and a comment all match. Here a reference is a *call node*
whose function resolves to the name, so a mention is excluded by construction.

Two design decisions worth stating:

* **The fallback is kept, and keeps saying ``approximate``.** A file in a language with no
  grammar is indexed by pattern, and both the file's entries and the bundle report it. A
  half-wired parser that silently misses a language is worse than an honest approximation.
* **Parse failures degrade rather than raise.** Tree-sitter returns a tree with ERROR nodes for
  a file that does not parse — mid-edit files do this constantly — and the definitions it *did*
  find are still useful. What is not useful is an indexer that dies on one bad file.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.context.retrieval.ripgrep import SKIP_DIRS
from ai_harness.context.retrieval.symbols import Definition, Reference, SymbolIndex

LANGUAGE_BY_SUFFIX: dict[str, str] = {
    ".py": "python",
    ".pyi": "python",
    ".ts": "typescript",
    ".tsx": "tsx",
    ".js": "javascript",
    ".jsx": "javascript",
    ".mjs": "javascript",
    ".go": "go",
    ".rs": "rust",
}
"""The languages the harness actually meets. Anything else falls back to the pattern index."""

DEFINITION_NODES: dict[str, dict[str, str]] = {
    "python": {"function_definition": "function", "class_definition": "class"},
    "typescript": {
        "function_declaration": "function",
        "class_declaration": "class",
        "method_definition": "function",
        "interface_declaration": "type",
        "type_alias_declaration": "type",
        "enum_declaration": "type",
    },
    "go": {
        "function_declaration": "function",
        "method_declaration": "function",
        "type_declaration": "type",
    },
    "rust": {
        "function_item": "function",
        "struct_item": "type",
        "enum_item": "type",
        "trait_item": "type",
    },
}
DEFINITION_NODES["tsx"] = DEFINITION_NODES["typescript"]
DEFINITION_NODES["javascript"] = DEFINITION_NODES["typescript"]

CALL_NODES: dict[str, tuple[str, ...]] = {
    "python": ("call",),
    "typescript": ("call_expression", "new_expression"),
    "tsx": ("call_expression", "new_expression"),
    "javascript": ("call_expression", "new_expression"),
    "go": ("call_expression",),
    "rust": ("call_expression", "macro_invocation"),
}


def language_for(path: Path) -> str | None:
    return LANGUAGE_BY_SUFFIX.get(path.suffix)


@dataclass
class TreeSitterIndex:
    """A parsed definition and call index, with the pattern index as the fallback.

    Implements the same surface as :class:`~ai_harness.context.retrieval.symbols.SymbolIndex`, so
    the conformance suite runs against both and a caller cannot tell which it holds — except by
    asking ``approximate``, which is the one thing it *should* be able to tell.
    """

    root: Path
    commit_sha: str
    fallback: SymbolIndex | None = None
    approximate: bool = False
    """False where a grammar genuinely parsed the file. Set back to True if anything fell back."""
    _definitions: dict[str, list[Definition]] = field(default_factory=dict)
    _references: dict[str, list[Reference]] = field(default_factory=dict)
    _built_for: str | None = None
    _parsed_files: int = 0
    _fallback_files: int = 0

    # ── building ─────────────────────────────────────────────────────────────────

    def build(self) -> TreeSitterIndex:
        definitions: dict[str, list[Definition]] = {}
        references: dict[str, list[Reference]] = {}
        parsed = 0
        fell_back = 0

        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or any(part in SKIP_DIRS for part in path.parts):
                continue
            language = language_for(path)
            if language is None:
                fell_back += 1
                continue
            parser = _parser(language)
            if parser is None:
                fell_back += 1
                continue
            try:
                source = path.read_bytes()
            except OSError:
                continue

            relative = str(path.relative_to(self.root))
            tree = parser.parse(source)
            self._collect(tree.root_node, language, relative, source, definitions, references)
            parsed += 1

        self._definitions = definitions
        self._references = references
        self._built_for = self.commit_sha
        self._parsed_files = parsed
        self._fallback_files = fell_back

        if self.fallback is not None:
            self.fallback.commit_sha = self.commit_sha
            self.fallback.build()
        # Honest reporting: the moment one file was not parsed, the index as a whole is an
        # approximation, whatever the parsed majority managed.
        self.approximate = fell_back > 0 and self.fallback is not None
        return self

    def _collect(
        self,
        node: Any,
        language: str,
        path: str,
        source: bytes,
        definitions: dict[str, list[Definition]],
        references: dict[str, list[Reference]],
        enclosing: str = "",
    ) -> None:
        kinds = DEFINITION_NODES.get(language, {})
        calls = CALL_NODES.get(language, ())
        scope = enclosing

        if node.type in kinds:
            name = _name_of(node, source)
            if name:
                # The decorator sits ABOVE the definition in the tree, so the line reported is
                # the `def`/`class` line — which is what a citation should point at, and what a
                # line-anchored regex loses the moment a decorator appears.
                definitions.setdefault(name, []).append(
                    Definition(
                        name=name,
                        path=path,
                        line=node.start_point[0] + 1,
                        kind=kinds[node.type],
                    )
                )
                scope = name

        if node.type in calls:
            target = _callee(node, source)
            if target:
                references.setdefault(target, []).append(
                    Reference(
                        name=target,
                        path=path,
                        line=node.start_point[0] + 1,
                        caller=enclosing,
                    )
                )

        for child in node.children:
            self._collect(child, language, path, source, definitions, references, scope)

    # ── the same surface as the pattern index ────────────────────────────────────

    def definitions_of(self, name: str) -> list[Definition]:
        """Where ``name`` is defined — or nothing, if the index is stale."""
        if self.is_stale():
            return []
        found = list(self._definitions.get(name, []))
        if self.fallback is not None:
            known = {(d.path, d.line) for d in found}
            found += [
                d for d in self.fallback.definitions_of(name) if (d.path, d.line) not in known
            ]
        return found

    def references_of(self, name: str) -> list[Reference]:
        """Who **calls** ``name`` — from the call graph, not from a text match.

        The fallback is deliberately not consulted here. The pattern index cannot answer this
        question, and an answer assembled half from calls and half from string matches would be
        worse than either: a reviewer could not tell which half a citation came from.
        """
        if self.is_stale():
            return []
        return list(self._references.get(name, []))

    def is_stale(self) -> bool:
        return self._built_for != self.commit_sha

    def invalidate(self, commit_sha: str) -> TreeSitterIndex:
        self.commit_sha = commit_sha
        return self

    @property
    def size(self) -> int:
        return sum(len(entries) for entries in self._definitions.values())

    @property
    def stats(self) -> dict[str, int]:
        """What was parsed and what was not — the number that justifies ``approximate``."""
        return {
            "parsed_files": self._parsed_files,
            "fallback_files": self._fallback_files,
            "definitions": self.size,
            "references": sum(len(entries) for entries in self._references.values()),
        }


# ── grammar plumbing ─────────────────────────────────────────────────────────────


_PARSERS: dict[str, Any] = {}


def _parser(language: str) -> Any:
    """Lazily loaded, and a missing grammar is a supported state rather than an import error."""
    if language in _PARSERS:
        return _PARSERS[language]
    try:  # pragma: no cover — the miss path needs the extra to be absent
        from tree_sitter_language_pack import get_parser

        parser = get_parser(language)
    except Exception:
        parser = None
    _PARSERS[language] = parser
    return parser


def available() -> bool:
    """Whether any grammar loaded. Callers choose the backend on this, not on a try/except."""
    return _parser("python") is not None


def _text(node: Any, source: bytes) -> str:
    return source[node.start_byte : node.end_byte].decode(errors="replace")


def _name_of(node: Any, source: bytes) -> str:
    named = node.child_by_field_name("name")
    if named is not None:
        return _text(named, source)
    # Go's `type_declaration` wraps its spec; the name is one level down.
    for child in node.children:
        spec = child.child_by_field_name("name") if hasattr(child, "child_by_field_name") else None
        if spec is not None:
            return _text(spec, source)
    return ""


def _callee(node: Any, source: bytes) -> str:
    """The name being called, with the receiver stripped.

    ``obj.send()`` resolves to ``send``: the harness asks "who calls send_with_retry", and an
    answer that only matched unqualified calls would miss every method call. The trade is that
    two classes with a same-named method are conflated, which is a *smaller* error than missing
    the call entirely — and one the citation's file:line lets a reader resolve.
    """
    function = node.child_by_field_name("function") or node.child_by_field_name("constructor")
    if function is None:
        # Rust's macro_invocation carries `macro` instead of `function`.
        function = node.child_by_field_name("macro")
    if function is None:
        return ""
    text = _text(function, source)
    if "." in text:
        text = text.rsplit(".", 1)[-1]
    if "::" in text:
        text = text.rsplit("::", 1)[-1]
    return text.strip()
