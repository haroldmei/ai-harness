"""Reading a shell spine as a declaration — proposed, never written (#97).

A repository with a tuned `quality-gates.sh` has a working gate contract expressed in bash.
Moving it to `.harness/gates.yaml` by retyping it from memory is how a gate quietly goes
missing, and *never weaken what exists* is the one invariant of §19 with no second chance.

Four things are read out of the spine, and each is read from **the spine being adopted** rather
than from this package's transcription of it. `registry.py` carries a copy of one particular
spine's tier table, which is right for interpreting *that* spine and wrong as an assumption
about somebody else's:

* ``GATES=(…)`` — the gate names, and therefore the set that must survive the move;
* ``declare -A REQUIRED_BY_TIER=(…)`` — requiredness, mapped onto ``required_from_tier`` as the
  lowest tier at which a gate is demanded;
* ``STACK_GATES`` — which gates boot containers, and therefore need the stack semaphore;
* an optional ``--json`` scorecard — real durations, which make the emitted timeouts plausible
  rather than uniform.

**The output is a proposal.** Q9 settled the general form: *propose gates in the MR body; never
write CI configuration autonomously*. A gate declaration is the contract by which the harness is
permitted to merge, and a tool that writes its own contract has removed the human from the only
place they were load-bearing. So this renders text; something else decides where it goes.

The honest part is what it *cannot* do. A gate whose body is bash — a loop over services, a jq
expression against `state/`, an inline heredoc — has no single command to declare, and inventing
one would be the failure this module exists to prevent. Those are emitted as comments naming the
gate and why, so an unexpressible gate is a finding rather than a silent omission.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from ai_harness.schemas.enums import Tier
from ai_harness.schemas.gates import TIER_ORDER, GateSpec

GATES_RE = re.compile(r"^GATES=\((?P<names>[^)]*)\)", re.M)
REQUIRED_BLOCK_RE = re.compile(r"declare\s+-A\s+REQUIRED_BY_TIER=\((?P<body>.*?)\n\)", re.S)
REQUIRED_ROW_RE = re.compile(r"\[(?P<tier>\w+)\]=\"(?P<names>[^\"]*)\"")
STACK_RE = re.compile(r"STACK_GATES=\((?P<names>[^)]*)\)")
HOOK_RE = re.compile(r"^\s*if\s+\[\[\s+-x\s+(?P<hook>[\w./-]+\.sh)\s+\]\]", re.M)

DEFAULT_TIMEOUT_S = 3600
TIMEOUT_HEADROOM = 4
"""A gate's declared timeout is several times its observed duration. A timeout set at the
observed time fires on the first slow day, and the failure looks like a broken gate rather than
a busy machine."""


@dataclass(frozen=True, slots=True)
class Unexpressible:
    """A gate that cannot become a ``GateSpec``, and the reason — which is the useful part."""

    name: str
    why: str


@dataclass
class Adoption:
    """What one spine looks like as a declaration, and what did not survive the reading."""

    gates: list[GateSpec] = field(default_factory=list)
    unexpressible: list[Unexpressible] = field(default_factory=list)
    inferred_requiredness: bool = False
    """True when the spine declared no tier table and this package's transcription was used —
    a guess, and it is labelled as one in the emitted file."""
    source: str = ""
    notes: list[str] = field(default_factory=list)

    @property
    def complete(self) -> bool:
        return not self.unexpressible

    def as_yaml(self, *, tier: Tier = Tier.LAUNCH) -> str:
        """Render the proposal. Hand-rendered so the comments survive — they are the finding."""
        lines = [
            f"# Proposed by `agent gates adopt {self.source}`. NOT authoritative until a human",
            "# has read it: a gate declaration is the contract by which the harness is permitted",
            "# to merge, and a tool that writes its own contract has removed the only reader who",
            "# was load-bearing (Q9).",
            "#",
            f"# Adopted {len(self.gates)} gate(s) from the spine's GATES=() registry.",
        ]
        if self.inferred_requiredness:
            lines += [
                "#",
                "# WARNING: the spine declared no REQUIRED_BY_TIER, so requiredness below is",
                "# INFERRED from this package's transcription of a different spine. Check every",
                "# `required_from_tier` before trusting it — an inferred contract that reads as a",
                "# declared one is exactly the confusion rung 3 labels as `inferred`.",
            ]
        for note in self.notes:
            lines.append(f"# {note}")
        if self.unexpressible:
            lines += [
                "#",
                "# NOT ADOPTED — these have no single command to declare. Each one is a decision",
                "# still to make: port it, move it with the product, or drop it deliberately.",
            ]
            lines += [f"#   {item.name}: {item.why}" for item in self.unexpressible]

        lines += ["", f"tier: {tier.value}", "", "gates:"]
        for spec in self.gates:
            lines.append(f"  - name: {spec.name}")
            lines.append(f"    kind: {spec.kind}")
            command = ", ".join(f'"{part}"' for part in spec.command or [])
            lines.append(f"    command: [{command}]")
            if spec.resource != "cpu":
                lines.append(f"    resource: {spec.resource}")
            if spec.required_from_tier is not None:
                lines.append(f"    required_from_tier: {spec.required_from_tier.value}")
            lines.append(f"    timeout_s: {spec.timeout_s}")
        return "\n".join(lines) + "\n"


def read_registry(text: str) -> list[str]:
    match = GATES_RE.search(text)
    if not match:
        return []
    return [name for name in match.group("names").split() if name]


def read_required_by_tier(text: str) -> dict[Tier, set[str]]:
    """The spine's own tier table. Empty when it does not declare one."""
    block = REQUIRED_BLOCK_RE.search(text)
    if not block:
        return {}
    table: dict[Tier, set[str]] = {}
    for row in REQUIRED_ROW_RE.finditer(block.group("body")):
        try:
            tier = Tier(row.group("tier"))
        except ValueError:
            continue
        table[tier] = {name for name in row.group("names").split() if name}
    return table


def read_stack_gates(text: str) -> set[str]:
    match = STACK_RE.search(text)
    return {name.strip("\"'") for name in match.group("names").split()} if match else set()


def lowest_required_tier(gate: str, table: dict[Tier, set[str]]) -> Tier | None:
    """The lowest tier that demands this gate — which is what ``required_from_tier`` means."""
    for tier in TIER_ORDER:
        if gate in table.get(tier, set()):
            return tier
    return None


def read_scorecard(path: Path) -> dict[str, float]:
    """``{gate: duration_s}`` from a ``--json`` run. Absent is fine; it only tunes timeouts."""
    try:
        payload = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    rows = payload if isinstance(payload, list) else payload.get("results") or []
    durations: dict[str, float] = {}
    for row in rows:
        if isinstance(row, dict) and row.get("gate"):
            try:
                durations[str(row["gate"])] = float(row.get("duration_s") or 0)
            except (TypeError, ValueError):
                continue
    return durations


def adopt(
    spine: Path,
    *,
    scorecard: Path | None = None,
    root: Path | None = None,
) -> Adoption:
    """Read a shell spine and propose the equivalent declaration."""
    text = spine.read_text()
    base = root or spine.parent.parent
    names = read_registry(text)
    table = read_required_by_tier(text)
    stack = read_stack_gates(text)
    durations = read_scorecard(scorecard) if scorecard is not None else {}

    adoption = Adoption(source=str(spine), inferred_requiredness=not table)
    if not table:
        from ai_harness.quality.registry import REQUIRED_BY_TIER

        table = {tier: set(gates) for tier, gates in REQUIRED_BY_TIER.items()}
    if not names:
        adoption.notes.append(
            "the spine declares no GATES=() registry, so nothing could be enumerated"
        )
        return adoption

    for name in names:
        hook = _project_hook(base, name)
        if hook is None:
            adoption.unexpressible.append(
                Unexpressible(
                    name=name,
                    why=(
                        f"no `scripts/{name}.sh` hook; the gate body is bash inside the spine and "
                        "has no single command to declare"
                    ),
                )
            )
            continue
        observed = durations.get(name, 0.0)
        adoption.gates.append(
            GateSpec(
                name=name,
                kind="shell",
                command=["bash", hook],
                resource="stack" if name in stack else "cpu",
                required_from_tier=lowest_required_tier(name, table),
                timeout_s=_timeout_for(observed),
            )
        )

    if durations:
        adoption.notes.append(
            f"timeouts derived from a scorecard: {TIMEOUT_HEADROOM}x the observed duration"
        )
    return adoption


def _project_hook(base: Path, gate: str) -> str | None:
    """The spine's own convention: ``scripts/<gate>.sh`` overrides the inline body when present.

    That convention is what makes adoption possible at all — where a repository has already
    factored a gate into its own script, the declaration can call the same script, and the
    behaviour that moves is *identical* rather than merely equivalent.
    """
    candidate = base / "scripts" / f"{gate}.sh"
    return f"scripts/{gate}.sh" if candidate.exists() else None


def _timeout_for(observed_s: float) -> int:
    if observed_s <= 0:
        return DEFAULT_TIMEOUT_S
    return max(int(observed_s * TIMEOUT_HEADROOM), 60)
