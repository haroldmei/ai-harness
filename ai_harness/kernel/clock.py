"""Injectable time.

Every timeout, backoff and lease expiry in the harness reads the clock through this
protocol, so the tests that exercise them are deterministic and instantaneous. A module
that calls ``time.time()`` directly is a module whose timeout behaviour can only be tested
by waiting for it — which is why nothing does.
"""

from __future__ import annotations

import asyncio
import time
from datetime import UTC, datetime, timedelta
from typing import Protocol, runtime_checkable


@runtime_checkable
class Clock(Protocol):
    """Wall time, monotonic time, and sleeping — the three things that must be fakeable."""

    def now(self) -> datetime:
        """Timezone-aware wall-clock time. Used for expiry, deferral and audit stamps."""
        ...

    def monotonic(self) -> float:
        """Monotonic seconds. Used for durations, which must not jump when wall time does."""
        ...

    async def sleep(self, seconds: float) -> None:
        """Await ``seconds``. The only sleep in the codebase."""
        ...


class SystemClock:
    """The real clock. The only implementation that reaches the operating system."""

    def now(self) -> datetime:
        return datetime.now(UTC)

    def monotonic(self) -> float:
        return time.monotonic()

    async def sleep(self, seconds: float) -> None:
        await asyncio.sleep(seconds)


class FrozenClock:
    """A clock that only moves when a test moves it.

    ``sleep`` advances the clock rather than waiting, so a policy with a 300-second backoff
    is exercised in microseconds and the assertion is on the *elapsed* value rather than on
    the wall time the suite took.
    """

    def __init__(self, start: datetime | None = None) -> None:
        self._now = start or datetime(2026, 1, 1, tzinfo=UTC)
        self._mono = 0.0
        self.slept: list[float] = []

    def now(self) -> datetime:
        return self._now

    def monotonic(self) -> float:
        return self._mono

    async def sleep(self, seconds: float) -> None:
        """Advance instead of waiting — but still **yield**.

        Returning without yielding looks harmless and is not: a background task that sleeps in
        a loop (the lease heartbeat does exactly this) never gives the event loop a chance to
        run anything else, so the whole suite hangs at full CPU. ``asyncio.sleep(0)`` keeps the
        test instantaneous while staying cooperative.
        """
        self.slept.append(seconds)
        self.advance(seconds)
        await asyncio.sleep(0)

    def advance(self, seconds: float) -> None:
        self._now += timedelta(seconds=seconds)
        self._mono += seconds
