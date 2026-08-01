"""Which agent owns a failing gate — `route-failure.sh`'s table, as data (#108).

`registry.py` already carries a mapping named after this script, and it is a *different* mapping:
gate → *area* (`types`, `style`, `tests`), which is what the triager reasons about. This one is
gate → *owner*, the agent that gets spawned to fix it. Both are useful and neither substitutes
for the other, so this is the second table rather than an edit to the first.

The routing is a lookup with one wrinkle worth keeping: **`typecheck`, `lint` and `unit` route by
the failing path, not by the gate.** A type error under `src/components/` is the frontend
developer's and the same error under `prisma/` is the migrator's, and sending every type failure
to one owner is how a gate becomes somebody else's problem to triage by hand.

Every comment in the shell's table is a decision about ownership, and the ones that are not
obvious are kept: a coverage shortfall is missing tests rather than broken behaviour, so it goes
to whoever writes red-before-green tests; a mutation failure means the tests are too weak, which
is the same owner; an i18n failure is a copy change even when the catalog is mobile's.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

UNKNOWN = "unknown"
"""What the shell echoes when it has no rule. Not a default owner: an unrouted gate is a gate
somebody has to look at, and silently assigning it would hide that."""


@dataclass(frozen=True, slots=True)
class AreaRule:
    """A path pattern and the owner it implies, for gates that route by *where* they failed."""

    pattern: re.Pattern[str]
    owner: str


TYPE_AND_LINT_RULES: tuple[AreaRule, ...] = (
    AreaRule(re.compile(r"src/(app|components|pages)/"), "frontend-developer"),
    AreaRule(re.compile(r"src/(lib|api|server)/"), "backend-developer"),
    AreaRule(re.compile(r"(prisma|migrations)/"), "db-migrator"),
)
TYPE_AND_LINT_DEFAULT = "frontend-developer"

UNIT_RULES: tuple[AreaRule, ...] = (
    AreaRule(re.compile(r"components|pages|frontend"), "frontend-developer"),
    AreaRule(re.compile(r"jobs|queues"), "background-jobs"),
    AreaRule(re.compile(r"db|prisma|migrations"), "db-migrator"),
)
UNIT_DEFAULT = "backend-developer"

OWNERS: dict[str, str] = {
    # Tests too weak, rather than behaviour broken — the owner that writes stronger ones.
    "mutation": "adversarial-tester",
    "coverage": "adversarial-tester",
    "quarantine": "adversarial-tester",
    # An open bug with no committed reproducing test: red-before-green comes first.
    "repro-tests": "adversarial-tester",
    "integration": "backend-developer",
    "contract": "backend-developer",
    # Could be either; the orchestrator overrides with the bug's own owner field.
    "e2e": "frontend-developer",
    "visual": "frontend-developer",
    # Catalog parity and the hardcoded-string ratchet: a copy change, even when the failing
    # catalog is mobile's.
    "i18n": "frontend-developer",
    # A Maestro flow against the app: the assertion is about mobile source, not the web.
    "mobile-e2e": "frontend-developer",
    "mobile-perf": "perf-tester",
    "lighthouse": "perf-tester",
    "a11y": "ux-designer",
    # A doc naming a path that moved, or a generated index that was hand-edited.
    "docs-refs": "api-docs",
    "iteration-immutable": "api-docs",
    "migration-drift": "db-migrator",
    "seed-integrity": "db-migrator",
    "wedge-coverage": "e2e-tester",
    "journey-coverage": "e2e-tester",
}


def route(gate: str, *, area: str = "") -> str:
    """The agent that owns this failure. ``unknown`` when nothing claims it."""
    if gate in ("typecheck", "lint"):
        return _by_area(area, TYPE_AND_LINT_RULES, TYPE_AND_LINT_DEFAULT)
    if gate == "unit":
        return _by_area(area, UNIT_RULES, UNIT_DEFAULT)
    return OWNERS.get(gate, UNKNOWN)


def _by_area(area: str, rules: tuple[AreaRule, ...], default: str) -> str:
    for rule in rules:
        if rule.pattern.search(area):
            return rule.owner
    return default
