"""shadow comparisons must survive a restart

§24 Phase 2 gates the cutover on *a week* of agreement between the two reviewers, and a week is
longer than any process lives. Holding observations in a list made that criterion unsatisfiable
rather than merely unstarted: a restart, a deploy or a crash reset the evidence to zero, and the
report would still print an agreement rate — computed over whatever happened to survive.

``UTCDateTime`` is rendered as its impl (``sa.DateTime(timezone=True)``), which is the DDL it
produces. The decorator's behaviour is a Python-side bind/result concern rather than a schema
one, and spelling it out here would make the migration import the models it should not need.

Revision ID: ac0e5fe12b5b
Revises: 1ee81638fa6e
Create Date: 2026-08-01 16:50:47.058826
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "ac0e5fe12b5b"
down_revision: str | None = "1ee81638fa6e"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "shadow_comparisons",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("run_id", sa.String(length=64), nullable=False),
        sa.Column("repo", sa.String(length=255), nullable=False),
        sa.Column("head_sha", sa.String(length=64), nullable=False),
        sa.Column("round", sa.Integer(), nullable=False),
        sa.Column("agreement", sa.String(length=32), nullable=False),
        sa.Column("shell_verdict", sa.String(length=32), nullable=True),
        sa.Column("shell_blocking", sa.Integer(), nullable=False),
        sa.Column("shell_note", sa.Text(), nullable=False),
        sa.Column("python_verdict", sa.String(length=32), nullable=True),
        sa.Column("python_blocking", sa.Integer(), nullable=False),
        sa.Column("python_downgraded", sa.Boolean(), nullable=False),
        sa.Column("python_note", sa.Text(), nullable=False),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column("shell_usd", sa.Numeric(precision=12, scale=4), nullable=False),
        sa.Column("python_usd", sa.Numeric(precision=12, scale=4), nullable=False),
        sa.Column("observed_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        # One observation per (run, commit, round). The shadow runner may be invoked twice for
        # the same review — a retry, an overlapping nightly job, a rerun after a crash — and
        # double-counting an agreement would inflate the very rate the cutover gates on.
        sa.UniqueConstraint("run_id", "head_sha", "round", name="uq_comparison_observation"),
    )
    with op.batch_alter_table("shadow_comparisons", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_shadow_comparisons_agreement"), ["agreement"], unique=False
        )
        batch_op.create_index(
            batch_op.f("ix_shadow_comparisons_head_sha"), ["head_sha"], unique=False
        )
        batch_op.create_index(
            batch_op.f("ix_shadow_comparisons_observed_at"), ["observed_at"], unique=False
        )
        batch_op.create_index(batch_op.f("ix_shadow_comparisons_repo"), ["repo"], unique=False)
        batch_op.create_index(batch_op.f("ix_shadow_comparisons_run_id"), ["run_id"], unique=False)


def downgrade() -> None:
    with op.batch_alter_table("shadow_comparisons", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_shadow_comparisons_run_id"))
        batch_op.drop_index(batch_op.f("ix_shadow_comparisons_repo"))
        batch_op.drop_index(batch_op.f("ix_shadow_comparisons_observed_at"))
        batch_op.drop_index(batch_op.f("ix_shadow_comparisons_head_sha"))
        batch_op.drop_index(batch_op.f("ix_shadow_comparisons_agreement"))

    op.drop_table("shadow_comparisons")
