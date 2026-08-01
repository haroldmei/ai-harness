"""``REVIEW`` — independent adversarial review, in isolation, bounded.

Ports ``agent-pr-reviewer.sh`` in full. The parts that matter are the ones that are easy to get
subtly wrong, and each is a property of this module rather than of a prompt:

* **A separate sandboxed clone**, never the implementer's workspace (§9.5). A linked worktree's
  ``.git`` is a *pointer file* into the primary, so hiding the primary breaks git inside it —
  only a self-contained clone can be isolated. The reviewer also gets no write capability at
  all.
* **A transient or an empty envelope consumes no round.** #2407: a completed seven-minute
  review whose envelope never reached stdout was classified as a hard failure, and $2.29 of
  opus review was discarded. The streak is bounded separately, at 2.
* **A verdict for an unchanged commit is reused**, not re-bought — the idempotency key is
  ``review:{run}:{commit_sha}:{round}``.
* **Two distinct escalation messages**, because "the model produced no verdict" and "the CLI
  never delivered one" send a human to two different places.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any

from ai_harness.agents.reviewer import ReviewBrief, Reviewer
from ai_harness.context.diff_bundler import DiffBundle, bundle
from ai_harness.kernel.ids import idempotency_key
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.schemas.enums import Isolation, Signal, Verdict
from ai_harness.schemas.review import ReviewResult
from ai_harness.subgraphs.base import SubgraphResult

EMPTY_ENVELOPE_CAP = 2
"""Consecutive empty envelopes before escalating. Unbounded spins forever on a silent CLI."""


@dataclass
class ReviewContext:
    """What the REVIEW state is given. Assembled by the caller, never fetched from here."""

    run_id: str
    repo: str
    base_sha: str
    head_sha: str
    issue_title: str = ""
    issue_body: str = ""
    acceptance_criteria: str = ""
    issue_number: int | None = None
    diff_text: str = ""
    round: int = 1
    max_rounds: int = 4
    empty_streak: int = 0
    prior_findings: list[str] = field(default_factory=list)
    gate_summary: str = ""
    isolation: Isolation = Isolation.NONE
    clone_path: Path | None = None
    diff_artefact_id: str | None = None
    cached_verdict: ReviewResult | None = None
    """A verdict already recorded for this exact (commit, round) — reused rather than re-bought."""
    run_spend: Any = None


@dataclass
class ReviewSubgraph:
    """The REVIEW state."""

    reviewer: Reviewer
    state_name: str = "REVIEW"

    async def execute(self, ctx: ReviewContext) -> Outcome[SubgraphResult]:
        key = idempotency_key("review", run=ctx.run_id, sha=ctx.head_sha, round=ctx.round)

        if ctx.cached_verdict is not None:
            # Idempotency: the same commit at the same round has already been judged.
            return Outcome.ok(_result(ctx.cached_verdict, ctx, key, reused=True))

        if ctx.round > ctx.max_rounds:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"review round cap reached ({ctx.max_rounds})",
                remedy=(
                    "the reviewer and the fixer have exchanged the maximum number of rounds; a "
                    "human should decide whether the change is close enough to land"
                ),
            )

        diff = _bundle_diff(ctx)
        brief = ReviewBrief(
            issue_title=ctx.issue_title,
            issue_body=ctx.issue_body,
            acceptance_criteria=ctx.acceptance_criteria,
            diff=diff,
            round=ctx.round,
            issue_number=ctx.issue_number,
            gate_summary=ctx.gate_summary,
            prior_findings=list(ctx.prior_findings),
        )

        outcome = await self.reviewer.review(
            brief,
            repo=ctx.repo,
            base_sha=ctx.base_sha,
            head_sha=ctx.head_sha,
            run=ctx.run_spend,
        )
        if outcome.is_err:
            assert outcome.error is not None
            return Outcome.of(_classify_failure(outcome.error, ctx))

        call = outcome.unwrap()
        verdict = call.value
        assert isinstance(verdict, ReviewResult)
        result = _result(verdict, ctx, key)
        return Outcome.ok(
            SubgraphResult(
                signal=result.signal,
                reason=result.reason,
                payload={
                    **result.payload,
                    "repairs": call.repairs,
                    "untrusted_sources": call.untrusted_sources,
                    "diff_complete": diff.complete,
                },
                head_sha=ctx.head_sha,
                base_sha=ctx.base_sha,
                usd=call.usd,
                input_tokens=call.input_tokens,
                output_tokens=call.output_tokens,
                cache_read_tokens=call.cache_read_tokens,
                model=call.model,
                template_id=call.template_id,
                prompt_sha256=call.prompt_sha256,
                prompt_bytes=call.prompt_bytes,
                isolation=ctx.isolation.value,
            )
        )


def _bundle_diff(ctx: ReviewContext) -> DiffBundle:
    terms = [term for term in ctx.acceptance_criteria.split() if len(term) > 4][:10]
    return bundle(
        ctx.diff_text,
        acceptance_terms=terms,
        artefact_id=ctx.diff_artefact_id,
    )


def _result(
    verdict: ReviewResult, ctx: ReviewContext, key: str, *, reused: bool = False
) -> SubgraphResult:
    """Map a verdict onto a routing signal. The downgrade already happened in the schema."""
    signal = Signal.ADVANCE if verdict.verdict is Verdict.APPROVE else Signal.FIX
    if verdict.verdict is Verdict.COMMENT:
        # "I cannot reach a verdict on this evidence" is not a request for changes, and it is
        # not an approval. It is a human's problem.
        signal = Signal.ESCALATE
    reason = (
        f"reused the verdict recorded for {ctx.head_sha[:12]} at round {ctx.round}"
        if reused
        else f"{verdict.verdict.value} with {len(verdict.blocking_findings)} blocking finding(s)"
    )
    return SubgraphResult(
        signal=signal,
        reason=reason,
        payload={
            "idempotency_key": key,
            "verdict": verdict.verdict.value,
            "downgraded": verdict.downgraded,
            "downgrade_reason": verdict.downgrade_reason,
            "findings": [
                {"severity": f.severity.value, "citation": f.citation, "title": f.title}
                for f in verdict.findings
            ],
            "severities": verdict.severity_histogram(),
            "reused": reused,
        },
        head_sha=ctx.head_sha,
        base_sha=ctx.base_sha,
        # A reused verdict costs nothing; a fresh one has its cost attached by the caller
        # from the AgentCall, because only that knows what the repair loop spent.
        usd=Decimal(0),
        isolation=ctx.isolation.value,
    )


def _classify_failure(error: Any, ctx: ReviewContext) -> Any:
    """Turn a failed review into the *right* failure — with the right message.

    ``agent-pr-reviewer.sh`` distinguishes these two cases in its escalation text, and it is
    right to: one says the model has nothing useful to say about this change, the other says the
    harness never heard back and should try again.
    """
    from ai_harness.kernel.outcome import ErrorRecord

    if error.category is ErrorCategory.UNKNOWN:
        streak = ctx.empty_streak + 1
        if streak < EMPTY_ENVELOPE_CAP:
            return ErrorRecord(
                category=ErrorCategory.UNKNOWN,
                message=f"the CLI never delivered a verdict (empty envelope {streak}/{EMPTY_ENVELOPE_CAP})",
                remedy=(
                    "the model may well have produced a verdict — this consumes no review round "
                    "and is retried on the next tick"
                ),
                details={"empty_streak": streak},
            )
        return ErrorRecord(
            category=ErrorCategory.NEEDS_HUMAN,
            message=(
                f"the CLI never delivered a verdict {EMPTY_ENVELOPE_CAP} times in a row — the "
                "harness has learned nothing about this change"
            ),
            remedy=(
                "check the model CLI itself (install, credentials, stdout): this is NOT a "
                "statement about the change under review"
            ),
        )
    if error.category is ErrorCategory.VALIDATION:
        return ErrorRecord(
            category=ErrorCategory.NEEDS_HUMAN,
            message="the model produced no usable verdict after the repair attempts",
            remedy=(
                "the reviewer answered, but not in a form that can be acted on — read the "
                "captured output; this IS a statement about the model, not about the CLI"
            ),
            evidence=error.evidence,
        )
    return error
