"""The Postgres backend.

Built now rather than later, per Q3: the cost is one thin module and it de-risks Q4, because
the Phase 5 lease backend and the ``SELECT … FOR UPDATE SKIP LOCKED`` queue both need this
connection to already exist and already be exercised by the conformance suite.

Nothing here is Postgres-*specific* except the driver and the pool: the schema, the queries
and the transaction boundaries are the ones :mod:`ai_harness.persistence.sql` uses for SQLite.
That is the point — a backend that needed its own query set would not be one protocol.
"""

from __future__ import annotations

from ai_harness.kernel.clock import Clock
from ai_harness.persistence.sql import SqlStore, open_store

DEFAULT_DRIVER = "postgresql+psycopg"


def url_for(dsn: str) -> str:
    """Normalise a DSN onto the psycopg driver, leaving an explicit driver alone."""
    if "+" in dsn.split("://", 1)[0]:
        return dsn
    if dsn.startswith("postgres://"):
        return dsn.replace("postgres://", f"{DEFAULT_DRIVER}://", 1)
    if dsn.startswith("postgresql://"):
        return dsn.replace("postgresql://", f"{DEFAULT_DRIVER}://", 1)
    return dsn


def open_postgres(dsn: str, *, clock: Clock | None = None, create: bool = False) -> SqlStore:
    """Open a Postgres-backed store. ``create`` is for tests; alembic owns deployment."""
    return open_store(url_for(dsn), clock=clock, create=create)
