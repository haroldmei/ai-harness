"""Repository-native retrieval (§17.2) — the contract.

**Decided: no vector store by default.** The reasoning is specific to source code, not general
RAG scepticism: the queries are structural ("where is ``WebhookSender`` defined", "what calls
``send_with_retry``", "which tests import this module"), and an approximate answer to "where is
this defined" is worse than useless. Code churns, so an embedding index returns stale line
numbers, and a stale line number becomes false *evidence* in a review.

The high-value retrieval inputs are already precise: the failing test's stack trace names the
file and line, the diff names the files, the issue names symbols. Seeding from those is both
cheaper and more accurate than similarity search over issue prose.

The protocol exists so the optional ``pgvector`` adapter (#68, Phase 6) can be added for the one
case that genuinely is semantic — *what fixed this fingerprint last time* — without the rest of
the harness knowing.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

from ai_harness.kernel.outcome import Outcome
from ai_harness.schemas.enums import State


@dataclass(frozen=True, slots=True)
class RetrievalQuery:
    """Seeded from precise inputs, never from prose alone."""

    state: State
    symbols: list[str] = field(default_factory=list)
    paths: list[str] = field(default_factory=list)
    stack_traces: list[str] = field(default_factory=list)
    failing_tests: list[str] = field(default_factory=list)
    keywords: list[str] = field(default_factory=list)
    max_chunks: int = 40
    max_tokens: int = 60_000


@dataclass(frozen=True, slots=True)
class Chunk:
    """One retrieved piece, with enough provenance to cite it."""

    path: str
    text: str
    line: int = 1
    symbol: str | None = None
    kind: str = "match"
    score: float = 0.0

    @property
    def citation(self) -> str:
        return f"{self.path}:{self.line}"


@dataclass(frozen=True, slots=True)
class RetrievalBundle:
    chunks: list[Chunk] = field(default_factory=list)
    truncated: int = 0
    """How many candidates did not fit. Stated, never silently dropped."""
    sources: list[str] = field(default_factory=list)

    @property
    def complete(self) -> bool:
        return self.truncated == 0


class RetrievalService(Protocol):
    async def bundle(self, query: RetrievalQuery) -> Outcome[RetrievalBundle]: ...
