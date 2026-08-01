"""The default retrieval stack, composed.

§17.2's table, in priority order: exact search, symbol definitions, recent change context. Each
source contributes citable chunks, the bundle is capped, and **what did not fit is counted** —
a retrieval bundle that silently truncates is the same defect as a diff that silently truncates.

No embeddings. The optional ``pgvector`` adapter (#68) plugs in at the same protocol for the one
query that genuinely is semantic: *what fixed this fingerprint last time*.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.context.retrieval.protocol import (
    Chunk,
    RetrievalBundle,
    RetrievalQuery,
)
from ai_harness.context.retrieval.ripgrep import RipgrepSearch
from ai_harness.context.retrieval.symbols import SymbolIndex
from ai_harness.context.trust import Provenance, Untrusted
from ai_harness.kernel.outcome import Outcome

CHARS_PER_TOKEN = 4


@dataclass
class RepoRetrieval:
    """ripgrep + a symbol index, over one worktree at one commit."""

    root: Path
    index: SymbolIndex | None = None
    search: RipgrepSearch | None = None
    sources: list[str] = field(default_factory=lambda: ["ripgrep", "symbols"])

    def __post_init__(self) -> None:
        if self.search is None:
            self.search = RipgrepSearch(root=self.root)

    async def bundle(self, query: RetrievalQuery) -> Outcome[RetrievalBundle]:
        chunks: list[Chunk] = []

        # 1. Definitions first: "where is X defined" is the question with an exact answer.
        if self.index is not None and not self.index.is_stale():
            for symbol in query.symbols:
                for definition in self.index.definitions_of(symbol)[:3]:
                    chunks.append(definition.as_chunk())

        # 2. Then exact search, seeded from symbols and explicit keywords.
        assert self.search is not None
        for term in [*query.symbols, *query.keywords]:
            found = await self.search.search(term, max_results=query.max_chunks)
            if found.is_ok:
                chunks.extend(found.unwrap())
            if len(chunks) >= query.max_chunks * 2:
                break

        deduped: list[Chunk] = []
        seen: set[tuple[str, int]] = set()
        for chunk in chunks:
            key = (chunk.path, chunk.line)
            if key not in seen:
                seen.add(key)
                deduped.append(chunk)

        kept: list[Chunk] = []
        spent = 0
        truncated = 0
        for chunk in deduped:
            cost = max(len(chunk.text) // CHARS_PER_TOKEN, 1)
            if len(kept) < query.max_chunks and spent + cost <= query.max_tokens:
                kept.append(chunk)
                spent += cost
            else:
                truncated += 1

        return Outcome.ok(
            RetrievalBundle(chunks=kept, truncated=truncated, sources=list(self.sources))
        )


def as_untrusted(bundle: RetrievalBundle) -> list[Untrusted]:
    """Retrieved repository content is **untrusted** — it is file content, after all.

    Easy to forget, and forgetting it would reopen the injection path from the other side: a
    hostile comment in a source file is as attacker-controllable as a hostile issue body.
    """
    return [
        Untrusted(
            text=f"{chunk.citation}: {chunk.text}",
            provenance=Provenance.RETRIEVAL,
            source=chunk.citation,
        )
        for chunk in bundle.chunks
    ]
