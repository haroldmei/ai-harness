"""The measurement that every later default depends on.

`selfhost.md` estimates 25–35 tok/s for a 30B 4-bit model. That is a planning bound, not a
number about this box: the primary model is a mixture-of-experts with ~3B active parameters, so
the real figure could be several times higher, and the timeouts, ceilings and pacing defaults of
7C/7D are all derived from whichever it turns out to be. Guessing here would put a guess inside
every one of them.

Two rates are measured, because they are not the same rate and only one of them is what people
quote:

* **prefill** — prompt tokens ÷ time to first token. This is what makes a 30k-token diff
  expensive, and it is the rate that decides whether a large context window is affordable.
* **decode** — output tokens ÷ (total − TTFT). This is the 25–35 tok/s number, and it is what
  makes a whole-file edit expensive (#88).

Both are measured at several prompt lengths, because on a card this size they degrade with the
window and a single-point measurement hides that.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

import httpx

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome

FILLER_WORD = "token "
"""One short ASCII word ≈ one token for every tokenizer in use here. The server's own reported
``prompt_tokens`` is what gets recorded, so the approximation only affects the target, never the
measurement."""

DEFAULT_PROMPT_SIZES = (1_000, 8_000, 32_000)
DEFAULT_OUTPUT_TOKENS = 256


@dataclass(frozen=True, slots=True)
class BenchPoint:
    """One measured request."""

    requested_prompt_tokens: int
    prompt_tokens: int
    output_tokens: int
    ttft_s: float
    total_s: float

    @property
    def prefill_tps(self) -> float:
        return self.prompt_tokens / self.ttft_s if self.ttft_s > 0 else 0.0

    @property
    def decode_tps(self) -> float:
        decode_s = self.total_s - self.ttft_s
        return self.output_tokens / decode_s if decode_s > 0 else 0.0


@dataclass(frozen=True, slots=True)
class BenchResult:
    """What one model does on this box. Committed, and referenced by every derived default."""

    model: str
    base_url: str
    points: list[BenchPoint] = field(default_factory=list)

    @property
    def decode_tps(self) -> float:
        """The conservative figure — the slowest decode rate observed, not the average.

        A timeout derived from an average is a timeout that fires on the long prompts, which are
        exactly the prompts worth not losing.
        """
        rates = [p.decode_tps for p in self.points if p.decode_tps > 0]
        return min(rates) if rates else 0.0

    @property
    def prefill_tps(self) -> float:
        rates = [p.prefill_tps for p in self.points if p.prefill_tps > 0]
        return min(rates) if rates else 0.0

    def as_markdown(self) -> str:
        lines = [
            f"### {self.model}",
            "",
            "| prompt tokens | output tokens | TTFT (s) | total (s) | prefill tok/s | decode tok/s |",
            "|---:|---:|---:|---:|---:|---:|",
        ]
        for point in self.points:
            lines.append(
                f"| {point.prompt_tokens} | {point.output_tokens} | {point.ttft_s:.2f} | "
                f"{point.total_s:.2f} | {point.prefill_tps:.0f} | {point.decode_tps:.1f} |"
            )
        lines += [
            "",
            f"Conservative decode rate (slowest observed): **{self.decode_tps:.1f} tok/s**  ",
            f"Conservative prefill rate: **{self.prefill_tps:.0f} tok/s**",
            "",
        ]
        return "\n".join(lines)


def filler(target_tokens: int) -> str:
    return FILLER_WORD * max(target_tokens, 1)


async def measure(
    *,
    base_url: str,
    model: str,
    prompt_sizes: tuple[int, ...] = DEFAULT_PROMPT_SIZES,
    output_tokens: int = DEFAULT_OUTPUT_TOKENS,
    client: httpx.AsyncClient | None = None,
    clock: Clock | None = None,
    timeout_s: float = 900.0,
) -> Outcome[BenchResult]:
    """Stream one completion per prompt size and record what the server actually did."""
    ticker = clock or SystemClock()
    owned = client or httpx.AsyncClient(timeout=timeout_s)
    points: list[BenchPoint] = []
    try:
        for size in prompt_sizes:
            point = await _one(
                client=owned,
                base_url=base_url,
                model=model,
                size=size,
                output_tokens=output_tokens,
                clock=ticker,
            )
            if point.is_err:
                assert point.error is not None
                return Outcome.of(point.error)
            points.append(point.unwrap())
    finally:
        if client is None:
            await owned.aclose()
    return Outcome.ok(BenchResult(model=model, base_url=base_url, points=points))


async def _one(
    *,
    client: httpx.AsyncClient,
    base_url: str,
    model: str,
    size: int,
    output_tokens: int,
    clock: Clock,
) -> Outcome[BenchPoint]:
    body = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": (
                    "Ignore the following filler and count to a hundred.\n\n" + filler(size)
                ),
            }
        ],
        "max_tokens": output_tokens,
        "temperature": 0.0,
        "stream": True,
        # Without this the streamed response carries no usage, and the *server's* token counts
        # are the only ones worth recording — the filler's size is a target, not a measurement.
        "stream_options": {"include_usage": True},
    }

    started = clock.monotonic()
    ttft = 0.0
    prompt_tokens = 0
    completion_tokens = 0
    try:
        async with client.stream("POST", f"{base_url}/chat/completions", json=body) as response:
            if response.status_code >= 400:
                await response.aread()
                return Outcome.fail(
                    ErrorCategory.ENVIRONMENT,
                    f"benchmark request rejected ({response.status_code})",
                    details={"body": response.text[:200]},
                )
            async for line in response.aiter_lines():
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                if ttft == 0.0 and _has_content(chunk):
                    ttft = clock.monotonic() - started
                usage = chunk.get("usage")
                if isinstance(usage, dict):
                    prompt_tokens = int(usage.get("prompt_tokens", prompt_tokens) or 0)
                    completion_tokens = int(usage.get("completion_tokens", completion_tokens) or 0)
    except httpx.HTTPError as exc:
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT, f"benchmark transport error: {exc}", dependency="serving"
        )

    total = clock.monotonic() - started
    if ttft == 0.0:
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            "no content chunk arrived — the server streamed nothing to time",
        )
    return Outcome.ok(
        BenchPoint(
            requested_prompt_tokens=size,
            prompt_tokens=prompt_tokens or size,
            output_tokens=completion_tokens or 0,
            ttft_s=ttft,
            total_s=total,
        )
    )


def _has_content(chunk: dict[str, object]) -> bool:
    choices = chunk.get("choices")
    if not isinstance(choices, list) or not choices:
        return False
    first = choices[0]
    if not isinstance(first, dict):
        return False
    delta = first.get("delta")
    return isinstance(delta, dict) and bool(delta.get("content"))
