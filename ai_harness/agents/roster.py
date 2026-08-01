"""The roster — and the refusal that makes independent review mean something.

``FR-075`` in the shell harness is enforced fail-fast at both ends
(``agent-pr-reviewer.sh:104-107``, ``agent-pr-fixer.sh:89-92``):

    REFUSING: PR_REVIEWER_MODEL must DIFFER from PR_FIXER_MODEL — independent review needs a
    different model.

Two scripts each checking it is two places it can be forgotten, and neither of them can refuse
on behalf of the other. Here it is a validator on the roster: a configuration where the reviewer
and the implementer share a model **cannot be constructed**, so there is no code path that runs
a self-review.

The refusal is deliberately not a warning. A self-review that looks like a review is worse than
no review, because the evidence block will say a second model approved it.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class Role(StrEnum):
    PLANNER = "planner"
    TRIAGER = "triager"
    IMPLEMENTER = "implementer"
    REVIEWER = "reviewer"
    CONFLICT_RESOLVER = "conflict_resolver"
    SUMMARISER = "summariser"


class RosterError(ValueError):
    """Raised at construction. A roster that cannot be trusted is never half-built."""


INDEPENDENT_PAIRS: tuple[tuple[Role, Role], ...] = ((Role.REVIEWER, Role.IMPLEMENTER),)
"""Roles that must not share a model. The reviewer judging its own work is the whole point."""


@dataclass(frozen=True)
class AgentRoster:
    """Which model plays which role, validated at construction."""

    models: dict[Role, str]

    def __post_init__(self) -> None:
        missing = [role for role in (Role.REVIEWER, Role.IMPLEMENTER) if role not in self.models]
        if missing:
            raise RosterError(
                f"the roster must name a model for {', '.join(r.value for r in missing)}"
            )
        for first, second in INDEPENDENT_PAIRS:
            if self.models.get(first) == self.models.get(second):
                raise RosterError(
                    f"REFUSING: the {first.value} and the {second.value} must use DIFFERENT "
                    f"models — independent review needs a different model, and both are set to "
                    f"{self.models.get(first)!r}"
                )

    def model_for(self, role: Role) -> str:
        try:
            return self.models[role]
        except KeyError as exc:
            raise RosterError(f"no model configured for {role.value}") from exc

    def independent(self, first: Role, second: Role) -> bool:
        return self.models.get(first) != self.models.get(second)
