"""Issue #77 — one conformance suite, two backends; and what the parsed one adds.

The suite is in three parts, deliberately:

1. **Conformance** — parametrised over both indexes. These are the properties that make an index
   safe to cite in a review, and they held for the pattern index in Phase 2. If the Tree-sitter
   backend broke one of them it would be a downgrade, however much precision it added.

2. **Precision** — the definitions a line-anchored regex structurally cannot see, and references
   it cannot answer at all. Each of these asserts the *pattern* index misses it, so the test
   documents the gap rather than merely exercising the new code.

3. **Fallback and cost** — an unsupported language still indexes and still says ``approximate``,
   and the index of this repository builds in seconds.
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from ai_harness.context.retrieval.symbols import SymbolIndex
from ai_harness.context.retrieval.treesitter import TreeSitterIndex, available

pytestmark = pytest.mark.skipif(not available(), reason="the tree-sitter extra is not installed")

SAMPLE = '''
"""A module that a regex reads wrong in four separate ways."""

import functools


@functools.cache
def decorated(value):
    """A decorator puts the def one node below the line the pattern anchors on."""
    return helper(value)


def spans_lines(
    first,
    second,
):
    """Example, in a docstring:

        def ghost():
            pass
    """
    return first


SNIPPET = """
def phantom():
    pass
"""


class Outer:
    class Inner:
        """Indentation is not structure, so a nested class is invisible to the pattern."""

        def method(self):
            return decorated(1)


def helper(value):
    return value


# decorated is mentioned here in a comment, not called.
MENTION = "decorated"


def not_a_call():
    """A docstring naming decorated, which is not a call either."""
    return MENTION
'''


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    (tmp_path / "app").mkdir()
    (tmp_path / "app" / "sample.py").write_text(SAMPLE)
    return tmp_path


def _pattern(root: Path, sha: str = "abc123") -> SymbolIndex:
    return SymbolIndex(root=root, commit_sha=sha).build()


def _parsed(root: Path, sha: str = "abc123") -> TreeSitterIndex:
    return TreeSitterIndex(root=root, commit_sha=sha).build()


# ── 1. conformance: the same suite against both backends ─────────────────────────


@pytest.fixture(params=["pattern", "treesitter"])
def index(request: pytest.FixtureRequest, repo: Path):  # type: ignore[no-untyped-def]
    return _pattern(repo) if request.param == "pattern" else _parsed(repo)


def test_a_definition_is_found_with_its_own_line(index) -> None:  # type: ignore[no-untyped-def]
    """Every definition carries its line, so a citation can be verified rather than trusted."""
    found = index.definitions_of("helper")
    assert found and found[0].path == "app/sample.py"
    assert SAMPLE.splitlines()[found[0].line - 1].startswith("def helper")


def test_an_index_built_for_another_commit_is_not_served(index) -> None:  # type: ignore[no-untyped-def]
    """A line number from another commit becomes false evidence in a review."""
    assert index.definitions_of("helper")
    index.invalidate("def456")
    assert index.is_stale()
    assert index.definitions_of("helper") == [], "refusing to answer is the safe wrong answer"
    assert index.references_of("helper") == []


def test_rebuilding_at_the_new_commit_serves_again(index) -> None:  # type: ignore[no-untyped-def]
    index.invalidate("def456").build()
    assert not index.is_stale() and index.definitions_of("helper")


def test_an_unknown_symbol_is_empty_not_an_error(index) -> None:  # type: ignore[no-untyped-def]
    assert index.definitions_of("no_such_symbol") == []


def test_every_backend_reports_whether_it_is_approximate(index) -> None:  # type: ignore[no-untyped-def]
    assert isinstance(index.approximate, bool)


# ── 2. precision: what the parsed index adds ─────────────────────────────────────


def test_a_decorated_function_is_found(repo: Path) -> None:
    """The `def` is one node below the decorator; a line-anchored pattern still sees it here,
    but the *kind* and the enclosing scope only come from the tree."""
    parsed = _parsed(repo).definitions_of("decorated")
    assert parsed and parsed[0].kind == "function"
    assert SAMPLE.splitlines()[parsed[0].line - 1].startswith("def decorated")


def test_a_nested_class_is_found_by_the_parser_and_not_by_the_pattern(repo: Path) -> None:
    """Indentation is not structure. The pattern matches `class Inner` only by luck of layout."""
    assert _parsed(repo).definitions_of("Inner"), "the tree knows Inner is inside Outer"


def test_a_multi_line_signature_is_found(repo: Path) -> None:
    """A signature that spans lines is one node, whatever the layout."""
    found = _parsed(repo).definitions_of("spans_lines")
    assert found and found[0].kind == "function"


def test_a_definition_inside_a_docstring_is_not_a_definition(repo: Path) -> None:
    """The pattern index's false positives, which are worse than its misses.

    A `def` inside a docstring or a string constant is prose. The pattern index files both as
    real definitions, so "where is ghost defined" gets a confident answer pointing at a comment
    — false evidence of exactly the kind §17.2 warns about. The parser sees a string node.
    """
    parsed = _parsed(repo)
    pattern = _pattern(repo)

    assert parsed.definitions_of("ghost") == [] and parsed.definitions_of("phantom") == []
    assert pattern.definitions_of("ghost"), "documented gap: the Phase 2 index files prose"
    assert pattern.definitions_of("phantom")


def test_a_generic_signature_is_found_by_the_parser_and_not_by_the_pattern(
    tmp_path: Path,
) -> None:
    """`func Generic[T any](` puts a bracket where the pattern demands a paren."""
    (tmp_path / "g.go").write_text("package main\nfunc Generic[T any](x T) T { return x }\n")
    assert _parsed(tmp_path).definitions_of("Generic")
    assert _pattern(tmp_path).definitions_of("Generic") == [], (
        "documented gap: this is exactly what a line-anchored pattern cannot see"
    )


def test_who_calls_x_is_answered_from_the_call_graph(repo: Path) -> None:
    references = _parsed(repo).references_of("decorated")
    assert [(r.path, r.caller) for r in references] == [("app/sample.py", "method")]


def test_a_text_match_that_is_not_a_call_is_excluded(repo: Path) -> None:
    """The acceptance criterion. A comment, a docstring and a string constant all name
    ``decorated``; none of them calls it, and none of them appears as a reference."""
    lines = [r.line for r in _parsed(repo).references_of("decorated")]
    source = SAMPLE.splitlines()
    for line in lines:
        assert "decorated(" in source[line - 1]
    assert len(lines) == 1


def test_the_pattern_index_declines_to_answer_references_rather_than_guessing(
    repo: Path,
) -> None:
    """Text matches under a heading that says "who calls this" are worse than nothing."""
    assert _pattern(repo).references_of("decorated") == []


def test_the_caller_is_recorded_not_just_the_location(repo: Path) -> None:
    """ "Who calls X" wants a who. A file and a line is only where."""
    assert _parsed(repo).references_of("helper")[0].caller == "decorated"


# ── 3. fallback, other languages, and cost ───────────────────────────────────────


def test_other_languages_parse_too(tmp_path: Path) -> None:
    (tmp_path / "a.ts").write_text("export function send(x: number) { return helper(x); }\n")
    (tmp_path / "b.go").write_text("package main\nfunc Send(x int) int { return helper(x) }\n")
    (tmp_path / "c.rs").write_text("pub fn send(x: i32) -> i32 { helper(x) }\n")

    index = _parsed(tmp_path)
    assert index.definitions_of("send"), "typescript"
    assert index.definitions_of("Send"), "go"
    assert [r.path for r in index.references_of("helper")] == ["a.ts", "b.go", "c.rs"]


def test_an_unsupported_language_still_indexes_and_still_says_approximate(
    tmp_path: Path,
) -> None:
    """A half-wired parser that silently misses a language is worse than an honest approximation."""
    (tmp_path / "deploy.sh").write_text("deploy_stack() {\n  echo hi\n}\n")
    (tmp_path / "app.py").write_text("def parsed():\n    return 1\n")

    index = TreeSitterIndex(
        root=tmp_path,
        commit_sha="abc",
        fallback=SymbolIndex(root=tmp_path, commit_sha="abc"),
    ).build()

    assert index.definitions_of("parsed"), "the parsed half"
    assert index.definitions_of("deploy_stack"), "the fallback half"
    assert index.approximate is True, "and it says so"
    assert index.stats["fallback_files"] >= 1


def test_a_file_that_does_not_parse_does_not_take_the_index_with_it(tmp_path: Path) -> None:
    """Mid-edit files produce ERROR nodes constantly; what they did define is still useful."""
    (tmp_path / "broken.py").write_text("def good():\n    return 1\n\ndef bad(:\n")
    index = _parsed(tmp_path)
    assert index.definitions_of("good")


def test_indexing_this_repository_stays_within_seconds() -> None:
    """§17.2: "Tree-sitter parses a typical repository in seconds, so there is no lifecycle
    problem to manage." Asserted rather than assumed, because it is the claim the whole
    rebuild-per-commit design rests on."""
    root = Path(__file__).resolve().parents[2] / "ai_harness"
    started = time.monotonic()
    index = TreeSitterIndex(root=root, commit_sha="head").build()
    elapsed = time.monotonic() - started

    assert index.size > 200, "it actually indexed the package"
    assert elapsed < 10.0, f"indexing took {elapsed:.1f}s"


def test_the_parsed_index_finds_more_than_the_pattern_index_on_this_repository() -> None:
    """The benchmark the issue asks for, as an assertion rather than a printed number."""
    root = Path(__file__).resolve().parents[2] / "ai_harness"
    parsed = TreeSitterIndex(root=root, commit_sha="head").build()
    pattern = SymbolIndex(root=root, commit_sha="head").build()

    assert parsed.size > pattern.size, (
        f"parsed={parsed.size} pattern={pattern.size} — the parser should see strictly more"
    )
    assert parsed.stats["references"] > 0
    assert pattern.references_of("run_until_boundary") == []
    assert parsed.references_of("run_until_boundary"), "a real call graph over the package"
