"""The supervisor loop (§22.2).

A worker calls :func:`run_until_boundary` once per dispatch. It may return at any state
boundary, and the run is always resumable from its last checkpoint **by any worker** — which is
the property that makes the shell harness robust and that the port must not lose: no long-lived
process, no in-memory state that survives a tick.

The order of the loop body is not stylistic. Each step exists because the step after it would
otherwise be able to spend something it should not:

1. **circuit breakers, before any spend** — W3: the shell records cost *after* the call, so a
   loop is bounded by iterations rather than by dollars;
2. **parking checks** — a deferred run whose timer has not expired, an approval nobody has
   answered, a blocker still open. Each returns immediately and **releases the lease**, because
   a parked run holding its own lease blocks its own re-dispatch;
3. **attempt caps** — checked against the durable counter, not an in-memory one;
4. **execute the subgraph**, under a timeout, through the boundary that cannot raise;
5. **route deterministically**, with no LLM anywhere near the decision;
6. **write the checkpoint and the run update in ONE transaction** (§15.3).
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import timedelta
from typing import Any

from ai_harness.kernel.budget import CircuitBreaker
from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.ids import idempotency_key
from ai_harness.kernel.lease import LeaseManager, run_lease_key
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.observability.logging import Logger
from ai_harness.orchestration.registry import Registry
from ai_harness.orchestration.router import route
from ai_harness.orchestration.transitions import Transition, consumes_budget
from ai_harness.persistence.sql import SqlStore
from ai_harness.schemas.checkpoint import Checkpoint
from ai_harness.schemas.enums import Disposition, RunStatus, State
from ai_harness.schemas.errors import ErrorInfo
from ai_harness.schemas.run import Run
from ai_harness.subgraphs.base import SubgraphResult, guarded


@dataclass
class Deps:
    """Everything the supervisor needs, injected — nothing is global."""

    store: SqlStore
    registry: Registry
    leases: LeaseManager
    breaker: CircuitBreaker
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)
    blocker_is_closed: Any = None
    """``async (reference) -> bool``. Supplied by the forge; absent means "still blocked"."""
    context_builder: Any = None
    """``async (run, deps) -> ctx``. Absent means the subgraph receives the run itself."""
    lease_ttl_s: float = 900.0


async def run_until_boundary(run_id: str, worker_id: str, deps: Deps) -> RunStatus:
    """Execute one run from its current checkpoint until it parks or terminates."""
    async with deps.leases.hold(
        run_lease_key(run_id), ttl_s=deps.lease_ttl_s, holder=worker_id
    ) as lease:
        if lease is None:
            # Someone else owns it. Not an error — the normal outcome of concurrent dispatch.
            deps.logger.info("run is owned by another worker", run_id=run_id)
            return RunStatus.RUNNING

        run = await deps.store.load(run_id)
        if run is None:
            deps.logger.error("no such run", run_id=run_id)
            return RunStatus.PARKED_TERMINAL

        log = deps.logger.bind(run_id=run_id, worker=worker_id, repo=run.request.repo)

        while True:
            # ── 1. breakers, before any spend ────────────────────────────────────
            verdict = deps.breaker.check(run.spend_view())
            if verdict is not None:
                log.error("budget breaker tripped", reason=verdict.reason, detail=verdict.detail)
                return await _terminate(
                    run,
                    Disposition.ESCALATED,
                    ErrorInfo(
                        category=ErrorCategory.NEEDS_HUMAN,
                        message=f"budget breaker: {verdict.reason}",
                        remedy=verdict.detail,
                    ),
                    deps,
                )

            # ── 2. parked? proceed only if the condition has cleared ─────────────
            parked = await _still_parked(run, deps)
            if parked is not None:
                log.info("run stays parked", status=parked.value, state=run.state.value)
                return parked
            run = _clear_parking(run)

            if run.terminal:
                return RunStatus.PARKED_TERMINAL

            # ── 3. attempt caps, from the durable counter ────────────────────────
            policy = deps.registry.policy_for(run.state)
            attempts = _attempts(run, policy.counter)
            if attempts >= policy.max_attempts:
                log.error("state attempt cap reached", state=run.state.value, attempts=attempts)
                return await _terminate(
                    run,
                    Disposition.ESCALATED,
                    ErrorInfo(
                        category=ErrorCategory.NEEDS_HUMAN,
                        message=f"{run.state.value} attempted {attempts} times",
                        remedy=f"the cap is {policy.max_attempts}; raise it or fix the cause",
                    ),
                    deps,
                )

            # ── 4. execute, bounded, behind the boundary that cannot raise ───────
            subgraph = deps.registry.subgraph_for(run.state)
            ctx = await _build_context(run, deps)
            started = deps.clock.monotonic()
            started_at = deps.clock.now()
            outcome = await _execute(subgraph, ctx, timeout=policy.timeout_s, state=run.state)
            duration = deps.clock.monotonic() - started

            # ── 5. route — deterministically, with no model in sight ─────────────
            result = outcome.value_or_none
            transition = route(
                run.state,
                signal=result.signal if result is not None else None,
                category=outcome.category,
            )
            log.info(
                "state finished",
                state=run.state.value,
                next_state=transition.next_state.value,
                outcome="ok" if outcome.is_ok else str(outcome.category),
                why=transition.reason,
                duration_s=round(duration, 3),
            )

            # ── 6. one transaction ───────────────────────────────────────────────
            run = await _commit(
                run,
                transition,
                outcome,
                result,
                deps,
                duration=duration,
                started_at=started_at,
                attempt=attempts + 1,
            )

            if transition.parks or transition.terminal:
                return run.status
            if run.state is State.COMPLETE:
                return RunStatus.PARKED_TERMINAL


async def _execute(
    subgraph: Any, ctx: Any, *, timeout: float, state: State
) -> Outcome[SubgraphResult]:
    """Run the subgraph under a wall-clock bound. A timeout is an ``Outcome``, not an exception."""

    async def _call() -> Outcome[SubgraphResult]:
        return await asyncio.wait_for(subgraph.execute(ctx), timeout=timeout)

    outcome = await guarded(_call, state=state.value)
    if outcome.is_err and outcome.error is not None and "TimeoutError" in outcome.error.message:
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            f"{state.value} exceeded {timeout:.0f}s",
            remedy="a state that will not finish is an environment problem, not a code defect",
        )
    return outcome


async def _still_parked(run: Run, deps: Deps) -> RunStatus | None:
    """``None`` means proceed. Anything else releases the worker (and, on return, the lease)."""
    if run.status is RunStatus.DEFERRED:
        if run.defer_until is not None and run.defer_until > deps.clock.now():
            return RunStatus.DEFERRED
        return None
    if run.status is RunStatus.AWAITING_APPROVAL:
        if run.pending_approval_id is None:
            return None
        decision = await deps.store.poll(run.pending_approval_id)
        if decision is None:
            return RunStatus.AWAITING_APPROVAL
        if decision.denied:
            await _terminate(
                run,
                Disposition.ESCALATED,
                ErrorInfo(
                    category=ErrorCategory.POLICY,
                    message="approval denied",
                    remedy=decision.reason or "the operator declined; nothing was attempted",
                ),
                deps,
            )
            return RunStatus.PARKED_TERMINAL
        return None
    if run.status is RunStatus.BLOCKED:
        if run.blocked_on is None or deps.blocker_is_closed is None:
            return RunStatus.BLOCKED
        cleared = await deps.blocker_is_closed(run.blocked_on)
        return None if cleared else RunStatus.BLOCKED
    if run.status is RunStatus.PARKED_TERMINAL:
        return RunStatus.PARKED_TERMINAL
    return None


def _clear_parking(run: Run) -> Run:
    if run.status is RunStatus.RUNNING:
        return run
    return run.model_copy(
        update={
            "status": RunStatus.RUNNING,
            "defer_until": None,
            "pending_approval_id": None,
            "blocked_on": None if run.status is RunStatus.BLOCKED else run.blocked_on,
        }
    )


def _attempts(run: Run, counter: str | None) -> int:
    return 0 if counter is None else int(getattr(run.counters, counter, 0))


async def _build_context(run: Run, deps: Deps) -> Any:
    if deps.context_builder is None:
        return run
    return await deps.context_builder(run, deps)


async def _commit(
    run: Run,
    transition: Transition,
    outcome: Outcome[SubgraphResult],
    result: SubgraphResult | None,
    deps: Deps,
    *,
    duration: float,
    started_at: Any,
    attempt: int,
) -> Run:
    """Apply the transition and record the checkpoint atomically."""
    counters = run.counters
    if transition.counter and consumes_budget(outcome.category):
        counters = counters.bump(transition.counter)
    if outcome.category is ErrorCategory.UNKNOWN:
        # An empty envelope is a *streak*, bounded separately, and it costs no state budget.
        counters = counters.bump("empty_envelope_streak")
    elif outcome.is_ok:
        counters = counters.model_copy(update={"empty_envelope_streak": 0})

    error = ErrorInfo.from_record(outcome.error) if outcome.error is not None else None
    defer_until = (
        deps.clock.now() + timedelta(seconds=transition.defer_for_s)
        if transition.defer_for_s
        else None
    )

    updates: dict[str, Any] = {
        "state": transition.next_state,
        "status": transition.status,
        "disposition": transition.disposition,
        "counters": counters,
        "defer_until": defer_until,
        "last_error": error.message if error else None,
        "spend_usd": run.spend_usd + (result.usd if result else 0),
        "tokens": run.tokens + ((result.input_tokens + result.output_tokens) if result else 0),
    }
    if result is not None:
        updates["head_sha"] = result.head_sha or run.head_sha
        updates["base_sha"] = result.base_sha or run.base_sha
    if transition.terminal:
        updates["finished_at"] = deps.clock.now()

    advanced = run.model_copy(update=updates)
    seq = await deps.store.next_seq(run.run_id)
    checkpoint = Checkpoint(
        run_id=run.run_id,
        seq=seq,
        state=run.state,
        next_state=transition.next_state,
        status=transition.status,
        attempt=attempt,
        round=run.counters.review_rounds,
        idempotency_key=idempotency_key(
            run.state.value.lower(), run=run.run_id, attempt=attempt, sha=run.head_sha
        ),
        started_at=started_at,
        finished_at=deps.clock.now(),
        duration_s=duration,
        usd=result.usd if result else 0,
        input_tokens=result.input_tokens if result else 0,
        output_tokens=result.output_tokens if result else 0,
        cache_read_tokens=result.cache_read_tokens if result else 0,
        model=result.model if result else None,
        template_id=result.template_id if result else None,
        prompt_sha256=result.prompt_sha256 if result else None,
        prompt_bytes=result.prompt_bytes if result else None,
        base_sha=advanced.base_sha,
        head_sha=advanced.head_sha,
        isolation=result.isolation if result else None,
        artefacts=list(result.artefacts) if result else [],
        result={"signal": result.signal.value, "why": transition.reason, **result.payload}
        if result
        else {"why": transition.reason},
        error=error,
    )
    return await deps.store.commit_transition(advanced, checkpoint)


async def _terminate(run: Run, disposition: Disposition, error: ErrorInfo, deps: Deps) -> RunStatus:
    """End the run, recording *why* — never by silently dropping it."""
    advanced = run.model_copy(
        update={
            "state": State.COMPLETE,
            "status": RunStatus.PARKED_TERMINAL,
            "disposition": disposition,
            "finished_at": deps.clock.now(),
            "last_error": error.message,
        }
    )
    seq = await deps.store.next_seq(run.run_id)
    await deps.store.commit_transition(
        advanced,
        Checkpoint(
            run_id=run.run_id,
            seq=seq,
            state=run.state,
            next_state=State.COMPLETE,
            status=RunStatus.PARKED_TERMINAL,
            finished_at=deps.clock.now(),
            base_sha=run.base_sha,
            head_sha=run.head_sha,
            result={"why": error.remedy or error.message},
            error=error,
        ),
    )
    return RunStatus.PARKED_TERMINAL
