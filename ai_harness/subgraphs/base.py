"""The subgraph boundary — level 2 of a deliberately two-level model.

§25: deeper hierarchies make cost, failure and provenance untraceable, so there is a
supervisor and there are subgraphs, and that is the whole tree.

Two properties are enforced here rather than trusted:

**Nothing raises across a state boundary** (§7.2). :func:`guarded` catches everything a
subgraph can throw and converts it into ``Outcome(FATAL)``. The process does not die; the run
parks with an error record a human can read. ``KeyboardInterrupt``, ``SystemExit`` and
``CancelledError`` still propagate — those are the operator and the runtime talking, not the
subgraph failing.

**Results are typed** (W13). The shell driver learns what the inbox did by grepping its *log*
for ``claiming issue #N``, so rewording a log line breaks the driver. A subgraph here returns
a :class:`SubgraphResult`; nothing parses anyone's output.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any, Protocol

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.schemas.enums import Signal


@dataclass(frozen=True, slots=True)
class SubgraphResult:
    """What a state concluded, and what it cost to conclude it."""

    signal: Signal
    reason: str = ""
    payload: dict[str, Any] = field(default_factory=dict)
    """The state's typed output, dumped — small enough to read, complete enough to replay."""
    artefacts: list[str] = field(default_factory=list)
    head_sha: str = ""
    base_sha: str = ""
    usd: Decimal = Decimal(0)
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    model: str | None = None
    template_id: str | None = None
    prompt_sha256: str | None = None
    prompt_bytes: int | None = None
    isolation: str | None = None


class Subgraph(Protocol):
    """One state's work, as a black box with a typed input and a typed output."""

    state_name: str

    async def execute(self, ctx: Any) -> Outcome[SubgraphResult]: ...


async def guarded(
    operation: Callable[[], Awaitable[Outcome[SubgraphResult]]],
    *,
    state: str,
) -> Outcome[SubgraphResult]:
    """Run a subgraph so that it cannot raise into the supervisor.

    The boundary exists because the alternative is a crashed worker: the shell driver tolerates
    a non-zero stage exit precisely so a broken stage costs one tick rather than the run, and
    this is that property, typed.
    """
    try:
        return await operation()
    except (KeyboardInterrupt, SystemExit, asyncio.CancelledError):
        # The operator or the runtime is talking. Let it through.
        raise
    except Exception as exc:
        return Outcome.fail(
            ErrorCategory.FATAL,
            f"{state} raised {type(exc).__name__}: {exc}",
            remedy=(
                "an unexpected exception crossed a state boundary; the run parks and the "
                "process survives — see the checkpoint for the traceback digest"
            ),
            details={"exception": type(exc).__name__, "state": state},
        )


class NotImplementedSubgraph:
    """A placeholder for a state whose subgraph has not been ported yet.

    Escalating loudly beats a silent no-op: a run that reaches an unported state must stop and
    say so, not appear to have succeeded. Phases 3 and 4 replace these one at a time.
    """

    def __init__(self, state_name: str, phase: str) -> None:
        self.state_name = state_name
        self.phase = phase

    async def execute(self, ctx: Any) -> Outcome[SubgraphResult]:
        return Outcome.fail(
            ErrorCategory.NEEDS_HUMAN,
            f"{self.state_name} is not implemented yet (arrives in {self.phase})",
            remedy=f"drive this state with the shell engine until {self.phase} lands",
        )
