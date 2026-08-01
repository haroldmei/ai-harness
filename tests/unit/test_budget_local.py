"""Budgets when tokens are free: GPU-seconds, energy pricing and the time breaker (#87)."""

from __future__ import annotations

from decimal import Decimal

from ai_harness.kernel.budget import (
    LOCAL_BUDGET,
    BudgetSpec,
    CircuitBreaker,
    CostEvent,
    CostTracker,
    RunSpend,
    is_self_hosted,
)
from ai_harness.kernel.clock import FrozenClock
from ai_harness.llm.engines.protocol import Usage
from ai_harness.llm.pricing import cloud_equivalent, price

RUN = "r1"
REPO = "o/r"


def _run(clock: FrozenClock) -> RunSpend:
    return RunSpend(run_id=RUN, repo=REPO, started_at=clock.now())


def _event(**kwargs: object) -> CostEvent:
    base: dict[str, object] = {
        "run_id": RUN,
        "repo": REPO,
        "state": "REVIEW",
        "provider": "local",
        "model": "qwen3-coder-30b",
        "usd": Decimal("0.01"),
    }
    return CostEvent(**{**base, **kwargs})  # type: ignore[arg-type]


def test_a_local_model_is_priced_rather_than_free():
    usage = Usage(input_tokens=1_000_000, output_tokens=1_000_000)
    local = price(usage, provider="local", model="qwen3-coder-30b")

    # Not zero: a $0 column would make every dollar ceiling untrippable at exactly the moment
    # the loop became cheapest to leave running (W3).
    assert local > 0
    # And cheaper than the hosted roster by the margin that justifies the phase.
    assert local < cloud_equivalent(usage)


def test_a_new_local_model_needs_no_table_entry_to_be_accounted_for():
    usage = Usage(input_tokens=1000, output_tokens=1000)
    assert price(usage, provider="local", model="devstral-24b") == price(
        usage, provider="local", model="qwen3-coder-30b"
    )


def test_the_hosted_comparison_prices_cache_reads_at_hosted_rates():
    usage = Usage(input_tokens=100_000, output_tokens=10_000, cache_read_tokens=90_000)
    # Otherwise a local run that hit its prefix cache would look better than the hosted
    # alternative for a reason that has nothing to do with where the model runs.
    assert cloud_equivalent(usage) > cloud_equivalent(
        Usage(input_tokens=100_000, output_tokens=10_000)
    )


def test_only_our_own_card_counts_as_gpu_time():
    assert is_self_hosted("local")
    assert not is_self_hosted("anthropic")
    assert not is_self_hosted("claude-cli")


def test_the_tracker_accumulates_seconds_per_run_and_per_repo_day():
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    tracker.record(_event(gpu_seconds=120.0))
    tracker.record(_event(gpu_seconds=90.0))
    tracker.record(_event(run_id="r2", gpu_seconds=30.0))

    assert tracker.run_seconds(RUN) == 210.0
    assert tracker.run_seconds("r2") == 30.0
    assert tracker.repo_day_seconds(REPO) == 240.0


def test_a_runaway_local_loop_is_stopped_by_the_time_ceiling():
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    budget = BudgetSpec(
        max_usd_per_run=Decimal("25"),
        max_usd_per_repo_day=Decimal("500"),
        max_model_seconds_per_run=300.0,
    )
    breaker = CircuitBreaker(budget, tracker, clock=clock)
    run = _run(clock)

    assert breaker.check(run) is None
    tracker.record(_event(gpu_seconds=310.0, usd=Decimal("0.04")))

    verdict = breaker.check(run)
    assert verdict is not None
    assert verdict.reason == "model-time ceiling reached"
    # The dollar ceiling is nowhere near tripping — which is the whole point of the second rail.
    assert tracker.run_total(RUN) < Decimal("1")


def test_the_reservation_is_denied_before_dispatch_not_after():
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(
        BudgetSpec(
            max_usd_per_run=Decimal("25"),
            max_usd_per_repo_day=Decimal("500"),
            max_model_seconds_per_run=600.0,
        ),
        tracker,
        clock=clock,
    )
    run = _run(clock)

    held = breaker.reserve(run, Decimal("0.01"), 500.0)
    assert held.is_ok
    # A second call that would take the run past its model-time ceiling is refused *before* the
    # GPU is occupied, exactly as W3's fix refuses before the money is spent.
    denied = breaker.reserve(run, Decimal("0.01"), 500.0)
    assert denied.is_err
    assert denied.error is not None and "model-time ceiling" in denied.error.message

    breaker.settle(held.unwrap(), _event(gpu_seconds=120.0))
    assert tracker.run_seconds(RUN) == 120.0
    assert breaker.committed_seconds(RUN) == 120.0
    assert breaker.reserve(run, Decimal("0.01"), 400.0).is_ok


def test_a_repository_can_run_out_of_card_for_the_day():
    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(LOCAL_BUDGET, tracker, clock=clock)
    # Charged to a *different* run in the same repository, so the run-level ceiling is nowhere
    # near tripping and the daily one is the only thing that can fire.
    tracker.record(
        _event(run_id="earlier", gpu_seconds=LOCAL_BUDGET.max_gpu_seconds_per_repo_day or 0.0)
    )

    verdict = breaker.check(_run(clock))
    assert verdict is not None and verdict.reason == "repo daily GPU ceiling reached"


def test_an_unset_local_ceiling_is_still_a_configuration_error_not_unlimited():
    clock = FrozenClock()
    breaker = CircuitBreaker(BudgetSpec(), CostTracker(clock=clock), clock=clock)
    verdict = breaker.check(_run(clock))
    assert verdict is not None and verdict.reason == "not configured"


async def test_the_client_reserves_model_time_and_charges_only_its_own_card():
    from ai_harness.llm.client import LLMClient
    from ai_harness.llm.engines.fake_vllm import FakeVLLM
    from ai_harness.llm.engines.protocol import LLMRequest
    from ai_harness.llm.engines.vllm import VLLMEngine

    clock = FrozenClock()
    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(LOCAL_BUDGET, tracker, clock=clock)
    server = FakeVLLM(prompt_tokens=4000, completion_tokens=800)
    client = LLMClient(
        engine=VLLMEngine(base_url="http://127.0.0.1:8000/v1", client=server.client()),
        tracker=tracker,
        breaker=breaker,
        clock=clock,
        decode_tps=30.0,
    )

    request = LLMRequest(prompt="x" * 4000, model="qwen3-coder-30b", max_tokens=2000)
    # 2000 tokens at the pessimistic 30 tok/s is over a minute of card, and the estimate says so
    # before anything is dispatched.
    assert client.estimate_seconds(request) > 60

    outcome = await client.complete(request, run=_run(clock), state="IMPLEMENT")
    assert outcome.is_ok
    assert tracker.run_total(RUN) > 0  # priced, not free
    assert breaker.committed_seconds(RUN) == tracker.run_seconds(RUN)


def test_the_evidence_block_states_what_the_run_would_have_cost_hosted():
    from ai_harness.observability.reports import EvidenceBlock
    from ai_harness.schemas.enums import GateSet, Tier
    from ai_harness.schemas.gates import GateReport

    rendered = EvidenceBlock(
        run_id="r1",
        report=GateReport(run_id="r1", tier=Tier.LAUNCH, gate_set=GateSet.FULL, results=[]),
        spend_usd=Decimal("0.42"),
        cloud_equivalent_usd=Decimal("7.10"),
        gpu_seconds=930.0,
        swap_seconds=45.0,
    ).render()

    assert "hosted equivalent $7.10" in rendered
    assert "saved $6.68" in rendered
    assert "GPU 930s" in rendered
    # Swap time is its own line so it is not mistaken for thinking.
    assert "model swaps 45s" in rendered


async def test_agent_cost_splits_local_from_hosted_and_reports_seconds(tmp_path):
    from ai_harness.persistence.sqlite import open_sqlite

    store = open_sqlite(tmp_path / "harness.db")
    try:
        await store.record(_event(gpu_seconds=100.0, usd=Decimal("0.05")))
        await store.record(_event(provider="anthropic", model="claude-opus-5", usd=Decimal("2.50")))
        summary = await store.summary(repo=REPO)
    finally:
        store.dispose()

    assert summary["local_usd"] == "0.0500"
    assert summary["hosted_usd"] == "2.5000"
    assert summary["local_calls"] == 1 and summary["hosted_calls"] == 1
    assert summary["gpu_seconds"] == 100.0
