"""The relational schema (§15.2).

This is the table set that replaces the four stores of W1 — GitHub labels, GitHub comments,
``/tmp`` flocks and ``/tmp`` counters — which could and did disagree with each other. Three
properties are structural rather than conventional:

* **Checkpoints are append-only.** There is no update path in the store, and ``(run_id, seq)``
  is unique, so a replayed state cannot rewrite history.
* **Every counter is a column.** The shell reconstructs the review round, the re-arm count, the
  env-defer count and the self-repair count by regex-scraping PR comments — one API call per
  counter, fail-closed on a parse error, and the record and the notification are the same
  object. Here reading one is a query.
* **A lease has an expiry column**, which replaces the shell's 20-minute staleness heuristic
  for stale-claim reaping. The Postgres lease backend of Phase 5 sits directly on this table.

``Decimal`` money is stored as ``NUMERIC(12, 4)`` — never a float. A budget breaker that reads
a float ceiling is a breaker that eventually rounds the wrong way.
"""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import (
    JSON,
    Boolean,
    Dialect,
    Float,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    TypeDecorator,
    UniqueConstraint,
)
from sqlalchemy import DateTime as SADateTime
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class UTCDateTime(TypeDecorator[datetime]):
    """A timestamp that is timezone-aware on **every** backend.

    SQLite has no timezone-aware type: ``DateTime(timezone=True)`` stores what it is given and
    hands back a *naive* datetime, so a value written as UTC comes back unlabelled. Every
    comparison the harness makes against a stored timestamp — ``defer_until`` in the machine
    loop, the 24h/72h approval timeouts, lease expiry — would then raise ``TypeError`` or,
    worse, compare correctly on Postgres and wrongly on SQLite.

    Normalising on the way in and re-attaching UTC on the way out makes the two backends agree,
    which is the whole premise of one conformance suite.
    """

    impl = SADateTime
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect: Dialect) -> datetime | None:
        if value is None:
            return None
        return value.astimezone(UTC) if value.tzinfo else value.replace(tzinfo=UTC)

    def process_result_value(self, value: datetime | None, dialect: Dialect) -> datetime | None:
        if value is None:
            return None
        return value if value.tzinfo else value.replace(tzinfo=UTC)


def DateTime(timezone: bool = True) -> UTCDateTime:
    return UTCDateTime(timezone=timezone)


class Base(DeclarativeBase):
    """Declarative base. ``JSON`` is portable across SQLite and Postgres as written."""


class RunRow(Base):
    """One unit of durable work. Labels become a projection of this row, not the reverse."""

    __tablename__ = "runs"

    run_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    repo: Mapped[str] = mapped_column(String(255), index=True)
    forge: Mapped[str] = mapped_column(String(32), default="github")
    issue: Mapped[int | None] = mapped_column(Integer, nullable=True, index=True)

    state: Mapped[str] = mapped_column(String(32), index=True)
    status: Mapped[str] = mapped_column(String(32), index=True)
    disposition: Mapped[str | None] = mapped_column(String(32), nullable=True)

    branch: Mapped[str] = mapped_column(String(255), default="")
    base_sha: Mapped[str] = mapped_column(String(64), default="")
    head_sha: Mapped[str] = mapped_column(String(64), default="")
    worktree_path: Mapped[str | None] = mapped_column(Text, nullable=True)
    mr_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    mr_url: Mapped[str | None] = mapped_column(Text, nullable=True)

    # ── the counters the shell scrapes out of comments (W2) ──────────────────────
    review_rounds: Mapped[int] = mapped_column(Integer, default=0)
    implement_attempts: Mapped[int] = mapped_column(Integer, default=0)
    plan_attempts: Mapped[int] = mapped_column(Integer, default=0)
    validate_attempts: Mapped[int] = mapped_column(Integer, default=0)
    self_repair_attempts: Mapped[int] = mapped_column(Integer, default=0)
    deps_retries: Mapped[int] = mapped_column(Integer, default=0)
    env_defers: Mapped[int] = mapped_column(Integer, default=0)
    rearms: Mapped[int] = mapped_column(Integer, default=0)
    resolver_attempts: Mapped[int] = mapped_column(Integer, default=0)
    empty_envelope_streak: Mapped[int] = mapped_column(Integer, default=0)
    schema_repairs: Mapped[int] = mapped_column(Integer, default=0)

    spend_usd: Mapped[Decimal] = mapped_column(Numeric(12, 4), default=Decimal(0))
    tokens: Mapped[int] = mapped_column(Integer, default=0)

    defer_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    blocked_on: Mapped[str | None] = mapped_column(String(128), nullable=True)
    pending_approval_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    lease_holder: Mapped[str | None] = mapped_column(String(128), nullable=True)

    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)

    request: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    """The validated ``JobRequest``, stored whole so a run is reproducible from its row."""

    engine: Mapped[str] = mapped_column(String(16), default="shell")
    """Which engine drove this run — the Phase 2/3 shadow comparison reads it."""

    checkpoints: Mapped[list[CheckpointRow]] = relationship(
        back_populates="run", cascade="all, delete-orphan", order_by="CheckpointRow.seq"
    )

    __table_args__ = (Index("ix_runs_repo_state", "repo", "state"),)


class CheckpointRow(Base):
    """An immutable state boundary. Written in the same transaction as the run update."""

    __tablename__ = "checkpoints"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    run_id: Mapped[str] = mapped_column(
        String(64), ForeignKey("runs.run_id", ondelete="CASCADE"), index=True
    )
    seq: Mapped[int] = mapped_column(Integer)

    state: Mapped[str] = mapped_column(String(32))
    next_state: Mapped[str] = mapped_column(String(32))
    status: Mapped[str] = mapped_column(String(32), default="running")
    attempt: Mapped[int] = mapped_column(Integer, default=1)
    round: Mapped[int] = mapped_column(Integer, default=0)
    """``round`` and ``attempt`` are deliberately separate axes, as in the shell spans."""

    idempotency_key: Mapped[str] = mapped_column(String(255), default="", index=True)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    duration_s: Mapped[float | None] = mapped_column(Numeric(12, 3), nullable=True)

    usd: Mapped[Decimal] = mapped_column(Numeric(12, 4), default=Decimal(0))
    input_tokens: Mapped[int] = mapped_column(Integer, default=0)
    output_tokens: Mapped[int] = mapped_column(Integer, default=0)
    cache_read_tokens: Mapped[int] = mapped_column(Integer, default=0)

    model: Mapped[str | None] = mapped_column(String(128), nullable=True)
    template_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    prompt_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    prompt_bytes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    """A digest and a size — never the prompt text. Storing it makes the harness a data store."""

    base_sha: Mapped[str] = mapped_column(String(64), default="")
    head_sha: Mapped[str] = mapped_column(String(64), default="")
    isolation: Mapped[str | None] = mapped_column(String(32), nullable=True)
    artefacts: Mapped[list[str]] = mapped_column(JSON, default=list)
    result: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    error: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)

    run: Mapped[RunRow] = relationship(back_populates="checkpoints")

    __table_args__ = (
        UniqueConstraint("run_id", "seq", name="uq_checkpoint_seq"),
        Index("ix_checkpoints_run_seq", "run_id", "seq"),
    )


class LeaseRow(Base):
    """The durable half of a claim. An expiry column, not a staleness heuristic."""

    __tablename__ = "leases"

    key: Mapped[str] = mapped_column(String(255), primary_key=True)
    holder: Mapped[str] = mapped_column(String(128))
    token: Mapped[str] = mapped_column(String(64))
    acquired_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


class FingerprintRow(Base):
    """The triage ledger: attempts per failure signature, and the resolution when known.

    The shell ledger counts attempts and **discards resolutions**, which is why "what fixed
    this last time" is unanswerable there and why §17.2 lists it as the one genuinely valuable
    vector-search case. Keeping the resolution costs one column.
    """

    __tablename__ = "fingerprint_ledger"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    repo: Mapped[str] = mapped_column(String(255), index=True)
    signature: Mapped[str] = mapped_column(String(64), index=True)
    gate: Mapped[str] = mapped_column(String(64), default="")
    triage_class: Mapped[str] = mapped_column(String(32), default="")
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    open_blocker: Mapped[str | None] = mapped_column(String(64), nullable=True)
    resolution: Mapped[str | None] = mapped_column(Text, nullable=True)
    normalised: Mapped[str | None] = mapped_column(Text, nullable=True)
    first_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (UniqueConstraint("repo", "signature", name="uq_fingerprint_repo_sig"),)


class ApprovalRow(Base):
    """A parked decision. The run releases its lease while this is outstanding."""

    __tablename__ = "approvals"

    approval_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    run_id: Mapped[str] = mapped_column(String(64), index=True)
    state: Mapped[str] = mapped_column(String(32))
    capability: Mapped[str] = mapped_column(String(64))
    reason: Mapped[str] = mapped_column(Text, default="")
    evidence: Mapped[list[str]] = mapped_column(JSON, default=list)
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    approved: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    decided_by: Mapped[str | None] = mapped_column(String(128), nullable=True)
    decision_reason: Mapped[str | None] = mapped_column(Text, nullable=True)


class CostRow(Base):
    """One priced unit of work. ``agent cost`` is a query over this table."""

    __tablename__ = "cost_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    run_id: Mapped[str] = mapped_column(String(64), index=True)
    repo: Mapped[str] = mapped_column(String(255), index=True)
    state: Mapped[str] = mapped_column(String(32), default="")
    provider: Mapped[str] = mapped_column(String(64), default="")
    model: Mapped[str] = mapped_column(String(128), default="")
    template_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    usd: Mapped[Decimal] = mapped_column(Numeric(12, 4), default=Decimal(0))
    input_tokens: Mapped[int] = mapped_column(Integer, default=0)
    output_tokens: Mapped[int] = mapped_column(Integer, default=0)
    cache_read_tokens: Mapped[int] = mapped_column(Integer, default=0)
    cache_write_tokens: Mapped[int] = mapped_column(Integer, default=0)
    gpu_seconds: Mapped[float] = mapped_column(Float, default=0.0)
    """Seconds this call held *our* card. Zero for a hosted provider: the resource this box
    runs out of is the GPU, and a hosted call does not consume it (L5)."""
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


class SpineComparisonRow(Base):
    """One gate, compared between a shell spine and the declaration proposed to replace it (#98).

    Durable for the same reason the shadow comparisons are: the criterion spans more commits than
    one process sees, and evidence that resets on a restart makes the criterion unsatisfiable
    rather than merely unstarted.

    The grain is one *gate* rather than one commit, because that is the grain at which a
    disagreement is explained — "coverage differs because the declaration measures the package
    and the spine measured the services too" is an explanation about coverage, and it should not
    have to be repeated on every commit's row.
    """

    __tablename__ = "spine_comparisons"
    __table_args__ = (
        UniqueConstraint("repo", "commit_sha", "gate", name="uq_spine_comparison_gate"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    repo: Mapped[str] = mapped_column(String(255), index=True)
    commit_sha: Mapped[str] = mapped_column(String(64), index=True)
    gate: Mapped[str] = mapped_column(String(128), index=True)

    kind: Mapped[str] = mapped_column(String(32), index=True)
    shell_status: Mapped[str | None] = mapped_column(String(32), nullable=True)
    declared_status: Mapped[str | None] = mapped_column(String(32), nullable=True)
    shell_required: Mapped[bool] = mapped_column(Boolean, default=False)
    declared_required: Mapped[bool] = mapped_column(Boolean, default=False)
    shell_duration_s: Mapped[float] = mapped_column(Float, default=0.0)
    declared_duration_s: Mapped[float] = mapped_column(Float, default=0.0)
    note: Mapped[str] = mapped_column(Text, default="")
    explanation: Mapped[str] = mapped_column(Text, default="")
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


class ArtefactRow(Base):
    """A pointer to preserved evidence — gate logs, diffs, invalid model output.

    The bytes live on a filesystem or in object storage; the row records where and for how
    long, so the §16.4 rule "flush artefacts first, cleanup last" has something to point at.
    """

    __tablename__ = "artefacts"

    artefact_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    run_id: Mapped[str] = mapped_column(String(64), index=True)
    kind: Mapped[str] = mapped_column(String(32))
    uri: Mapped[str] = mapped_column(Text)
    bytes: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class ComparisonRow(Base):
    """One shadow observation, durable.

    §24 Phase 2 gates the cutover on *a week* of agreement, and a week is longer than any
    process lives. Holding observations in memory made the criterion unsatisfiable rather than
    merely unstarted: a restart, a deploy or a crash silently reset the evidence to zero and the
    report would still print an agreement rate, computed over whatever survived.

    ``explanation`` is the column the cutover actually blocks on. A disagreement is not a
    regression — the shell reviewer's known defects are in the comparison set — so what must be
    empty before a flip is *unexplained* disagreements, and an explanation is a human writing in
    this column.
    """

    __tablename__ = "shadow_comparisons"
    __table_args__ = (
        UniqueConstraint("run_id", "head_sha", "round", name="uq_comparison_observation"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    run_id: Mapped[str] = mapped_column(String(64), index=True)
    repo: Mapped[str] = mapped_column(String(255), index=True)
    head_sha: Mapped[str] = mapped_column(String(64), index=True)
    round: Mapped[int] = mapped_column(Integer, default=1)

    agreement: Mapped[str] = mapped_column(String(32), index=True)
    shell_verdict: Mapped[str | None] = mapped_column(String(32), nullable=True)
    shell_blocking: Mapped[int] = mapped_column(Integer, default=0)
    shell_note: Mapped[str] = mapped_column(Text, default="")
    python_verdict: Mapped[str | None] = mapped_column(String(32), nullable=True)
    python_blocking: Mapped[int] = mapped_column(Integer, default=0)
    python_downgraded: Mapped[bool] = mapped_column(Boolean, default=False)
    python_note: Mapped[str] = mapped_column(Text, default="")

    explanation: Mapped[str] = mapped_column(Text, default="")
    shell_usd: Mapped[Decimal] = mapped_column(Numeric(12, 4), default=Decimal(0))
    python_usd: Mapped[Decimal] = mapped_column(Numeric(12, 4), default=Decimal(0))
    """§24.1's "cost increases" risk row needs both paths priced on the same reviews."""
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


ALL_TABLES = (
    RunRow,
    CheckpointRow,
    LeaseRow,
    FingerprintRow,
    ApprovalRow,
    CostRow,
    ArtefactRow,
    ComparisonRow,
)
