"""The reviewer agent.

Ported first, and deliberately: it is the most self-contained stage, its output is the clearest
schema, it makes no repository writes, and **its two known defects are exactly what the schema
layer fixes** — the ``{``-character extraction bug (#2419) and the approve-with-blockers
self-contradiction.

What the shell prompt gets right is kept: the adversarial framing, the explicit non-goals ("do
NOT raise style/formatting nits"), the falsifiability requirement ("MUST cite a file:line"), the
round context, and the decision rule. What changes is where the guarantees live — the citation
requirement is a schema constraint, and the verdict reconciliation happens in
:class:`~ai_harness.schemas.review.ReviewResult` rather than in an ``if`` at one call site.
"""

from __future__ import annotations

from dataclasses import dataclass

from ai_harness.agents.base import Agent, AgentCall
from ai_harness.context.diff_bundler import DiffBundle
from ai_harness.context.trust import (
    Provenance,
    Trusted,
    TrustedPrompt,
    Untrusted,
)
from ai_harness.kernel.outcome import Outcome
from ai_harness.llm.client import LLMClient
from ai_harness.schemas.review import ReviewResult

TEMPLATE_ID = "reviewer-v1"


@dataclass(frozen=True, slots=True)
class ReviewBrief:
    """Everything the reviewer is given. Untrusted parts are marked as such here, not later."""

    issue_title: str
    issue_body: str
    acceptance_criteria: str
    diff: DiffBundle
    round: int = 1
    issue_number: int | None = None
    gate_summary: str = ""
    prior_findings: list[str] | None = None


def build_prompt(brief: ReviewBrief, *, repo: str, base_sha: str, head_sha: str) -> TrustedPrompt:
    """Assemble the review prompt, stable prefix first.

    The ordering matters twice: it is the trust boundary (instructions before data, always), and
    it is the caching boundary (§17.3 — the role contract and the pinned facts are identical
    across the review⇄fix rounds, which are the dominant cost centre).
    """
    from ai_harness.agents.base import PROMPTS

    prompt = TrustedPrompt()
    prompt.add_trusted(Trusted((PROMPTS / f"{TEMPLATE_ID}.md").read_text()))
    prompt.add_trusted(
        Trusted(
            "Facts that remain true for this review:\n"
            f"repository: {repo}\n"
            f"base_sha: {base_sha}\n"
            f"head_sha: {head_sha}\n"
            f"review round: {brief.round}\n"
            f"diff completeness: {'complete' if brief.diff.complete else 'PARTIAL — see the elision marker'}"
        )
    )
    if brief.acceptance_criteria:
        prompt.add_trusted(
            Trusted(f"Acceptance criterion to judge against:\n{brief.acceptance_criteria}")
        )
    if brief.prior_findings:
        prompt.add_trusted(
            Trusted(
                "Findings from earlier rounds, which the change claims to have addressed:\n"
                + "\n".join(f"- {finding}" for finding in brief.prior_findings)
            )
        )
    if brief.gate_summary:
        prompt.add_trusted(Trusted(f"Gate results on this head commit:\n{brief.gate_summary}"))

    where = f"issue #{brief.issue_number}" if brief.issue_number else "issue"
    prompt.add_untrusted(Untrusted(brief.issue_title, Provenance.ISSUE_TITLE, source=where))
    prompt.add_untrusted(Untrusted(brief.issue_body, Provenance.ISSUE_BODY, source=where))
    prompt.add_untrusted(
        Untrusted(brief.diff.render(), Provenance.DIFF, source=f"{repo}@{head_sha[:12]}")
    )
    return prompt


@dataclass
class Reviewer:
    """The agent, its model, and nothing else."""

    client: LLMClient
    model: str
    template_id: str = TEMPLATE_ID

    def agent(self) -> Agent[ReviewResult]:
        return Agent(
            name="reviewer",
            template_id=self.template_id,
            output_type=ReviewResult,
            client=self.client,
            model=self.model,
        )

    async def review(
        self,
        brief: ReviewBrief,
        *,
        repo: str,
        base_sha: str,
        head_sha: str,
        run: object = None,
    ) -> Outcome[AgentCall]:
        prompt = build_prompt(brief, repo=repo, base_sha=base_sha, head_sha=head_sha)
        return await self.agent().call(
            prompt, run=run, state="REVIEW", round_=brief.round, attempt=brief.round
        )
