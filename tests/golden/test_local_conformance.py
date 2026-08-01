"""Local prompts, and the conformance run that says whether they work (#90)."""

from __future__ import annotations

from ai_harness.agents.base import PROMPTS
from ai_harness.agents.templates import LOCAL_SUFFIX, is_local_family, template_for
from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.llm.conformance import ConformanceCase, render, run_conformance
from ai_harness.llm.engines.scripted import PATHOLOGICAL, Envelope, ScriptedLLM
from ai_harness.llm.extract import Rung
from ai_harness.schemas.review import ReviewResult

GOOD = '{"verdict": "approve", "summary": "the criterion is met", "findings": []}'


def _case(name: str) -> ConformanceCase:
    return ConformanceCase(
        name=name,
        template_id="reviewer-v1-local",
        prompt="review this diff",
        model_type=ReviewResult,
    )


def test_a_local_model_gets_the_local_template_and_a_hosted_one_does_not():
    assert template_for("reviewer-v1", "devstral-24b") == "reviewer-v1-local"
    assert template_for("implementer-v2", "qwen3-coder-30b") == "implementer-v2-local"
    assert template_for("planner-v1", "qwen3-coder-30b") == "planner-v1-local"

    # A hosted roster must not inherit prompts tuned for a smaller model (L12).
    assert template_for("reviewer-v1", "claude-opus-5") == "reviewer-v1"
    assert not is_local_family("claude-opus-5")


def test_a_role_with_no_local_variant_falls_back_to_the_strict_prompt():
    # A missing variant means "not tuned yet", which is a worse fit rather than a broken one.
    assert not (PROMPTS / f"triager-v1{LOCAL_SUFFIX}.md").exists()
    assert template_for("triager-v1", "qwen3-coder-30b") == "triager-v1"


def test_the_local_variants_keep_the_guarantees_and_drop_the_prose():
    strict = (PROMPTS / "reviewer-v1.md").read_text()
    local = (PROMPTS / "reviewer-v1-local.md").read_text()

    # Shorter, because a 4-bit 30B follows a long implicit prompt considerably worse.
    assert len(local) < len(strict) * 1.2
    # The guarantees are guarantees, not style: they survive verbatim in substance.
    assert "file:line" in local  # falsifiability
    assert "BLOCKER" in local or "blocker" in local  # weakened tests are blocking
    assert "downgrade" in local  # approve-with-blockers is reconciled in code
    assert "DATA" in local  # the trust boundary
    # And the schema is shown rather than described, which is the actual difference.
    assert '"verdict"' in local and '"findings"' in local


def test_every_agent_resolves_its_template_at_construction():
    from ai_harness.agents.implementer import Implementer
    from ai_harness.agents.planner import Planner
    from ai_harness.agents.reviewer import Reviewer
    from ai_harness.llm.client import LLMClient

    client = LLMClient(engine=ScriptedLLM())
    assert Reviewer(client=client, model="devstral-24b").template_id == "reviewer-v1-local"
    assert Planner(client=client, model="qwen3-coder-30b").template_id == "planner-v1-local"
    assert Reviewer(client=client, model="claude-opus-5").template_id == "reviewer-v1"

    from pathlib import Path

    from ai_harness.policies.engine import PolicyEngine
    from ai_harness.schemas.policy import Policy
    from ai_harness.tools.broker import ToolBroker

    implementer = Implementer(
        client=client,
        model="qwen3-coder-30b",
        broker=ToolBroker(policy=PolicyEngine(Policy())),
        workspace=Path(),
    )
    assert implementer.template_id == "implementer-v2-local"


def test_the_prompt_actually_sent_is_the_resolved_one():
    from ai_harness.agents.reviewer import ReviewBrief, build_prompt
    from ai_harness.context.diff_bundler import DiffBundle, FileDiff

    brief = ReviewBrief(
        issue_title="t",
        issue_body="b",
        acceptance_criteria="c",
        diff=DiffBundle(included=[FileDiff(path="a.py", text="diff --git a/a.py b/a.py")]),
    )
    rendered = build_prompt(
        brief, repo="o/r", base_sha="a", head_sha="b", template_id="reviewer-v1-local"
    ).render()
    # The template id and the text must not be able to disagree — the failure mode is a span
    # that attributes behaviour to a prompt that was never used.
    assert "One JSON object. No prose before it" in rendered


async def test_a_clean_model_scores_a_perfect_first_pass():
    engine = ScriptedLLM(default=[Envelope.result(GOOD)])
    report = await run_conformance(engine, [_case("clean")] * 5, model="devstral-24b")

    assert report.first_pass_rate == 1.0
    assert report.repairs_per_call == 0.0
    assert report.refusal_rate == 0.0
    assert report.rungs == {str(Rung.RAW): 5}


async def test_prose_wrapped_json_is_recovered_but_the_rung_says_who_did_the_work():
    engine = ScriptedLLM(default=[PATHOLOGICAL["prose_wrapped"]])
    report = await run_conformance(engine, [_case("prose")], model="qwen3-coder-30b")

    assert report.valid_rate == 1.0
    # Recovered by the ladder rather than by the model: a tail here is the signal that guided
    # decoding is off, or that the prompt is not landing.
    assert report.rungs == {str(Rung.BRACKET_SCAN): 1}


async def test_a_repair_is_counted_because_it_is_a_full_re_generation():
    engine = ScriptedLLM(
        default=[PATHOLOGICAL["brace_only"], Envelope.result(GOOD)],
    )
    report = await run_conformance(engine, [_case("repaired")], model="qwen3-coder-30b")

    assert report.valid_rate == 1.0
    assert report.first_pass_rate == 0.0
    assert report.repairs_per_call == 1.0


async def test_a_model_that_cannot_produce_the_schema_is_counted_as_a_refusal():
    engine = ScriptedLLM(default=[PATHOLOGICAL["brace_only"]])
    report = await run_conformance(engine, [_case("hopeless")], model="qwen3-coder-30b")

    assert report.refusal_rate == 1.0
    assert report.results[0].category is ErrorCategory.VALIDATION


async def test_a_transport_failure_is_not_scored_as_a_conformance_failure():
    engine = ScriptedLLM(default=[PATHOLOGICAL["rate_limited"]])
    report = await run_conformance(engine, [_case("rate limited")], model="qwen3-coder-30b")

    # It is still counted as unusable — but the category says the model never spoke, which is
    # what stops a serving outage from reading as a bad prompt.
    assert report.results[0].category is ErrorCategory.RATE_LIMITED


async def test_the_table_is_the_thing_a_later_run_is_compared_against():
    engine = ScriptedLLM(default=[Envelope.result(GOOD)])
    report = await run_conformance(engine, [_case("clean")] * 3, model="devstral-24b")

    table = render([report], title="Conformance — scripted baseline")
    assert "| devstral-24b | reviewer-v1-local |" in table
    assert "100%" in table


async def test_the_committed_scripted_baseline_is_the_one_this_code_produces():
    """The doc is a baseline only if it cannot drift away from the code that made it."""
    from pathlib import Path

    cases = [
        ConformanceCase(
            name=name, template_id="reviewer-v1-local", prompt="p", model_type=ReviewResult
        )
        for name in PATHOLOGICAL
    ]
    report = await run_conformance(
        ScriptedLLM(default=list(PATHOLOGICAL.values())), cases, model="scripted"
    )

    committed = (
        Path(__file__).resolve().parents[2] / "docs/measurements/conformance.md"
    ).read_text()
    assert report.as_row() in committed
