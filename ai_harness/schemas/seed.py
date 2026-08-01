"""Seed-data contracts.

``seed-integrity.sh`` already gets this right and the semantics are ported unchanged: seeding
and *asserting the seed landed* are separate steps, and the seed must be idempotent — re-run
it and the row counts must not move.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class SeedResult(BaseModel):
    seeded: bool = False
    verified: bool = False
    """A separate step from ``seeded``: an exit code is not evidence the rows landed."""
    idempotent: bool | None = None
    """``None`` when the re-run was not performed; ``False`` is a hard failure."""
    row_counts: dict[str, int] = Field(default_factory=dict)
    expected_min_rows: dict[str, int] = Field(default_factory=dict)
    failures: list[str] = Field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.seeded and self.verified and self.idempotent is not False and not self.failures
