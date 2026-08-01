"""Issue #6 — leases: the live half of a claim."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import FlockLeaseBackend, LeaseManager, MemoryLeaseBackend


async def test_a_held_lease_is_unavailable_but_not_an_error() -> None:
    backend = MemoryLeaseBackend()
    first = await backend.acquire("run:1", ttl_s=60, holder="w1")
    second = await backend.acquire("run:1", ttl_s=60, holder="w2")
    assert first is not None
    assert second is None, "someone else owns it — not an error"


async def test_an_expired_lease_is_reclaimable() -> None:
    clock = FrozenClock()
    backend = MemoryLeaseBackend(clock=clock)
    assert await backend.acquire("run:1", ttl_s=60, holder="w1") is not None
    clock.advance(61)
    assert await backend.acquire("run:1", ttl_s=60, holder="w2") is not None


async def test_hold_releases_on_every_exit_path() -> None:
    """A parked run that kept its lease would block its own re-dispatch."""
    clock = FrozenClock()
    manager = LeaseManager(MemoryLeaseBackend(clock=clock), clock=clock)
    async with manager.hold("run:1", ttl_s=30, holder="w1") as lease:
        assert lease is not None
    backend = MemoryLeaseBackend(clock=clock)
    manager2 = LeaseManager(backend, clock=clock)
    try:
        async with manager2.hold("run:2", ttl_s=30, holder="w1") as lease:
            assert lease is not None
            raise RuntimeError("state blew up")
    except RuntimeError:
        pass
    assert await backend.acquire("run:2", ttl_s=30, holder="w2") is not None


async def test_hold_yields_none_when_another_worker_owns_the_run() -> None:
    backend = MemoryLeaseBackend()
    await backend.acquire("run:1", ttl_s=60, holder="w1")
    manager = LeaseManager(backend)
    async with manager.hold("run:1", ttl_s=60, holder="w2") as lease:
        assert lease is None


async def test_flock_backend_excludes_and_releases(tmp_path: Path) -> None:
    backend = FlockLeaseBackend(tmp_path)
    handle = await backend.acquire("run:1", ttl_s=60, holder="w1")
    assert handle is not None and handle.fd is not None
    assert await backend.acquire("run:1", ttl_s=60, holder="w2") is None
    await backend.release(handle)
    again = await backend.acquire("run:1", ttl_s=60, holder="w2")
    assert again is not None
    await backend.release(again)


def test_a_killed_holder_strands_nothing(tmp_path: Path) -> None:
    """The kernel releases the fd on process death, so no reaper is needed for the lock."""
    script = (
        "import asyncio, sys;"
        f"sys.path.insert(0, {str(Path.cwd())!r});"
        "from ai_harness.kernel.lease import FlockLeaseBackend;"
        f"b = FlockLeaseBackend({str(tmp_path)!r});"
        "h = asyncio.run(b.acquire('run:1', ttl_s=600, holder='doomed'));"
        "print('held', flush=True);"
        "import os; os.kill(os.getpid(), 9)"
    )
    proc = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True)
    assert "held" in proc.stdout
    assert proc.returncode == -9

    import asyncio

    backend = FlockLeaseBackend(tmp_path)
    handle = asyncio.run(backend.acquire("run:1", ttl_s=60, holder="next"))
    assert handle is not None, "a SIGKILLed holder must not strand the lock"
    assert handle.fd is not None
    os.close(handle.fd)
