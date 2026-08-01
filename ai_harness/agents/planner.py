"""The planner — the only model call that influences routing, and it is schema-constrained.

§9.2. The shell harness plans implicitly, inside the build prompt, which means the decision
"this is an epic, do not build it" is made by the same call that would otherwise start building
and is visible only as an absence of work. Making the plan a typed artefact is what lets
``ANALYSE`` decide *out of scope*, *epic* or *needs approval* deterministically, and what lets an
identical input cache-hit instead of re-planning.
"""

from __future__ import annotations

from dataclasses import dataclass

from ai_harness.agents.base import PROMPTS, Agent, AgentCall
from ai_harness.context.retrieval.protocol import RetrievalBundle
from ai_harness.context.trust import Provenance, Trusted, TrustedPrompt, Untrusted
from ai_harness.kernel.ids import digest
from ai_harness.kernel.outcome import Outcome
from ai_harness.llm.client import LLMClient
from ai_harness.schemas.plan import WorkPlan

TEMPLATE_ID = "planner-v1"


@dataclass(frozen=True, slots=True)
class PlanBrief:
    """What the planner is given."""

    issue_title: str
    issue_body: str
    issue_number: int | None = None
    repo: str = ""
    base_sha: str = ""
    protected_paths: tuple[str, ...] = ()
    prior_failure: str = ""
    """A gate failure or review findings, when replanning rather than planning."""
    prior_findings: tuple[str, ...] = ()
    retrieval: RetrievalBundle | None = None

    def input_hash(self) -> str:
        """Identity of the *inputs*. Identical inputs need not be planned twice (§9.2)."""
        material = "\x1f".join(
            [
                self.repo,
                str(self.issue_number),
                self.issue_title,
                self.issue_body,
                self.base_sha,
                self.prior_failure,
                *self.prior_findings,
            ]
        )
        return digest(material)[:16]


def build_prompt(brief: PlanBrief) -> TrustedPrompt:
    prompt = TrustedPrompt()
    prompt.add_trusted(Trusted((PROMPTS / f"{TEMPLATE_ID}.md").read_text()))
    facts = [f"repository: {brief.repo}", f"base_sha: {brief.base_sha}"]
    if brief.protected_paths:
        facts.append("paths that park for approval if touched: " + ", ".join(brief.protected_paths))
    prompt.add_trusted(Trusted("Facts about this repository:\n" + "\n".join(facts)))

    if brief.prior_failure:
        prompt.add_trusted(
            Trusted(
                "This is a REPLAN. The previous attempt failed as follows, and the plan should "
                "account for it rather than repeat it."
            )
        )
    if brief.prior_findings:
        prompt.add_trusted(
            Trusted(
                "Review findings the change must address:\n"
                + "\n".join(f"- {f}" for f in brief.prior_findings)
            )
        )

    where = f"issue #{brief.issue_number}" if brief.issue_number else "issue"
    prompt.add_untrusted(Untrusted(brief.issue_title, Provenance.ISSUE_TITLE, source=where))
    prompt.add_untrusted(Untrusted(brief.issue_body, Provenance.ISSUE_BODY, source=where))
    if brief.prior_failure:
        prompt.add_untrusted(
            Untrusted(brief.prior_failure, Provenance.GATE_LOG, source="the previous attempt")
        )
    for chunk in (brief.retrieval.chunks if brief.retrieval else [])[:20]:
        prompt.add_untrusted(
            Untrusted(
                f"{chunk.citation}: {chunk.text}",
                Provenance.RETRIEVAL,
                source=chunk.citation,
            )
        )
    return prompt


@dataclass
class Planner:
    client: LLMClient
    model: str
    template_id: str = TEMPLATE_ID

    def agent(self) -> Agent[WorkPlan]:
        return Agent(
            name="planner",
            template_id=self.template_id,
            output_type=WorkPlan,
            client=self.client,
            model=self.model,
        )

    async def plan(
        self, brief: PlanBrief, *, run: object = None, attempt: int = 1
    ) -> Outcome[AgentCall]:
        return await self.agent().call(
            build_prompt(brief), run=run, state="ANALYSE", attempt=attempt
        )
