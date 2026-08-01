"""``Agent`` — one prompt template, one output schema, one policy.

This module is the **only** caller of :func:`ai_harness.llm.structured.call_structured`, and an
``import-linter`` contract enforces that: subgraphs, orchestration, quality, workspace and the
CLI are all forbidden from importing it. The reason is that the prompt/schema pairing is where
correctness lives — a caller that builds its own prompt and parses its own output has quietly
forked the extraction ladder and the repair loop.

Prompts are content-addressed (Q13): ``template_id`` plus a sha256 of the rendered text on every
span, so a template change is visible in the telemetry and a regression can be pinned to the
version that caused it. The text itself is never stored (§21.4).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path

from pydantic import BaseModel

from ai_harness.context.trust import TrustedPrompt
from ai_harness.kernel.ids import digest
from ai_harness.kernel.outcome import Outcome
from ai_harness.llm.client import LLMClient
from ai_harness.llm.engines.protocol import Completion, EngineCapabilities, LLMRequest
from ai_harness.llm.pacing import Pace
from ai_harness.llm.structured import call_structured

PROMPTS = Path(__file__).parent / "prompts"


@dataclass(frozen=True, slots=True)
class AgentCall:
    """What an agent produced, and everything the checkpoint needs about how."""

    value: BaseModel
    model: str
    template_id: str
    prompt_sha256: str
    prompt_bytes: int
    repairs: int
    usd: Decimal = Decimal(0)
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    untrusted_sources: list[str] = field(default_factory=list)


@dataclass
class Agent[TOut: BaseModel]:
    """A role: a versioned template, a schema, and the model that plays it."""

    name: str
    template_id: str
    output_type: type[TOut]
    client: LLMClient
    model: str
    max_tokens: int = 8192
    repair_limit: int = 2
    timeout_s: float = 900.0
    pace: Pace | None = None
    """When present, the timeout is derived from this box's measured decode rate instead of the
    flat default (#89). One number for every call is either far too generous for a triage or far
    too tight for a whole-file IMPLEMENT, and the second is how nearly-finished generation gets
    thrown away."""

    def template(self) -> str:
        """The versioned prompt text. A change here changes ``template_id`` by convention."""
        path = PROMPTS / f"{self.template_id}.md"
        return path.read_text() if path.exists() else ""

    async def call(
        self,
        prompt: TrustedPrompt,
        *,
        run: object = None,
        state: str | None = None,
        round_: int = 0,
        attempt: int = 1,
    ) -> Outcome[AgentCall]:
        """Render, dispatch, validate, repair — once, in one place."""
        rendered = prompt.render()
        timeout_s = self.timeout_s
        if self.pace is not None:
            timeout_s = self.pace.timeout_for(
                prompt_tokens=len(rendered) // 4, max_tokens=self.max_tokens
            )
        request = LLMRequest(
            prompt=rendered,
            model=self.model,
            max_tokens=self.max_tokens,
            template_id=self.template_id,
            timeout_s=timeout_s,
        )
        engine = _BudgetedEngine(
            client=self.client, run=run, state=state, round_=round_, attempt=attempt
        )
        outcome = await call_structured(
            engine, request, self.output_type, repair_limit=self.repair_limit
        )
        if outcome.is_err:
            assert outcome.error is not None
            return Outcome.of(outcome.error)

        structured = outcome.unwrap()
        completion = structured.completion
        return Outcome.ok(
            AgentCall(
                value=structured.value,
                model=completion.model,
                template_id=self.template_id,
                prompt_sha256=digest(rendered),
                prompt_bytes=len(rendered.encode("utf-8", "replace")),
                repairs=structured.repairs,
                usd=engine.spent,
                input_tokens=completion.usage.input_tokens,
                output_tokens=completion.usage.output_tokens,
                cache_read_tokens=completion.usage.cache_read_tokens,
                untrusted_sources=prompt.sources,
            )
        )


@dataclass
class _BudgetedEngine:
    """Adapts the budget-aware client to the ``Engine`` shape ``call_structured`` expects.

    The repair loop must go through the same reservation, pricing and span emission as the first
    attempt — a repair costs real tokens, and a repair that bypassed the breaker would be a hole
    in exactly the ceiling the breaker exists to hold.
    """

    client: LLMClient
    run: object = None
    state: str | None = None
    round_: int = 0
    attempt: int = 1
    spent: Decimal = Decimal(0)
    name: str = ""
    capabilities: EngineCapabilities = field(default_factory=EngineCapabilities)

    def __post_init__(self) -> None:
        # Settable attributes, not properties: the ``Engine`` protocol declares them as
        # variables, and a read-only property does not satisfy it.
        self.name = self.client.engine.name
        self.capabilities = self.client.engine.capabilities

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        from ai_harness.kernel.budget import RunSpend

        before = (
            self.client.tracker.run_total(self.run.run_id)
            if isinstance(self.run, RunSpend)
            else Decimal(0)
        )
        outcome = await self.client.complete(
            request,
            run=self.run if isinstance(self.run, RunSpend) else None,
            state=self.state,
            round_=self.round_,
            attempt=self.attempt,
        )
        if isinstance(self.run, RunSpend):
            self.spent += self.client.tracker.run_total(self.run.run_id) - before
        return outcome
