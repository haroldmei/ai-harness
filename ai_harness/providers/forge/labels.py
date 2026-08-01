"""The label vocabulary — a **projection** of durable state, not the state itself.

W1's root cause is that the shell treats a label as the FSM's memory, and a label has no
compare-and-swap, no atomicity and an eventually-consistent search index. From Phase 4 the
``runs`` table is authoritative and labels are written *from* it, which is what makes them safe
to be wrong for a few seconds.

Keeping the names identical to the shell's is deliberate: during the migration both engines
read the same board, and a human watching the repository sees no change.
"""

from __future__ import annotations

from ai_harness.schemas.enums import Disposition, RunStatus, State

AGENT = "agent"
PROPOSED = "proposed"
WIP = "wip"
REVIEW_NEEDED = "review-needed"
REVIEW_WIP = "review-wip"
CHANGES_REQUESTED = "changes-requested"
FIX_WIP = "fix-wip"
REVIEW_APPROVED = "review-approved"
MERGE_WIP = "merge-wip"
MERGE_STUCK = "merge-stuck"
REVIEW_STUCK = "review-stuck"
MERGED = "merged"
DONE = "done"
BLOCKED = "blocked"
NEEDS_HUMAN = "needs-human"
SHADOW = "harness-shadow"
"""Phase 2 shadow mode posts here, so the Python reviewer's verdict is visible but not acted on."""

CLAIM_LABELS = frozenset({WIP, REVIEW_WIP, FIX_WIP, MERGE_WIP})
"""Labels that assert a claim. A claim label with no live lease is what the reaper releases."""

TERMINAL_LABELS = frozenset({MERGED, DONE, NEEDS_HUMAN})

_STATE_LABELS: dict[State, str] = {
    State.PREPARE: WIP,
    State.ANALYSE: WIP,
    State.IMPLEMENT: FIX_WIP,
    State.VALIDATE: FIX_WIP,
    State.REVIEW: REVIEW_NEEDED,
    State.INTEGRATE: MERGE_WIP,
    State.COMPLETE: DONE,
}

_DISPOSITION_LABELS: dict[Disposition, str] = {
    Disposition.MERGED: MERGED,
    Disposition.DELIVERED: REVIEW_NEEDED,
    Disposition.ESCALATED: NEEDS_HUMAN,
    Disposition.BLOCKED: BLOCKED,
    Disposition.ABANDONED: AGENT,
    Disposition.CANCELLED: AGENT,
}


def label_for(state: State, status: RunStatus, disposition: Disposition | None = None) -> str:
    """The single label that projects this run's position onto the board."""
    if disposition is not None:
        return _DISPOSITION_LABELS.get(disposition, NEEDS_HUMAN)
    if status is RunStatus.BLOCKED:
        return BLOCKED
    if status is RunStatus.AWAITING_APPROVAL:
        return NEEDS_HUMAN
    if status is RunStatus.PARKED_TERMINAL:
        return REVIEW_STUCK
    return _STATE_LABELS[state]


def managed_labels() -> frozenset[str]:
    """Every label the harness owns. Anything else on an issue is a human's and is left alone."""
    return frozenset(
        {
            *_STATE_LABELS.values(),
            *_DISPOSITION_LABELS.values(),
            *CLAIM_LABELS,
            REVIEW_APPROVED,
            CHANGES_REQUESTED,
            MERGE_STUCK,
            REVIEW_STUCK,
            BLOCKED,
            NEEDS_HUMAN,
            MERGED,
            DONE,
            SHADOW,
        }
    )
