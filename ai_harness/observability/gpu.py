"""The GPU is part of the system now, so it is part of the telemetry.

Until Phase 7 the model was someone else's infrastructure and the only observable facts about it
were tokens, latency and cost. It is now a process on this box holding 17 GB of VRAM, and its
failure modes are ours: thermal throttling, a queue backing up, a cache thrashing, an OOM at the
moment a long diff arrives, a driver that came back from suspend wrong.

Two sources, both read-only and both optional:

* **the serving stack** exposes Prometheus text at ``/metrics``. Parsed rather than scraped into
  a second system, because the harness already has an exporter and a second one would be a second
  place for the numbers to disagree.
* **the card** answers ``nvidia-smi --query-gpu``. A subprocess, because the alternative is a
  CUDA dependency in a package that otherwise has none, for four numbers.

Neither is required. A box without ``nvidia-smi`` and a server without ``/metrics`` produce an
empty reading and a note — never an exception, and never a failed run. The span contract applies
here for the same reason it applies there: **telemetry never fails the caller**.
"""

from __future__ import annotations

import asyncio
import shutil
from dataclasses import dataclass, field

import httpx

SMI_FIELDS = (
    "utilization.gpu",
    "memory.used",
    "memory.total",
    "temperature.gpu",
    "power.draw",
    "clocks_throttle_reasons.active",
)

THROTTLE_BITS: dict[int, str] = {
    0x0001: "gpu idle",
    0x0002: "applications clocks setting",
    0x0004: "sw power cap",
    0x0008: "hw slowdown",
    0x0010: "sync boost",
    0x0020: "sw thermal slowdown",
    0x0040: "hw thermal slowdown",
    0x0080: "hw power brake",
    0x0100: "display clock setting",
}

THROTTLE_MASK = 0x0004 | 0x0008 | 0x0020 | 0x0040 | 0x0080
"""The bits worth waking someone for. `gpu idle` is not one of them, and neither is a display
clock: they mean the card is fine and doing nothing much."""

SERVING_METRICS = {
    # The vLLM names, mapped onto what an operator is actually asking.
    "vllm:num_requests_waiting": "serving_queue_depth",
    "vllm:num_requests_running": "serving_requests_running",
    "vllm:gpu_cache_usage_perc": "serving_kv_cache_usage",
    "vllm:gpu_prefix_cache_hit_rate": "serving_prefix_cache_hit_rate",
    "vllm:num_preemptions_total": "serving_preemptions_total",
    "vllm:time_to_first_token_seconds_sum": "serving_ttft_seconds_sum",
    "vllm:time_to_first_token_seconds_count": "serving_ttft_seconds_count",
    "vllm:generation_tokens_total": "serving_generation_tokens_total",
}


@dataclass(frozen=True, slots=True)
class GpuReading:
    """One look at the card. Every field optional, because every source is optional."""

    utilisation_pct: float | None = None
    memory_used_mb: float | None = None
    memory_total_mb: float | None = None
    temperature_c: float | None = None
    power_w: float | None = None
    throttle_reason: str = ""
    available: bool = False
    note: str = ""

    @property
    def memory_free_mb(self) -> float | None:
        if self.memory_total_mb is None or self.memory_used_mb is None:
            return None
        return self.memory_total_mb - self.memory_used_mb

    @property
    def throttling(self) -> bool:
        """Whether something is *actually* limiting the clocks.

        ``nvidia-smi`` reports a bitmask, and the low bit means ``GpuIdle`` — a card with
        nothing to do. Treating any non-zero mask as throttling would report a healthy idle box
        as thermally limited, which is the kind of false alarm that teaches people to ignore the
        real one.
        """
        return bool(self.throttle_bits & THROTTLE_MASK) or self.throttle_reason.strip().lower() in (
            "active",
            "sw thermal slowdown",
            "hw thermal slowdown",
        )

    @property
    def throttle_bits(self) -> int:
        text = self.throttle_reason.strip()
        try:
            return int(text, 16) if text.lower().startswith("0x") else 0
        except ValueError:
            return 0

    @property
    def throttle_names(self) -> str:
        active = [name for bit, name in THROTTLE_BITS.items() if self.throttle_bits & bit]
        return ", ".join(active) or (self.throttle_reason.strip() or "none")


async def read_gpu(*, binary: str = "nvidia-smi", timeout_s: float = 5.0) -> GpuReading:
    """Read the card, or say why not. Never raises."""
    if shutil.which(binary) is None:
        return GpuReading(note=f"{binary} is not on PATH; GPU telemetry is unavailable")
    argv = [binary, f"--query-gpu={','.join(SMI_FIELDS)}", "--format=csv,noheader,nounits"]
    try:
        process = await asyncio.create_subprocess_exec(
            *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        stdout, _ = await asyncio.wait_for(process.communicate(), timeout=timeout_s)
    except (OSError, TimeoutError) as exc:
        return GpuReading(note=f"{binary} did not answer: {exc}")

    lines = stdout.decode("utf-8", "replace").strip().splitlines()
    if not lines:
        return GpuReading(note=f"{binary} returned nothing")
    parts = [part.strip() for part in lines[0].split(",")]
    if len(parts) < len(SMI_FIELDS):
        return GpuReading(note=f"{binary} returned {len(parts)} fields, expected {len(SMI_FIELDS)}")

    return GpuReading(
        utilisation_pct=_number(parts[0]),
        memory_used_mb=_number(parts[1]),
        memory_total_mb=_number(parts[2]),
        temperature_c=_number(parts[3]),
        power_w=_number(parts[4]),
        throttle_reason=parts[5],
        available=True,
    )


@dataclass
class ServingMetrics:
    """The serving stack's own numbers, mapped onto ours."""

    values: dict[str, float] = field(default_factory=dict)
    available: bool = False
    note: str = ""

    @property
    def mean_ttft_s(self) -> float | None:
        total = self.values.get("serving_ttft_seconds_sum")
        count = self.values.get("serving_ttft_seconds_count")
        return total / count if total is not None and count else None


async def read_serving(
    base_url: str, *, client: httpx.AsyncClient | None = None, timeout_s: float = 5.0
) -> ServingMetrics:
    """Fetch and parse ``/metrics``. An absent endpoint is a note, not a failure."""
    root = base_url[: -len("/v1")] if base_url.endswith("/v1") else base_url
    owned = client or httpx.AsyncClient(timeout=timeout_s)
    try:
        response = await owned.get(f"{root}/metrics")
    except httpx.HTTPError as exc:
        return ServingMetrics(note=f"the serving endpoint exposed no metrics: {exc}")
    finally:
        if client is None:
            await owned.aclose()

    if response.status_code >= 400:
        return ServingMetrics(note=f"/metrics answered {response.status_code}")
    return ServingMetrics(values=parse_prometheus(response.text), available=True)


def parse_prometheus(text: str) -> dict[str, float]:
    """Pull the handful of series worth having out of Prometheus exposition text."""
    values: dict[str, float] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, brace, rest = line.partition("{")
        if brace:
            _, _, rest = rest.partition("}")
            value_text = rest.strip()
        else:
            name, _, value_text = line.partition(" ")
        mapped = SERVING_METRICS.get(name.strip())
        if mapped is None:
            continue
        fields = value_text.split()
        number = _number(fields[0]) if fields else None
        if number is not None:
            # Summed across label sets: this box serves one model at a time, so the label
            # dimension carries nothing a single-card operator can act on.
            values[mapped] = values.get(mapped, 0.0) + number
    return values


def _number(text: str) -> float | None:
    try:
        return float(text)
    except (TypeError, ValueError):
        return None
