"""The SQLite backend — the one the local CLI uses, and the reason A4 is falsifiable.

§24.1 lists "Postgres becomes a new single point of failure" as a real migration risk. The
mitigation is that this path exists and is tested by the same conformance suite: ``agent run``
works end to end with no database *server* installed.

Two pragmas are not decoration. ``journal_mode=WAL`` lets the recorder write while a reader
inspects, and ``foreign_keys=ON`` is off by default in SQLite — without it the cascade that
removes a run's checkpoints silently does nothing, and orphaned history is worse than none.
"""

from __future__ import annotations

from pathlib import Path

from sqlalchemy import Engine, event

from ai_harness.kernel.clock import Clock
from ai_harness.persistence.sql import SqlStore, open_store

MEMORY_URL = "sqlite:///:memory:"


def url_for(path: str | Path) -> str:
    return f"sqlite:///{Path(path)}"


def open_sqlite(
    path: str | Path | None = None, *, clock: Clock | None = None, create: bool = True
) -> SqlStore:
    """Open (and by default create) a SQLite-backed store."""
    url = MEMORY_URL if path is None else url_for(path)
    store = open_store(url, clock=clock, create=False)
    _apply_pragmas(store.engine)
    if create:
        store.create_all()
    return store


def _apply_pragmas(engine: Engine) -> None:
    @event.listens_for(engine, "connect")
    def _set_pragmas(dbapi_connection: object, _record: object) -> None:
        cursor = dbapi_connection.cursor()  # type: ignore[attr-defined]
        try:
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.execute("PRAGMA journal_mode=WAL")
            cursor.execute("PRAGMA busy_timeout=5000")
        finally:
            cursor.close()
