"""``route()`` — pure, LLM-free, and exhaustively tested.

Principle §7.1: *no LLM call decides a workflow edge.* Determinism is what makes routing
testable, replayable and injection-proof — an issue body cannot talk the harness into a
different state, because the thing that chooses states cannot read an issue body.

That guarantee is mechanical, not aspirational: an ``import-linter`` contract forbids this
module from importing ``ai_harness.llm``, ``ai_harness.agents`` or ``ai_harness.providers``,
and a test makes the forbidden import and asserts the build fails.

The function has no I/O, no clock and no state. Given the same arguments it returns the same
transition forever, which is what ``agent replay`` depends on.
"""

from __future__ import annotations

from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.orchestration.transitions import SIGNAL_ROUTES, Transition, route_error
from ai_harness.schemas.enums import Disposition, RunStatus, Signal, State


def route(
    state: State,
    *,
    signal: Signal | None = None,
    category: ErrorCategory | None = None,
) -> Transition:
    """Where does a run in ``state`` go next?

    Exactly one of ``signal`` (the subgraph succeeded and concluded something) or ``category``
    (it failed) is expected. Anything else — both, neither, or a pair with no table entry — is
    a situation the harness has not anticipated, and the only safe answer is to escalate
    rather than to guess (§7.4).
    """
    if category is not None:
        return route_error(state, category)

    if signal is None:
        return _fail_closed(state, "neither a signal nor an error category was supplied")

    transition = SIGNAL_ROUTES.get((state, signal))
    if transition is None:
        return _fail_closed(state, f"no edge for {state.value} + {signal.value}")
    return transition


def _fail_closed(state: State, reason: str) -> Transition:
    return Transition(
        next_state=State.COMPLETE,
        status=RunStatus.PARKED_TERMINAL,
        disposition=Disposition.ESCALATED,
        reason=(
            f"{reason} — a genuinely novel situation escalates rather than being reasoned "
            f"about (from {state.value})"
        ),
    )


def known_signals(state: State) -> set[Signal]:
    """Which signals this state can legitimately produce. Used by the subgraph tests."""
    return {signal for (owner, signal) in SIGNAL_ROUTES if owner is state}


def is_terminal(state: State) -> bool:
    return state is State.COMPLETE
