"""cost events carry the seconds they spent on the card

L5: at local rates a dollar ceiling cannot trip in a working day, so the resource that actually
binds is the GPU itself. `agent cost` has to be able to answer "how much card did this repository
use today", and that is a column rather than a derivation -- wall-clock is not GPU time, and the
difference is exactly what `selfhost.md`'s "the GPU is idle during much of the workflow" claim
turns on.

Existing rows get 0.0, which is correct rather than merely convenient: they were hosted calls,
and a hosted call spends none of this box's card.

Revision ID: b8f2c1d40a77
Revises: ac0e5fe12b5b
Create Date: 2026-08-01 20:10:00.000000
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b8f2c1d40a77"
down_revision: str | None = "ac0e5fe12b5b"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("cost_events", schema=None) as batch_op:
        batch_op.add_column(
            sa.Column("gpu_seconds", sa.Float(), nullable=False, server_default="0")
        )


def downgrade() -> None:
    with op.batch_alter_table("cost_events", schema=None) as batch_op:
        batch_op.drop_column("gpu_seconds")
