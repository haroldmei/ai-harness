"""Recent-change context and ownership — "who last changed this, and why".

``git log`` and ``git blame`` answer questions an embedding cannot: what changed here recently,
what the commit said it was doing, and who owns the area. These are also the cheapest useful
signals in a review, because the reviewer's real question is usually *what did this change,
relative to what was already true*.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from ai_harness.context.retrieval.protocol import Chunk
from ai_harness.kernel.outcome import Outcome
from ai_harness.providers.git.protocol import GitClient


@dataclass
class GitHistory:
    """Recent commits touching a path, as citable chunks."""

    git: GitClient
    root: Path

    async def recent_changes(self, path: str, *, limit: int = 5) -> Outcome[list[Chunk]]:
        outcome = await self.git.run(
            "log", f"-{limit}", "--pretty=format:%h %an %ad %s", "--date=short", "--", path
        )
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        chunks = [
            Chunk(path=path, line=1, text=line, kind="history")
            for line in outcome.unwrap().output.splitlines()
            if line.strip()
        ]
        return Outcome.ok(chunks)

    async def owners(self, path: str, *, limit: int = 3) -> Outcome[list[str]]:
        """Who touches this most. ``CODEOWNERS`` wins when the repository declares one."""
        codeowners = self._codeowners_for(path)
        if codeowners:
            return Outcome.ok(codeowners)
        outcome = await self.git.run("log", "-50", "--pretty=format:%an", "--", path)
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        counts: dict[str, int] = {}
        for name in outcome.unwrap().output.splitlines():
            if name.strip():
                counts[name.strip()] = counts.get(name.strip(), 0) + 1
        ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
        return Outcome.ok([name for name, _ in ranked[:limit]])

    def _codeowners_for(self, path: str) -> list[str]:
        import fnmatch

        for candidate in ("CODEOWNERS", ".github/CODEOWNERS", "docs/CODEOWNERS"):
            file = self.root / candidate
            if not file.exists():
                continue
            for line in file.read_text(errors="replace").splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                pattern, *owners = stripped.split()
                if fnmatch.fnmatch(path, pattern.lstrip("/")) or path.startswith(
                    pattern.strip("/*")
                ):
                    return owners
        return []


def tests_for(path: str) -> list[str]:
    """Candidate test paths for a source file, from naming convention and layout.

    Convention beats cleverness here: ``app/svc.py`` → ``tests/test_svc.py``,
    ``src/Cart.tsx`` → ``src/Cart.test.tsx``. Wrong guesses cost a failed lookup; a missing
    guess costs a reviewer who never sees the test that covers the change.
    """
    name = path.rsplit("/", 1)[-1]
    stem, _, suffix = name.rpartition(".")
    if not stem:
        return []
    if suffix == "py":
        return [f"tests/test_{stem}.py", f"tests/{stem}_test.py", f"test_{stem}.py"]
    if suffix in {"ts", "tsx", "js", "jsx"}:
        directory = path.rsplit("/", 1)[0] if "/" in path else "."
        return [
            f"{directory}/{stem}.test.{suffix}",
            f"{directory}/{stem}.spec.{suffix}",
            f"{directory}/__tests__/{stem}.test.{suffix}",
        ]
    if suffix == "go":
        return [path.replace(".go", "_test.go")]
    return []
