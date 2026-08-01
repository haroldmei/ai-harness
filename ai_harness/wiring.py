"""The composition root — the one place that knows how everything fits together.

Every module in this package takes its collaborators as constructor arguments and reaches for
nothing global. That is what makes them testable, and it leaves exactly one thing undone: some
single place must actually build the graph. Until now nothing did, which is why `agent work` and
`agent tick` did not exist even though `Worker` and `Ticker` were finished and tested.

Three rules this file follows, in the order they matter:

1. **It is the only file that constructs things it did not receive.** Anything that reaches for
   an engine, a token or a path does it here, so a test that wants a different one substitutes a
   value rather than patching a module.

2. **Missing credentials are a startup failure, not a runtime one.** A worker that starts, claims
   a run, spends a lease and *then* discovers `ANTHROPIC_API_KEY` is unset has consumed a
   dispatch and produced nothing. :func:`build_deps` refuses up front, with the name of what is
   missing.

3. **A repository that is not cut over cannot be driven.** ``profile.engine`` gates this, and
   the check lives here rather than in the CLI so every entry point inherits it — the flag is
   the Phase 2–5 rollback and it is only worth anything if nothing can route around it.

The registry binds all seven states. States whose subgraph needs something absent (a forge token
for INTEGRATE, say) are left unbound *deliberately*: an unbound state escalates with a reason,
which is a run parked for a human rather than a run that silently skipped its own integration.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from ai_harness.agents.planner import Planner
from ai_harness.agents.reviewer import Reviewer
from ai_harness.agents.roster import AgentRoster, Role
from ai_harness.agents.triager import Triager
from ai_harness.config import HarnessConfig
from ai_harness.kernel.budget import CircuitBreaker, CostTracker
from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.lease import FlockLeaseBackend, LeaseBackend, LeaseManager
from ai_harness.llm.client import LLMClient
from ai_harness.llm.engines.protocol import Engine
from ai_harness.llm.pacing import GpuTime
from ai_harness.observability.logging import Logger
from ai_harness.orchestration.machine import Deps
from ai_harness.orchestration.registry import Registry
from ai_harness.persistence.leases import SqlLeaseBackend
from ai_harness.persistence.queue import SqlQueue
from ai_harness.persistence.sql import SqlStore
from ai_harness.providers.forge.protocol import Forge
from ai_harness.providers.git.cli import GitCLI
from ai_harness.quality.discovery import discover
from ai_harness.quality.runner import GateRunner
from ai_harness.schemas.enums import State, Tier
from ai_harness.subgraphs.analyse import AnalyseSubgraph
from ai_harness.subgraphs.implement import ImplementSubgraph
from ai_harness.subgraphs.integrate import IntegrateSubgraph
from ai_harness.subgraphs.review import ReviewSubgraph
from ai_harness.subgraphs.validate import ValidateSubgraph


class WiringError(RuntimeError):
    """Raised at startup, never mid-run.

    The distinction is the whole point: a misconfiguration discovered before the first claim
    costs a process exit and a clear message, and the same one discovered after the claim costs
    a lease, a dispatch and an escalated run that blames the branch.
    """


@dataclass(frozen=True, slots=True)
class Harness:
    """Everything an entry point needs, assembled."""

    config: HarnessConfig
    store: SqlStore
    deps: Deps
    queue: SqlQueue
    forge: Forge | None = None
    unbound: tuple[State, ...] = ()
    """States left unbound, and therefore escalating with a reason rather than skipping."""

    def close(self) -> None:
        self.store.dispose()


# ── the pieces ───────────────────────────────────────────────────────────────────


def build_engine(config: HarnessConfig, *, logger: Logger | None = None) -> Engine:
    """One engine, chosen by name. An unknown name is a startup error, not a default.

    Defaulting here would mean a typo in ``roster.engine`` silently ran every model call
    through whichever engine happened to be first — the same class of bug as an unknown tier
    defaulting to the weakest gate set.
    """
    if config.roster.engines:
        return build_router(config, logger=logger)
    name = config.roster.engine
    if name == "claude-cli":
        from ai_harness.llm.engines.claude_cli import ClaudeCLIEngine

        return ClaudeCLIEngine(cwd=str(config.repo_path))
    if name in ("anthropic", "anthropic-api"):
        from ai_harness.llm.engines.anthropic_api import AnthropicAPIEngine

        _require("ANTHROPIC_API_KEY")
        anthropic: Engine = AnthropicAPIEngine()
        return anthropic
    if name in ("openai", "openai-api"):
        from ai_harness.llm.engines.openai_api import OpenAIEngine

        _require("OPENAI_API_KEY")
        engine: Engine = OpenAIEngine()
        return engine
    if name in ("local", "vllm"):
        return build_local_engine(config, logger=logger)
    raise WiringError(
        f"unknown engine {name!r}; expected claude-cli, anthropic, openai or local. "
        "Nothing is defaulted here on purpose: a typo would silently change every model call."
    )


def roster_models(config: HarnessConfig) -> dict[Role, str]:
    """The five role→model bindings, in one place, so nothing re-derives them differently."""
    return {
        Role.PLANNER: config.roster.planner_model,
        Role.IMPLEMENTER: config.roster.implementer_model,
        Role.REVIEWER: config.roster.reviewer_model,
        Role.CONFLICT_RESOLVER: config.roster.conflict_resolver_model,
        Role.TRIAGER: config.roster.triager_model,
    }


def build_router(config: HarnessConfig, *, logger: Logger | None = None) -> Engine:
    """One engine per model — the shape a local roster actually has.

    Every model the roster names must be routable *before* anything is claimed. The alternative
    is discovering at REVIEW that the reviewer's model was never served, which costs a run, and
    which the roster's own reviewer-≠-implementer refusal exists to make impossible in the other
    direction.
    """
    from ai_harness.llm.engines.routing import RoutingEngine, RoutingError

    named = {model for model in roster_models(config).values() if model}
    unmapped = sorted(named - set(config.roster.engines))
    if unmapped:
        # The same rule as `build_engine`, one level down. Falling back to `roster.engine` here
        # would send a mistyped local model name to the cloud CLI, and the resulting review
        # would look exactly like a real one.
        raise WiringError(
            f"roster.engines names no engine for {', '.join(unmapped)}. A mixed roster must map "
            "every model explicitly: defaulting would route a typo somewhere plausible."
        )
    routes: dict[str, Engine] = {}
    for model in sorted(named):
        routes[model] = _engine_named(
            config.roster.engines[model], config, model=model, logger=logger
        )

    fallbacks: dict[str, Engine] = {}
    if config.roster.fallback_engine:
        target = _engine_named(config.roster.fallback_engine, config, logger=logger)
        for model in config.roster.fallback_models:
            fallbacks[model] = target

    try:
        router = RoutingEngine(routes=routes, fallbacks=fallbacks)
        router.requires(*named)
    except RoutingError as exc:
        raise WiringError(str(exc)) from exc
    return router


def _engine_named(
    name: str, config: HarnessConfig, *, model: str | None = None, logger: Logger | None = None
) -> Engine:
    """Build one engine by name, without consulting the roster's own default."""
    scoped = config.model_copy(deep=True)
    scoped.roster.engines = {}
    scoped.roster.engine = name
    if model is not None and name in ("local", "vllm"):
        return build_local_engine(scoped, model=model, logger=logger)
    return build_engine(scoped, logger=logger)


LOCAL_LEASE_TTL_S = 3600.0
"""A local state can be a model swap plus several minutes of generation, and a lease that
expires mid-generation is a lost run — the failure a week-long soak finds and a unit test does
not. The hosted default stays 900s, where a state that takes fifteen minutes is already wrong."""


def lease_ttl_for(config: HarnessConfig) -> float:
    engines = {config.roster.engine, *config.roster.engines.values()}
    return LOCAL_LEASE_TTL_S if engines & {"local", "vllm"} else 900.0


def probe_cache_path(config: HarnessConfig) -> Path:
    state = config.state_dir
    if not state.is_absolute():
        state = config.repo_path / state
    return state / "probe-cache.json"


def build_local_engine(
    config: HarnessConfig,
    *,
    model: str | None = None,
    logger: Logger | None = None,
) -> Engine:
    """A vLLM engine for one served model, with its window and capabilities already known.

    The window comes from the registry rather than from the first rejection: the *point* of L6 is
    to refuse an oversized prompt before it reaches the wire, and an engine that learns its window
    by being told off has already paid for the round trip it exists to avoid.

    Capabilities come from the cached probe when one exists for this exact (server, model,
    revision), and otherwise stay at their conservative defaults with a warning. This is
    deliberately not a refusal: an unprobed server is *slower* — every structured call falls back
    to the extraction ladder — but it is not unsafe, and refusing here would make `agent work`
    unusable until somebody ran a second command. The probe is network I/O, and the composition
    root does not do network I/O.
    """
    from ai_harness.llm.engines.vllm import VLLMEngine
    from ai_harness.llm.serving.models import RegistryError, load_registry
    from ai_harness.llm.serving.probe import ProbeCache

    try:
        registry = load_registry(root=config.repo_path)
        plan = registry.plan(model or config.roster.implementer_model)
    except RegistryError as exc:
        raise WiringError(
            f"the local engine needs a model registry: {exc}\n"
            "Refusing at startup: a worker that discovers this after claiming has already spent "
            "a dispatch and a lease."
        ) from exc

    engine = VLLMEngine(base_url=plan.base_url, max_model_len=plan.max_model_len)
    cached = ProbeCache(probe_cache_path(config)).load(
        base_url=plan.base_url, model=plan.spec.name, revision=plan.spec.revision
    )
    if cached is not None:
        engine.capabilities = cached.capabilities()
        if cached.max_model_len is not None:
            engine.max_model_len = min(plan.max_model_len, cached.max_model_len)
    elif logger is not None:
        logger.warning(
            "no capability probe for this model revision; assuming the conservative defaults",
            model=plan.spec.name,
            effect="structured output goes through the extraction ladder and costs repairs",
            remedy=f"run `agent serving probe {plan.spec.name}`",
        )
    return engine


def build_forge(config: HarnessConfig) -> Forge | None:
    """The forge, or ``None`` when no token is configured.

    ``None`` rather than an exception, because a repository can be analysed, implemented and
    validated without one. What it cannot do is INTEGRATE, and that state is then left unbound
    so the run escalates saying so — instead of reaching REVIEW and failing on the first write.
    """
    if config.forge == "gitlab":
        token = os.environ.get("GITLAB_TOKEN", "")
        if not token:
            return None
        from ai_harness.providers.forge.gitlab import GitLabForge

        return GitLabForge(project=config.profile.name, token=token)

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    if not token:
        return None
    from ai_harness.providers.forge.github import GitHubForge

    return GitHubForge(repo=config.profile.name, token=token)


def build_leases(config: HarnessConfig, store: SqlStore, clock: Clock) -> LeaseBackend:
    """SQL leases when the store is shared, ``flock`` when it is a local file.

    §26's trigger, applied rather than described: a SQLite file is one host by construction, and
    ``flock`` is both correct and cheaper there. The moment the store is Postgres the fleet is
    possible, so liveness has to be a column any host can read.
    """
    if store.engine.dialect.name == "sqlite":
        return FlockLeaseBackend(directory=config.lease_dir, clock=clock)
    return SqlLeaseBackend(engine=store.engine, clock=clock)


def build_registry(
    config: HarnessConfig,
    *,
    client: LLMClient,
    roster: AgentRoster,
    forge: Forge | None,
    logger: Logger,
) -> tuple[Registry, tuple[State, ...]]:
    """Bind the states, and report the ones deliberately left unbound."""
    registry = Registry()
    unbound: list[State] = []

    git = GitCLI(root=config.repo_path)
    triager = Triager()

    registry.bind(
        State.ANALYSE,
        AnalyseSubgraph(
            planner=Planner(client=client, model=roster.model_for(Role.PLANNER)), triager=triager
        ),
    )
    registry.bind(State.IMPLEMENT, ImplementSubgraph(git=git))
    registry.bind(
        State.REVIEW,
        ReviewSubgraph(reviewer=Reviewer(client=client, model=roster.model_for(Role.REVIEWER))),
    )

    # The discovery ladder decides the gate profile; an unresolvable one escalates rather than
    # silently running a weaker set (§19.2 rung 5), which is why the Discovery is kept whole.
    discovery = discover(config.repo_path, tier=config.tier or Tier.LAUNCH)
    registry.bind(
        State.VALIDATE,
        ValidateSubgraph(
            runner=GateRunner(
                root=config.repo_path,
                profile=discovery.profile,
                project_prefix=config.profile.compose_project_prefix,
            ),
            triager=triager,
        ),
    )

    if forge is not None:
        registry.bind(State.INTEGRATE, IntegrateSubgraph(git=git, forge=forge))
    else:
        # Left unbound on purpose. An unbound state escalates with a reason, which parks the run
        # for a human — strictly better than reaching INTEGRATE and discovering there is no
        # token at the moment it tries to push.
        unbound.append(State.INTEGRATE)
        logger.warning(
            "INTEGRATE is unbound: no forge token is configured",
            forge=config.forge,
            effect="runs will escalate at INTEGRATE rather than fail while pushing",
        )

    return registry, tuple(unbound)


def build_deps(
    config: HarnessConfig,
    *,
    store: SqlStore,
    clock: Clock | None = None,
    logger: Logger | None = None,
    engine: Engine | None = None,
    forge: Forge | None = None,
) -> tuple[Deps, tuple[State, ...], Forge | None]:
    """Assemble the supervisor's dependencies, refusing early on anything missing."""
    clock = clock or SystemClock()
    logger = logger or Logger()

    roster = AgentRoster(models=roster_models(config))

    tracker = CostTracker(clock=clock)
    breaker = CircuitBreaker(config.policy.budget, tracker, clock=clock)
    client = LLMClient(
        engine=engine or build_engine(config, logger=logger),
        tracker=tracker,
        breaker=breaker,
        clock=clock,
        fallback_limit=config.roster.max_fallbacks_per_run,
    )
    resolved_forge = forge if forge is not None else build_forge(config)

    registry, unbound = build_registry(
        config, client=client, roster=roster, forge=resolved_forge, logger=logger
    )

    deps = Deps(
        store=store,
        registry=registry,
        leases=LeaseManager(build_leases(config, store, clock), clock=clock),
        breaker=breaker,
        clock=clock,
        logger=logger,
        lease_ttl_s=lease_ttl_for(config),
        gpu_time=GpuTime(clock=clock),
        blocker_is_closed=resolved_forge.blocker_closed if resolved_forge is not None else None,
    )
    return deps, unbound, resolved_forge


def build(
    config: HarnessConfig,
    *,
    clock: Clock | None = None,
    logger: Logger | None = None,
    engine: Engine | None = None,
    forge: Forge | None = None,
    require_cutover: bool = True,
) -> Harness:
    """The entry point every command uses. Refuses before it claims anything."""
    clock = clock or SystemClock()
    logger = logger or Logger()

    if require_cutover and config.profile.engine != "python":
        raise WiringError(
            f"{config.profile.name or 'this repository'} is not cut over: profile.engine is "
            f"{config.profile.engine!r}. The shell pipeline is still authoritative for it, and "
            "driving both would mean two engines advancing one run. Set engine: python to "
            "cut over — that flag is also the rollback."
        )

    store = _open_store(config, clock)
    deps, unbound, resolved_forge = build_deps(
        config, store=store, clock=clock, logger=logger, engine=engine, forge=forge
    )
    return Harness(
        config=config,
        store=store,
        deps=deps,
        queue=SqlQueue(store.engine, clock=clock),
        forge=resolved_forge,
        unbound=unbound,
    )


def _open_store(config: HarnessConfig, clock: Clock) -> SqlStore:
    url = config.database_url
    if url.startswith("sqlite"):
        from ai_harness.persistence.sqlite import open_sqlite

        path = Path(url.split("///", 1)[-1])
        if not path.is_absolute():
            path = config.repo_path / path
        return open_sqlite(path, clock=clock)

    from ai_harness.persistence.postgres import open_postgres

    # `create=False`: alembic owns the schema in deployment. Creating tables here would let a
    # worker start against a database nobody migrated and diverge from the revision history.
    return open_postgres(url, clock=clock, create=False)


def _require(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise WiringError(
            f"{name} is not set. Refusing at startup rather than mid-run: a worker that "
            "discovers this after claiming has already spent a dispatch and a lease."
        )
    return value
