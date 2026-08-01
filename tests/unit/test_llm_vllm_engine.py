"""The local engine's taxonomy — the whole content of the engine (#82)."""

from __future__ import annotations

import pytest

from ai_harness.kernel.outcome import NON_BUDGET_CONSUMING, RETRYABLE, ErrorCategory
from ai_harness.llm.engines.fake_vllm import FakeVLLM, Fault
from ai_harness.llm.engines.protocol import Engine, LLMRequest
from ai_harness.llm.engines.vllm import VLLMEngine

REQUEST = LLMRequest(prompt="review this diff", model="qwen3-coder-30b", template_id="reviewer-v1")


def _engine(server: FakeVLLM, **kwargs: object) -> VLLMEngine:
    return VLLMEngine(
        base_url="http://127.0.0.1:8000/v1",
        client=server.client(),
        max_model_len=server.max_model_len,
        **kwargs,  # type: ignore[arg-type]
    )


def test_it_satisfies_the_engine_protocol():
    assert isinstance(VLLMEngine(), Engine)


async def test_a_prompt_over_the_window_is_its_own_outcome_carrying_both_numbers():
    server = FakeVLLM(faults=[Fault.OVERFLOW])
    outcome = await _engine(server).complete(REQUEST)

    assert outcome.category is ErrorCategory.CONTEXT_OVERFLOW
    error = outcome.error
    assert error is not None
    assert error.details["declared_window"] == 65536
    assert error.details["requested_tokens"] == 65536 + 4096
    # The most predictable failure in the system must not read as the model's fault, must not
    # consume budget for a call that generated nothing, and must not be retried unchanged.
    assert ErrorCategory.CONTEXT_OVERFLOW in NON_BUDGET_CONSUMING
    assert ErrorCategory.CONTEXT_OVERFLOW not in RETRYABLE
    assert not outcome.budget_consuming


async def test_the_wrong_model_is_an_environment_failure_not_a_model_failure():
    for fault in (Fault.WRONG_MODEL,):
        outcome = await _engine(FakeVLLM(faults=[fault])).complete(REQUEST)
        assert outcome.category is ErrorCategory.ENVIRONMENT
        assert outcome.error is not None and "resident at a time" in (outcome.error.remedy or "")


async def test_saturation_is_back_pressure_and_not_a_vendor_rate_limit():
    outcome = await _engine(FakeVLLM(faults=[Fault.SATURATED])).complete(REQUEST)
    # RATE_LIMITED would make the harness sit out a Retry-After nobody sent.
    assert outcome.category is ErrorCategory.TRANSIENT
    assert outcome.error is not None and outcome.error.retry_after_s is None
    assert outcome.error.dependency == "model:local"


async def test_a_restarting_server_defers_the_run_through_the_dependency_breaker():
    outcome = await _engine(FakeVLLM(faults=[Fault.RESTARTING])).complete(REQUEST)
    assert outcome.category is ErrorCategory.TRANSIENT
    assert outcome.error is not None and outcome.error.dependency == "model:local"
    assert not outcome.budget_consuming


async def test_an_oom_mid_generation_is_transient_against_the_serving_dependency():
    outcome = await _engine(FakeVLLM(faults=[Fault.OOM])).complete(REQUEST)
    assert outcome.category is ErrorCategory.TRANSIENT
    assert outcome.error is not None and "KV budget" in (outcome.error.remedy or "")


async def test_no_content_is_unknown_because_the_call_may_have_worked():
    outcome = await _engine(FakeVLLM(faults=[Fault.EMPTY])).complete(REQUEST)
    assert outcome.category is ErrorCategory.UNKNOWN
    assert not outcome.budget_consuming


async def test_a_credential_the_server_rejects_is_never_retried():
    outcome = await _engine(FakeVLLM(faults=[Fault.NO_CREDENTIAL])).complete(REQUEST)
    assert outcome.category is ErrorCategory.AUTH
    assert not outcome.retryable


async def test_usage_round_trips_including_the_prefix_cache_hit():
    server = FakeVLLM(prompt_tokens=9000, completion_tokens=250, cached_tokens=7800)
    completion = (await _engine(server).complete(REQUEST)).unwrap()

    assert completion.provider == "local"
    assert completion.usage.input_tokens == 9000
    assert completion.usage.output_tokens == 250
    # The local analogue of provider prompt caching: no vendor bill to save, but the saving is
    # wall-clock, and it is only visible if it is recorded.
    assert completion.usage.cache_read_tokens == 7800


async def test_a_truncated_generation_returns_its_text_and_says_it_was_truncated():
    server = FakeVLLM(faults=[Fault.TRUNCATED], text='{"verdict": "approve"}')
    completion = (await _engine(server).complete(REQUEST)).unwrap()
    assert completion.raw["truncated"] is True
    assert completion.text  # the repair loop, not the engine, decides what to do about it


async def test_guided_decoding_is_only_requested_when_the_probe_proved_it():
    from ai_harness.llm.engines.protocol import EngineCapabilities

    schema = {"type": "object", "properties": {"verdict": {"type": "string"}}}
    request = LLMRequest(prompt="p", model="qwen3-coder-30b", schema=schema)

    plain = FakeVLLM()
    await _engine(plain).complete(request)
    assert b"response_format" not in plain.requests[0].content

    capable = FakeVLLM()
    engine = _engine(capable)
    engine.capabilities = EngineCapabilities(native_structured_output=True, prompt_caching=True)
    await engine.complete(request)
    assert b"response_format" in capable.requests[0].content


async def test_the_fault_script_is_consumed_in_order_then_the_server_is_fine():
    server = FakeVLLM(faults=[Fault.RESTARTING, Fault.RESTARTING])
    engine = _engine(server)
    assert (await engine.complete(REQUEST)).is_err
    assert (await engine.complete(REQUEST)).is_err
    assert (await engine.complete(REQUEST)).is_ok


def test_the_wiring_refuses_a_local_engine_without_a_registry(tmp_path):
    from ai_harness.config import HarnessConfig
    from ai_harness.wiring import WiringError, build_engine

    config = HarnessConfig(repo_path=tmp_path)
    config.roster.engine = "local"
    with pytest.raises(WiringError, match="model registry"):
        build_engine(config)


def test_the_wiring_builds_a_local_engine_from_the_committed_registry():
    from pathlib import Path

    from ai_harness.config import HarnessConfig
    from ai_harness.wiring import build_engine

    root = Path(__file__).resolve().parents[2]
    config = HarnessConfig(repo_path=root)
    config.roster.engine = "local"
    config.roster.implementer_model = "qwen3-coder-30b"

    engine = build_engine(config)
    assert engine.name == "local"
    assert getattr(engine, "max_model_len", None) == 65536
    assert getattr(engine, "base_url", "").endswith(":8000/v1")
