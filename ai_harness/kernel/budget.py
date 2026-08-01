"""Budgets, cost tracking, and the run circuit breaker.

W3: the shell harness records cost *after* the call, so a loop is bounded by iterations rather
than by dollars — ``PIPELINE_MAX_ROUNDS=10`` multiplied by an opus review has no ceiling. Here
the breaker is checked **before any spend**, and an estimate is reserved before dispatch and
reconciled against actuals afterwards.

Per Q6 the defaults are $25 per run and $500 per repository per day, and an *unset* budget is a
configuration error rather than "unlimited": :meth:`CircuitBreaker.check` denies a run whose
budget was never configured, which is the only reading of an unset ceiling that cannot spend
someone's money by accident.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, Field

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, ErrorRecord, Outcome


class BudgetSpec(BaseModel):
    """The ceilings for one run. ``None`` means *not configured*, never *unlimited*."""

    model_config = {"frozen": True}

    max_usd_per_run: Decimal | None = Field(default=None, ge=0)
    max_usd_per_repo_day: Decimal | None = Field(default=None, ge=0)
    max_wall_clock_s: float | None = Field(default=None, gt=0)
    max_tokens: int | None = Field(default=None, gt=0)
    max_attempts_per_state: dict[str, int] = Field(default_factory=dict)

    max_model_seconds_per_run: float | None = Field(default=None, gt=0)
    """The local rail (L5). At $0.000133 a GPU-second the dollar ceilings cannot trip in a
    working day, and the scarce resource has moved: one card, one agent, and a REVIEW round that
    takes minutes. Reserved before dispatch and settled against actual generation time, exactly
    like the dollar ceiling — W3's fix applied to the currency that now binds."""
    max_gpu_seconds_per_repo_day: float | None = Field(default=None, gt=0)

    @property
    def configured(self) -> bool:
        return self.max_usd_per_run is not None and self.max_usd_per_repo_day is not None


DEFAULT_BUDGET = BudgetSpec(
    max_usd_per_run=Decimal("25"),
    max_usd_per_repo_day=Decimal("500"),
    max_wall_clock_s=6 * 60 * 60,
)
"""The Q6 defaults, shipped so a first run is bounded rather than unbounded."""

LOCAL_BUDGET = BudgetSpec(
    max_usd_per_run=Decimal("25"),
    max_usd_per_repo_day=Decimal("500"),
    max_wall_clock_s=6 * 60 * 60,
    max_model_seconds_per_run=2 * 60 * 60,
    max_gpu_seconds_per_repo_day=16 * 60 * 60,
)
"""The same ceilings plus the two that can actually trip on a local roster: two hours of
generation for one run, sixteen hours of card per repository per day. A run that needs more than
two hours of *generation* -- not wall-clock, generation -- is not converging."""


SELF_HOSTED: frozenset[str] = frozenset({"local"})
"""Providers whose calls occupy *this* box's card.

It lives beside :class:`CostEvent` rather than in the price table because it is a fact about
*which resource is being spent*, and both the cost store and the client need it without either
of them being allowed to know about the other.
"""


def is_self_hosted(provider: str) -> bool:
    return provider in SELF_HOSTED


@dataclass(frozen=True, slots=True)
class CostEvent:
    """One priced unit of work. The atom of ``agent cost``."""

    run_id: str
    repo: str
    state: str
    provider: str
    model: str
    usd: Decimal
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    template_id: str | None = None
    gpu_seconds: float = 0.0
    """Seconds this call occupied *our* card. Zero for a hosted provider: their capacity is not
    the resource this box runs out of."""
    at: datetime | None = None

    @property
    def tokens(self) -> int:
        return self.input_tokens + self.output_tokens


class CostTracker:
    """Accumulates spend per run and per (repo, day) — the two axes the ceilings use."""

    def __init__(self, *, clock: Clock | None = None) -> None:
        self._clock = clock or SystemClock()
        self._events: list[CostEvent] = []
        self._by_run: dict[str, Decimal] = defaultdict(Decimal)
        self._by_repo_day: dict[tuple[str, date], Decimal] = defaultdict(Decimal)
        self._tokens_by_run: dict[str, int] = defaultdict(int)
        self._seconds_by_run: dict[str, float] = defaultdict(float)
        self._seconds_by_repo_day: dict[tuple[str, date], float] = defaultdict(float)

    def record(self, event: CostEvent) -> CostEvent:
        stamped = event if event.at else _with_time(event, self._clock.now())
        day = stamped.at.date() if stamped.at else self._clock.now().date()
        self._events.append(stamped)
        self._by_run[stamped.run_id] += stamped.usd
        self._by_repo_day[(stamped.repo, day)] += stamped.usd
        self._tokens_by_run[stamped.run_id] += stamped.tokens
        self._seconds_by_run[stamped.run_id] += stamped.gpu_seconds
        self._seconds_by_repo_day[(stamped.repo, day)] += stamped.gpu_seconds
        return stamped

    def run_total(self, run_id: str) -> Decimal:
        return self._by_run[run_id]

    def run_tokens(self, run_id: str) -> int:
        return self._tokens_by_run[run_id]

    def repo_day_total(self, repo: str, day: date | None = None) -> Decimal:
        return self._by_repo_day[(repo, day or self._clock.now().date())]

    def run_seconds(self, run_id: str) -> float:
        """Generation seconds on this box's card. Not wall-clock: tests and Docker are not the
        GPU, and the whole point of `selfhost.md`'s "the GPU is idle" claim is the difference."""
        return self._seconds_by_run[run_id]

    def repo_day_seconds(self, repo: str, day: date | None = None) -> float:
        return self._seconds_by_repo_day[(repo, day or self._clock.now().date())]

    @property
    def events(self) -> list[CostEvent]:
        return list(self._events)


def _with_time(event: CostEvent, at: datetime) -> CostEvent:
    return CostEvent(
        run_id=event.run_id,
        repo=event.repo,
        state=event.state,
        provider=event.provider,
        model=event.model,
        usd=event.usd,
        input_tokens=event.input_tokens,
        output_tokens=event.output_tokens,
        cache_read_tokens=event.cache_read_tokens,
        cache_write_tokens=event.cache_write_tokens,
        template_id=event.template_id,
        gpu_seconds=event.gpu_seconds,
        at=at,
    )


@dataclass(frozen=True, slots=True)
class BreakerVerdict:
    """Why a run may not proceed. Rendered into the escalation, so the text matters."""

    reason: str
    detail: str

    def as_outcome(self) -> Outcome[None]:
        return Outcome[None].fail(
            ErrorCategory.NEEDS_HUMAN,
            f"budget breaker: {self.reason}",
            remedy=self.detail,
        )


@dataclass
class Reservation:
    """An estimate held against a run's ceilings until the actual cost is known."""

    run_id: str
    estimate_usd: Decimal
    estimate_seconds: float = 0.0
    released: bool = False


@dataclass
class RunSpend:
    """The spend facts a breaker needs, without importing the ``Run`` schema (§22.1)."""

    run_id: str
    repo: str
    started_at: datetime
    tokens: int = 0
    attempts_by_state: dict[str, int] = field(default_factory=dict)
    fallbacks: int = 0
    """Calls a hosted engine took because the local one could not. Counted here because this is
    the object that knows which run this is (L7)."""


class CircuitBreaker:
    """The *run* breaker. Checked before every state, before any spend (§22.2 step 1)."""

    def __init__(
        self,
        budget: BudgetSpec,
        tracker: CostTracker,
        *,
        clock: Clock | None = None,
    ) -> None:
        self.budget = budget
        self.tracker = tracker
        self._clock = clock or SystemClock()
        self._reserved: dict[str, Decimal] = defaultdict(Decimal)
        self._reserved_seconds: dict[str, float] = defaultdict(float)

    def check(self, run: RunSpend) -> BreakerVerdict | None:
        """``None`` means proceed. Anything else terminates the run as escalated."""
        if not self.budget.configured:
            return BreakerVerdict(
                reason="not configured",
                detail=(
                    "max_usd_per_run and max_usd_per_repo_day must both be set before autonomy "
                    "is enabled — an unset budget is a configuration error, not 'unlimited'"
                ),
            )
        run_spend = self.committed(run.run_id)
        if self.budget.max_usd_per_run is not None and run_spend >= self.budget.max_usd_per_run:
            return BreakerVerdict(
                reason="run cost ceiling reached",
                detail=f"spent ${run_spend} of ${self.budget.max_usd_per_run}",
            )
        repo_spend = self.tracker.repo_day_total(run.repo)
        if (
            self.budget.max_usd_per_repo_day is not None
            and repo_spend >= self.budget.max_usd_per_repo_day
        ):
            return BreakerVerdict(
                reason="repo daily ceiling reached",
                detail=f"{run.repo} spent ${repo_spend} today of ${self.budget.max_usd_per_repo_day}",
            )
        seconds = self.committed_seconds(run.run_id)
        if (
            self.budget.max_model_seconds_per_run is not None
            and seconds >= self.budget.max_model_seconds_per_run
        ):
            return BreakerVerdict(
                reason="model-time ceiling reached",
                detail=(
                    f"{seconds:.0f}s of generation on this box's GPU, of "
                    f"{self.budget.max_model_seconds_per_run:.0f}s. At local rates the dollar "
                    "ceiling cannot trip in a working day; this is the one that binds"
                ),
            )
        repo_seconds = self.tracker.repo_day_seconds(run.repo)
        if (
            self.budget.max_gpu_seconds_per_repo_day is not None
            and repo_seconds >= self.budget.max_gpu_seconds_per_repo_day
        ):
            return BreakerVerdict(
                reason="repo daily GPU ceiling reached",
                detail=f"{run.repo} used {repo_seconds:.0f}s of card today of "
                f"{self.budget.max_gpu_seconds_per_repo_day:.0f}s",
            )
        if self.budget.max_tokens is not None and run.tokens >= self.budget.max_tokens:
            return BreakerVerdict(
                reason="token ceiling reached",
                detail=f"{run.tokens} tokens of {self.budget.max_tokens}",
            )
        if self.budget.max_wall_clock_s is not None:
            elapsed = (self._clock.now() - run.started_at).total_seconds()
            if elapsed >= self.budget.max_wall_clock_s:
                return BreakerVerdict(
                    reason="wall-clock ceiling reached",
                    detail=f"{elapsed:.0f}s of {self.budget.max_wall_clock_s:.0f}s",
                )
        for state, cap in self.budget.max_attempts_per_state.items():
            if run.attempts_by_state.get(state, 0) >= cap:
                return BreakerVerdict(
                    reason=f"{state} attempt cap reached",
                    detail=f"{run.attempts_by_state.get(state, 0)} attempts of {cap}",
                )
        return None

    def committed(self, run_id: str) -> Decimal:
        """Spent plus reserved. Reservations count, or two concurrent calls both fit."""
        return self.tracker.run_total(run_id) + self._reserved[run_id]

    def committed_seconds(self, run_id: str) -> float:
        return self.tracker.run_seconds(run_id) + self._reserved_seconds[run_id]

    def reserve(
        self, run: RunSpend, estimate_usd: Decimal, estimate_seconds: float = 0.0
    ) -> Outcome[Reservation]:
        """Hold an estimate before dispatch. A denial parks the run *before* the call."""
        verdict = self.check(run)
        if verdict is not None:
            return Outcome[Reservation].of(_verdict_error(verdict))
        projected = self.committed(run.run_id) + estimate_usd
        if self.budget.max_usd_per_run is not None and projected > self.budget.max_usd_per_run:
            return Outcome[Reservation].of(
                _verdict_error(
                    BreakerVerdict(
                        reason="reservation would exceed the run ceiling",
                        detail=(
                            f"${self.committed(run.run_id)} committed + ${estimate_usd} estimated "
                            f"> ${self.budget.max_usd_per_run}"
                        ),
                    )
                )
            )
        projected_seconds = self.committed_seconds(run.run_id) + estimate_seconds
        if (
            self.budget.max_model_seconds_per_run is not None
            and projected_seconds > self.budget.max_model_seconds_per_run
        ):
            return Outcome[Reservation].of(
                _verdict_error(
                    BreakerVerdict(
                        reason="reservation would exceed the run's model-time ceiling",
                        detail=(
                            f"{self.committed_seconds(run.run_id):.0f}s committed + "
                            f"{estimate_seconds:.0f}s estimated > "
                            f"{self.budget.max_model_seconds_per_run:.0f}s"
                        ),
                    )
                )
            )

        self._reserved[run.run_id] += estimate_usd
        self._reserved_seconds[run.run_id] += estimate_seconds
        return Outcome.ok(
            Reservation(
                run_id=run.run_id, estimate_usd=estimate_usd, estimate_seconds=estimate_seconds
            )
        )

    def settle(self, reservation: Reservation, event: CostEvent | None = None) -> None:
        """Release a reservation and record what was actually spent."""
        if reservation.released:
            return
        self._reserved[reservation.run_id] -= reservation.estimate_usd
        if self._reserved[reservation.run_id] < 0:
            self._reserved[reservation.run_id] = Decimal(0)
        self._reserved_seconds[reservation.run_id] -= reservation.estimate_seconds
        if self._reserved_seconds[reservation.run_id] < 0:
            self._reserved_seconds[reservation.run_id] = 0.0
        reservation.released = True
        if event is not None:
            self.tracker.record(event)


def _verdict_error(verdict: BreakerVerdict) -> ErrorRecord:
    return ErrorRecord(
        category=ErrorCategory.NEEDS_HUMAN,
        message=f"budget breaker: {verdict.reason}",
        remedy=verdict.detail,
    )
