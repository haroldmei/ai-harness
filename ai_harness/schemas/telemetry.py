"""The span contract.

Ported from ``lib/agent-trace.sh``, whose field choices were right: ``round`` and ``attempt``
as deliberately separate axes, and a privacy-safe prompt digest — ``template_id``, ``sha256``,
byte count — *never* the text. Phase 5 exports these to OpenTelemetry; the fields do not change
when it does.

The contract that matters most is behavioural and is asserted in the logging tests:
**telemetry never fails the caller**.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, Field


class Span(BaseModel):
    """One model call, gate run or state execution."""

    span_id: str
    run_id: str
    parent_id: str | None = None
    name: str
    state: str | None = None
    round: int = 0
    attempt: int = 1

    started_at: datetime | None = None
    duration_s: float | None = None
    outcome: str | None = None

    provider: str | None = None
    model: str | None = None
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    usd: Decimal = Decimal(0)

    template_id: str | None = None
    prompt_sha256: str | None = None
    prompt_bytes: int | None = None

    attributes: dict[str, str] = Field(default_factory=dict)

    @property
    def expensive(self) -> bool:
        """Retention is conditional: errors and expensive calls are kept for 14 days."""
        return self.usd >= Decimal("0.50")
