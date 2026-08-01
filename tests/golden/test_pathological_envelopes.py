"""Issues #9/#10/#20 — every shape that broke the shell harness, asserted end to end."""

from __future__ import annotations

import pytest

from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.llm.engines.protocol import LLMRequest, classify_envelope
from ai_harness.llm.engines.scripted import PATHOLOGICAL, Envelope, ScriptedLLM
from ai_harness.llm.structured import call_structured
from ai_harness.schemas.enums import Verdict
from ai_harness.schemas.review import ReviewResult


def _engine(*envelopes: Envelope) -> ScriptedLLM:
    return ScriptedLLM(default=list(envelopes))


def _request() -> LLMRequest:
    return LLMRequest(prompt="review this diff", template_id="reviewer-v1", model="test-model")


async def _review(*envelopes: Envelope) -> object:
    return await call_structured(_engine(*envelopes), _request(), ReviewResult)


def test_the_corpus_covers_every_recorded_shape() -> None:
    assert set(PATHOLOGICAL) >= {
        "empty_envelope",
        "rate_limited",
        "fenced_json",
        "pretty_bare_object",
        "self_contradiction",
        "prose_wrapped",
        "truncated",
        "brace_only",
    }


async def test_empty_envelope_is_unknown_and_costs_no_budget() -> None:
    """#2407 — the harness learned nothing; that is not a verdict of 'genuine failure'."""
    result = await _review(PATHOLOGICAL["empty_envelope"])
    assert result.category is ErrorCategory.UNKNOWN  # type: ignore[attr-defined]
    assert not result.budget_consuming  # type: ignore[attr-defined]


async def test_rate_limited_is_not_a_model_failure() -> None:
    result = await _review(PATHOLOGICAL["rate_limited"])
    assert result.category is ErrorCategory.RATE_LIMITED  # type: ignore[attr-defined]
    assert not result.budget_consuming  # type: ignore[attr-defined]


async def test_overloaded_is_transient() -> None:
    result = await _review(PATHOLOGICAL["overloaded"])
    assert result.category is ErrorCategory.TRANSIENT  # type: ignore[attr-defined]


async def test_auth_failure_is_terminal() -> None:
    result = await _review(PATHOLOGICAL["auth_rejected"])
    assert result.category is ErrorCategory.AUTH  # type: ignore[attr-defined]


async def test_fenced_json_yields_a_verdict() -> None:
    result = await call_structured(_engine(PATHOLOGICAL["fenced_json"]), _request(), ReviewResult)
    assert result.is_ok
    assert result.unwrap().value.verdict is Verdict.APPROVE


async def test_the_2419_shape_yields_a_verdict_rather_than_review_stuck() -> None:
    result = await call_structured(
        _engine(PATHOLOGICAL["pretty_bare_object"]), _request(), ReviewResult
    )
    assert result.is_ok, "a pretty-printed bare object must not be review-stuck"
    assert result.unwrap().value.verdict is Verdict.APPROVE


async def test_prose_wrapped_json_is_recovered() -> None:
    result = await call_structured(_engine(PATHOLOGICAL["prose_wrapped"]), _request(), ReviewResult)
    assert result.is_ok
    assert result.unwrap().value.verdict is Verdict.REQUEST_CHANGES


async def test_self_contradiction_is_corrected_not_obeyed() -> None:
    result = await call_structured(
        _engine(PATHOLOGICAL["self_contradiction"]), _request(), ReviewResult
    )
    assert result.is_ok
    review = result.unwrap().value
    assert review.verdict is Verdict.REQUEST_CHANGES
    assert review.downgraded, "the correction must be recorded, not silently applied"


async def test_braces_in_strings_do_not_break_extraction() -> None:
    result = await call_structured(
        _engine(PATHOLOGICAL["braces_in_strings"]), _request(), ReviewResult
    )
    assert result.is_ok and result.unwrap().value.verdict is Verdict.COMMENT


@pytest.mark.parametrize("shape", ["truncated", "brace_only"])
async def test_unusable_output_fails_validation_with_the_output_captured(shape: str) -> None:
    result = await call_structured(_engine(PATHOLOGICAL[shape]), _request(), ReviewResult)
    assert result.is_err
    assert result.category is ErrorCategory.VALIDATION
    assert result.error is not None and result.error.evidence is not None
    assert "output_head" in result.error.details


async def test_a_non_json_envelope_is_a_model_failure() -> None:
    result = await _review(PATHOLOGICAL["not_json"])
    assert result.category is ErrorCategory.MODEL_FAILURE  # type: ignore[attr-defined]


def test_a_limit_message_on_stderr_outranks_an_empty_envelope() -> None:
    """The CLI writes limit notices to stderr more often than to a truncated stdout."""
    outcome = classify_envelope(stdout=b"", stderr=b"usage limit reached", exit_code=1)
    assert outcome.category is ErrorCategory.RATE_LIMITED
