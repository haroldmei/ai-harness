"""The MR evidence block (§19.6) — how a human audits an autonomous change in ten seconds.

This is also the precondition for anyone opting into ``FF_ONLY``: nobody should enable automatic
merges into a repository whose gate results they cannot read at a glance.

Three things are stated rather than implied, because each is a way the block could otherwise
mislead:

* **inferred gates are labelled**, so "14 green" does not read as a contract when it is a guess;
* **forgiven failures are shown**, not hidden — a run that is green *because of the baseline* is
  a different fact from a run that is green;
* **what the reviewer could not see** is named, so an approval's scope is visible.

Everything here goes through the redactor: the block is posted publicly, and a gate log is
exactly the kind of place a token ends up.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal

from ai_harness.kernel.redaction import Redactor
from ai_harness.schemas.enums import GateStatus
from ai_harness.schemas.gates import GateReport
from ai_harness.schemas.review import ReviewResult

MARK = {
    GateStatus.PASS: "✅",
    GateStatus.FAIL: "❌",
    GateStatus.SKIP: "·",
    GateStatus.TIMEOUT: "⏱",
    GateStatus.ERROR: "❌",
}


@dataclass
class EvidenceBlock:
    """Everything the MR body says about how this change was judged."""

    run_id: str
    report: GateReport
    review: ReviewResult | None = None
    base_report: GateReport | None = None
    spend_usd: Decimal = Decimal(0)
    models: dict[str, str] = field(default_factory=dict)
    isolation: str = ""
    diff_complete: bool = True
    elided_files: list[str] = field(default_factory=list)
    redactor: Redactor = field(default_factory=Redactor)

    def render(self) -> str:
        parts = [f"## 🤖 Harness evidence — run {self.run_id[:8]}", ""]
        parts += self._banners()
        parts += self._gates()
        parts += self._regression()
        parts += self._review()
        parts += self._footer()
        return self.redactor.text("\n".join(parts).rstrip() + "\n")

    def _banners(self) -> list[str]:
        lines: list[str] = []
        if self.report.no_gates_discovered:
            lines.append(
                "> **no_gates_discovered** — nothing in this repository could be run as a "
                "quality gate. This change is proposed, not verified."
            )
        elif self.report.profile_discovered:
            lines.append(
                "> **gates inferred** — the gate set was inferred from CI config or a manifest "
                "rather than declared in `.harness/gates.yaml`. Requiredness is a guess."
            )
        if not self.diff_complete:
            lines.append(
                f"> **partial review** — {len(self.elided_files)} file(s) were not shown to the "
                f"reviewer: {', '.join(self.elided_files[:5])}."
            )
        if self.isolation and self.isolation == "none":
            lines.append(
                "> **no isolation** — this run executed without a sandbox. That was a "
                "configured decision, and it is recorded here because it changes what the "
                "other evidence is worth."
            )
        return [*lines, ""] if lines else []

    def _gates(self) -> list[str]:
        report = self.report
        required = [r for r in report.results if r.required]
        green = [r for r in required if r.green]
        header = (
            f"**Gates** (tier `{report.tier.value}`, {report.gate_set.value} set) — "
            f"{len(required)} required, {len(green)} green · "
            f"wall-clock {report.wall_clock_s:.0f}s · gate-time {report.gate_time_s:.0f}s "
            f"({report.speedup:.1f}x parallel)"
        )
        rows = ["", header, "", "| gate | status | duration | notes |", "|---|---|---|---|"]
        for result in report.results:
            notes = []
            if result.promoted:
                notes.append("**promoted**: a skipped required check is a failure")
            if result.inherited:
                notes.append("inherited from the base — forgiven, not hidden")
            if result.flake_confirmed:
                notes.append("flake: failed then passed on the confirmation re-run")
            if result.reason:
                notes.append(result.reason[:120])
            duration = f"{result.duration_s:.0f}s" if result.duration_s is not None else "—"
            rows.append(
                f"| {result.name} | {MARK[result.status]} {result.status.value} | {duration} "
                f"| {'; '.join(notes)} |"
            )
        return rows

    def _regression(self) -> list[str]:
        if self.base_report is None:
            return []
        added = self.report.regression_against(self.base_report)
        if not added:
            return ["", "**Regression vs base** — this branch adds no new failures."]
        return [
            "",
            "**Regression vs base** — this branch ADDS: " + ", ".join(f"`{r.name}`" for r in added),
        ]

    def _review(self) -> list[str]:
        if self.review is None:
            return []
        lines = ["", f"**Review** — {self.review.verdict.value}"]
        if self.review.downgraded:
            lines.append(
                f"> The model approved while listing blocking findings; the harness downgraded "
                f"it in code. {self.review.downgrade_reason}"
            )
        for finding in self.review.findings:
            lines.append(f"- `{finding.severity.value}` {finding.citation} — {finding.title}")
        return lines

    def _footer(self) -> list[str]:
        models = ", ".join(f"{role}: `{model}`" for role, model in sorted(self.models.items()))
        return [
            "",
            "---",
            f"cost ${self.spend_usd} · isolation `{self.isolation or 'unknown'}` · {models}",
            "",
            "_Generated by ai-harness. The gate results above are the ones that ran on this "
            "exact commit._",
        ]


def may_enable_ff_only(report: GateReport, *, base_is_green: bool | None) -> str | None:
    """``None`` if ``FF_ONLY`` is defensible for this run; otherwise why it is not.

    Auto-merge is safe *given* a trusted gate suite, a known-green base and a tuned resolver —
    none of which a tool may assume about an unseen repository (§25).
    """
    if report.no_gates_discovered:
        return "no gates were discovered"
    if report.profile_discovered:
        return "the gate set was inferred rather than declared"
    if not report.green:
        return "the gates are not green on this commit"
    if base_is_green is not True:
        return "the base is not confirmed green"
    return None
