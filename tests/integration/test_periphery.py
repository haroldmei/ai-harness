"""Issue #67 — the periphery: wrapped scripts, the canary, the scout, loop-until-dry.

§3.16 disposes of these as *wrap temporarily*: they are independent of the issue→merge path, so
each is invoked behind a typed result rather than ported. The tests below are about the two
things wrapping must not lose — that no caller parses a log line, and that the safety properties
of the originals survive the translation.

The canary tests use a stub `gcloud` that serves recorded JSON, in the same spirit as
`canary-deploy.test.sh`: the logic under test is which URL is smoked and which revision traffic
returns to, and neither needs a cloud account to be wrong.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import pytest

from ai_harness.deploy.canary import Canary, CanaryState
from ai_harness.deploy.smoke import Smoker
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.providers.deploy.script import ScriptProvider
from ai_harness.providers.forge.fake import FakeForge
from ai_harness.quality.adversarial import AdversarialLoop
from ai_harness.schemas.deploy import SmokeCheck
from ai_harness.schemas.enums import Capability, Decision, GateStatus, Signal
from ai_harness.schemas.gates import AdversarialFinding, GateReport, GateResult
from ai_harness.schemas.policy import Policy
from ai_harness.schemas.scout import ScoutCandidate, ScoutVerdict
from ai_harness.scout.service import PROPOSED, SPECULATIVE, Scout
from ai_harness.subgraphs.validate import ValidateContext, ValidateSubgraph

# ── the canary ───────────────────────────────────────────────────────────────────


def _gcloud(tmp_path: Path, described: dict[str, Any]) -> ScriptProvider:
    """A stub cloud CLI: serves `describe` from JSON, records every other invocation."""
    payload = tmp_path / "describe.json"
    payload.write_text(json.dumps(described))
    calls = tmp_path / "calls.txt"
    calls.touch()
    program = tmp_path / "gcloud.py"
    program.write_text(
        "import sys, pathlib\n"
        f"pathlib.Path({str(calls)!r}).open('a').write(' '.join(sys.argv[1:]) + '\\n')\n"
        "if '--format=json' in sys.argv:\n"
        f"    sys.stdout.write(pathlib.Path({str(payload)!r}).read_text())\n"
        "sys.exit(0)\n"
    )
    provider = ScriptProvider(command=[sys.executable, str(program)])
    provider.env = {}
    provider._calls = calls  # type: ignore[attr-defined]
    return provider


def _calls(provider: ScriptProvider) -> list[str]:
    return [line for line in provider._calls.read_text().splitlines() if line]  # type: ignore[attr-defined]


def _canary(tmp_path: Path, described: dict[str, Any], *, healthy: bool = True) -> Canary:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200 if healthy else 503, text="ok")

    return Canary(
        runner=_gcloud(tmp_path, described),
        state=CanaryState(directory=tmp_path / "state"),
        workspace=tmp_path,
        smoker=Smoker(
            client=httpx.AsyncClient(transport=httpx.MockTransport(handler)), clock=FrozenClock()
        ),
    )


LIVE = {
    "status": {
        "traffic": [
            {"revisionName": "svc-00007", "percent": 100},
            {"revisionName": "svc-00008", "percent": 0, "tag": "canary", "url": "https://canary"},
        ]
    }
}


async def test_the_rollback_target_is_recorded_before_anything_is_deployed(
    tmp_path: Path,
) -> None:
    """The step that is easy to omit and impossible to add later.

    After the deploy there is no longer a way to ask which revision was the good one.
    """
    canary = _canary(tmp_path, LIVE)
    assert (await canary.pin_healthy("svc")).unwrap() == "svc-00007"
    assert canary.state.healthy("svc") == "svc-00007"


async def test_the_canary_revision_is_never_the_rollback_target(tmp_path: Path) -> None:
    """Rolling back *to* the tagged revision would pin traffic to the one that just failed."""
    assert (await _canary(tmp_path, LIVE).pin_healthy("svc")).unwrap() != "svc-00008"


async def test_the_deploy_takes_no_traffic(tmp_path: Path) -> None:
    """The prior revision keeps serving 100%; the new one is reachable only at its tag URL."""
    canary = _canary(tmp_path, LIVE)
    await canary.deploy("svc", "gcr.io/x/y:1")
    argv = _calls(canary.runner)[0]
    assert "--no-traffic" in argv and "--tag=canary" in argv


async def test_smoke_targets_the_canary_url_not_the_live_one(tmp_path: Path) -> None:
    """Smoking the live URL tests the revision being replaced: it passes every time."""
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        return httpx.Response(200, text="ok")

    canary = Canary(
        runner=_gcloud(tmp_path, LIVE),
        state=CanaryState(directory=tmp_path / "state"),
        workspace=tmp_path,
        smoker=Smoker(
            client=httpx.AsyncClient(transport=httpx.MockTransport(handler)), clock=FrozenClock()
        ),
    )
    report = (await canary.smoke("svc", [SmokeCheck(name="root", path="/health")])).unwrap()
    assert report.passed
    assert seen == ["https://canary/health"]


async def test_smoke_refuses_when_there_is_no_canary_url(tmp_path: Path) -> None:
    """Falling back to the live URL would turn a missing deploy into a green result."""
    outcome = await _canary(tmp_path, {"status": {"traffic": []}}).smoke("svc")
    assert outcome.is_err
    assert "did the deploy step run" in (outcome.error.message if outcome.error else "")


async def test_the_canary_cannot_be_promoted_under_the_standard_policy(tmp_path: Path) -> None:
    """The acceptance criterion: promotion is not reachable by approval alone."""
    outcome = await _canary(tmp_path, LIVE).promote("svc", policy=Policy(), approved=True)
    assert outcome.category is ErrorCategory.POLICY


def _override() -> Policy:
    policy = Policy()
    return policy.model_copy(
        update={"capabilities": {**policy.capabilities, Capability.DEPLOY_PROD: Decision.ALLOW}}
    )


async def test_a_policy_override_still_requires_an_approval(tmp_path: Path) -> None:
    """Two deliberate human acts, not one. The approval is for promoting *this* result."""
    canary = _canary(tmp_path, LIVE)
    outcome = await canary.promote("svc", policy=_override(), approved=False)
    assert outcome.category is ErrorCategory.NEEDS_HUMAN
    assert not any("update-traffic" in call for call in _calls(canary.runner))


async def test_an_approved_promotion_shifts_traffic_and_drops_the_tag(tmp_path: Path) -> None:
    canary = _canary(tmp_path, LIVE)
    assert (await canary.promote("svc", policy=_override(), approved=True)).is_ok
    calls = _calls(canary.runner)
    assert any("--to-latest" in call for call in calls)
    assert any("--remove-tags=canary" in call for call in calls)


async def test_a_rollback_restores_the_recorded_revision_and_still_fails(tmp_path: Path) -> None:
    """Traffic is safe; the deploy is still a failure and must go red."""
    canary = _canary(tmp_path, LIVE)
    await canary.pin_healthy("svc")
    outcome = await canary.rollback("svc")

    assert outcome.is_err, "a workflow that went green here would ship the belief that it worked"
    assert outcome.error is not None and outcome.error.details["restored"] == "svc-00007"
    assert any("--to-revisions=svc-00007=100" in call for call in _calls(canary.runner))


async def test_a_first_deploy_has_no_rollback_target_and_says_so(tmp_path: Path) -> None:
    """Nothing is broken — the --no-traffic deploy never served — but nothing can be promoted."""
    canary = _canary(tmp_path, {"status": {"traffic": []}})
    await canary.pin_healthy("svc")
    outcome = await canary.rollback("svc")
    assert outcome.category is ErrorCategory.NEEDS_HUMAN
    assert "no last-healthy revision" in (outcome.error.message if outcome.error else "")


# ── the scout ────────────────────────────────────────────────────────────────────


def _candidate(**kw: Any) -> ScoutCandidate:
    base: dict[str, Any] = {
        "title": "the retry loop never resets its counter",
        "engine": "bug",
        "severity": "p1",
        "evidence": "app/retry.py:12",
        "confidence": 0.9,
    }
    base.update(kw)
    return ScoutCandidate(**base)


def _repo(tmp_path: Path) -> Path:
    (tmp_path / "app").mkdir(parents=True, exist_ok=True)
    (tmp_path / "app" / "retry.py").write_text("\n".join(f"line {n}" for n in range(1, 40)))
    return tmp_path


async def _produce(*candidates: ScoutCandidate) -> Any:
    async def producer(workspace: Path) -> list[ScoutCandidate]:
        return list(candidates)

    return producer


async def test_the_scout_files_issues_and_nothing_else(tmp_path: Path) -> None:
    forge = FakeForge()
    scout = Scout(forge=forge, workspace=_repo(tmp_path), producer=await _produce(_candidate()))
    report = (await scout.scan()).unwrap()

    assert len(report.filed) == 1
    filed = forge.issues[report.filed[0]]
    assert PROPOSED in filed.labels
    assert "scout-fingerprint" in filed.body


async def test_found_nothing_files_nothing(tmp_path: Path) -> None:
    """A scout that always files something is a scout that files noise."""
    forge = FakeForge()
    report = (
        await Scout(forge=forge, workspace=tmp_path, producer=await _produce()).scan()
    ).unwrap()
    assert report.filed_nothing and forge.issues == {}


async def test_a_hallucinated_citation_is_not_evidence(tmp_path: Path) -> None:
    """The bug engine's file:line is re-verified locally before filing — one file read."""
    forge = FakeForge()
    scout = Scout(
        forge=forge,
        workspace=_repo(tmp_path),
        producer=await _produce(
            _candidate(evidence="app/retry.py:9999"),
            _candidate(title="second", evidence="app/does-not-exist.py:1"),
            _candidate(title="third", evidence="somewhere in the retry code"),
            _candidate(title="fourth", evidence=""),
        ),
    )
    report = (await scout.scan()).unwrap()

    assert report.filed_nothing
    assert report.dropped == {
        "cited a line past the end of the file": 1,
        "cited a file that does not exist": 1,
        "unparseable evidence": 1,
        "no evidence": 1,
    }


async def test_a_critic_refutation_stops_a_finding_being_filed(tmp_path: Path) -> None:
    """A *different* model, because same-model self-review agrees with itself."""

    async def critic(candidate: ScoutCandidate) -> ScoutVerdict:
        return ScoutVerdict(refuted=True, reason="already built")

    forge = FakeForge()
    report = (
        await Scout(
            forge=forge,
            workspace=_repo(tmp_path),
            producer=await _produce(_candidate()),
            critic=critic,
        ).scan()
    ).unwrap()
    assert report.filed_nothing and report.dropped == {"already built": 1}


async def test_a_finding_a_human_already_closed_is_not_re_filed(tmp_path: Path) -> None:
    """Closed matters more than open: re-filing a rejection is how attention is lost."""
    forge = FakeForge()
    first = (
        await Scout(
            forge=forge, workspace=_repo(tmp_path), producer=await _produce(_candidate())
        ).scan()
    ).unwrap()
    await forge.close_issue(first.filed[0], reason="wontfix")

    second = (
        await Scout(
            forge=forge, workspace=_repo(tmp_path), producer=await _produce(_candidate())
        ).scan()
    ).unwrap()
    assert second.filed_nothing and second.dropped == {"duplicate": 1}


async def test_two_wordings_of_one_defect_are_one_finding(tmp_path: Path) -> None:
    forge = FakeForge()
    report = (
        await Scout(
            forge=forge,
            workspace=_repo(tmp_path),
            producer=await _produce(
                _candidate(title="the retry loop never resets its counter"),
                _candidate(title="The  retry loop never  resets its counter."),
            ),
        ).scan()
    ).unwrap()
    assert len(report.filed) == 1


async def test_the_per_run_cap_withholds_rather_than_drops(tmp_path: Path) -> None:
    """Withheld survivors are not lost: the next pass sees them again."""
    forge = FakeForge()
    report = (
        await Scout(
            forge=forge,
            workspace=_repo(tmp_path),
            max_issues=2,
            producer=await _produce(
                _candidate(title="first", evidence="app/retry.py:1", severity="p2"),
                _candidate(title="second", evidence="app/retry.py:2", severity="p0"),
                _candidate(title="third", evidence="app/retry.py:3", severity="p1"),
            ),
        ).scan()
    ).unwrap()

    assert len(report.filed) == 2 and report.withheld == 1
    assert forge.issues[report.filed[0]].title == "second", "ranked, so p0 goes first"


async def test_a_low_confidence_survivor_is_downgraded_not_dropped(tmp_path: Path) -> None:
    """Real-but-hard-to-reproduce defects must not vanish."""
    forge = FakeForge()
    report = (
        await Scout(
            forge=forge,
            workspace=_repo(tmp_path),
            producer=await _produce(_candidate(confidence=0.2)),
        ).scan()
    ).unwrap()
    assert SPECULATIVE in forge.issues[report.filed[0]].labels


def test_an_unknown_severity_is_rejected_rather_than_treated_as_low() -> None:
    """A typo that quietly demotes a p0 is worse than a loud rejection."""
    with pytest.raises(ValueError, match="unknown severity"):
        _candidate(severity="critical")


def test_the_ranking_is_severity_times_confidence_times_impact() -> None:
    assert _candidate(severity="p0", confidence=1.0, business_impact=1.0).rank == 3.0
    assert _candidate(severity="p0", confidence=0.5).rank == 1.5


# ── loop-until-dry ───────────────────────────────────────────────────────────────


@dataclass
class Attacker:
    """Returns a scripted batch per round."""

    rounds: list[list[AdversarialFinding]] = field(default_factory=list)
    called: int = 0

    async def __call__(self, round_number: int) -> list[AdversarialFinding]:
        self.called += 1
        index = round_number - 1
        return self.rounds[index] if index < len(self.rounds) else []


def _finding(title: str, location: str = "app/x.py:1", **kw: Any) -> AdversarialFinding:
    return AdversarialFinding(title=title, location=location, **kw)


async def test_the_loop_stops_after_consecutive_empty_rounds_not_after_one(tmp_path: Path) -> None:
    """One empty round is weak evidence: an attacker can miss an area once."""
    attacker = Attacker(rounds=[[_finding("a")], [], [_finding("b", "app/y.py:2")], [], []])
    report = await AdversarialLoop(attacker=attacker, max_rounds=9, dry_stop=2).run()

    assert attacker.called == 5
    assert [f.title for f in report.findings] == ["a", "b"]
    assert not report.exhausted


async def test_a_repeat_finding_does_not_reset_the_dry_counter() -> None:
    """Deduping per round instead of per run makes a repeated bug an infinite loop."""
    repeated = _finding("the same bug")
    attacker = Attacker(rounds=[[repeated], [repeated], [repeated], [repeated]])
    report = await AdversarialLoop(attacker=attacker, max_rounds=9, dry_stop=2).run()

    assert attacker.called == 3, "round 1 found it; rounds 2 and 3 added nothing new"
    assert len(report.findings) == 1


async def test_the_round_cap_is_reported_rather_than_hidden() -> None:
    """ "We stopped looking" and "there was nothing left" are different states."""
    attacker = Attacker(rounds=[[_finding(f"bug {n}", f"app/x.py:{n}")] for n in range(10)])
    report = await AdversarialLoop(attacker=attacker, max_rounds=3, dry_stop=2).run()
    assert report.rounds == 3 and report.exhausted


async def test_a_finding_without_a_repro_is_reported_but_carries_no_evidence() -> None:
    attacker = Attacker(
        rounds=[[_finding("a", repro_test="tests/test_a.py"), _finding("b", "app/y.py:2")]]
    )
    report = await AdversarialLoop(attacker=attacker, max_rounds=1, dry_stop=1).run()
    assert [f.title for f in report.reproducible] == ["a"]


async def test_the_adversarial_stage_is_advisory_and_never_reds_a_green_suite(
    tmp_path: Path,
) -> None:
    """A stage that could fail a build on an adversarial opinion makes every tantrum a red build."""

    @dataclass
    class GreenRunner:
        async def run(self, **kw: Any) -> Outcome[GateReport]:
            return Outcome.ok(
                GateReport(results=[GateResult(name="unit", raw_status=GateStatus.PASS)])
            )

        async def rerun(self, report: GateReport, names: list[str]) -> Outcome[GateReport]:
            return Outcome.ok(report)

    loop = AdversarialLoop(
        attacker=Attacker(rounds=[[_finding("something nasty")]]), max_rounds=2, dry_stop=1
    )
    result = (
        await ValidateSubgraph(runner=GreenRunner(), adversary=loop).execute(
            ValidateContext(
                run_id="r1",
                repo="acme/app",
                workspace=tmp_path,
                base_sha="base",
                adversarial=True,
            )
        )
    ).unwrap()

    assert result.signal is Signal.ADVANCE, "findings inform REVIEW; they do not fail VALIDATE"
    assert result.payload["adversarial"]["findings"][0]["title"] == "something nasty"


async def test_the_adversarial_stage_is_opt_in(tmp_path: Path) -> None:
    @dataclass
    class GreenRunner:
        async def run(self, **kw: Any) -> Outcome[GateReport]:
            return Outcome.ok(
                GateReport(results=[GateResult(name="unit", raw_status=GateStatus.PASS)])
            )

        async def rerun(self, report: GateReport, names: list[str]) -> Outcome[GateReport]:
            return Outcome.ok(report)

    loop = AdversarialLoop(attacker=Attacker(rounds=[[_finding("x")]]))
    result = (
        await ValidateSubgraph(runner=GreenRunner(), adversary=loop).execute(
            ValidateContext(run_id="r1", repo="acme/app", workspace=tmp_path, base_sha="base")
        )
    ).unwrap()
    assert "adversarial" not in result.payload
