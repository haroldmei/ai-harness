"""Issues #65 and #66 — the deployment stage, isolated environments, and seed data.

Every assertion below corresponds to a rule the shell scripts learned from an incident, and the
point of the port is that the rule is now a property of an object rather than a convention a
caller has to remember. Where the shell's own header says "three incidents", so does the test.

No docker is required: `docker` is injected as argv everywhere, so the volume-reaping and
bring-up logic run against a stub that records what it was asked to do. What that buys is the
ability to assert the *negative* — that an unrelated volume was never passed to `rm` — which is
the assertion that actually matters and which a real docker could not make safely.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import pytest

from ai_harness.deploy.environments import EnvironmentAllocator
from ai_harness.deploy.seed import Seeder, SeedManifest, dsn_is_ephemeral
from ai_harness.deploy.smoke import Smoker
from ai_harness.deploy.subgraph import DeployContext, DeployStage
from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.providers.deploy.compose import ComposeProvider
from ai_harness.providers.deploy.script import ScriptProvider, last_json_object
from ai_harness.schemas.deploy import (
    Artefact,
    DeployCapability,
    Deployment,
    DeploymentResult,
    EnvironmentSpec,
    SmokeCheck,
    SmokeReport,
)
from ai_harness.schemas.enums import GateStatus, Signal
from ai_harness.schemas.gates import GateReport, GateResult
from ai_harness.schemas.policy import Policy
from ai_harness.subgraphs.validate import ValidateContext, ValidateSubgraph

# ── #65: isolated environments ───────────────────────────────────────────────────


def _allocator(tmp_path: Path, docker: list[str] | None = None) -> EnvironmentAllocator:
    return EnvironmentAllocator(
        root=tmp_path,
        docker=docker or ["docker"],
        clock=FrozenClock(),
        lock_dir=tmp_path / "locks",
    )


def test_the_project_name_is_private_per_run(tmp_path: Path) -> None:
    """Compose namespaces containers, networks and volumes by project. That *is* the isolation."""
    allocator = _allocator(tmp_path)
    one = allocator.allocate("run-aaaa")
    two = allocator.allocate("run-bbbb")
    assert one.project != two.project
    assert one.project.startswith("harness-")


def test_ports_are_offset_never_probed(tmp_path: Path) -> None:
    """`epg_pick_port` bumps on conflict, which is racy by construction.

    Two runs probing from a shared base both see the same port free and both take it. A band per
    slot cannot race, because nothing is checked.
    """
    allocator = _allocator(tmp_path)
    first = allocator.allocate("run-a", slot=0).env()
    second = allocator.allocate("run-b", slot=1).env()
    assert int(second["SF_PG_PORT"]) - int(first["SF_PG_PORT"]) == 1000
    assert first["SF_PG_PORT"] != first["SF_API_PORT"]


def test_the_e2e_database_gets_tmpfs_and_no_named_volume(tmp_path: Path) -> None:
    """Three incidents: a volume from a prior branch carried a stale alembic revision.

    The stack then failed to boot with a generic "dependency failed to start", which is the
    kind of error that costs an afternoon. tmpfs cannot carry anything between runs.
    """
    assert _allocator(tmp_path).allocate("run-a").env()["HARNESS_DB_TMPFS"] == "1"


def test_volume_reaping_is_name_scoped(tmp_path: Path) -> None:
    """An unscoped prune reaches the developer's dev stack and other repositories' data."""
    environment = _allocator(tmp_path).allocate("run-abc")
    assert environment.owns_volume(f"{environment.project}_postgres_data")
    assert environment.owns_volume(f"{environment.project}_redis_data")

    for foreign in (
        "skillforge_postgres_data",  # the developer's dev stack
        "otherproject_postgres_data",
        "harness-run-xyz-0_postgres_data",  # another run's stack
        f"prefix-{environment.project}_postgres_data",  # not anchored at the start
    ):
        assert not environment.owns_volume(foreign), f"{foreign} is not this environment's"


@dataclass
class FakeDocker:
    """Records argv rather than running docker, so the *negative* can be asserted."""

    volumes: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)

    def script(self, tmp_path: Path) -> list[str]:
        listing = tmp_path / "volumes.txt"
        listing.write_text("\n".join(self.volumes))
        recorder = tmp_path / "removed.txt"
        recorder.touch()
        program = tmp_path / "fake_docker.py"
        program.write_text(
            "import sys, pathlib\n"
            "args = sys.argv[1:]\n"
            f"listing = pathlib.Path({str(listing)!r})\n"
            f"recorder = pathlib.Path({str(recorder)!r})\n"
            "if args[:3] == ['volume', 'ls', '-q']:\n"
            "    sys.stdout.write(listing.read_text())\n"
            "elif args[:3] == ['volume', 'rm', '-f']:\n"
            "    recorder.open('a').write(args[3] + '\\n')\n"
            "sys.exit(0)\n"
        )
        self._recorder = recorder  # type: ignore[attr-defined]
        return [sys.executable, str(program)]

    def reaped(self) -> list[str]:
        return [line for line in self._recorder.read_text().split() if line]  # type: ignore[attr-defined]


async def test_an_unrelated_volume_survives_a_reap(tmp_path: Path) -> None:
    """The acceptance criterion, asserted against what docker was actually asked to remove."""
    allocator = _allocator(tmp_path)
    environment = allocator.allocate("run-abc")

    docker = FakeDocker(
        volumes=[
            f"{environment.project}_postgres_data",
            f"{environment.project}_redis_data",
            "skillforge_postgres_data",
            "someone-elses_postgres_data",
        ]
    )
    allocator.docker = docker.script(tmp_path)

    removed = (await allocator.reap(environment)).unwrap()
    assert sorted(removed) == sorted(
        [f"{environment.project}_postgres_data", f"{environment.project}_redis_data"]
    )
    assert "skillforge_postgres_data" not in docker.reaped()
    assert "someone-elses_postgres_data" not in docker.reaped()


async def test_a_missing_docker_is_an_environment_failure_not_a_crash(tmp_path: Path) -> None:
    allocator = _allocator(tmp_path, docker=["/nonexistent/docker"])
    outcome = await allocator.reap(allocator.allocate("run-a"))
    assert outcome.category is ErrorCategory.ENVIRONMENT


async def test_environments_expire_so_a_crashed_run_leaks_nothing(tmp_path: Path) -> None:
    clock = FrozenClock()
    allocator = EnvironmentAllocator(root=tmp_path, clock=clock, lock_dir=tmp_path)
    from datetime import timedelta

    live = Deployment(deployment_id="a", expires_at=clock.now() + timedelta(seconds=600))
    stale = Deployment(deployment_id="b", expires_at=clock.now() - timedelta(seconds=1))
    assert [d.deployment_id for d in await allocator.expired([live, stale])] == ["b"]


async def test_the_same_project_serialises_and_distinct_projects_do_not(tmp_path: Path) -> None:
    """One lock per project: two runs must never share a database mid-migration."""
    allocator = _allocator(tmp_path)
    first = allocator.allocate("run-same")
    duplicate = allocator.allocate("run-same")
    other = allocator.allocate("run-other")

    assert await allocator.hold(first) is not None
    assert await allocator.hold(duplicate) is None, "same project, so it queues"
    assert await allocator.hold(other) is not None, "distinct projects are genuinely parallel"


# ── #65: smoke ───────────────────────────────────────────────────────────────────


async def test_smoke_goes_to_the_deployed_url() -> None:
    """`canary-deploy.sh`'s whole lesson: smoking the live URL tests the code you are replacing."""
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        return httpx.Response(200, text="ok")

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    report = await Smoker(client=client).run(
        "https://canary---svc.run.app", [SmokeCheck(name="root", path="/health")]
    )
    assert report.passed
    assert seen == ["https://canary---svc.run.app/health"]


async def test_a_refused_connection_is_a_failed_check_not_an_exception() -> None:
    """The most important negative result must not arrive as a crash."""

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    report = await Smoker(client=client, clock=FrozenClock()).run(
        "http://127.0.0.1:1", [SmokeCheck(name="root", retries=2, delay_s=0.0)]
    )
    assert not report.passed
    assert "ConnectError" in report.failures[0].reason
    assert report.failures[0].attempts == 2


async def test_a_stack_that_boots_and_serves_500s_is_not_healthy() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="boom")

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    report = await Smoker(client=client, clock=FrozenClock()).run(
        "http://127.0.0.1:8000", [SmokeCheck(name="root", retries=1)]
    )
    assert not report.passed and report.failures[0].status == 500


def test_an_empty_smoke_report_is_not_a_pass() -> None:
    """A deployment nobody checked is not a healthy one."""
    assert SmokeReport().passed is False


def test_a_result_cannot_claim_a_passing_smoke_against_an_unhealthy_stack() -> None:
    """Schema-valid but self-contradicting, so it is corrected in code rather than argued with."""
    assert DeploymentResult(smoke_passed=True, healthy=False).healthy is True


# ── #65: the script provider ─────────────────────────────────────────────────────


def test_the_result_is_read_as_json_never_grepped_from_a_log() -> None:
    """W13: the shell driver greps stage output, so rewording a log line breaks it."""
    text = "building…\nstep 2 of 3\n" + json.dumps({"url": "http://x", "healthy": True})
    assert last_json_object(text) == {"url": "http://x", "healthy": True}
    assert last_json_object("no json here at all") is None
    assert last_json_object('{\n  "url": "http://y"\n}') == {"url": "http://y"}


async def test_a_script_deploy_returns_a_typed_result(tmp_path: Path) -> None:
    program = tmp_path / "deploy.py"
    program.write_text(
        "import json, sys\n"
        "print('deploying', sys.argv[1])\n"
        "print(json.dumps({'url': 'http://127.0.0.1:9000', 'healthy': True,"
        " 'deployed_sha': 'abc123', 'project': 'p'}))\n"
    )
    provider = ScriptProvider(command=[sys.executable, str(program), "{run_id}"])
    deployment = (
        await provider.deploy(
            tmp_path, Artefact(reference="abc123"), EnvironmentSpec(run_id="r1", project="p")
        )
    ).unwrap()
    assert deployment.url == "http://127.0.0.1:9000"
    assert deployment.revision == "abc123"


async def test_a_script_that_prints_no_json_is_a_contract_failure(tmp_path: Path) -> None:
    program = tmp_path / "quiet.py"
    program.write_text("print('done')\n")
    provider = ScriptProvider(command=[sys.executable, str(program)])
    outcome = await provider.deploy(tmp_path, Artefact(), EnvironmentSpec(run_id="r1"))
    assert outcome.category is ErrorCategory.TOOL_FAILURE
    assert "no JSON result" in (outcome.error.message if outcome.error else "")


async def test_a_script_exiting_77_skips_rather_than_fails(tmp_path: Path) -> None:
    """The gate spine's "tooling absent" code, for the same reason: it is not a failed deploy."""
    program = tmp_path / "absent.py"
    program.write_text("import sys; sys.exit(77)\n")
    provider = ScriptProvider(command=[sys.executable, str(program)])
    outcome = await provider.deploy(tmp_path, Artefact(), EnvironmentSpec(run_id="r1"))
    assert outcome.category is ErrorCategory.ENVIRONMENT


async def test_a_script_provider_never_marks_its_own_homework(tmp_path: Path) -> None:
    """A provider reporting "smoked fine" is the failure mode the canary script exists to stop."""
    provider = ScriptProvider(command=["true"])
    report = (await provider.smoke(Deployment(deployment_id="d", url="http://x"), [])).unwrap()
    assert not report.passed


async def test_compose_detect_says_no_with_a_reason(tmp_path: Path) -> None:
    """Unsupported is an answer. A repository that cannot deploy must not be blocked by that."""
    capability = (await ComposeProvider().detect(tmp_path)).unwrap()
    assert not capability.supported
    assert "no compose file" in capability.skip_reason


# ── #65: the stage, and its policy gate ──────────────────────────────────────────


@dataclass
class StubProvider:
    """A provider that records the calls, so the *order* can be asserted."""

    name: str = "stub"
    calls: list[str] = field(default_factory=list)
    supported: bool = True
    build_fails: bool = False
    url: str = "http://127.0.0.1:30800"

    async def detect(self, workspace: Path) -> Outcome[DeployCapability]:
        self.calls.append("detect")
        return Outcome.ok(
            DeployCapability(supported=self.supported, provider=self.name, reason="stub")
        )

    async def build(self, workspace: Path, spec: Any) -> Outcome[Artefact]:
        self.calls.append("build")
        if self.build_fails:
            return Outcome.fail(ErrorCategory.ENVIRONMENT, "the build failed")
        return Outcome.ok(Artefact(reference=spec.revision))

    async def deploy(self, workspace: Path, artefact: Artefact, env: Any) -> Outcome[Deployment]:
        self.calls.append("deploy")
        return Outcome.ok(
            Deployment(deployment_id="d1", url=self.url, project=env.project, revision="abc")
        )

    async def smoke(self, deployment: Deployment, checks: list[SmokeCheck]) -> Outcome[SmokeReport]:
        self.calls.append("smoke")
        return Outcome.ok(SmokeReport(url=deployment.url or ""))

    async def teardown(self, deployment: Deployment) -> Outcome[None]:
        self.calls.append("teardown")
        return Outcome.ok(None)


def _stage(tmp_path: Path, provider: StubProvider, *, passing: bool = True) -> DeployStage:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200 if passing else 503, text="ok" if passing else "no")

    return DeployStage(
        provider=provider,
        allocator=_allocator(tmp_path),
        smoker=Smoker(
            client=httpx.AsyncClient(transport=httpx.MockTransport(handler)), clock=FrozenClock()
        ),
    )


def _ctx(tmp_path: Path, **kw: Any) -> DeployContext:
    base: dict[str, Any] = {
        "run_id": "run-1",
        "repo": "acme/app",
        "workspace": tmp_path,
        "revision": "abc123",
        "checks": [SmokeCheck(name="root", retries=1)],
    }
    base.update(kw)
    return DeployContext(**base)


async def test_production_is_denied_by_the_standard_policy(tmp_path: Path) -> None:
    """§2: out of scope by default. Reaching it takes a policy edit AND an approval."""
    provider = StubProvider()
    outcome = await _stage(tmp_path, provider).execute(_ctx(tmp_path, environment="production"))
    assert outcome.category is ErrorCategory.POLICY
    assert provider.calls == [], "denied before anything was detected, built or allocated"


@pytest.mark.parametrize("environment", ["preview", "staging", "production"])
async def test_nothing_beyond_dev_deploys_without_a_human(tmp_path: Path, environment: str) -> None:
    """Staging holds production-shaped data; treating it as "nearly dev" is how that leaks."""
    outcome = await _stage(tmp_path, StubProvider()).execute(
        _ctx(tmp_path, environment=environment)
    )
    assert outcome.category in (ErrorCategory.POLICY, ErrorCategory.NEEDS_HUMAN)


async def test_dev_deploys_require_approval_under_the_standard_policy(tmp_path: Path) -> None:
    outcome = await _stage(tmp_path, StubProvider()).execute(_ctx(tmp_path))
    assert outcome.category is ErrorCategory.NEEDS_HUMAN


def _permissive() -> Policy:
    from ai_harness.schemas.enums import Capability, Decision

    policy = Policy()
    return policy.model_copy(
        update={"capabilities": {**policy.capabilities, Capability.DEPLOY_DEV: Decision.ALLOW}}
    )


async def test_the_happy_path_builds_before_it_allocates_and_tears_down_after(
    tmp_path: Path,
) -> None:
    """A failed build must not leave a stack allocated, so the order is asserted, not assumed."""
    provider = StubProvider()
    result = (
        await _stage(tmp_path, provider).execute(_ctx(tmp_path, policy=_permissive()))
    ).unwrap()
    assert result.ok and result.smoke_passed
    assert provider.calls == ["detect", "build", "deploy", "teardown"]
    assert result.port_band == 30000


async def test_a_failed_build_never_allocates(tmp_path: Path) -> None:
    provider = StubProvider(build_fails=True)
    outcome = await _stage(tmp_path, provider).execute(_ctx(tmp_path, policy=_permissive()))
    assert outcome.is_err
    assert "deploy" not in provider.calls


async def test_an_unsupported_repository_skips_rather_than_fails(tmp_path: Path) -> None:
    provider = StubProvider(supported=False)
    result = (
        await _stage(tmp_path, provider).execute(_ctx(tmp_path, policy=_permissive()))
    ).unwrap()
    assert result.skipped and result.ok, "optional means optional"


async def test_a_failed_smoke_preserves_the_stack_for_inspection(tmp_path: Path) -> None:
    """Evidence first, cleanup last (§16.4). The TTL reaper collects it anyway."""
    provider = StubProvider()
    outcome = await _stage(tmp_path, provider, passing=False).execute(
        _ctx(tmp_path, policy=_permissive())
    )
    assert outcome.is_err
    assert "teardown" not in provider.calls, "a torn-down failure cannot be examined"


async def test_deployment_metadata_is_checkpointed_by_validate(tmp_path: Path) -> None:
    """The acceptance criterion: the result reaches the run, not just the log."""

    @dataclass
    class GreenRunner:
        async def run(self, **kw: Any) -> Outcome[GateReport]:
            return Outcome.ok(
                GateReport(results=[GateResult(name="unit", raw_status=GateStatus.PASS)])
            )

        async def rerun(self, report: GateReport, names: list[str]) -> Outcome[GateReport]:
            return Outcome.ok(report)

    provider = StubProvider()
    subgraph = ValidateSubgraph(runner=GreenRunner(), deployer=_stage(tmp_path, provider))
    result = (
        await subgraph.execute(
            ValidateContext(
                run_id="run-1",
                repo="acme/app",
                workspace=tmp_path,
                base_sha="base",
                deploy=_ctx(tmp_path, policy=_permissive()),
            )
        )
    ).unwrap()

    assert result.signal is Signal.ADVANCE
    assert result.payload["deployment"]["url"] == provider.url
    assert result.payload["deployment"]["smoke_passed"] is True


async def test_validate_without_a_deployer_is_unchanged(tmp_path: Path) -> None:
    """Optional means a repository that never deploys sees no difference at all."""

    @dataclass
    class GreenRunner:
        async def run(self, **kw: Any) -> Outcome[GateReport]:
            return Outcome.ok(
                GateReport(results=[GateResult(name="unit", raw_status=GateStatus.PASS)])
            )

        async def rerun(self, report: GateReport, names: list[str]) -> Outcome[GateReport]:
            return Outcome.ok(report)

    result = (
        await ValidateSubgraph(runner=GreenRunner()).execute(
            ValidateContext(run_id="run-1", repo="acme/app", workspace=tmp_path, base_sha="base")
        )
    ).unwrap()
    assert result.signal is Signal.ADVANCE
    assert "deployment" not in result.payload


async def test_a_deployment_that_could_not_run_defers_rather_than_blaming_the_branch(
    tmp_path: Path,
) -> None:
    """docker being down is not this branch's doing (invariant 10, #2124)."""

    @dataclass
    class GreenRunner:
        async def run(self, **kw: Any) -> Outcome[GateReport]:
            return Outcome.ok(
                GateReport(results=[GateResult(name="unit", raw_status=GateStatus.PASS)])
            )

        async def rerun(self, report: GateReport, names: list[str]) -> Outcome[GateReport]:
            return Outcome.ok(report)

    @dataclass
    class BrokenStage:
        async def execute(self, ctx: DeployContext) -> Outcome[DeploymentResult]:
            return Outcome.fail(ErrorCategory.ENVIRONMENT, "docker is unreachable")

    outcome = await ValidateSubgraph(runner=GreenRunner(), deployer=BrokenStage()).execute(
        ValidateContext(
            run_id="run-1",
            repo="acme/app",
            workspace=tmp_path,
            base_sha="base",
            deploy=_ctx(tmp_path),
        )
    )
    assert outcome.category is ErrorCategory.ENVIRONMENT


# ── #66: seed data ───────────────────────────────────────────────────────────────


def _environment(tmp_path: Path) -> EnvironmentSpec:
    return _allocator(tmp_path).allocate("run-seed").spec


def _dsn(environment: EnvironmentSpec) -> str:
    return f"postgresql://postgres:postgres@127.0.0.1:{environment.port_base + 432}/app"


@dataclass
class Counter:
    """Row counts from a stub database, with a scripted second reading."""

    counts: dict[str, int]
    second: dict[str, int] | None = None
    reads: int = 0

    async def __call__(self, table: str, query: str) -> int:
        self.reads += 1
        source = self.counts
        if self.second is not None and self.reads > len(self.counts):
            source = self.second
        return source.get(table, 0)


def _manifest(tmp_path: Path, marker: Path | None = None, **kw: Any) -> SeedManifest:
    seed = tmp_path / "seed.py"
    target = marker or (tmp_path / "seeded.txt")
    seed.write_text(f"import pathlib; pathlib.Path({str(target)!r}).open('a').write('x')\n")
    base: dict[str, Any] = {
        "boot_command": [sys.executable, str(seed)],
        "seed_command": [sys.executable, str(seed)],
        "tables": {"courses": 3},
        "idempotent": True,
    }
    base.update(kw)
    return SeedManifest(**base)


async def test_a_production_dsn_is_refused_before_anything_runs(tmp_path: Path) -> None:
    """The one place a mistake is unrecoverable, so it is the one place that refuses to guess."""
    marker = tmp_path / "ran.txt"
    environment = _environment(tmp_path)
    result = await Seeder(counter=Counter({"courses": 5})).run(
        tmp_path,
        manifest=_manifest(tmp_path, marker),
        environment=environment,
        dsn="postgresql://user:pw@db.prod.example.com:5432/app",
    )
    assert not result.ok and "refusing to seed" in result.failures[0]
    assert not marker.exists(), "no command ran at all"


@pytest.mark.parametrize(
    "dsn",
    [
        "",
        "postgresql://u:p@prod-db:5432/app",
        "postgresql://u:p@db.rds.amazonaws.com:5432/app",
        "postgresql://u:p@10.0.0.5:5432/app",
        "postgresql://u:p@127.0.0.1:5432/app",  # right host, wrong port: somebody else's stack
    ],
)
def test_the_dsn_check_fails_closed_on_anything_it_does_not_recognise(
    tmp_path: Path, dsn: str
) -> None:
    ok, why = dsn_is_ephemeral(dsn, _environment(tmp_path))
    assert not ok and why


def test_the_run_s_own_database_is_accepted(tmp_path: Path) -> None:
    environment = _environment(tmp_path)
    ok, _ = dsn_is_ephemeral(_dsn(environment), environment)
    assert ok


async def test_seeding_and_verifying_are_separate_failures(tmp_path: Path) -> None:
    """A seed command exiting 0 is not evidence the rows landed (invariant 12)."""
    environment = _environment(tmp_path)
    result = await Seeder(counter=Counter({"courses": 0})).run(
        tmp_path,
        manifest=_manifest(tmp_path),
        environment=environment,
        dsn=_dsn(environment),
    )
    assert result.seeded is True, "the command ran and exited 0"
    assert result.verified is False, "and the rows are not there"
    assert "courses: 0 rows < min_rows=3" in result.failures[0]


async def test_idempotency_is_asserted_not_assumed(tmp_path: Path) -> None:
    """Re-run the seed; the row counts must not move. This is what makes it safe every deploy."""
    environment = _environment(tmp_path)
    counter = Counter({"courses": 3}, second={"courses": 6})
    result = await Seeder(counter=counter).run(
        tmp_path,
        manifest=_manifest(tmp_path),
        environment=environment,
        dsn=_dsn(environment),
    )
    assert result.seeded and result.verified
    assert result.idempotent is False
    assert "not idempotent" in result.failures[0]
    assert "3 → 6" in result.failures[0]


async def test_a_good_seed_passes_all_three_checks(tmp_path: Path) -> None:
    environment = _environment(tmp_path)
    result = await Seeder(counter=Counter({"courses": 5})).run(
        tmp_path,
        manifest=_manifest(tmp_path),
        environment=environment,
        dsn=_dsn(environment),
    )
    assert result.ok and result.idempotent is True
    assert result.row_counts == {"courses": 5}


async def test_a_failed_seed_is_environment_not_a_code_defect(tmp_path: Path) -> None:
    """Blaming the branch for a broken database burns the fix budget on innocent code."""
    broken = tmp_path / "broken.py"
    broken.write_text("import sys; sys.exit(1)\n")
    environment = _environment(tmp_path)
    result = await Seeder(counter=Counter({})).run(
        tmp_path,
        manifest=SeedManifest(boot_command=[sys.executable, str(broken)], tables={"courses": 1}),
        environment=environment,
        dsn=_dsn(environment),
    )
    assert not result.ok and not result.seeded
    assert "exited 1" in result.failures[0]


async def test_the_gate_and_the_deploy_share_one_implementation(tmp_path: Path) -> None:
    """The acceptance criterion, proven by running both against the same manifest."""
    environment = _environment(tmp_path)
    manifest = _manifest(tmp_path)
    seeder = Seeder(counter=Counter({"courses": 5}), clock=FrozenClock())

    direct = await seeder.run(
        tmp_path, manifest=manifest, environment=environment, dsn=_dsn(environment)
    )
    gate = await Seeder(counter=Counter({"courses": 5}), clock=FrozenClock()).gate(
        tmp_path, manifest=manifest, environment=environment, dsn=_dsn(environment)
    )

    assert direct.ok
    assert gate.status is GateStatus.PASS and gate.name == "seed-integrity"


async def test_the_gate_skips_rather_than_failing_when_the_database_is_absent(
    tmp_path: Path,
) -> None:
    """`seed-integrity.sh` exits 77 for this. A branch must not fail for the host's state."""
    gate = await Seeder(counter=Counter({})).gate(
        tmp_path,
        manifest=_manifest(tmp_path),
        environment=_environment(tmp_path),
        dsn="",
        required=False,
    )
    assert gate.status is GateStatus.SKIP
    assert not gate.promoted, "an honest skip is not promoted to a failure"


def test_a_manifest_is_read_from_the_repository_not_inferred(tmp_path: Path) -> None:
    path = tmp_path / "db-migrator.json"
    path.write_text(
        json.dumps(
            {
                "boot_command": "make migrate && make seed",
                "seed_command": "make seed",
                "version": "3",
                "seed_expectations": {
                    "idempotent": True,
                    "tables": [
                        {"name": "courses", "min_rows": 3},
                        {"name": "users", "min_rows": 1, "count_query": "SELECT 42"},
                    ],
                },
            }
        )
    )
    manifest = SeedManifest.load(path)
    assert manifest.tables == {"courses": 3, "users": 1}
    assert manifest.count_queries == {"users": "SELECT 42"}
    assert manifest.boot_command[:2] == ["bash", "-c"], "a shell string is honoured, visibly"
    assert manifest.version == "3"
