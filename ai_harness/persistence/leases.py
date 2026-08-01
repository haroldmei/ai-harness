"""The SQL lease backend — an expiry column instead of a staleness heuristic.

Q4 said single host, and ``flock`` was correct for that. The trigger for this one is stated in
§26: *more than one host, or runs outliving a login session.* The protocol was designed so the
upgrade is mechanical, and it is: same interface, same conformance suite, different storage.

What changes semantically is the reaper. ``flock`` is released by the kernel when a process
dies, which is perfect on one host and useless across a fleet — a machine that loses power holds
nothing, but a machine that is merely *unreachable* still holds its file lock, and no other host
can see that. An expiry column makes liveness explicit: a holder that stops renewing loses the
lease at a knowable time, and the 20-minute staleness heuristic the shell needs
(``agent-pipeline.sh:370-414``) disappears.

One implementation serves both backends. Postgres gets ``SELECT … FOR UPDATE`` so two workers
racing are serialised by the database; SQLite serialises writers anyway, so the same code is
correct there without it.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import timedelta

from sqlalchemy import Engine, delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, sessionmaker

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.lease import LeaseHandle
from ai_harness.persistence.models import LeaseRow

SUPPORTS_FOR_UPDATE = {"postgresql", "mysql", "mariadb", "oracle"}


@dataclass
class SqlLeaseBackend:
    """Leases in the database, with an expiry that any host can evaluate."""

    engine: Engine
    clock: Clock = field(default_factory=SystemClock)
    _sessions: sessionmaker[Session] | None = None

    def __post_init__(self) -> None:
        self._sessions = sessionmaker(self.engine, expire_on_commit=False)

    @property
    def _locks_rows(self) -> bool:
        return self.engine.dialect.name in SUPPORTS_FOR_UPDATE

    async def acquire(self, key: str, *, ttl_s: float, holder: str) -> LeaseHandle | None:
        now = self.clock.now()
        expires = now + timedelta(seconds=ttl_s)
        token = os.urandom(8).hex()

        def _acquire(session: Session) -> LeaseHandle | None:
            query = select(LeaseRow).where(LeaseRow.key == key)
            if self._locks_rows:
                # Two workers reaching here at once are serialised by the database rather than
                # by hope. SQLite serialises writers itself, so this is a no-op there.
                query = query.with_for_update()
            row = session.scalars(query).first()

            if row is not None and row.expires_at > now:
                return None  # someone else owns it — not an error

            if row is None:
                session.add(
                    LeaseRow(
                        key=key,
                        holder=holder,
                        token=token,
                        acquired_at=now,
                        expires_at=expires,
                    )
                )
            else:
                # Expired: the previous holder is gone, unreachable, or too slow. Taking it
                # over changes the token, so their renew() will fail rather than silently
                # extending a lease they no longer hold.
                row.holder = holder
                row.token = token
                row.acquired_at = now
                row.expires_at = expires
            return LeaseHandle(key=key, holder=holder, ttl_s=ttl_s, expires_at=expires, token=token)

        try:
            return await self._run(_acquire)
        except IntegrityError:
            # Two workers found no row and both inserted. The unique key on `key` is what makes
            # that safe: exactly one insert survives, and the other worker learns it lost the
            # race the same way it learns anything else — the lease is unavailable.
            #
            # `SELECT … FOR UPDATE` cannot prevent this, because there is no row yet to lock.
            # Discovering that needed a real Postgres and four workers; it is invisible under
            # one worker and a mock, which is exactly the class of bug §26 says to expect when
            # going from one host to several.
            return None

    async def renew(self, handle: LeaseHandle) -> bool:
        if handle.released:
            return False
        now = self.clock.now()
        expires = now + timedelta(seconds=handle.ttl_s)

        def _renew(session: Session) -> bool:
            row = session.scalars(select(LeaseRow).where(LeaseRow.key == handle.key)).first()
            if row is None or row.token != handle.token:
                # The lease was taken over while we were working. Renewing it would be worse
                # than failing: two holders would each believe they own the run.
                return False
            row.expires_at = expires
            handle.expires_at = expires
            return True

        return await self._run(_renew)

    async def release(self, handle: LeaseHandle) -> None:
        handle.released = True

        def _release(session: Session) -> None:
            session.execute(
                delete(LeaseRow).where(LeaseRow.key == handle.key, LeaseRow.token == handle.token)
            )

        await self._run(_release)

    async def expired(self, *, before: float = 0.0) -> list[str]:
        """Keys whose holder stopped renewing. What a reaper would look at, if one existed."""
        cutoff = self.clock.now() - timedelta(seconds=before)

        def _expired(session: Session) -> list[str]:
            rows = session.scalars(select(LeaseRow).where(LeaseRow.expires_at <= cutoff)).all()
            return [row.key for row in rows]

        return await self._run(_expired)

    async def _run[T](self, fn: Callable[[Session], T]) -> T:
        assert self._sessions is not None
        sessions = self._sessions

        def _work() -> T:
            with sessions() as session, session.begin():
                return fn(session)

        return await asyncio.to_thread(_work)
