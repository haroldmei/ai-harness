"""``compare_spines`` — the shadow pattern, one layer down (#98).

Phase 2 solved this shape of problem for the reviewer: run both, compare the *decisions*, change
nothing, and cut over when **every disagreement is explained** — not when there are none (#43,
#76). Two gate spines are two engines; the scorecard is the decision.

The failure this exists to catch is not a declaration that disagrees loudly. It is one that
agrees about every gate it runs while quietly not running one, because from the outside that is
indistinguishable from a suite that got faster. So the comparison is over the **union** of gate
names, and absence is a first-class kind rather than a row that is simply not there.

Three things are deliberately not treated as failures, and saying so up front is what stops the
threshold moving afterwards:

* a declaration that is **stricter** than the spine — red where the shell was green — is not a
  weakening, and blocking on it would push people to adopt the weaker reading;
* a **duration** difference, within tolerance or outside it, never disqualifies;
* a different **reason** string on the same verdict is cosmetic, unless a human reads it, and
  that judgement belongs to whoever explains it rather than to this function.
"""

from __future__ import annotations

from ai_harness.schemas.gates import GateReport, GateResult
from ai_harness.schemas.spine import (
    DURATION_TOLERANCE,
    Difference,
    GateDifference,
    GateOutcome,
    SpineComparison,
)


def outcome_of(result: GateResult) -> GateOutcome:
    """A gate result, reduced. ``status`` is the promoted one — skip-is-not-pass has already
    been applied by the schema, and comparing raw statuses would compare two different things."""
    return GateOutcome(
        name=result.name,
        status=result.status,
        required=result.required,
        reason=(result.reason or "").strip(),
        duration_s=result.duration_s or 0.0,
    )


def compare_spines(
    shell: GateReport,
    declared: GateReport,
    *,
    repo: str = "",
    commit_sha: str = "",
) -> SpineComparison:
    """Diff two scorecards gate by gate, over the union of what either ran."""
    left = {result.name: outcome_of(result) for result in shell.results}
    right = {result.name: outcome_of(result) for result in declared.results}

    differences: list[GateDifference] = []
    for gate in sorted(set(left) | set(right)):
        differences.append(_one(gate, left.get(gate), right.get(gate)))

    return SpineComparison(
        repo=repo,
        commit_sha=commit_sha or shell.commit_sha or declared.commit_sha,
        differences=differences,
    )


def _one(gate: str, shell: GateOutcome | None, declared: GateOutcome | None) -> GateDifference:
    if shell is not None and declared is None:
        return GateDifference(
            gate=gate,
            kind=Difference.MISSING,
            shell=shell,
            note=(
                "the shell spine runs this gate and the declaration does not. A suite that "
                "silently stops running a gate looks exactly like a suite that got faster"
            ),
        )
    if shell is None and declared is not None:
        return GateDifference(
            gate=gate,
            kind=Difference.ADDED,
            declared=declared,
            note="declared but not in the shell spine — not a weakening, but say it was intended",
        )

    assert shell is not None and declared is not None
    if shell.status is not declared.status:
        direction = (
            "the declaration is GREEN where the spine is RED — this is the gate that would have "
            "caught something and now does not"
            if declared.green and not shell.green
            else "the declaration is stricter than the spine"
        )
        return GateDifference(
            gate=gate,
            kind=Difference.STATUS,
            shell=shell,
            declared=declared,
            note=f"{shell.status} vs {declared.status}: {direction}",
        )

    if shell.required != declared.required:
        return GateDifference(
            gate=gate,
            kind=Difference.REQUIREDNESS,
            shell=shell,
            declared=declared,
            note=(
                "same verdict, but only one of them would block a merge. A gate demoted to "
                "advisory is a gate removed, slowly"
            ),
        )

    if _diverges(shell.duration_s, declared.duration_s):
        return GateDifference(
            gate=gate,
            kind=Difference.DURATION,
            shell=shell,
            declared=declared,
            note=(
                f"{shell.duration_s:.0f}s vs {declared.duration_s:.0f}s — never disqualifying, "
                "recorded because a declaration that is much slower gets turned off by somebody "
                "in a hurry"
            ),
        )

    if shell.reason != declared.reason and (shell.reason or declared.reason):
        return GateDifference(
            gate=gate,
            kind=Difference.REASON,
            shell=shell,
            declared=declared,
            note="same verdict, different diagnostic line",
        )

    return GateDifference(gate=gate, kind=Difference.AGREE, shell=shell, declared=declared)


def _diverges(left: float, right: float) -> bool:
    if left <= 0 and right <= 0:
        return False
    baseline = max(left, right, 1.0)
    return abs(left - right) / baseline > DURATION_TOLERANCE


def render(comparison: SpineComparison) -> str:
    """What ``agent gates compare --report`` prints. The unexplained ones are the point."""
    lines = [
        f"── spine comparison — {comparison.repo or 'this repository'} "
        f"@ {comparison.commit_sha[:12] or 'working tree'} ──",
        "",
    ]
    if not comparison.disagreements:
        lines.append("  the declaration and the spine agree on every gate")
    for difference in comparison.disagreements:
        mark = "BLOCK" if difference.disqualifying and not difference.explanation else "note "
        lines.append(f"  {mark} {difference.kind.value:<13} {difference.gate}")
        if difference.note:
            lines.append(f"        {difference.note}")
        if difference.explanation:
            lines.append(f"        explained: {difference.explanation}")

    unexplained = comparison.unexplained
    lines += [
        "",
        f"  {len(comparison.disagreements)} disagreement(s), {len(unexplained)} unexplained, "
        f"{len(comparison.blocking)} blocking",
    ]
    if unexplained:
        lines.append(
            "  The criterion is every disagreement EXPLAINED, not zero disagreements (#43)."
        )
    return "\n".join(lines) + "\n"
