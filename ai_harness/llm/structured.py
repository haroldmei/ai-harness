"""``call_structured`` — extract, validate, repair, bounded.

This is the module that fixes W4. The shell harness hand-rolls a three-rung extraction at one
call site and nothing validates the result, so two distinct defects ship: an unparseable
fragment is accepted because it is non-empty (#2419), and a self-contradicting verdict is
acted on because nothing checks cross-field consistency.

Here the contract is:

1. call the engine — a transport failure is returned unchanged, so a rate limit stays a rate
   limit and consumes no budget;
2. extract with the ladder, which requires a parse at every rung;
3. validate against the Pydantic model, whose validators *correct* what can be corrected
   (approve-with-blockers) and reject what cannot;
4. on failure, send **one clarified repair prompt** carrying the exact validation error, at
   most ``repair_limit`` times;
5. then fail with ``VALIDATION`` and the last invalid output attached as evidence.

Repairs cost tokens, so they are budget-consuming by category. Transport transients are not.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import TypeVar

from pydantic import BaseModel, ValidationError

from ai_harness.kernel.ids import artefact_id
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.engines.protocol import Completion, Engine, LLMRequest
from ai_harness.llm.extract import Rung, extract_object

T = TypeVar("T", bound=BaseModel)

REPAIR_TEMPLATE = """Your previous response could not be used.

{problem}

Reply with ONE JSON object and nothing else — no prose, no code fence, no explanation.
It must satisfy this schema:

{schema}
"""


@dataclass(frozen=True, slots=True)
class StructuredResult[TModel: BaseModel]:
    """The validated value plus how much work it took to get it."""

    value: TModel
    completion: Completion
    rung: Rung
    repairs: int
    raw_text: str


async def call_structured[TModel: BaseModel](
    engine: Engine,
    request: LLMRequest,
    model_type: type[TModel],
    *,
    repair_limit: int = 2,
) -> Outcome[StructuredResult[TModel]]:
    """Call ``engine`` and return a validated ``model_type``, repairing at most twice."""
    schema_text = json.dumps(model_type.model_json_schema(), indent=2, sort_keys=True)
    attempt_request = request
    last_text = ""
    last_problem = ""

    for repairs in range(repair_limit + 1):
        outcome = await engine.complete(attempt_request)
        if outcome.is_err:
            # Transport failure: hand it back exactly as classified. A rate limit must not
            # become a validation error, or it would start consuming a budget.
            assert outcome.error is not None
            return Outcome.of(outcome.error)

        completion = outcome.unwrap()
        last_text = completion.text
        extraction = extract_object(completion.text)

        if not extraction.found:
            last_problem = (
                "No JSON object could be parsed from it. "
                f"{extraction.candidates_tried} candidate(s) were tried and none parsed."
            )
        else:
            try:
                value = model_type.model_validate(extraction.value)
            except ValidationError as exc:
                last_problem = f"It did not satisfy the schema:\n{_summarise(exc)}"
            else:
                return Outcome.ok(
                    StructuredResult(
                        value=value,
                        completion=completion,
                        rung=extraction.rung,
                        repairs=repairs,
                        raw_text=completion.text,
                    )
                )

        if repairs == repair_limit:
            break

        attempt_request = _repair_request(request, last_problem, schema_text)

    return Outcome.fail(
        ErrorCategory.VALIDATION,
        f"model output did not satisfy {model_type.__name__} after {repair_limit} repair(s)",
        remedy="inspect the captured output; if the schema is wrong, fix the schema, not the prompt",
        evidence=artefact_id("llm-output", last_text.encode("utf-8", "replace")),
        details={"problem": last_problem, "output_head": last_text[:2000]},
    )


def _repair_request(request: LLMRequest, problem: str, schema_text: str) -> LLMRequest:
    """A repair is a *new, narrower* request — never the same prompt sent again."""
    return LLMRequest(
        prompt=request.prompt
        + "\n\n"
        + REPAIR_TEMPLATE.format(problem=problem, schema=schema_text),
        system=request.system,
        model=request.model,
        max_tokens=request.max_tokens,
        temperature=request.temperature,
        template_id=f"{request.template_id}+repair",
        schema=request.schema,
        stop=list(request.stop),
        timeout_s=request.timeout_s,
        allow_fallback=request.allow_fallback,
    )


def _summarise(error: ValidationError) -> str:
    lines = []
    for item in error.errors()[:8]:
        location = ".".join(str(part) for part in item["loc"]) or "<root>"
        lines.append(f"- {location}: {item['msg']}")
    return "\n".join(lines)
