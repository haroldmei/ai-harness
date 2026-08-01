"""State → subgraph binding, and the per-state policy the supervisor enforces.

Timeouts and attempt caps live here rather than inside each subgraph for the same reason the
transition table does: they are operational settings an operator tunes, and a bound buried in
the code it bounds cannot be reviewed as a set. The defaults are §9's, verbatim.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ai_harness.schemas.enums import State
from ai_harness.subgraphs.base import NotImplementedSubgraph, Subgraph


@dataclass(frozen=True, slots=True)
class StatePolicy:
    """What the supervisor enforces around a state, without knowing what it does."""

    timeout_s: float
    max_attempts: int
    counter: str | None = None
    """The ``Counters`` field that bounds this state, checked before entry."""


DEFAULT_POLICIES: dict[State, StatePolicy] = {
    State.PREPARE: StatePolicy(timeout_s=15 * 60, max_attempts=3),
    State.ANALYSE: StatePolicy(timeout_s=10 * 60, max_attempts=3, counter="plan_attempts"),
    State.IMPLEMENT: StatePolicy(timeout_s=45 * 60, max_attempts=6, counter="implement_attempts"),
    State.VALIDATE: StatePolicy(timeout_s=90 * 60, max_attempts=6, counter="validate_attempts"),
    State.REVIEW: StatePolicy(timeout_s=20 * 60, max_attempts=4, counter="review_rounds"),
    State.INTEGRATE: StatePolicy(timeout_s=30 * 60, max_attempts=3),
    State.COMPLETE: StatePolicy(timeout_s=60, max_attempts=1),
}


@dataclass
class Registry:
    """Binds states to their subgraphs. Unbound states escalate rather than vanish."""

    subgraphs: dict[State, Subgraph] = field(default_factory=dict)
    policies: dict[State, StatePolicy] = field(default_factory=lambda: dict(DEFAULT_POLICIES))
    phase_for_unbound: str = "a later phase"

    def bind(self, state: State, subgraph: Subgraph) -> Registry:
        self.subgraphs[state] = subgraph
        return self

    def subgraph_for(self, state: State) -> Subgraph:
        bound = self.subgraphs.get(state)
        if bound is not None:
            return bound
        return NotImplementedSubgraph(state.value, self.phase_for_unbound)

    def policy_for(self, state: State) -> StatePolicy:
        return self.policies.get(state, StatePolicy(timeout_s=15 * 60, max_attempts=3))

    def timeout_for(self, state: State) -> float:
        return self.policy_for(state).timeout_s

    @property
    def bound_states(self) -> set[State]:
        return set(self.subgraphs)
