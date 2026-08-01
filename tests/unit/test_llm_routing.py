"""Routing by model, and the counted fallback that keeps "$0" an honest number (#84)."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime

import pytest

from ai_harness.kernel.budget import RunSpend
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.client import LLMClient
from ai_harness.llm.engines.protocol import Completion, EngineCapabilities, LLMRequest, Usage
from ai_harness.llm.engines.routing import RoutingEngine, RoutingError


@dataclass
class StubEngine:
    """An engine that answers, or fails with a category chosen by the test."""

    name: str
    failure: ErrorCategory | None = None
    capabilities: EngineCapabilities = field(default_factory=EngineCapabilities)
    calls: list[LLMRequest] = field(default_factory=list)

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        self.calls.append(request)
        if self.failure is not None:
            return Outcome.fail(self.failure, f"{self.name} said no")
        return Outcome.ok(
            Completion(
                text="{}",
                model=request.model,
                provider=self.name,
                usage=Usage(input_tokens=10, output_tokens=5),
            )
        )


def _run() -> RunSpend:
    return RunSpend(run_id="r1", repo="o/r", started_at=datetime.now(UTC))


def test_each_role_reaches_its_own_engine():
    local = StubEngine(name="local")
    cloud = StubEngine(name="anthropic")
    router = RoutingEngine(routes={"qwen3-coder-30b": local, "claude-opus-5": cloud})

    assert router.engine_for("qwen3-coder-30b") is local
    assert router.engine_for("claude-opus-5") is cloud


def test_an_unrouted_model_is_a_construction_error_not_a_default():
    router = RoutingEngine(routes={"qwen3-coder-30b": StubEngine(name="local")})
    with pytest.raises(RoutingError, match="no engine is configured"):
        router.engine_for("devstral-24b")
    with pytest.raises(RoutingError, match="the roster names model"):
        router.requires("qwen3-coder-30b", "devstral-24b")


def test_capabilities_are_the_intersection_of_the_routes():
    guided = StubEngine(
        name="local", capabilities=EngineCapabilities(native_structured_output=True)
    )
    plain = StubEngine(name="other", capabilities=EngineCapabilities())
    router = RoutingEngine(routes={"a": guided, "b": plain})
    # What a caller may rely on for ANY route is what every route supports.
    assert router.capabilities.native_structured_output is False

    assert RoutingEngine(routes={"a": guided}).capabilities.native_structured_output is True


def test_a_fallback_for_an_unrouted_model_is_refused_at_construction():
    with pytest.raises(RoutingError, match="unrouted"):
        RoutingEngine(
            routes={"a": StubEngine(name="local")},
            fallbacks={"b": StubEngine(name="anthropic")},
        )


async def test_without_a_fallback_a_local_outage_never_reaches_a_paid_api():
    local = StubEngine(name="local", failure=ErrorCategory.TRANSIENT)
    router = RoutingEngine(routes={"qwen3-coder-30b": local})

    outcome = await router.complete(LLMRequest(prompt="p", model="qwen3-coder-30b"))
    assert outcome.category is ErrorCategory.TRANSIENT


async def test_a_configured_fallback_answers_and_says_that_it_did():
    local = StubEngine(name="local", failure=ErrorCategory.TRANSIENT)
    cloud = StubEngine(name="anthropic")
    router = RoutingEngine(routes={"m": local}, fallbacks={"m": cloud})

    completion = (await router.complete(LLMRequest(prompt="p", model="m"))).unwrap()
    assert completion.provider == "anthropic"
    assert completion.raw["fallback"]["from"] == "local"
    assert completion.raw["fallback"]["category"] == "transient"


async def test_only_provider_shaped_failures_fall_back():
    cloud = StubEngine(name="anthropic")
    for category in (ErrorCategory.VALIDATION, ErrorCategory.CONTEXT_OVERFLOW, ErrorCategory.AUTH):
        local = StubEngine(name="local", failure=category)
        router = RoutingEngine(routes={"m": local}, fallbacks={"m": cloud})
        outcome = await router.complete(LLMRequest(prompt="p", model="m"))
        # A bigger wallet is not a smaller prompt, and a schema violated once will be violated
        # again — neither is worth paying a second provider for.
        assert outcome.category is category
    assert cloud.calls == []


async def test_when_both_fail_the_primary_is_blamed():
    local = StubEngine(name="local", failure=ErrorCategory.TRANSIENT)
    cloud = StubEngine(name="anthropic", failure=ErrorCategory.RATE_LIMITED)
    router = RoutingEngine(routes={"m": local}, fallbacks={"m": cloud})

    outcome = await router.complete(LLMRequest(prompt="p", model="m"))
    assert outcome.error is not None and "local said no" in outcome.error.message


async def test_the_client_counts_fallbacks_and_puts_them_on_the_span():
    from ai_harness.schemas.telemetry import Span

    spans: list[Span] = []

    class Sink:
        def emit(self, span: Span) -> None:
            spans.append(span)

    router = RoutingEngine(
        routes={"m": StubEngine(name="local", failure=ErrorCategory.TRANSIENT)},
        fallbacks={"m": StubEngine(name="anthropic")},
    )
    client = LLMClient(engine=router, sink=Sink())
    run = _run()

    await client.complete(LLMRequest(prompt="p", model="m"), run=run)
    assert run.fallbacks == 1
    assert spans[-1].attributes["fallback.to"] == "anthropic"


async def test_the_third_fallback_escalates_instead_of_spending_more():
    router = RoutingEngine(
        routes={"m": StubEngine(name="local", failure=ErrorCategory.TRANSIENT)},
        fallbacks={"m": StubEngine(name="anthropic")},
    )
    client = LLMClient(engine=router, fallback_limit=2)
    run = _run()

    assert (await client.complete(LLMRequest(prompt="p", model="m"), run=run)).is_ok
    assert (await client.complete(LLMRequest(prompt="p", model="m"), run=run)).is_ok
    third = await client.complete(LLMRequest(prompt="p", model="m"), run=run)

    assert run.fallbacks == 2
    assert third.category is ErrorCategory.NEEDS_HUMAN
    assert (
        third.error is not None and "already used its 2 hosted fallback(s)" in third.error.message
    )


def test_the_evidence_block_says_a_run_with_fallbacks_was_not_free():
    from ai_harness.observability.reports import EvidenceBlock
    from ai_harness.schemas.enums import GateSet, Tier
    from ai_harness.schemas.gates import GateReport

    block = EvidenceBlock(
        run_id="r1",
        report=GateReport(run_id="r1", tier=Tier.LAUNCH, gate_set=GateSet.FULL, results=[]),
        fallbacks=["reviewer: local unreachable"],
    )
    rendered = block.render()
    assert "hosted fallback(s)" in rendered
    assert "This run was not free" in rendered


def test_the_wiring_builds_a_router_for_a_mixed_roster(tmp_path, monkeypatch):
    from pathlib import Path

    from ai_harness.config import HarnessConfig
    from ai_harness.wiring import WiringError, build_engine

    root = Path(__file__).resolve().parents[2]
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test")
    config = HarnessConfig(repo_path=root, state_dir=tmp_path)
    config.roster.implementer_model = "qwen3-coder-30b"
    config.roster.planner_model = "qwen3-coder-30b"
    config.roster.triager_model = "qwen3-coder-30b"
    config.roster.reviewer_model = "devstral-24b"
    config.roster.conflict_resolver_model = "devstral-24b"
    config.roster.engines = {"qwen3-coder-30b": "local", "devstral-24b": "local"}

    router = build_engine(config)
    assert router.name == "router"
    # Two models, two ports: the thing one engine could not express.
    implementer = router.engine_for("qwen3-coder-30b")  # type: ignore[attr-defined]
    reviewer = router.engine_for("devstral-24b")  # type: ignore[attr-defined]
    assert implementer.base_url.endswith(":8000/v1")
    assert reviewer.base_url.endswith(":8001/v1")

    # A mistyped model must not quietly resolve to the default engine: that is how a review
    # ends up running on the implementer's provider and still looking like a review.
    config.roster.reviewer_model = "not-in-the-registry"
    with pytest.raises(WiringError, match="names no engine"):
        build_engine(config)


# ── #91's code half: two models, compared, neither of them posting ──────────────


async def test_the_shadow_runner_can_compare_two_reviewers_instead_of_scraping_a_pr():
    from dataclasses import dataclass as _dataclass
    from decimal import Decimal

    from ai_harness.kernel.clock import FrozenClock
    from ai_harness.orchestration.shadow_runner import ShadowRunner
    from ai_harness.schemas.enums import Signal, Verdict
    from ai_harness.schemas.shadow import Agreement

    @_dataclass
    class StubReviewer:
        verdict: str
        blocking: int = 0

        async def execute(self, ctx):
            from ai_harness.subgraphs.base import SubgraphResult

            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.ADVANCE,
                    payload={
                        "review": {
                            "verdict": self.verdict,
                            "blocking_findings": ["a.py:1"] * self.blocking,
                        }
                    },
                    usd=Decimal("0.01"),
                )
            )

    class Forge:
        writes_blocked = True

        async def find_mr_by_head(self, head):
            return Outcome.ok(None)

        async def get_diff(self, number):
            return Outcome.ok("diff --git a/a.py b/a.py")

    class Store:
        def __init__(self):
            self.stored = []

        async def observe(self, comparison, *, repo):
            self.stored.append(comparison)
            return comparison

    store = Store()
    runner = ShadowRunner(
        reviewer=StubReviewer(verdict="approve"),
        forge=Forge(),  # type: ignore[arg-type]
        store=store,
        repo="o/r",
        clock=FrozenClock(),
        baseline=StubReviewer(verdict="request_changes", blocking=1),
        baseline_engine="cloud",
    )

    observation = (await runner.observe(7)).unwrap()
    comparison = observation.comparison

    # The failure mode worth catching is the local reviewer being *quieter*: approving what the
    # cloud reviewer blocks. It has to show up as a disagreement, not as a missing observation.
    assert comparison.shell.verdict is Verdict.REQUEST_CHANGES
    assert comparison.python.verdict is Verdict.APPROVE
    assert comparison.agreement is not Agreement.AGREE
    assert store.stored


async def test_a_reviewer_that_crashes_is_recorded_rather_than_skipped():
    from ai_harness.kernel.clock import FrozenClock
    from ai_harness.orchestration.shadow_runner import ShadowRunner

    class Boom:
        async def execute(self, ctx):
            return Outcome.fail(ErrorCategory.TRANSIENT, "the local server went away")

    class Ok:
        async def execute(self, ctx):
            from decimal import Decimal

            from ai_harness.schemas.enums import Signal
            from ai_harness.subgraphs.base import SubgraphResult

            return Outcome.ok(
                SubgraphResult(
                    signal=Signal.ADVANCE,
                    payload={"review": {"verdict": "approve"}},
                    usd=Decimal("0.01"),
                )
            )

    class Forge:
        writes_blocked = True

        async def find_mr_by_head(self, head):
            return Outcome.ok(None)

        async def get_diff(self, number):
            return Outcome.ok("diff")

    class Store:
        async def observe(self, comparison, *, repo):
            return comparison

    runner = ShadowRunner(
        reviewer=Boom(),
        forge=Forge(),  # type: ignore[arg-type]
        store=Store(),
        repo="o/r",
        clock=FrozenClock(),
        baseline=Ok(),
    )

    comparison = (await runner.observe(9)).unwrap().comparison
    # "The local reviewer crashed on 3% of PRs" is what an observation window is for; a runner
    # that skipped those would report a flattering rate over the survivors.
    assert comparison.python.verdict is None
    assert "went away" in comparison.python.note
