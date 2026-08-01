"""The serialisable face of :class:`ai_harness.kernel.outcome.ErrorRecord`.

The kernel's ``ErrorRecord`` is a dataclass because the kernel imports nothing from the
package. This is its Pydantic twin, used wherever an error is persisted or rendered.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field

from ai_harness.kernel.outcome import ErrorCategory, ErrorRecord


class ErrorInfo(BaseModel):
    """A stored failure. ``remedy`` is what a human is told to do about it."""

    category: ErrorCategory
    message: str
    remedy: str | None = None
    retry_after_s: float | None = None
    dependency: str | None = None
    evidence: str | None = None
    occurred_at: datetime | None = None
    details: dict[str, Any] = Field(default_factory=dict)

    @classmethod
    def from_record(cls, record: ErrorRecord) -> ErrorInfo:
        return cls(
            category=record.category,
            message=record.message,
            remedy=record.remedy,
            retry_after_s=record.retry_after_s,
            dependency=record.dependency,
            evidence=record.evidence,
            occurred_at=record.occurred_at,
            details=dict(record.details),
        )

    def to_record(self) -> ErrorRecord:
        return ErrorRecord(
            category=self.category,
            message=self.message,
            remedy=self.remedy,
            retry_after_s=self.retry_after_s,
            dependency=self.dependency,
            evidence=self.evidence,
            occurred_at=self.occurred_at,
            details=dict(self.details),
        )
