"""Issues #31 and #32 — the transition table and the pure router.

Exhaustive over ``ErrorCategory × State``: a missing arm is a **test failure**, not a runtime
surprise. That is the whole reason the table is data.
"""

from __future__ import annotations

import inspect

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from ai_harness.kernel.outcome import NON_BUDGET_CONSUMING, ErrorCategory
from ai_harness.orchestration import router as router_module
from ai_harness.orchestration.router import known_signals, route
from ai_harness.orchestration.transitions import (
    SIGNAL_ROUTES,
    consumes_budget,
    render_table,
    route_error,
)
from ai_harness.schemas.enums import Disposition, RunStatus, Signal, State

ALL_STATES = list(State)
ALL_CATEGORIES = list(ErrorCategory)


# ── exhaustiveness ───────────────────────────────────────────────────────────────


@pytest.mark.parametrize("state", ALL_STATES)
@pytest.mark.parametrize("category", ALL_CATEGORIES)
def test_every_state_and_category_pair_routes_somewhere(
    state: State, category: ErrorCategory
) -> None:
    transition = route(state, category=category)
    assert isinstance(transition.next_state, State)
    assert transition.reason, "every edge must say why it exists"


@pytest.mark.parametrize("state", ALL_STATES)
def test_every_state_has_at_least_one_success_edge(state: State) -> None:
    assert known_signals(state), f"{state.value} can never succeed"


@pytest.mark.parametrize("state", [s for s in State if s is not State.COMPLETE])
def test_every_non_terminal_state_can_reach_completion(state: State) -> None:
    """Invariant 12: every terminal state needs a re-entry path, and every state an exit."""
    reachable = {SIGNAL_ROUTES[(state, signal)].next_state for signal in known_signals(state)}
    assert State.COMPLETE in reachable or reachable - {state}


def test_the_state_count_is_still_seven() -> None:
    assert len(ALL_STATES) == 7


# ── the failure edges ────────────────────────────────────────────────────────────


@pytest.mark.parametrize("category", sorted(NON_BUDGET_CONSUMING, key=str))
@pytest.mark.parametrize("state", ALL_STATES)
def test_a_blameless_failure_never_advances_or_charges(
    state: State, category: ErrorCategory
) -> None:
    """Invariant 1, enforced by the table rather than by each caller's if."""
    transition = route(state, category=category)
    assert not consumes_budget(category)
    if transition.status is RunStatus.DEFERRED:
        assert transition.next_state is state, "a parked run IS in its state"
        assert transition.counter is None


@pytest.mark.parametrize("state", ALL_STATES)
def test_auth_is_terminal_everywhere(state: State) -> None:
    transition = route(state, category=ErrorCategory.AUTH)
    assert transition.terminal and transition.disposition is Disposition.ESCALATED


@pytest.mark.parametrize("state", ALL_STATES)
def test_rate_limits_defer_with_a_delay_and_no_counter(state: State) -> None:
    transition = route(state, category=ErrorCategory.RATE_LIMITED)
    assert transition.status is RunStatus.DEFERRED
    assert transition.defer_for_s and transition.defer_for_s > 0
    assert transition.counter is None


@pytest.mark.parametrize("state", ALL_STATES)
def test_an_empty_envelope_parks_rather_than_escalating(state: State) -> None:
    """#2407: the failure most worth retrying must not be the one guaranteed to escalate."""
    transition = route(state, category=ErrorCategory.UNKNOWN)
    assert transition.status is RunStatus.DEFERRED
    assert transition.next_state is state


@pytest.mark.parametrize("state", ALL_STATES)
def test_a_repo_conflict_re_gates_rather_than_resolving_blindly(state: State) -> None:
    assert route(state, category=ErrorCategory.REPO_CONFLICT).next_state is State.VALIDATE


@pytest.mark.parametrize("state", ALL_STATES)
def test_fatal_fails_closed(state: State) -> None:
    transition = route(state, category=ErrorCategory.FATAL)
    assert transition.disposition is Disposition.ESCALATED


# ── the success edges ────────────────────────────────────────────────────────────


def test_the_happy_path_is_the_seven_state_walk() -> None:
    walk = [State.PREPARE]
    signals = {
        State.PREPARE: Signal.ADVANCE,
        State.ANALYSE: Signal.ADVANCE,
        State.IMPLEMENT: Signal.ADVANCE,
        State.VALIDATE: Signal.ADVANCE,
        State.REVIEW: Signal.ADVANCE,
        State.INTEGRATE: Signal.DELIVERED,
    }
    state = State.PREPARE
    while state in signals:
        state = route(state, signal=signals[state]).next_state
        walk.append(state)
    assert walk == [
        State.PREPARE,
        State.ANALYSE,
        State.IMPLEMENT,
        State.VALIDATE,
        State.REVIEW,
        State.INTEGRATE,
        State.COMPLETE,
    ]


def test_the_review_fix_loop_returns_to_implement() -> None:
    transition = route(State.REVIEW, signal=Signal.FIX)
    assert transition.next_state is State.IMPLEMENT
    assert transition.counter == "review_rounds", "a fix round costs a review round"


def test_the_self_repair_loop_is_the_same_edge_at_a_different_budget() -> None:
    """IMPLEMENT ↔ VALIDATE is the fixer's inline self-repair loop — one implementation."""
    to_validate = route(State.IMPLEMENT, signal=Signal.ADVANCE)
    back_to_implement = route(State.VALIDATE, signal=Signal.FIX)
    assert to_validate.next_state is State.VALIDATE
    assert back_to_implement.next_state is State.IMPLEMENT
    assert back_to_implement.counter == "self_repair_attempts"
    assert to_validate.counter != back_to_implement.counter


def test_integration_defaults_to_delivered_not_merged() -> None:
    """Q1: MR_ONLY is the shipped default; FF_ONLY is opt-in per repository."""
    assert route(State.INTEGRATE, signal=Signal.DELIVERED).disposition is Disposition.DELIVERED
    assert route(State.INTEGRATE, signal=Signal.MERGED).disposition is Disposition.MERGED


def test_approval_parks_in_the_same_state() -> None:
    for state in (State.ANALYSE, State.IMPLEMENT, State.VALIDATE, State.INTEGRATE):
        transition = route(state, signal=Signal.NEEDS_APPROVAL)
        assert transition.next_state is state
        assert transition.status is RunStatus.AWAITING_APPROVAL


# ── fail-closed and purity ───────────────────────────────────────────────────────


def test_an_unanticipated_pair_escalates_rather_than_guessing() -> None:
    transition = route(State.REVIEW, signal=Signal.MERGED)
    assert transition.disposition is Disposition.ESCALATED
    assert "no edge" in transition.reason


def test_supplying_neither_a_signal_nor_a_category_escalates() -> None:
    assert route(State.REVIEW).disposition is Disposition.ESCALATED


def test_a_category_wins_over_a_signal_because_a_failure_is_not_a_conclusion() -> None:
    transition = route(State.REVIEW, signal=Signal.ADVANCE, category=ErrorCategory.RATE_LIMITED)
    assert transition.status is RunStatus.DEFERRED


@settings(max_examples=200, deadline=None)
@given(
    state=st.sampled_from(ALL_STATES),
    signal=st.one_of(st.none(), st.sampled_from(list(Signal))),
    category=st.one_of(st.none(), st.sampled_from(ALL_CATEGORIES)),
)
def test_routing_is_deterministic_under_fuzzing(
    state: State, signal: Signal | None, category: ErrorCategory | None
) -> None:
    assert route(state, signal=signal, category=category) == route(
        state, signal=signal, category=category
    )


def test_the_router_imports_nothing_that_could_call_a_model() -> None:
    """The mechanical guarantee, asserted on the imports themselves rather than on the prose.

    Grepping the source would trip over the docstring that explains the rule, which is exactly
    the kind of test that gets deleted rather than fixed. Parse the imports instead.
    """
    import ast

    tree = ast.parse(inspect.getsource(router_module))
    imported: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module)
        elif isinstance(node, ast.Import):
            imported.update(alias.name for alias in node.names)

    forbidden = (
        "ai_harness.llm",
        "ai_harness.agents",
        "ai_harness.providers",
        "httpx",
        "subprocess",
    )
    assert not [m for m in imported if m.startswith(forbidden)]
    assert imported <= {
        "__future__",
        "ai_harness.kernel.outcome",
        "ai_harness.orchestration.transitions",
        "ai_harness.schemas.enums",
    }, imported


def test_the_table_renders_as_documentation() -> None:
    """A table that cannot be rendered is a table the docs will eventually disagree with."""
    rendered = render_table()
    assert rendered.count("\n") >= len(SIGNAL_ROUTES)
    assert "| REVIEW | advance | INTEGRATE |" in rendered


def test_route_error_and_route_agree() -> None:
    for state in ALL_STATES:
        for category in ALL_CATEGORIES:
            assert route(state, category=category) == route_error(state, category)
