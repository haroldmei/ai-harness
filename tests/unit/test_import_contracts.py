"""Issue #2 — the two forbidden edges, proven by making them and watching the build fail.

A contract nobody has seen fail is a contract nobody knows works. Each test copies the package
into a temporary tree, introduces exactly one forbidden import, and asserts ``lint-imports``
rejects it — then asserts the untouched tree passes.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
LINTER = ROOT / ".venv" / "bin" / "lint-imports"

pytestmark = pytest.mark.skipif(not LINTER.exists(), reason="lint-imports is not installed")


def _sandbox(tmp_path: Path) -> Path:
    shutil.copytree(ROOT / "ai_harness", tmp_path / "ai_harness")
    shutil.copy(ROOT / ".importlinter", tmp_path / ".importlinter")
    return tmp_path


def _lint(cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(LINTER)],
        cwd=cwd,
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(cwd), "HOME": str(cwd)},
    )


def test_the_contracts_hold_on_the_real_tree(tmp_path: Path) -> None:
    result = _lint(_sandbox(tmp_path))
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_sideways_subgraph_import_breaks_the_build(tmp_path: Path) -> None:
    """The rule that would have prevented the seven duplications of §3.14 before they drifted."""
    sandbox = _sandbox(tmp_path)
    target = sandbox / "ai_harness" / "subgraphs" / "review.py"
    target.write_text("import ai_harness.subgraphs.implement  # deliberately forbidden\n")
    result = _lint(sandbox)
    assert result.returncode != 0
    assert "Peer subgraphs are independent" in result.stdout


def test_the_router_reaching_an_llm_breaks_the_build(tmp_path: Path) -> None:
    """The mechanical guarantee that no LLM call decides a workflow transition (§7.1)."""
    sandbox = _sandbox(tmp_path)
    target = sandbox / "ai_harness" / "orchestration" / "router.py"
    target.write_text("import ai_harness.llm.client  # deliberately forbidden\n")
    result = _lint(sandbox)
    assert result.returncode != 0
    assert "The router cannot reach an LLM" in result.stdout


def test_the_kernel_importing_upward_breaks_the_build(tmp_path: Path) -> None:
    sandbox = _sandbox(tmp_path)
    target = sandbox / "ai_harness" / "kernel" / "ids.py"
    target.write_text(target.read_text() + "\nimport ai_harness.schemas.run  # forbidden\n")
    result = _lint(sandbox)
    assert result.returncode != 0
    assert "kernel imports nothing" in result.stdout


def test_a_subgraph_calling_call_structured_directly_breaks_the_build(tmp_path: Path) -> None:
    """agents/base.py is the only permitted caller — the prompt/schema boundary is one place."""
    sandbox = _sandbox(tmp_path)
    target = sandbox / "ai_harness" / "subgraphs" / "validate.py"
    target.write_text("import ai_harness.llm.structured  # forbidden\n")
    result = _lint(sandbox)
    assert result.returncode != 0
    assert "call_structured has exactly one caller" in result.stdout


def test_python_version_is_what_the_package_declares() -> None:
    assert sys.version_info >= (3, 12)
