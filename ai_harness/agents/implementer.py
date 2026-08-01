"""The implementer — three briefs, one prompt family, every edit through the broker.

The model proposes edits as data; :class:`Implementer` applies them through the
:class:`~ai_harness.tools.broker.ToolBroker`. That indirection is the whole point: containment,
capability checks and the audit trail then apply to *the model's* edits and not merely to the
harness's own file writes.

Three briefs, one prompt family — the difference between building, fixing review findings and
repairing a red gate is the brief, not a second implementation. The shell has three
implementations of this and they have already drifted apart.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from pydantic import BaseModel, Field

from ai_harness.agents.base import PROMPTS, Agent, AgentCall
from ai_harness.agents.edits import AnchoredEdit, EditError, apply_anchor
from ai_harness.agents.templates import template_for
from ai_harness.context.trust import Provenance, Trusted, TrustedPrompt, Untrusted
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.client import LLMClient
from ai_harness.schemas.enums import Brief
from ai_harness.schemas.plan import WorkPlan
from ai_harness.tools.broker import ToolBroker, ToolCall

TEMPLATE_ID = "implementer-v2"
"""v2 adds the anchored edit form. A prompt change is a deployment (Q13): the template id moves
so a regression is attributable to the version that caused it, and v1 stays on disk because the
rollback has to be a configuration change rather than a git revert."""


class FileEdit(BaseModel):
    """One whole-file write. Whole files, not patches: a patch that does not apply cleanly is a
    second failure mode, and the model has the file in front of it."""

    path: str = Field(min_length=1)
    content: str
    intent: str = ""


class ImplementationOutput(BaseModel):
    """What the implementer returns. Edits are *proposed*; the broker decides."""

    summary: str = Field(min_length=1)
    edits: list[FileEdit] = Field(default_factory=list)
    anchored_edits: list[AnchoredEdit] = Field(default_factory=list)
    """The cheap expression of the same thing (#88). Re-materialised into whole files inside
    this agent, so the broker, the audit trail and the subgraph see exactly what they saw
    before -- output tokens are the only thing that changes."""
    deletions: list[str] = Field(default_factory=list)
    tests_added: list[str] = Field(default_factory=list)
    blocked: bool = False
    blocked_reason: str = ""
    notes: list[str] = Field(default_factory=list)
    """Unrelated problems noticed but deliberately not fixed."""

    @property
    def produced_work(self) -> bool:
        return bool(self.edits or self.anchored_edits or self.deletions)


BRIEF_HEADERS = {
    Brief.BUILD: "You are implementing a plan for the first time.",
    Brief.FIX: "You are addressing review findings on a change you already made.",
    Brief.REPAIR: "You are repairing a gate that failed on a change you already made.",
}


@dataclass
class ImplementerBrief:
    plan: WorkPlan | None = None
    brief: Brief = Brief.BUILD
    issue_title: str = ""
    issue_body: str = ""
    issue_number: int | None = None
    findings: tuple[str, ...] = ()
    gate_failure: str = ""
    current_files: dict[str, str] = field(default_factory=dict)
    """Path → content for the files the plan names. Untrusted, like all repository content."""


def build_prompt(
    brief: ImplementerBrief, *, repo: str, template_id: str = TEMPLATE_ID
) -> TrustedPrompt:
    prompt = TrustedPrompt()
    prompt.add_trusted(Trusted((PROMPTS / f"{template_id}.md").read_text()))
    prompt.add_trusted(Trusted(BRIEF_HEADERS[brief.brief]))
    if brief.plan is not None:
        lines = [f"summary: {brief.plan.summary}", f"approach: {brief.plan.approach}"]
        lines += [f"change {c.path}: {c.intent}" for c in brief.plan.changes]
        if brief.plan.acceptance_mapping:
            lines.append("demonstrated by: " + ", ".join(brief.plan.acceptance_mapping))
        if brief.plan.out_of_scope:
            lines.append("explicitly OUT of scope: " + ", ".join(brief.plan.out_of_scope))
        prompt.add_trusted(Trusted("The plan:\n" + "\n".join(lines)))
    if brief.findings:
        prompt.add_trusted(
            Trusted("Findings to address:\n" + "\n".join(f"- {f}" for f in brief.findings))
        )
    prompt.add_trusted(Trusted(f"Repository: {repo}"))

    where = f"issue #{brief.issue_number}" if brief.issue_number else "issue"
    if brief.issue_title:
        prompt.add_untrusted(Untrusted(brief.issue_title, Provenance.ISSUE_TITLE, source=where))
    if brief.issue_body:
        prompt.add_untrusted(Untrusted(brief.issue_body, Provenance.ISSUE_BODY, source=where))
    if brief.gate_failure:
        prompt.add_untrusted(
            Untrusted(brief.gate_failure, Provenance.GATE_LOG, source="the failing gate")
        )
    for path, content in brief.current_files.items():
        prompt.add_untrusted(Untrusted(content, Provenance.FILE_CONTENT, source=path))
    return prompt


@dataclass
class Implementer:
    """Asks the model for edits, then applies them through the broker."""

    client: LLMClient
    model: str
    broker: ToolBroker
    workspace: Path
    repo: str = ""
    template_id: str = TEMPLATE_ID

    def __post_init__(self) -> None:
        # Resolved once, here, rather than at the call site: an `if` where the prompt is
        # rendered is an `if` that eventually disagrees with the one beside it (L12).
        if self.template_id == TEMPLATE_ID:
            self.template_id = template_for(TEMPLATE_ID, self.model)

    def agent(self) -> Agent[ImplementationOutput]:
        return Agent(
            name="implementer",
            template_id=self.template_id,
            output_type=ImplementationOutput,
            client=self.client,
            model=self.model,
            max_tokens=16384,
        )

    async def implement(
        self, brief: ImplementerBrief, *, run: object = None, attempt: int = 1
    ) -> Outcome[AgentCall]:
        outcome = await self.agent().call(
            build_prompt(brief, repo=self.repo, template_id=self.template_id),
            run=run,
            state="IMPLEMENT",
            attempt=attempt,
        )
        if outcome.is_err:
            return outcome

        call = outcome.unwrap()
        output = call.value
        assert isinstance(output, ImplementationOutput)

        if output.blocked:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"the implementer stopped: {output.blocked_reason or output.summary}",
                remedy="a partial change that looks finished is worse than an honest refusal",
            )

        applied = await self._apply(output)
        if applied.is_err:
            return Outcome.of(applied.error)  # type: ignore[arg-type]
        return Outcome.ok(call)

    async def _apply(self, output: ImplementationOutput) -> Outcome[int]:
        """Every write goes through the broker — containment, policy and audit included."""
        materialised = self._materialise(output)
        if materialised.is_err:
            return Outcome.of(materialised.error)  # type: ignore[arg-type]

        for edit in materialised.unwrap():
            result = await self.broker.invoke(
                ToolCall(
                    tool="fs.write",
                    arguments={"path": edit.path, "content": edit.content},
                    paths=[edit.path],
                    reason=edit.intent or "implementing the plan",
                )
            )
            if result.is_err:
                return Outcome.of(result.error)  # type: ignore[arg-type]
        for path in output.deletions:
            result = await self.broker.invoke(
                ToolCall(tool="fs.delete", arguments={"path": path}, paths=[path])
            )
            if result.is_err:
                return Outcome.of(result.error)  # type: ignore[arg-type]
        return Outcome.ok(len(output.edits) + len(output.anchored_edits) + len(output.deletions))

    def _materialise(self, output: ImplementationOutput) -> Outcome[list[FileEdit]]:
        """Turn anchored edits into whole-file writes, or fail before anything is written.

        Deliberately all-or-nothing: a run where two of three hunks applied is the half-applied
        patch that whole-file writes exist to prevent, and it would leave a tree nobody can
        reason about. A VALIDATION failure here goes through the repair loop that already
        exists, and the model is told exactly which anchor did not match.
        """
        edits = list(output.edits)
        for anchored in output.anchored_edits:
            target = self.workspace / anchored.path
            if not target.exists():
                return Outcome.fail(
                    ErrorCategory.VALIDATION,
                    f"{anchored.path} does not exist, so it cannot be edited by anchor",
                    remedy="write the whole file instead; an anchor needs something to anchor to",
                )
            try:
                result = apply_anchor(target.read_text(), anchored)
            except EditError as exc:
                return Outcome.fail(
                    ErrorCategory.VALIDATION,
                    str(exc),
                    remedy=(
                        "copy the anchor verbatim from the file, and extend it until it appears "
                        "exactly once. An ambiguous anchor is refused rather than guessed"
                    ),
                    details={
                        "path": exc.path,
                        "occurrences": exc.occurrences,
                        "anchor_head": exc.anchor[:200],
                    },
                )
            edits.append(FileEdit(path=result.path, content=result.content, intent=result.intent))
        return Outcome.ok(edits)

    def editor(self, brief: ImplementerBrief, *, run: object = None):  # type: ignore[no-untyped-def]
        """Adapt to ``ImplementSubgraph.editor``: it passes a context, we already have the brief."""

        async def _edit(ctx: object) -> Outcome[None]:
            result = await self.implement(brief, run=run, attempt=getattr(ctx, "attempt", 1))
            return Outcome.ok(None) if result.is_ok else Outcome.of(result.error)  # type: ignore[arg-type]

        return _edit


def filesystem_handlers(workspace: Path) -> dict[str, object]:
    """The handlers the broker calls once a write is permitted.

    Deliberately dumb: containment and policy already happened, and duplicating those checks
    here would create a second place for them to disagree.
    """

    async def write(path: str, content: str) -> Outcome[str]:
        target = workspace / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        return Outcome.ok(path)

    async def delete(path: str) -> Outcome[str]:
        target = workspace / path
        if target.exists():
            target.unlink()
        return Outcome.ok(path)

    async def read(path: str) -> Outcome[str]:
        target = workspace / path
        return Outcome.ok(target.read_text() if target.exists() else "")

    return {"fs.write": write, "fs.delete": delete, "fs.read": read}
