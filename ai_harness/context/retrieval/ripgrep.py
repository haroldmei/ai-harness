"""Exact and regex search — "where does this string appear".

``ripgrep`` when the host has it, a bounded Python walk when it does not. The fallback is not a
lesser answer: both are *exact*, which is the property that matters. What ``rg`` buys is speed
on a large tree, so the fallback carries hard limits and reports when it hit them rather than
pretending it searched everything.
"""

from __future__ import annotations

import asyncio
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.context.retrieval.protocol import Chunk
from ai_harness.kernel.outcome import ErrorCategory, Outcome

SKIP_DIRS = {
    ".git",
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    "dist",
    "build",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "target",
    "vendor",
}
TEXT_SUFFIXES = {
    ".py",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
    ".go",
    ".rs",
    ".rb",
    ".java",
    ".kt",
    ".c",
    ".h",
    ".cpp",
    ".sh",
    ".yaml",
    ".yml",
    ".toml",
    ".json",
    ".md",
    ".sql",
    ".tf",
}


@dataclass
class RipgrepSearch:
    """Exact search over a worktree."""

    root: Path
    max_files_scanned: int = 20_000
    timeout_s: float = 30.0
    binary: str | None = field(default_factory=lambda: shutil.which("rg"))

    async def search(self, pattern: str, *, max_results: int = 40) -> Outcome[list[Chunk]]:
        if self.binary:
            return await self._ripgrep(pattern, max_results=max_results)
        return self._python(pattern, max_results=max_results)

    async def _ripgrep(self, pattern: str, *, max_results: int) -> Outcome[list[Chunk]]:
        argv = [
            self.binary or "rg",
            "--line-number",
            "--no-heading",
            "--color",
            "never",
            "--max-count",
            str(max_results),
            "-e",
            pattern,
            ".",
        ]
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                cwd=str(self.root),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            out, _ = await asyncio.wait_for(process.communicate(), timeout=self.timeout_s)
        except (FileNotFoundError, TimeoutError):
            return self._python(pattern, max_results=max_results)

        chunks: list[Chunk] = []
        for line in out.decode("utf-8", "replace").splitlines()[:max_results]:
            path, _, rest = line.partition(":")
            number, _, text = rest.partition(":")
            if not number.isdigit():
                continue
            chunks.append(Chunk(path=path.lstrip("./"), line=int(number), text=text.strip()))
        return Outcome.ok(chunks)

    def _python(self, pattern: str, *, max_results: int) -> Outcome[list[Chunk]]:
        try:
            expression = re.compile(pattern)
        except re.error as exc:
            return Outcome.fail(ErrorCategory.TOOL_FAILURE, f"bad search pattern: {exc}")

        chunks: list[Chunk] = []
        scanned = 0
        for path in sorted(self.root.rglob("*")):
            if len(chunks) >= max_results or scanned >= self.max_files_scanned:
                break
            if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
                continue
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            scanned += 1
            try:
                content = path.read_text(errors="replace")
            except OSError:
                continue
            for number, line in enumerate(content.splitlines(), start=1):
                if expression.search(line):
                    chunks.append(
                        Chunk(
                            path=str(path.relative_to(self.root)),
                            line=number,
                            text=line.strip(),
                        )
                    )
                    if len(chunks) >= max_results:
                        break
        return Outcome.ok(chunks)
