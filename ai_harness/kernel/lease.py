"""Leases — the *live* half of a claim.

Invariant 7: *a claim needs both a durable record and a live lease; either alone strands
work* (#2086). The shell harness gets the lease right — ``flock``, released by the kernel when
the process dies, so a crashed stage cannot strand a PR — and the record wrong: a GitHub label
with no compare-and-swap, reaped by a 20-minute staleness heuristic.

Per Q4 the shipped backend is ``flock`` (single host). The protocol is the seam that makes the
Postgres backend of Phase 5 a mechanical addition rather than a rewrite, and it is why an
expiry column can later replace the staleness heuristic entirely.

Acquiring a lease that someone else holds returns ``None``. That is **not an error**: it means
another worker owns the run, which is the normal, expected outcome of concurrent dispatch.
"""

from __future__ import annotations

import asyncio
import contextlib
import errno
import fcntl
import os
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Protocol

from ai_harness.kernel.clock import Clock, SystemClock

RUN_LEASE_PREFIX = "run:"


def run_lease_key(run_id: str) -> str:
    """The lease key for a run.

    One function rather than three f-strings, because the queue now *reads* these keys to skip
    runs another worker is holding — and a key format that disagreed between the writer and the
    reader would fail silently, as a queue that hands out work nobody can act on.
    """
    return f"{RUN_LEASE_PREFIX}{run_id}"


@dataclass
class LeaseHandle:
    """A held lease. Only the backend that issued it may renew or release it."""

    key: str
    holder: str
    ttl_s: float
    expires_at: datetime
    token: str = ""
    fd: int | None = field(default=None, repr=False)
    released: bool = False


class LeaseBackend(Protocol):
    """Acquire, renew, release. Three operations, several very different implementations."""

    async def acquire(self, key: str, *, ttl_s: float, holder: str) -> LeaseHandle | None: ...

    async def renew(self, handle: LeaseHandle) -> bool: ...

    async def release(self, handle: LeaseHandle) -> None: ...


class LeaseManager:
    """Wraps a backend with the heartbeat, which is where leases are usually got wrong.

    ``hold`` releases on *every* exit path, including the parked return of §22.2 — a deferred
    run that kept its lease would block its own re-dispatch.
    """

    def __init__(self, backend: LeaseBackend, *, clock: Clock | None = None) -> None:
        self._backend = backend
        self._clock = clock or SystemClock()

    async def acquire(self, key: str, *, ttl_s: float = 300.0, holder: str) -> LeaseHandle | None:
        return await self._backend.acquire(key, ttl_s=ttl_s, holder=holder)

    async def release(self, handle: LeaseHandle) -> None:
        await self._backend.release(handle)

    @contextlib.asynccontextmanager
    async def hold(
        self, key: str, *, ttl_s: float = 300.0, holder: str, renew_every_s: float | None = None
    ) -> AsyncIterator[LeaseHandle | None]:
        """Hold a lease, renewing in the background, releasing on any exit."""
        handle = await self.acquire(key, ttl_s=ttl_s, holder=holder)
        if handle is None:
            yield None
            return
        interval = renew_every_s if renew_every_s is not None else max(ttl_s / 3, 1.0)
        task = asyncio.create_task(self._heartbeat(handle, interval))
        try:
            yield handle
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
            await self.release(handle)

    async def _heartbeat(self, handle: LeaseHandle, interval: float) -> None:
        """Renew until cancelled.

        The *cadence* sleeps in real time deliberately, while everything semantic — expiry,
        acquisition, reclaim — reads the injectable clock. A heartbeat driven by a frozen clock
        is a busy loop: ``sleep`` returns instantly, the task renews again, and it starves the
        event loop it shares with the work it is protecting.
        """
        while True:
            await asyncio.sleep(interval)
            if not await self._backend.renew(handle):
                return


class MemoryLeaseBackend:
    """In-process leases. The test backend, and the one that can be made to fail on demand."""

    def __init__(self, *, clock: Clock | None = None) -> None:
        self._clock = clock or SystemClock()
        self._held: dict[str, LeaseHandle] = {}
        self.renew_should_fail = False

    async def acquire(self, key: str, *, ttl_s: float, holder: str) -> LeaseHandle | None:
        existing = self._held.get(key)
        if existing is not None and not existing.released:
            if existing.expires_at > self._clock.now():
                return None
            # Expired: the previous holder is gone (crashed, partitioned, or too slow).
            existing.released = True
        handle = LeaseHandle(
            key=key,
            holder=holder,
            ttl_s=ttl_s,
            expires_at=self._clock.now() + _seconds(ttl_s),
            token=os.urandom(8).hex(),
        )
        self._held[key] = handle
        return handle

    async def renew(self, handle: LeaseHandle) -> bool:
        if self.renew_should_fail or handle.released:
            return False
        current = self._held.get(handle.key)
        if current is None or current.token != handle.token:
            return False
        current.expires_at = self._clock.now() + _seconds(handle.ttl_s)
        handle.expires_at = current.expires_at
        return True

    async def release(self, handle: LeaseHandle) -> None:
        handle.released = True
        current = self._held.get(handle.key)
        if current is not None and current.token == handle.token:
            del self._held[handle.key]

    def steal(self, key: str) -> None:
        """Simulate lease loss mid-state, for the chaos suite."""
        handle = self._held.pop(key, None)
        if handle is not None:
            handle.released = True


class FlockLeaseBackend:
    """``flock``-backed leases: correct on one host, released by the kernel on process death.

    The file descriptor is held open deliberately. That is the whole mechanism: a ``SIGKILL``ed
    worker's lock disappears when its fds are closed, so no reaper is required for the *lock*
    (only for the durable record, which the persistence layer owns).

    The fd must never be taken inside ``$(…)``-style transient scope — the shell equivalent of
    that bug had every caller "acquire" slot 0 while holding nothing (``slot-lock.sh:15-19``).
    In Python the analogue is letting the handle be garbage-collected, so the fd lives on the
    handle and is closed only by :meth:`release`.
    """

    def __init__(self, directory: str | Path, *, clock: Clock | None = None) -> None:
        self._dir = Path(directory)
        self._dir.mkdir(parents=True, exist_ok=True)
        self._clock = clock or SystemClock()

    def _path(self, key: str) -> Path:
        safe = key.replace("/", "_").replace(":", "_")
        return self._dir / f"{safe}.lock"

    async def acquire(self, key: str, *, ttl_s: float, holder: str) -> LeaseHandle | None:
        path = self._path(key)
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(fd)
            if exc.errno in (errno.EACCES, errno.EAGAIN):
                return None  # someone else owns it — not an error
            raise
        os.truncate(fd, 0)
        os.write(fd, f"{holder}\n{os.getpid()}\n".encode())
        return LeaseHandle(
            key=key,
            holder=holder,
            ttl_s=ttl_s,
            expires_at=self._clock.now() + _seconds(ttl_s),
            fd=fd,
        )

    async def renew(self, handle: LeaseHandle) -> bool:
        if handle.released or handle.fd is None:
            return False
        handle.expires_at = self._clock.now() + _seconds(handle.ttl_s)
        return True

    async def release(self, handle: LeaseHandle) -> None:
        if handle.released or handle.fd is None:
            handle.released = True
            return
        with contextlib.suppress(OSError):
            fcntl.flock(handle.fd, fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            os.close(handle.fd)
        handle.fd = None
        handle.released = True


def _seconds(value: float) -> timedelta:
    return timedelta(seconds=value)
