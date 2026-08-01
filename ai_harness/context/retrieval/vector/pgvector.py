"""The optional pgvector adapter (§17.2) — off by default, and enabled only with a stated trigger.

§17.2 argues *against* a vector store for code retrieval, and that argument still stands: the
queries are structural, code churns, and an approximate answer to "where is this defined" is
worse than useless. This adapter exists for the three cases the same section names as genuine:

* more than ten repositories, or a monorepo where symbol indexing gets slow;
* retrieval over **prose** — ADRs, design docs, incident write-ups;
* the high-value one: **what fixed this fingerprint last time?** The shell ledger counts attempts
  and discards resolutions, so every recurrence of a known failure is re-solved from scratch.
  Embedding past ``TriageDecision`` + ``ImplementResult`` pairs makes prior fixes reusable, and
  that is a genuinely semantic query.

Four contracts, each of which is a way this can go wrong:

1. **Chunking is by symbol boundary, never a fixed-size window.** Splitting a function in half
   destroys the retrieval unit: neither half answers the question, and both look plausible.

2. **The tenant and repo filter is in the SQL**, not applied afterwards. A post-filter leaks on
   every path that forgets it, and there is always a path that forgets it. In the query it is
   structural, and the test attempts a cross-tenant read to prove it.

3. **Stale entries are down-weighted and never cited with a line number.** An entry whose
   ``commit_sha`` is no longer an ancestor of the base describes code that may have moved. It can
   still be *useful* — "we fixed this by rewriting the retry loop" survives a refactor — but its
   line number does not, so the citation is dropped rather than the entry.

4. **Top-k 50, reranked to 10** by symbol overlap. Similarity alone ranks prose that discusses a
   symbol above the code that defines it.

Postgres is already present, so this adds no service. It is still off unless configured, and the
policy that turns it on records why.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any

from sqlalchemy import Engine, text

from ai_harness.context.retrieval.protocol import Chunk, RetrievalBundle, RetrievalQuery
from ai_harness.kernel.outcome import ErrorCategory, Outcome

TOP_K = 50
RERANK_K = 10
STALE_PENALTY = 0.5
"""A stale entry is halved, not dropped: a past fix outlives the lines it was applied to."""


@dataclass(frozen=True, slots=True)
class VectorEntry:
    """One embedded chunk, with the provenance every citation needs."""

    text: str
    embedding: list[float]
    tenant: str
    repo: str
    commit_sha: str = ""
    path: str = ""
    symbol: str = ""
    language: str = ""
    kind: str = "code"
    line: int = 1


@dataclass
class PgVectorRetrieval:
    """Semantic retrieval over Postgres. Implements the same ``RetrievalService`` protocol."""

    engine: Engine
    tenant: str
    repo: str
    embedder: Any = None
    """``async (text) -> list[float]``. Absent ⇒ the adapter reports itself unavailable."""
    is_ancestor: Any = None
    """``(commit_sha) -> bool``. Absent ⇒ everything is treated as stale, which fails safe."""
    table: str = "context_chunks"
    enabled: bool = False
    """Off unless a policy turns it on. §17.2's default is *no vector store*."""

    async def bundle(self, query: RetrievalQuery) -> Outcome[RetrievalBundle]:
        if not self.enabled or self.embedder is None:
            return Outcome.ok(
                RetrievalBundle(sources=["pgvector:disabled"]),
            )

        text_query = " ".join([*query.symbols, *query.keywords, *query.failing_tests]).strip()
        if not text_query:
            # Similarity search needs something to be similar *to*. Prose alone is exactly what
            # §17.2 says not to seed from, so an empty structural query returns nothing rather
            # than inventing one.
            return Outcome.ok(RetrievalBundle(sources=["pgvector"]))

        embedded = await self.embedder(text_query)
        found = await self._search(embedded, limit=TOP_K)
        if found.is_err:
            return Outcome.of(found.error)  # type: ignore[arg-type]

        ranked = rerank(found.unwrap(), query, is_ancestor=self.is_ancestor)
        kept = ranked[: min(RERANK_K, query.max_chunks)]
        return Outcome.ok(
            RetrievalBundle(
                chunks=kept,
                truncated=max(len(ranked) - len(kept), 0),
                sources=["pgvector"],
            )
        )

    async def _search(self, embedding: list[float], *, limit: int) -> Outcome[list[VectorEntry]]:
        """The permission boundary lives in this WHERE clause, and nowhere else."""
        statement = text(
            f"""
            SELECT text, tenant, repo, commit_sha, path, symbol, language, kind, line,
                   embedding <=> CAST(:embedding AS vector) AS distance
              FROM {self.table}
             WHERE tenant = :tenant AND repo = :repo
             ORDER BY distance ASC
             LIMIT :limit
            """
        )

        def _run() -> list[VectorEntry]:
            with self.engine.connect() as connection:
                rows = connection.execute(
                    statement,
                    {
                        "embedding": _vector_literal(embedding),
                        "tenant": self.tenant,
                        "repo": self.repo,
                        "limit": limit,
                    },
                ).mappings()
                return [
                    VectorEntry(
                        text=row["text"],
                        embedding=[],
                        tenant=row["tenant"],
                        repo=row["repo"],
                        commit_sha=row["commit_sha"] or "",
                        path=row["path"] or "",
                        symbol=row["symbol"] or "",
                        language=row["language"] or "",
                        kind=row["kind"] or "code",
                        line=int(row["line"] or 1),
                    )
                    for row in rows
                ]

        try:
            return Outcome.ok(await asyncio.to_thread(_run))
        except Exception as exc:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"pgvector retrieval failed: {exc}",
                remedy="retrieval is optional; the repo-native stack answers without it",
            )


def chunk_by_symbol(
    source: str, *, path: str, symbols: list[tuple[str, int]]
) -> list[dict[str, Any]]:
    """Split at symbol boundaries, never at a fixed window.

    ``symbols`` is ``[(name, start_line)]`` in file order, as a symbol index produces. Each chunk
    runs to the start of the next symbol, so a function is never cut in half — a half-function
    answers no question while looking like it might.
    """
    lines = source.splitlines()
    if not symbols:
        return [{"symbol": "", "line": 1, "text": source, "path": path}] if source else []

    ordered = sorted(symbols, key=lambda item: item[1])
    chunks: list[dict[str, Any]] = []
    if ordered[0][1] > 1:
        # Everything above the first symbol is one chunk: imports and module docstrings are a
        # retrieval unit of their own, and attaching them to the first function misattributes it.
        chunks.append(
            {
                "symbol": "",
                "line": 1,
                "text": "\n".join(lines[: ordered[0][1] - 1]),
                "path": path,
            }
        )
    for index, (name, start) in enumerate(ordered):
        end = ordered[index + 1][1] - 1 if index + 1 < len(ordered) else len(lines)
        chunks.append(
            {
                "symbol": name,
                "line": start,
                "text": "\n".join(lines[start - 1 : end]),
                "path": path,
            }
        )
    return [chunk for chunk in chunks if chunk["text"].strip()]


def rerank(
    entries: list[VectorEntry], query: RetrievalQuery, *, is_ancestor: Any = None
) -> list[Chunk]:
    """Symbol overlap first, staleness second.

    Similarity alone puts the ADR that *mentions* ``send_with_retry`` above the module that
    defines it, which is the failure §17.2 predicts. Overlap with the query's symbols is a cheap,
    explainable rerank that fixes exactly that.
    """
    wanted = {symbol.lower() for symbol in query.symbols}
    scored: list[tuple[float, Chunk]] = []

    for rank, entry in enumerate(entries):
        base = 1.0 - (rank / max(len(entries), 1))
        if entry.symbol and entry.symbol.lower() in wanted:
            base += 1.0
        elif any(symbol in entry.text.lower() for symbol in wanted):
            base += 0.25

        stale = _is_stale(entry, is_ancestor)
        if stale:
            base *= STALE_PENALTY

        scored.append(
            (
                base,
                Chunk(
                    # A stale entry keeps its text and loses its location: the fix it describes
                    # may still be right, but the line it was applied at may not exist.
                    path=entry.path if not stale else "",
                    line=entry.line if not stale else 0,
                    text=entry.text,
                    symbol=entry.symbol or None,
                    kind=f"vector:{entry.kind}" + (":stale" if stale else ""),
                    score=base,
                ),
            )
        )

    scored.sort(key=lambda item: item[0], reverse=True)
    return [chunk for _, chunk in scored]


def _is_stale(entry: VectorEntry, is_ancestor: Any) -> bool:
    """No ancestry check available ⇒ stale. Fails safe, because the cost of the mistake is
    a citation to a line that has moved, and that is evidence a reviewer will act on."""
    if not entry.commit_sha:
        return True
    if is_ancestor is None:
        return True
    return not bool(is_ancestor(entry.commit_sha))


def _vector_literal(embedding: list[float]) -> str:
    return "[" + ",".join(f"{value:.6f}" for value in embedding) + "]"


SCHEMA = """
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS context_chunks (
    id          BIGSERIAL PRIMARY KEY,
    tenant      TEXT NOT NULL,
    repo        TEXT NOT NULL,
    commit_sha  TEXT NOT NULL DEFAULT '',
    path        TEXT NOT NULL DEFAULT '',
    symbol      TEXT NOT NULL DEFAULT '',
    language    TEXT NOT NULL DEFAULT '',
    kind        TEXT NOT NULL DEFAULT 'code',
    line        INTEGER NOT NULL DEFAULT 1,
    text        TEXT NOT NULL,
    embedding   vector(1536) NOT NULL
);
CREATE INDEX IF NOT EXISTS context_chunks_tenant_repo ON context_chunks (tenant, repo);
"""
"""Not an alembic migration on purpose.

The extension is optional and the embedding dimension depends on the model, so putting this in
the migration chain would make every deployment carry a table it does not use and a dimension
somebody else chose. Enabling the adapter is a deployment decision, and so is running this.
"""
