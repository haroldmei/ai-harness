"""Counting tokens honestly, and fitting a real window (#86)."""

from __future__ import annotations

import httpx
import pytest

from ai_harness.context.assembler import ContextAssembler, ContextBudget, PinnedFact, fit
from ai_harness.context.trust import Trusted
from ai_harness.kernel.tokens import DEFAULT_CHARS_PER_TOKEN, CalibratedCounter
from ai_harness.llm.serving.tokenize import ServerCounter, counter_for

CODE = "def handle(request):\n    return {'ok': True}\n" * 40


def test_the_estimate_starts_conservative_and_says_it_is_not_exact():
    counter = CalibratedCounter()
    assert counter.exact is False
    # Under-counting costs the call; over-counting costs some context. The margin is applied in
    # the direction that fits less.
    naive = len(CODE) / DEFAULT_CHARS_PER_TOKEN
    assert counter.count(CODE) > naive


def test_calibration_converges_on_the_real_ratio_from_traffic_the_harness_already_has():
    counter = CalibratedCounter()
    for _ in range(30):
        counter.calibrate(characters=3200, tokens=1000)  # 3.2 chars/token, i.e. code

    assert counter.chars_per_token == pytest.approx(3.2, abs=0.15)
    assert counter.samples == 30
    # With evidence the safety margin shrinks: an established ratio does not need 15% of slack.
    assert counter.margin == 0.02


def test_an_implausible_sample_is_refused_rather_than_learned():
    counter = CalibratedCounter()
    before = counter.chars_per_token
    counter.calibrate(characters=100, tokens=0)  # a division that would explode
    counter.calibrate(characters=1_000_000, tokens=1)  # a cached-prefix accounting quirk
    counter.calibrate(characters=0, tokens=10)
    assert counter.chars_per_token == before
    assert counter.samples == 0


async def test_the_exact_counter_uses_the_models_own_tokenizer_and_calibrates_for_free():
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.url.path)
        return httpx.Response(200, json={"count": 500})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        counter = ServerCounter(base_url="http://127.0.0.1:8000/v1", model="m", client=client)
        exact = await counter.count_exact("x" * 1600)

    assert exact.unwrap() == 500
    assert seen == ["/tokenize"]
    # 1600 characters, 500 tokens: the estimate has now learned 3.2 without a call made to learn.
    assert counter.fallback.chars_per_token < DEFAULT_CHARS_PER_TOKEN
    assert counter.exact is True


async def test_a_tokenizer_that_is_not_there_degrades_to_the_estimate_and_says_so():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        counter = ServerCounter(base_url="http://127.0.0.1:8000/v1", model="m", client=client)
        outcome = await counter.count_exact("hello")

    assert outcome.is_err
    assert counter.count("hello") > 0  # counting still works, it is just not exact


def test_counter_for_picks_the_exact_one_only_when_there_is_a_server():
    assert isinstance(counter_for(base_url=None, model="m"), CalibratedCounter)
    assert counter_for(base_url="http://127.0.0.1:8000/v1", model="m").exact is True


def test_the_budget_comes_from_the_served_window_not_from_a_hosted_models_number():
    default = ContextBudget()
    assert default.max_tokens == 120_000  # unchanged for callers that never set one

    local = ContextBudget.for_model(window=32_768)
    assert local.max_tokens == 32_768
    assert local.usable == 32_768 - 8_000
    # A window is shared between the prompt and the answer, and a quarter of a small window is
    # not a sane output reservation.
    tiny = ContextBudget.for_model(window=8_192)
    assert tiny.reserve_for_output == 2_048


def _sections(retrieved: int = 20) -> dict[str, object]:
    return {
        "system": Trusted("You are a reviewer."),
        "pinned": [PinnedFact("acceptance", "the tests pass")],
        "active": [Trusted(CODE)],
        "retrieved": [Trusted(CODE) for _ in range(retrieved)],
    }


def test_a_prompt_that_does_not_fit_is_re_assembled_once_and_says_what_was_withheld():
    assembler = ContextAssembler(counter=CalibratedCounter())
    assembled = fit(assembler, window=4_096, max_output_tokens=1_024, **_sections())

    assert assembled.tokens <= 4_096
    assert not assembled.complete
    assert assembled.dropped_retrieved > 0
    assert "did not fit the budget and are NOT shown" in assembled.prompt
    # The acceptance criterion survives eviction; that is the whole point of the pinned tier.
    assert "the tests pass" in assembled.prompt


def test_a_prompt_that_fits_is_assembled_once_and_not_marked_re_assembled():
    assembler = ContextAssembler(counter=CalibratedCounter())
    assembled = fit(assembler, window=65_536, **_sections(retrieved=2))

    assert assembled.complete
    assert assembled.reassembled is False


def test_the_second_assembly_is_smaller_and_marked():
    # An active tier alone larger than the window: nothing below pinned can save it, so the
    # second attempt is the last one, and it is honest about being a second attempt.
    assembler = ContextAssembler(counter=CalibratedCounter())
    huge = {
        "system": Trusted("s"),
        "pinned": [],
        "active": [Trusted(CODE * 20)],
        "retrieved": [Trusted(CODE) for _ in range(5)],
    }
    assembled = fit(assembler, window=2_048, max_output_tokens=512, **huge)
    assert assembled.reassembled is True


async def test_no_request_reaches_the_server_above_the_window():
    from ai_harness.kernel.outcome import ErrorCategory
    from ai_harness.llm.engines.fake_vllm import FakeVLLM
    from ai_harness.llm.engines.protocol import LLMRequest
    from ai_harness.llm.engines.vllm import VLLMEngine

    server = FakeVLLM(max_model_len=8_192)
    engine = VLLMEngine(
        base_url="http://127.0.0.1:8000/v1",
        client=server.client(),
        max_model_len=8_192,
        counter=CalibratedCounter(),
    )

    outcome = await engine.complete(
        LLMRequest(prompt=CODE * 20, model="qwen3-coder-30b", max_tokens=2_000)
    )

    assert outcome.category is ErrorCategory.CONTEXT_OVERFLOW
    # The point: the assembler refuses first. Nothing was sent, so nothing was waited for.
    assert server.requests == []
    error = outcome.error
    assert error is not None and error.details["declared_window"] == 8_192


async def test_the_client_learns_the_ratio_and_records_the_prefix_cache_hit_ratio():
    from ai_harness.llm.client import LLMClient
    from ai_harness.llm.engines.fake_vllm import FakeVLLM
    from ai_harness.llm.engines.protocol import LLMRequest
    from ai_harness.llm.engines.vllm import VLLMEngine
    from ai_harness.schemas.telemetry import Span

    spans: list[Span] = []

    class Sink:
        def emit(self, span: Span) -> None:
            spans.append(span)

    server = FakeVLLM(prompt_tokens=1_000, cached_tokens=800)
    counter = CalibratedCounter()
    client = LLMClient(
        engine=VLLMEngine(base_url="http://127.0.0.1:8000/v1", client=server.client()),
        sink=Sink(),
        counter=counter,
    )

    await client.complete(LLMRequest(prompt="x" * 3_400, model="qwen3-coder-30b"))

    assert counter.samples == 1
    assert counter.chars_per_token < DEFAULT_CHARS_PER_TOKEN
    assert spans[-1].attributes["cache.hit_ratio"] == "0.800"
