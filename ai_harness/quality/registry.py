"""Gate registry, tiers, and selection — the shell's semantics, re-expressed as data.

Three holes are closed here explicitly, each with an incident behind it:

* **Unknown tier aborts.** ``--tier lanuch`` fell back to the weaker ``preview`` set, silently
  dropping integration, contract, coverage, migration-drift, visual and mobile-e2e, and still
  printed "all gates pass". Guessing downward is the one interpretation that can ship red code.
* **Allow-list is not deny-list.** A required gate absent from ``--only`` is an honest skip
  (the deployed lanes legitimately scope their runs); one removed via ``--skip`` is a failure.
* **An unregistered gate fails.** A name with no implementation is a ``FAIL``, never a silent
  drop — it is one line's omission away on every new gate.
"""

from __future__ import annotations

from ai_harness.schemas.enums import GateSelection, GateStatus, Tier
from ai_harness.schemas.gates import GateProfile, GateResult, GateSpec

REQUIRED_BY_TIER: dict[Tier, tuple[str, ...]] = {
    # Transcribed from quality-gates.sh's REQUIRED_BY_TIER.
    Tier.TOY: ("typecheck", "lint"),
    Tier.PREVIEW: ("typecheck", "lint", "docs-refs", "iteration-immutable", "unit"),
    Tier.LAUNCH: (
        "typecheck",
        "lint",
        "docs-refs",
        "iteration-immutable",
        "migration-drift",
        "unit",
        "coverage",
        "integration",
        "contract",
        "visual",
        "mobile-e2e",
    ),
    Tier.SCALE: (
        "typecheck",
        "lint",
        "docs-refs",
        "iteration-immutable",
        "migration-drift",
        "unit",
        "coverage",
        "integration",
        "contract",
        "e2e",
        "visual",
        "mobile-e2e",
    ),
}

STACK_GATES = frozenset(
    {
        "integration",
        "e2e",
        "visual",
        "mobile-e2e",
        "seed-integrity",
        "migration-drift",
        "lighthouse",
    }
)
"""Gates that boot containers and bind ports. They get their own semaphore and port band."""

GATE_OWNERS: dict[str, str] = {
    # route-failure.sh's lookup table, as data rather than code.
    "typecheck": "types",
    "lint": "style",
    "unit": "tests",
    "coverage": "tests",
    "integration": "backend",
    "contract": "api",
    "e2e": "frontend",
    "visual": "frontend",
    "mobile-e2e": "mobile",
    "migration-drift": "database",
    "seed-integrity": "database",
    "docs-refs": "docs",
}


class UnknownTierError(ValueError):
    """Raised rather than falling back to a weaker set. Fail closed (§7.4)."""


def parse_tier(value: str) -> Tier:
    try:
        return Tier(value)
    except ValueError as exc:
        known = ", ".join(t.value for t in Tier)
        raise UnknownTierError(f"unknown tier {value!r} (known: {known})") from exc


def required_names(tier: Tier, override: list[str] | None = None) -> set[str]:
    """The required set for a tier, or an explicit override (the ``REQUIRED_GATES`` escape)."""
    if override is not None:
        return set(override)
    if tier not in REQUIRED_BY_TIER:
        raise UnknownTierError(f"no required set for tier {tier!r}")
    return set(REQUIRED_BY_TIER[tier])


def select(
    names: list[str],
    *,
    only: list[str] | None = None,
    skip: list[str] | None = None,
) -> dict[str, GateSelection]:
    """Decide, per gate, whether it runs — and *why* it does not, which changes the verdict."""
    selection: dict[str, GateSelection] = {}
    for name in names:
        if skip and name in skip:
            selection[name] = GateSelection.DENY_LISTED
        elif only is not None and name not in only:
            selection[name] = GateSelection.NOT_SELECTED
        else:
            selection[name] = GateSelection.RAN
    return selection


def build_profile(
    names: list[str],
    *,
    tier: Tier,
    required_override: list[str] | None = None,
) -> GateProfile:
    """A profile for a set of gate names, with requiredness resolved from the tier."""
    required = required_names(tier, required_override)
    specs = [
        GateSpec(
            name=name,
            required_from_tier=_first_tier_requiring(name) if name in required else None,
            resource="stack" if name in STACK_GATES else "cpu",
        )
        for name in names
    ]
    return GateProfile(tier=tier, gates=specs, full_set=list(names))


def _first_tier_requiring(name: str) -> Tier | None:
    for tier in (Tier.TOY, Tier.PREVIEW, Tier.LAUNCH, Tier.SCALE):
        if name in REQUIRED_BY_TIER[tier]:
            return tier
    return None


def unregistered_result(name: str) -> GateResult:
    """A named gate with no implementation. Loud, not silent."""
    return GateResult(
        name=name,
        raw_status=GateStatus.FAIL,
        required=True,
        reason=f"gate {name!r} is named but has no implementation",
    )
