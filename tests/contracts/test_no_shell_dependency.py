"""The package may meet a shell spine; it may not depend on one (#102, S4 of Phase 8).

Q2's coupling rule is enforced by a test — *"a test fails if any host-project string reappears in
the package"* — and that test is why the package stayed clean while the repository did not. The
same mechanism holds the shell out once the orchestrator is gone.

The distinction the contract has to draw is between **meeting** and **depending**:

* the ladder naming `scripts/quality-gates.sh` beside `make check` and `tox` is the harness
  meeting a target repository on its own terms. Removing it would make the harness demand
  `.harness/gates.yaml` from every repository it touches, which is inventing rather than
  discovering — the exact inversion of §19.1;
* a module reaching for a script *in this repository* is the coupling W12 named.

Mechanically the two look alike, so the exceptions are **data with reasons attached** rather than
ignore comments. A new `.sh` literal fails until somebody writes down which of the two it is,
which is the whole point: the question gets asked once, by a human, at the moment it is cheap.

Docstrings and comments are exempt by construction — this walks the AST, so `agent-pr-merger.sh:112`
cited in prose as the reason a guard exists is invisible here. Deleting the script must not delete
the reason.
"""

from __future__ import annotations

import ast
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[2] / "ai_harness"

ALLOWED: dict[str, dict[str, str]] = {
    # The ladder itself (§19.2 rung 2). This is the entry the phase exists to protect.
    "quality/discovery.py": {
        "scripts/quality-gates.sh": "the entry-point table: a pattern for ANY repository",
        "quality-gates.sh": "the same marker, matched to decide whether to read its registry",
        "no gate entry point (quality-gates.sh, make check, just ci, tox, nox)": (
            "the note explaining which rungs did not match"
        ),
    },
    # Meeting a target repository's spine, on that repository's terms.
    "quality/adapters/shell.py": {
        "add .harness/gates.yaml, or a scripts/quality-gates.sh / make check target": (
            "remedy text telling an operator how to give a repository discoverable gates"
        ),
    },
    "quality/adopt.py": {
        ".sh": "constructing `scripts/<gate>.sh` to look for a target repo's own hook",
        ".sh` hook; the gate body is bash inside the spine and has no single command to declare": (
            "the reason an unexpressible gate is reported rather than invented"
        ),
    },
    "cli/main.py": {
        "scripts/quality-gates.sh": (
            "the default location of the spine `gates adopt` and `gates compare` read — the "
            "target repository's, never this one's"
        ),
    },
    # Indexing somebody else's repository, where shell files are just source.
    "context/retrieval/ripgrep.py": {
        ".sh": "a file extension in the retrieval index — shell is source like any other",
    },
}

WHY = """
A `.sh` string appeared in package code that is not in the allow-list.

Two things look alike here and only one is allowed:

  * the harness MEETING a target repository's shell spine — the discovery ladder, the shell
    adapter, adoption. That is §19.1 working as designed, and it stays;
  * the harness DEPENDING on a script in this repository. That is the coupling Q2 forbids and
    Phase 8 removes.

If this is the first, add it to ALLOWED with the reason. If it is the second, it is the thing
this contract exists to stop.
""".strip()


def _code_strings(path: Path) -> list[tuple[int, str]]:
    """Every string literal that is *code* — docstrings and comments excluded.

    Comments never reach the AST. Docstrings do, so bare-expression strings are skipped: an
    incident citation in prose is history, and history is why the guard it explains is there.
    """
    tree = ast.parse(path.read_text())
    prose: set[int] = set()
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            prose.add(id(node.value))

    found: list[tuple[int, str]] = []
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and ".sh" in node.value
            and id(node) not in prose
        ):
            found.append((node.lineno, node.value))
    return found


def test_no_package_file_reaches_for_a_shell_script_it_has_not_declared():
    violations: list[str] = []
    for path in sorted(PACKAGE.rglob("*.py")):
        relative = str(path.relative_to(PACKAGE))
        permitted = ALLOWED.get(relative, {})
        for line, literal in _code_strings(path):
            if literal not in permitted:
                violations.append(f"  ai_harness/{relative}:{line}: {literal!r}")

    assert not violations, WHY + "\n\n" + "\n".join(violations)


def test_every_exception_states_why_it_is_one():
    for module, entries in ALLOWED.items():
        for literal, reason in entries.items():
            assert reason.strip(), f"{module}: {literal!r} is allowed without a reason"


def test_the_allow_list_has_no_entries_for_files_that_are_gone():
    """An allow-list that outlives its subject is how an exception becomes permanent."""
    for module in ALLOWED:
        assert (PACKAGE / module).exists(), f"{module} no longer exists; drop its exception"


def test_a_citation_in_prose_is_not_a_dependency(tmp_path):
    """The mechanism that lets the incident history survive the deletion."""
    module = tmp_path / "cited.py"
    module.write_text(
        '"""Ports agent-pr-merger.sh in full."""\n\n\n'
        "def guard() -> None:\n"
        '    """Four safety properties, from agent-pr-merger.sh:112."""\n'
        "    # see scripts/agent-inbox.sh:15 for why this is single-pass\n"
        "    return None\n"
    )
    assert _code_strings(module) == []


def test_an_invocation_is_caught_even_when_it_looks_incidental(tmp_path):
    module = tmp_path / "sneaky.py"
    module.write_text(
        "import subprocess\n\n\n"
        "def run() -> None:\n"
        '    subprocess.run(["bash", "scripts/verify-loop.sh"], check=True)\n'
    )
    assert _code_strings(module) == [(5, "scripts/verify-loop.sh")]


def test_the_ladder_still_names_a_shell_spine():
    """The exception that must survive: removing it would make the harness demand a declaration
    from every repository it touches, which is inventing rather than discovering (§19.1)."""
    from ai_harness.quality.discovery import ENTRY_POINTS

    markers = [marker for marker, _ in ENTRY_POINTS]
    assert "scripts/quality-gates.sh" in markers
    assert any("make" in " ".join(command) for _, command in ENTRY_POINTS)
