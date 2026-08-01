"""The §9 transition table, as data.

Principle §7.1: *the FSM is the product; everything else is an adapter.* Keeping the table as
data rather than as control flow buys three things that matter more than elegance: it can be
tested exhaustively, it can be rendered as documentation that cannot drift from the code, and a
missing edge is a **test failure** rather than a runtime surprise.

Two dimensions decide a transition and they are deliberately separate:

* a **signal** — what the state's own subgraph concluded (gates green, no work produced,
  changes requested). Semantic, and produced only by code that ran successfully.
* an **error category** — how the attempt failed. Uniform across states, because "the provider
  rate-limited us" means the same thing in every state.

The second table is what makes invariant 1 structural: a category in
:data:`~ai_harness.kernel.outcome.NON_BUDGET_CONSUMING` routes to a park that increments
nothing, no matter which state produced it.
"""

from __future__ import annotations

from dataclasses import dataclass

from ai_harness.kernel.outcome import NON_BUDGET_CONSUMING, ErrorCategory
from ai_harness.schemas.enums import Disposition, RunStatus, Signal, State


@dataclass(frozen=True, slots=True)
class Transition:
    """Where the run goes, and what that costs it."""

    next_state: State
    status: RunStatus = RunStatus.RUNNING
    disposition: Disposition | None = None
    counter: str | None = None
    """Which ``Counters`` field this transition increments. ``None`` means none."""
    defer_for_s: float | None = None
    reason: str = ""

    @property
    def terminal(self) -> bool:
        return self.next_state is State.COMPLETE and self.disposition is not None

    @property
    def parks(self) -> bool:
        return self.status is not RunStatus.RUNNING


def _complete(disposition: Disposition, reason: str) -> Transition:
    return Transition(
        next_state=State.COMPLETE,
        status=RunStatus.PARKED_TERMINAL,
        disposition=disposition,
        reason=reason,
    )


# ── the success edges of §9, one row per (state, signal) ─────────────────────────

SIGNAL_ROUTES: dict[tuple[State, Signal], Transition] = {
    # PREPARE (§9.1)
    (State.PREPARE, Signal.ADVANCE): Transition(
        State.ANALYSE, reason="workspace ready, base pinned"
    ),
    (State.PREPARE, Signal.REPLAN): Transition(
        State.ANALYSE, reason="an undeclared dependency is a code defect the agent can fix"
    ),
    (State.PREPARE, Signal.ABANDONED): _complete(
        Disposition.ABANDONED, "another worker holds the claim"
    ),
    (State.PREPARE, Signal.ESCALATE): _complete(Disposition.ESCALATED, "epic or policy-denied"),
    # ANALYSE (§9.2)
    (State.ANALYSE, Signal.ADVANCE): Transition(
        State.IMPLEMENT, counter="plan_attempts", reason="plan accepted"
    ),
    (State.ANALYSE, Signal.REPIN): Transition(State.PREPARE, reason="base moved under us"),
    (State.ANALYSE, Signal.BLOCKED): Transition(
        State.COMPLETE,
        status=RunStatus.BLOCKED,
        disposition=Disposition.BLOCKED,
        reason="infra or unrelated failure — blocker filed",
    ),
    (State.ANALYSE, Signal.NEEDS_APPROVAL): Transition(
        State.ANALYSE, status=RunStatus.AWAITING_APPROVAL, reason="plan risk exceeds the threshold"
    ),
    (State.ANALYSE, Signal.ESCALATE): _complete(Disposition.ESCALATED, "epic or underspecified"),
    # IMPLEMENT (§9.3)
    (State.IMPLEMENT, Signal.ADVANCE): Transition(
        State.VALIDATE, counter="implement_attempts", reason="work produced"
    ),
    (State.IMPLEMENT, Signal.REPLAN): Transition(
        State.ANALYSE, counter="implement_attempts", reason="no work produced; replan"
    ),
    (State.IMPLEMENT, Signal.NEEDS_APPROVAL): Transition(
        State.IMPLEMENT,
        status=RunStatus.AWAITING_APPROVAL,
        reason="diff size or a protected path",
    ),
    (State.IMPLEMENT, Signal.ESCALATE): _complete(Disposition.ESCALATED, "implement budget spent"),
    # VALIDATE (§9.4)
    (State.VALIDATE, Signal.ADVANCE): Transition(
        State.REVIEW, counter="validate_attempts", reason="required gates green"
    ),
    (State.VALIDATE, Signal.FIX): Transition(
        State.IMPLEMENT, counter="self_repair_attempts", reason="gates red, fault = self"
    ),
    (State.VALIDATE, Signal.REPLAN): Transition(
        State.ANALYSE, counter="validate_attempts", reason="gates red, fault = plan"
    ),
    (State.VALIDATE, Signal.NEEDS_APPROVAL): Transition(
        State.VALIDATE,
        status=RunStatus.AWAITING_APPROVAL,
        reason="the anti-weakening check found deleted or skipped tests",
    ),
    (State.VALIDATE, Signal.ESCALATE): _complete(
        Disposition.ESCALATED, "base red, or the environment cap was reached"
    ),
    # REVIEW (§9.5)
    (State.REVIEW, Signal.ADVANCE): Transition(
        State.INTEGRATE, counter="review_rounds", reason="approved, no blocking findings"
    ),
    (State.REVIEW, Signal.FIX): Transition(
        State.IMPLEMENT, counter="review_rounds", reason="changes requested"
    ),
    (State.REVIEW, Signal.ESCALATE): _complete(
        Disposition.ESCALATED, "round cap, or unparseable after repairs"
    ),
    # INTEGRATE (§9.6)
    (State.INTEGRATE, Signal.DELIVERED): _complete(
        Disposition.DELIVERED, "MR opened (the MR_ONLY default)"
    ),
    (State.INTEGRATE, Signal.MERGED): _complete(Disposition.MERGED, "fast-forwarded"),
    (State.INTEGRATE, Signal.REGATE): Transition(
        State.VALIDATE, reason="base advanced or a conflict was resolved — re-gate the union"
    ),
    (State.INTEGRATE, Signal.FIX): Transition(
        State.IMPLEMENT, counter="resolver_attempts", reason="the conflict is a code defect"
    ),
    (State.INTEGRATE, Signal.NEEDS_APPROVAL): Transition(
        State.INTEGRATE,
        status=RunStatus.AWAITING_APPROVAL,
        reason="protected branch, force-push, or a non-default strategy",
    ),
    (State.INTEGRATE, Signal.ESCALATE): _complete(Disposition.ESCALATED, "conflict unresolvable"),
    # COMPLETE is terminal; it accepts only the dispositions that name how it ended.
    (State.COMPLETE, Signal.MERGED): _complete(Disposition.MERGED, "merged"),
    (State.COMPLETE, Signal.DELIVERED): _complete(Disposition.DELIVERED, "delivered"),
    (State.COMPLETE, Signal.ESCALATE): _complete(Disposition.ESCALATED, "escalated"),
    (State.COMPLETE, Signal.ADVANCE): _complete(Disposition.DELIVERED, "nothing left to do"),
}


# ── the failure edges, uniform across states (§16.2) ─────────────────────────────

DEFER_SECONDS: dict[ErrorCategory, float] = {
    ErrorCategory.TRANSIENT: 60.0,
    ErrorCategory.RATE_LIMITED: 300.0,
    ErrorCategory.UNKNOWN: 30.0,
    ErrorCategory.ENVIRONMENT: 300.0,
}


def route_error(state: State, category: ErrorCategory) -> Transition:
    """Where a failed attempt goes. Identical in every state, on purpose.

    A category that is not the attempt's fault parks the run in the **same** state — which is
    what "a parked run *is* in its state" means, and why resume needs no special case.
    """
    if category in DEFER_SECONDS:
        return Transition(
            next_state=state,
            status=RunStatus.DEFERRED,
            defer_for_s=DEFER_SECONDS[category],
            reason=f"{category.value}: retried next tick, consuming no budget",
        )
    if category is ErrorCategory.REPO_CONFLICT:
        # Never resolve-and-retry blindly: re-gate against what the base actually is now.
        return Transition(State.VALIDATE, reason="the base moved — re-gate the union")
    if category is ErrorCategory.TOOL_FAILURE:
        return Transition(
            State.IMPLEMENT,
            counter="implement_attempts",
            reason="a deterministic tool error is a defect the fixer can own",
        )
    if category is ErrorCategory.NEEDS_HUMAN:
        return Transition(
            next_state=state,
            status=RunStatus.AWAITING_APPROVAL,
            reason="a decision the harness may not make",
        )
    if category is ErrorCategory.VALIDATION:
        return _complete(
            Disposition.ESCALATED, "model output did not satisfy its schema after repairs"
        )
    if category is ErrorCategory.MODEL_FAILURE:
        return _complete(Disposition.ESCALATED, "the model produced unusable output")
    if category is ErrorCategory.PERMANENT:
        return _complete(Disposition.DELIVERED, "terminal and understood")
    if category is ErrorCategory.AUTH:
        return _complete(Disposition.ESCALATED, "credentials rejected — never retried")
    if category is ErrorCategory.POLICY:
        return _complete(Disposition.ESCALATED, "a capability was denied")
    # FATAL, and anything a future member adds: fail closed (§7.4).
    return _complete(Disposition.ESCALATED, f"unhandled {category.value} — failing closed")


def consumes_budget(category: ErrorCategory | None) -> bool:
    """Success consumes; a failure consumes only when it was the attempt's fault."""
    return category is None or category not in NON_BUDGET_CONSUMING


def render_table() -> str:
    """The table as Markdown, so the documentation cannot drift from the code."""
    lines = ["| state | signal | → | status | counter | why |", "|---|---|---|---|---|---|"]
    for (state, signal), transition in sorted(
        SIGNAL_ROUTES.items(), key=lambda item: (item[0][0].value, item[0][1].value)
    ):
        lines.append(
            f"| {state.value} | {signal.value} | {transition.next_state.value} "
            f"| {transition.status.value} | {transition.counter or '—'} | {transition.reason} |"
        )
    return "\n".join(lines)
