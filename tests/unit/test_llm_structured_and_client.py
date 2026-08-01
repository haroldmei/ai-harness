"""Issues #9/#10/#11 — the repair loop, engine behaviour, pricing and the client."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path

from ai_harness.kernel.budget import (
    DEFAULT_BUDGET,
    CircuitBreaker,
    CostTracker,
    RunSpend,
)
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.llm.client import LLMClient
from ai_harness.llm.engines.claude_cli import ClaudeCLIEngine
from ai_harness.llm.engines.protocol import LLMRequest, Usage
from ai_harness.llm.engines.scripted import Envelope, ScriptedLLM
from ai_harness.llm.pricing import is_priced, price, rate_for
from ai_harness.llm.structured import call_structured
from ai_harness.schemas.review import ReviewResult
from ai_harness.schemas.telemetry import Span


def _request(**kw: object) -> LLMRequest:
    base: dict[str, object] = {
        "prompt": "review this",
        "template_id": "reviewer-v1",
        "model": "claude-opus-5",
    }
    base.update(kw)
    return LLMRequest(**base)  # type: ignore[arg-type]


# ── the repair loop ──────────────────────────────────────────────────────────────


async def test_a_repair_is_a_narrower_prompt_not_the_same_one_again() -> None:
    engine = ScriptedLLM(
        default=[
            Envelope.result("I think it looks fine, honestly."),
            Envelope.result('{"verdict": "approve", "summary": "fine"}'),
        ]
    )
    result = await call_structured(engine, _request(), ReviewResult)
    assert result.is_ok and result.unwrap().repairs == 1
    assert len(engine.calls) == 2
    assert "Reply with ONE JSON object" in engine.calls[1].prompt
    assert engine.calls[1].template_id.endswith("+repair")


async def test_repairs_are_bounded_at_two() -> None:
    engine = ScriptedLLM(default=[Envelope.result("nope")])
    result = await call_structured(engine, _request(), ReviewResult, repair_limit=2)
    assert result.is_err and result.category is ErrorCategory.VALIDATION
    assert len(engine.calls) == 3, "one initial call plus two repairs"


async def test_a_schema_violation_is_repaired_with_the_specific_error() -> None:
    engine = ScriptedLLM(
        default=[
            Envelope.result(
                json.dumps({"verdict": "approve", "findings": [{"severity": "blocker"}]})
            ),
            Envelope.result(json.dumps({"verdict": "approve", "summary": "ok"})),
        ]
    )
    result = await call_structured(engine, _request(), ReviewResult)
    assert result.is_ok
    assert "did not satisfy the schema" in engine.calls[1].prompt


async def test_a_transport_failure_is_returned_unchanged() -> None:
    """A rate limit must not become a VALIDATION error, or it would start costing budget."""
    engine = ScriptedLLM(default=[Envelope.error(api_error_status=429, result="slow down")])
    result = await call_structured(engine, _request(), ReviewResult)
    assert result.category is ErrorCategory.RATE_LIMITED
    assert len(engine.calls) == 1, "a transport failure must not trigger a repair"


# ── the scripted engine ──────────────────────────────────────────────────────────


async def test_scripted_envelopes_are_keyed_by_template_and_ordinal() -> None:
    engine = ScriptedLLM(
        script={
            "reviewer-v1": [
                Envelope.result('{"verdict":"approve"}'),
                Envelope.result('{"verdict":"comment"}'),
            ],
            "planner-v1": [Envelope.result('{"summary":"plan"}')],
        }
    )
    first = await engine.complete(_request())
    second = await engine.complete(_request())
    planner = await engine.complete(_request(template_id="planner-v1"))
    assert "approve" in first.unwrap().text
    assert "comment" in second.unwrap().text
    assert "plan" in planner.unwrap().text


# ── the claude CLI engine ────────────────────────────────────────────────────────


async def test_claude_cli_reads_a_real_envelope_from_a_stub_binary(tmp_path: Path) -> None:
    stub = tmp_path / "claude"
    stub.write_text(
        "#!/bin/sh\n"
        'printf \'{"is_error":false,"result":"{\\"verdict\\":\\"approve\\"}",'
        '"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100},'
        '"total_cost_usd":0.42,"model":"claude-opus-5"}\'\n'
    )
    stub.chmod(0o755)
    engine = ClaudeCLIEngine(binary=str(stub))
    result = await engine.complete(_request())
    assert result.is_ok
    completion = result.unwrap()
    assert completion.usage.cache_read_tokens == 100
    assert completion.usage.reported_usd == Decimal("0.42")


async def test_claude_cli_missing_binary_is_environment_not_model_failure(tmp_path: Path) -> None:
    engine = ClaudeCLIEngine(binary=str(tmp_path / "nope"))
    result = await engine.complete(_request())
    assert result.category is ErrorCategory.ENVIRONMENT
    assert result.error is not None and result.error.remedy


async def test_claude_cli_does_not_bypass_permissions_by_default() -> None:
    """W9: the shell passes bypassPermissions at all nine call sites. Not the default here."""
    engine = ClaudeCLIEngine()
    argv = engine._argv(_request())
    assert "bypassPermissions" not in argv


async def test_claude_cli_empty_stdout_is_unknown(tmp_path: Path) -> None:
    stub = tmp_path / "claude"
    stub.write_text("#!/bin/sh\nexit 0\n")
    stub.chmod(0o755)
    result = await ClaudeCLIEngine(binary=str(stub)).complete(_request())
    assert result.category is ErrorCategory.UNKNOWN


# ── pricing ──────────────────────────────────────────────────────────────────────


def test_a_reported_cost_wins_over_the_table() -> None:
    usage = Usage(input_tokens=1000, output_tokens=1000, reported_usd=Decimal("0.99"))
    assert price(usage, provider="claude-cli", model="claude-opus-5") == Decimal("0.99")


def test_token_only_providers_are_priced_from_the_table() -> None:
    usage = Usage(input_tokens=1_000_000, output_tokens=1_000_000)
    assert price(usage, provider="anthropic", model="claude-opus-5") == Decimal("90")


def test_cache_reads_are_priced_separately() -> None:
    cached = price(Usage(cache_read_tokens=1_000_000), provider="anthropic", model="claude-opus-5")
    fresh = price(Usage(input_tokens=1_000_000), provider="anthropic", model="claude-opus-5")
    assert cached < fresh and cached > 0


def test_an_unpriced_model_is_not_free() -> None:
    assert not is_priced("anthropic", "some-unreleased-model")
    assert price(Usage(output_tokens=1_000_000), provider="x", model="y") > 0


def test_rates_are_selected_by_effective_date() -> None:
    rate, known = rate_for("anthropic", "claude-opus-5", datetime(2026, 1, 1, tzinfo=UTC))
    assert known and rate.output == Decimal("75")


# ── the client ───────────────────────────────────────────────────────────────────


class _Collector:
    def __init__(self) -> None:
        self.spans: list[Span] = []

    def emit(self, span: Span) -> None:
        self.spans.append(span)


def _run(clock: FrozenClock) -> RunSpend:
    return RunSpend(run_id="r1", repo="acme/app", started_at=clock.now())


async def test_the_client_prices_records_and_spans_a_call() -> None:
    clock = FrozenClock()
    sink = _Collector()
    tracker = CostTracker(clock=clock)
    engine = ScriptedLLM(
        default=[
            Envelope.result(
                '{"verdict":"approve"}',
                usage={"input_tokens": 1_000_000, "output_tokens": 0},
            )
        ],
        name="anthropic",
    )
    client = LLMClient(engine=engine, tracker=tracker, clock=clock, sink=sink)
    result = await client.complete(_request(), run=_run(clock), state="REVIEW", round_=2)
    assert result.is_ok
    assert tracker.run_total("r1") == Decimal("15")
    span = sink.spans[0]
    assert span.round == 2 and span.attempt == 1 and span.state == "REVIEW"
    assert span.input_tokens == 1_000_000


async def test_spans_carry_a_digest_never_the_prompt() -> None:
    sink = _Collector()
    client = LLMClient(
        engine=ScriptedLLM(default=[Envelope.result("{}")]),
        clock=FrozenClock(),
        sink=sink,
    )
    await client.complete(_request(prompt="a very secret prompt"), run=_run(FrozenClock()))
    span = sink.spans[0]
    assert span.prompt_sha256 and len(span.prompt_sha256) == 64
    assert "secret" not in span.model_dump_json()


async def test_telemetry_never_fails_the_caller() -> None:
    class _Exploding:
        def emit(self, span: Span) -> None:
            raise RuntimeError("sink is down")

    client = LLMClient(
        engine=ScriptedLLM(default=[Envelope.result('{"verdict":"approve"}')]),
        clock=FrozenClock(),
        sink=_Exploding(),
    )
    result = await client.complete(_request(), run=_run(FrozenClock()))
    assert result.is_ok, "a broken sink must not fail the model call"


async def test_the_client_denies_before_dispatch_when_the_budget_is_spent() -> None:
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(DEFAULT_BUDGET, tracker, clock=clock)
    engine = ScriptedLLM(default=[Envelope.result('{"verdict":"approve"}')], name="anthropic")
    client = LLMClient(engine=engine, tracker=tracker, breaker=breaker, clock=clock)
    breaker.reserve(_run(clock), Decimal("24.99")).unwrap()

    result = await client.complete(_request(max_tokens=100_000), run=_run(clock))
    assert result.is_err
    assert not engine.calls, "the call must not be dispatched at all"


async def test_a_failed_call_still_emits_a_span_with_its_category() -> None:
    sink = _Collector()
    client = LLMClient(
        engine=ScriptedLLM(default=[Envelope(stdout=b"")]),
        clock=FrozenClock(),
        sink=sink,
    )
    result = await client.complete(_request(), run=_run(FrozenClock()))
    assert result.is_err
    assert sink.spans[0].outcome == ErrorCategory.UNKNOWN.value
