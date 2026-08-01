"""gate-spine comparisons must survive a restart

#98: the criterion for replacing a repository's shell spine with a declaration is *every
disagreement explained*, measured across more commits than one process sees. Holding those
comparisons in memory would make the criterion unsatisfiable rather than merely unstarted --
exactly the defect ac0e5fe12b5b fixed for the reviewer's shadow observations.

The grain is one gate rather than one commit, because that is the grain at which a disagreement
is explained: "coverage differs because the declaration measures the package and the spine
measured the services too" is a fact about coverage, and making somebody retype it per commit is
how a criterion becomes a formality.

Revision ID: c93a7d15e2b1
Revises: b8f2c1d40a77
Create Date: 2026-08-01 21:40:00.000000
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c93a7d15e2b1"
down_revision: str | None = "b8f2c1d40a77"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "spine_comparisons",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("repo", sa.String(length=255), nullable=False),
        sa.Column("commit_sha", sa.String(length=64), nullable=False),
        sa.Column("gate", sa.String(length=128), nullable=False),
        sa.Column("kind", sa.String(length=32), nullable=False),
        sa.Column("shell_status", sa.String(length=32), nullable=True),
        sa.Column("declared_status", sa.String(length=32), nullable=True),
        sa.Column("shell_required", sa.Boolean(), nullable=False),
        sa.Column("declared_required", sa.Boolean(), nullable=False),
        sa.Column("shell_duration_s", sa.Float(), nullable=False),
        sa.Column("declared_duration_s", sa.Float(), nullable=False),
        sa.Column("note", sa.Text(), nullable=False),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column("observed_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        # One row per (repo, commit, gate). A re-comparison after a crash must update rather
        # than double-count the disagreement the criterion is measured on.
        sa.UniqueConstraint("repo", "commit_sha", "gate", name="uq_spine_comparison_gate"),
    )
    with op.batch_alter_table("spine_comparisons", schema=None) as batch_op:
        batch_op.create_index(batch_op.f("ix_spine_comparisons_repo"), ["repo"], unique=False)
        batch_op.create_index(
            batch_op.f("ix_spine_comparisons_commit_sha"), ["commit_sha"], unique=False
        )
        batch_op.create_index(batch_op.f("ix_spine_comparisons_gate"), ["gate"], unique=False)
        batch_op.create_index(batch_op.f("ix_spine_comparisons_kind"), ["kind"], unique=False)
        batch_op.create_index(
            batch_op.f("ix_spine_comparisons_observed_at"), ["observed_at"], unique=False
        )


def downgrade() -> None:
    op.drop_table("spine_comparisons")
