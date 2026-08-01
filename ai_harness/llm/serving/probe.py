"""Capabilities, measured (L4).

``EngineCapabilities`` is a literal written next to each engine — a *claim*. For a vendor API
that is fine, because the capability is contractual. For a server on this box it is not: whether
guided decoding works depends on the build, the flags the unit was started with and the
quantisation of the loaded weights, and all three change without anybody editing configuration.

The stake is structured output. The extraction ladder and the bounded repair loop were designed
for a model that mostly emits valid JSON; a 4-bit 30B does not, and a repair is a *full
re-generation* — minutes, not cents. Guided decoding moves schema conformance from hope to
transport guarantee. Believing it is on when it is not does not fail loudly; it shows up as a
repair rate nobody attributes.

So: one constrained generation decides it, the result is cached per (server, model, revision),
and a revision change invalidates the cache — because new weights are a new answer.

Two things are deliberately *not* probed by generating:

* **the window** is a GET on the model card, and cheap;
* **prefix caching** is *observed* rather than probed, because proving it costs a second long
  call whose only purpose is to be a repeat. Every completion already reports cached tokens, so
  :meth:`ProbeResult.observe` learns it for free from real traffic — and until traffic proves it,
  the answer is honestly "not yet observed" rather than a guess in either direction.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.engines.protocol import EngineCapabilities

PROBE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"ok": {"type": "boolean"}, "model": {"type": "string"}},
    "required": ["ok"],
    "additionalProperties": False,
}
"""Deliberately trivial. The probe asks whether the *mechanism* works, not whether the model is
clever — a schema hard enough to fail on merit would make an absent capability and a weak model
indistinguishable."""

PROBE_PROMPT = 'Reply with {"ok": true} and nothing else.'

GUIDED_DECODING_FLAG = "--guided-decoding-backend xgrammar"
PREFIX_CACHE_FLAG = "--enable-prefix-caching"


@dataclass
class ProbeResult:
    """What one server can actually do, and how each answer was reached."""

    model: str
    base_url: str
    revision: str = ""
    guided_decoding: bool = False
    max_model_len: int | None = None
    tokenizer_available: bool = False
    prefix_caching: bool | None = None
    """``None`` means *not yet observed*, which is not the same as ``False``."""
    notes: list[str] = field(default_factory=list)

    def capabilities(self) -> EngineCapabilities:
        return EngineCapabilities(
            native_structured_output=self.guided_decoding,
            prompt_caching=bool(self.prefix_caching),
            tool_use=False,
            reports_cost=False,
        )

    def observe(self, *, cache_read_tokens: int) -> None:
        """Learn prefix caching from real traffic rather than from a call that only repeats one."""
        if cache_read_tokens > 0:
            self.prefix_caching = True

    def as_dict(self) -> dict[str, Any]:
        return {
            "model": self.model,
            "base_url": self.base_url,
            "revision": self.revision,
            "guided_decoding": self.guided_decoding,
            "max_model_len": self.max_model_len,
            "tokenizer_available": self.tokenizer_available,
            "prefix_caching": self.prefix_caching,
            "notes": list(self.notes),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> ProbeResult:
        return cls(
            model=str(data.get("model", "")),
            base_url=str(data.get("base_url", "")),
            revision=str(data.get("revision", "")),
            guided_decoding=bool(data.get("guided_decoding", False)),
            max_model_len=data.get("max_model_len"),
            tokenizer_available=bool(data.get("tokenizer_available", False)),
            prefix_caching=data.get("prefix_caching"),
            notes=list(data.get("notes", [])),
        )


async def probe(
    *,
    base_url: str,
    model: str,
    revision: str = "",
    client: httpx.AsyncClient | None = None,
    timeout_s: float = 120.0,
) -> Outcome[ProbeResult]:
    """One constrained generation, two cheap GETs, and an honest answer for each capability."""
    owned = client or httpx.AsyncClient(timeout=timeout_s)
    result = ProbeResult(model=model, base_url=base_url, revision=revision)
    try:
        await _read_card(owned, base_url, result)
        await _read_tokenizer(owned, base_url, result)
        outcome = await _try_guided(owned, base_url, model, result)
        if outcome.is_err:
            assert outcome.error is not None
            return Outcome.of(outcome.error)
    finally:
        if client is None:
            await owned.aclose()
    return Outcome.ok(result)


async def _read_card(client: httpx.AsyncClient, base_url: str, result: ProbeResult) -> None:
    try:
        response = await client.get(f"{base_url}/models")
        cards = (response.json() or {}).get("data") or []
    except (httpx.HTTPError, ValueError):
        result.notes.append("the model card could not be read; the window is unknown")
        return
    for card in cards:
        if card.get("id") == result.model:
            window = card.get("max_model_len")
            result.max_model_len = int(window) if window is not None else None
            if card.get("revision"):
                result.revision = str(card["revision"])
            return
    result.notes.append(f"{result.model} is not in the server's model list")


async def _read_tokenizer(client: httpx.AsyncClient, base_url: str, result: ProbeResult) -> None:
    """``/tokenize`` is what makes token counting honest (#86). Its absence is worth naming."""
    root = base_url[: -len("/v1")] if base_url.endswith("/v1") else base_url
    try:
        response = await client.post(
            f"{root}/tokenize", json={"model": result.model, "prompt": "probe"}
        )
        payload = response.json() if response.status_code < 400 else {}
    except (httpx.HTTPError, ValueError):
        payload = {}
    result.tokenizer_available = bool(payload.get("tokens"))
    if not result.tokenizer_available:
        result.notes.append(
            "the server exposes no /tokenize endpoint: token counts fall back to the "
            "characters/4 estimate, which under-counts code and over-counts prose"
        )


async def _try_guided(
    client: httpx.AsyncClient, base_url: str, model: str, result: ProbeResult
) -> Outcome[ProbeResult]:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": PROBE_PROMPT}],
        "max_tokens": 40,
        "temperature": 0.0,
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "probe", "schema": PROBE_SCHEMA, "strict": False},
        },
    }
    try:
        response = await client.post(f"{base_url}/chat/completions", json=body)
    except httpx.HTTPError as exc:
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            f"the capability probe could not reach {base_url}: {exc}",
            remedy="start the serving unit before the worker; this is a startup condition",
            dependency="serving",
        )

    if response.status_code >= 400:
        # A server that rejects the request *because of* response_format has answered the
        # question: the mechanism is not there. That is a degradation, not a failure — the
        # extraction ladder still works, more slowly.
        result.guided_decoding = False
        result.notes.append(
            f"guided decoding is unavailable (server said {response.status_code}); "
            f"start the unit with {GUIDED_DECODING_FLAG} to enable it. "
            "Until then every structured call depends on the extraction ladder and repairs."
        )
        return Outcome.ok(result)

    try:
        payload = response.json()
        text = ((payload.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
        parsed = json.loads(text)
    except (ValueError, IndexError, AttributeError):
        result.guided_decoding = False
        result.notes.append(
            "the server accepted a JSON schema but did not honour it; treating guided decoding "
            "as absent, because a constraint that is accepted and ignored is worse than one that "
            "is refused"
        )
        return Outcome.ok(result)

    result.guided_decoding = isinstance(parsed, dict) and "ok" in parsed
    if not result.guided_decoding:
        result.notes.append("the constrained response did not satisfy the probe schema")
    return Outcome.ok(result)


def check_window(result: ProbeResult, *, required: int) -> Outcome[int]:
    """Refuse at startup when the server serves a smaller window than the plan assumed.

    Discovering this at use costs a claimed run and a ``CONTEXT_OVERFLOW`` in the middle of a
    review. Discovering it here costs a process exit and a message with both numbers in it.
    """
    if result.max_model_len is None:
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            f"{result.model} does not report a window, so {required} cannot be guaranteed",
            remedy="upgrade the serving stack, or set the window explicitly in .harness/models.yaml",
        )
    if result.max_model_len < required:
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            f"{result.model} is serving a {result.max_model_len}-token window but "
            f"{required} was planned",
            remedy=(
                "the unit was started with different flags than the registry derives; "
                "re-render it with `agent serving unit` or lower the registry's cap"
            ),
            details={"served": result.max_model_len, "required": required},
        )
    return Outcome.ok(result.max_model_len)


@dataclass
class ProbeCache:
    """One probe per (server, model, revision). New weights are a new answer."""

    path: Path

    def key(self, *, base_url: str, model: str, revision: str) -> str:
        return f"{base_url}|{model}|{revision}"

    def load(self, *, base_url: str, model: str, revision: str) -> ProbeResult | None:
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return None
        entry = data.get(self.key(base_url=base_url, model=model, revision=revision))
        return ProbeResult.from_dict(entry) if isinstance(entry, dict) else None

    def store(self, result: ProbeResult) -> None:
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            data = {}
        data[self.key(base_url=result.base_url, model=result.model, revision=result.revision)] = (
            result.as_dict()
        )
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(data, indent=2, sort_keys=True))
        except OSError:
            # A cache that cannot be written is a slower startup, never a failed one.
            return
