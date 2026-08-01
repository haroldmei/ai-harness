"""The triager — six classes, evidence first, and every self-filing loop capped.

W6: ~40 regexes classify runner output across the shell harness, and a misparse burns the fix
budget on an innocent test — #2124 spent every retry on a test that passed 15/15 on ``main``.
The fix is not better regexes; it is **deciding from evidence before deciding from judgement**:

1. the **baseline** answers "was this already red on this exact base?" (invariant 9) — a branch
   is judged by the failures it *adds*, and this runs upstream of everything else;
2. the **typed extractors** in ``quality/reason.py`` answer "did the tooling even run?"
   (invariant 10) and "which tests failed?";
3. only what evidence cannot settle goes to a model, schema-constrained.

Invariant 8 governs the filing: fingerprint + ledger + a **global** cap. One breakage becoming
one auto-filed issue per observed subset is what produced the #2381→#2385 chain, and the cluster
signature exists so those subsets collapse to one entry rather than four.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ai_harness.kernel.fingerprint import Fingerprint, cluster_signature, fingerprint
from ai_harness.kernel.outcome import Outcome
from ai_harness.quality.baseline import BaselineStatus, BaselineVerdict
from ai_harness.quality.reason import failing_test_ids, looks_environmental, reason_summary
from ai_harness.schemas.enums import TriageClass
from ai_harness.schemas.gates import GateReport
from ai_harness.schemas.plan import TriageDecision

DEPS_MARKERS = (
    "cannot find module",
    "modulenotfounderror",
    "unmet dependency",
    "npm err! missing",
    "no matching distribution",
    "could not resolve dependency",
)
STALE_BASE_MARKERS = (
    "non-fast-forward",
    "your branch is behind",
    "merge conflict",
    "cannot rebase",
)
TRANSIENT_MARKERS = (
    "connection reset",
    "temporarily unavailable",
    "timed out",
    "econnreset",
    "etimedout",
    "rate limit",
)


@dataclass(frozen=True, slots=True)
class TriageCaps:
    """The §3.11 bounds, as data. Each exists because a loop ran without it."""

    max_attempts_per_fingerprint: int = 3
    max_open_blockers: int = 5
    max_self_repair: int = 2
    max_transient: int = 8


@dataclass(frozen=True, slots=True)
class TriageInput:
    """Everything the triager decides from."""

    repo: str
    gate_report: GateReport
    log_text: str = ""
    baseline: BaselineVerdict | None = None
    base_is_green: bool | None = None
    """``None`` means unknown — and unknown fails closed rather than blaming the base."""
    attempts: int = 0
    """How many times this signature has already been seen. Supplied by the caller.

    The ledger is durable state, and an agent that fetches its own state is an agent whose
    behaviour depends on something its caller cannot see. The counts arrive in the input for
    the same reason a review context arrives assembled: it makes the judgement reproducible.
    """
    open_blockers: int = 0


@dataclass
class Triager:
    """Classifies a red gate. Deterministic where the evidence allows it, and pure throughout.

    No store, no clock, no I/O: given the same evidence it returns the same class forever,
    which is what makes the imported shell corpus a usable test set.
    """

    caps: TriageCaps = field(default_factory=TriageCaps)

    async def classify(self, data: TriageInput) -> Outcome[TriageDecision]:
        report = data.gate_report
        failures = report.failures
        text = data.log_text or "\n".join(f.reason for f in failures)

        # 1. Inherited red, upstream of everything (invariant 9).
        if data.baseline is not None and data.baseline.status is BaselineStatus.FORGIVEN:
            return Outcome.ok(
                TriageDecision(
                    triage_class=TriageClass.UNRELATED,
                    reason=(
                        "every failure was already red on this exact base — the branch adds "
                        "nothing red"
                    ),
                    evidence_lines=data.baseline.forgiven[:5],
                    confidence=1.0,
                )
            )

        # 2. "The tooling could not run" is a third outcome (invariant 10). Checked before any
        #    judgement about the code, because a wedged Docker daemon looks like a red gate.
        if looks_environmental(text) or any(
            r.reason and looks_environmental(r.reason) for r in failures
        ):
            return Outcome.ok(
                self._decide(
                    TriageClass.INFRA,
                    data,
                    text,
                    reason="the tooling could not run — this is not a statement about the code",
                    remedy="fix the host or the container runtime; no code change will help",
                )
            )

        lowered = text.lower()
        if any(marker in lowered for marker in DEPS_MARKERS):
            return Outcome.ok(
                self._decide(
                    TriageClass.DEPS,
                    data,
                    text,
                    reason="a declared dependency will not resolve",
                    remedy="an install that exits 0 is not evidence the tree resolves",
                )
            )
        if any(marker in lowered for marker in STALE_BASE_MARKERS):
            return Outcome.ok(
                self._decide(
                    TriageClass.STALE_BASE,
                    data,
                    text,
                    reason="the branch is behind the base it is judged against",
                    remedy="rebase and re-gate rather than fixing anything",
                )
            )
        if any(marker in lowered for marker in TRANSIENT_MARKERS):
            return Outcome.ok(
                self._decide(
                    TriageClass.TRANSIENT,
                    data,
                    text,
                    reason="a self-healing failure",
                    remedy="retried next tick; consumes no fix budget",
                )
            )

        # 3. A red gate on a green base, with tests that name themselves, is the branch's.
        if data.base_is_green is True:
            return Outcome.ok(
                self._decide(
                    TriageClass.SELF,
                    data,
                    text,
                    reason="the base is green and these failures are new",
                    remedy="the change introduced this; the fixer can own it",
                )
            )

        if data.base_is_green is None and data.baseline is None:
            # Fail closed: with no baseline and no confirmed base state, do NOT blame the base.
            # A red base that forgives itself is how one breakage became five blocked issues.
            return Outcome.ok(
                self._decide(
                    TriageClass.SELF,
                    data,
                    text,
                    reason=(
                        "no baseline for this base sha and the base state is unconfirmed — "
                        "attributing to the branch rather than accusing an innocent base"
                    ),
                    remedy="record a baseline on the base to make this decidable",
                    confidence=0.5,
                )
            )

        return Outcome.ok(
            self._decide(
                TriageClass.UNRELATED,
                data,
                text,
                reason="the base is red and these failures are not the branch's",
                remedy="file one blocker against the base, not one per branch",
            )
        )

    def _decide(
        self,
        triage_class: TriageClass,
        data: TriageInput,
        text: str,
        *,
        reason: str,
        remedy: str,
        confidence: float = 1.0,
    ) -> TriageDecision:
        signature = self.signature(data)
        return TriageDecision(
            triage_class=triage_class,
            fingerprint=signature.signature if signature else None,
            reason=reason,
            remedy=remedy,
            confidence=confidence,
            evidence_lines=[reason_summary(text)] if text else [],
        )

    def signature(self, data: TriageInput) -> Fingerprint | None:
        """One signature for the whole failure set, not one per failing test.

        A per-failure fingerprint changes as each lane fixes a different subset, which is
        exactly why none of the shell's guardrails fired during #2381→#2385.
        """
        failures = data.gate_report.failures
        tests = failing_test_ids(data.log_text) if data.log_text else []
        if tests:
            gate = failures[0].name if failures else "gates"
            return Fingerprint(
                signature=cluster_signature(gate, tests),
                normalised=f"{gate}: {len(tests)} failing test(s)",
            )
        parts = [f"{f.name}:{f.reason}" for f in failures]
        return fingerprint(*parts, scope=data.gate_report.tier.value)

    def may_file(self, decision: TriageDecision, *, attempts: int, open_blockers: int) -> bool:
        """Is filing a blocker for this still within the caps? (invariant 8)

        Both counts come from the caller, which read them from the ledger. A signature-less
        failure can never be bounded, so it never opens a loop.
        """
        if decision.fingerprint is None:
            return False
        if attempts >= self.caps.max_attempts_per_fingerprint:
            return False
        return open_blockers < self.caps.max_open_blockers

    def within_budget(self, decision: TriageDecision, *, attempts: int) -> bool:
        """Which caps apply depends on the class — and a transient never costs a fix budget."""
        if decision.triage_class is TriageClass.TRANSIENT:
            return attempts < self.caps.max_transient
        if decision.triage_class is TriageClass.SELF:
            return attempts < self.caps.max_self_repair
        return attempts < self.caps.max_attempts_per_fingerprint
