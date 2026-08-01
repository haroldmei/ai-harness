"""Immutable checkpoints — the record half of a claim (invariant 7).

A checkpoint is append-only and self-contained: it says which state ran, what it produced,
what it cost, and what the run looked like afterwards. That is what makes ``resume`` a
lookup rather than an inference, and what lets any worker pick up any run.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

from pydantic import BaseModel, Field

from ai_harness.schemas.enums import RunStatus, State
from ai_harness.schemas.errors import ErrorInfo


class Checkpoint(BaseModel):
    """One state boundary, recorded in the same transaction as the run update (§15.3)."""

    model_config = {"frozen": True}

    run_id: str
    seq: int = Field(ge=0)
    state: State
    next_state: State
    status: RunStatus = RunStatus.RUNNING
    attempt: int = Field(default=1, ge=1)
    round: int = Field(default=0, ge=0)
    """``round`` and ``attempt`` are deliberately separate axes, as in the shell spans."""

    idempotency_key: str = ""
    started_at: datetime | None = None
    finished_at: datetime | None = None
    duration_s: float | None = None

    usd: Decimal = Decimal(0)
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0

    model: str | None = None
    template_id: str | None = None
    prompt_sha256: str | None = None
    prompt_bytes: int | None = None
    """A digest and a size. Never the prompt text — storing it makes the harness a data store."""

    base_sha: str = ""
    head_sha: str = ""
    isolation: str | None = None
    artefacts: list[str] = Field(default_factory=list)
    result: dict[str, Any] = Field(default_factory=dict)
    """The state's typed output, dumped. Small enough to read, complete enough to replay."""
    error: ErrorInfo | None = None
