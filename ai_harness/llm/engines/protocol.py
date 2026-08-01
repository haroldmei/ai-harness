"""The engine seam, and the one classifier every engine maps onto.

The shell harness has nine ``claude -p`` call sites with an identical shape and, before
``lib/agent-model-call.sh`` was extracted, four classifiers that disagreed with each other.
Here the taxonomy is shared and only the *transport mapping* is per-engine.

``EngineCapabilities`` exists so structured output has one code path rather than two: an
engine with native schema support uses it, an engine without falls back to the extraction
ladder, and callers never branch on the provider.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any, Protocol, runtime_checkable

from ai_harness.kernel.outcome import ErrorCategory, Outcome

_TRANSIENT_RE = re.compile(
    r"session limit|usage limit|rate.?limit|overloaded|too many requests|quota",
    re.IGNORECASE,
)
"""The CLI phrases these the same way on stdout and stderr; the shell kept two divergent copies."""

_AUTH_RE = re.compile(r"invalid api key|unauthorized|authentication|forbidden|401|403", re.I)

_TRANSIENT_STATUSES = {429, 500, 502, 503, 529}


@dataclass(frozen=True, slots=True)
class EngineCapabilities:
    native_structured_output: bool = False
    prompt_caching: bool = False
    tool_use: bool = False
    reports_cost: bool = False
    """A2: the ``claude`` CLI reports cost; most APIs report tokens only (§21.3)."""


@dataclass(frozen=True, slots=True)
class Usage:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    reported_usd: Decimal | None = None

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens


@dataclass(frozen=True, slots=True)
class LLMRequest:
    """One call. ``template_id`` and the prompt digest are what a span records."""

    prompt: str
    system: str = ""
    model: str = ""
    max_tokens: int = 8192
    temperature: float = 0.0
    template_id: str = "adhoc"
    schema: dict[str, Any] | None = None
    """Passed natively when the engine supports it; otherwise rendered into the prompt."""
    stop: list[str] = field(default_factory=list)
    timeout_s: float = 900.0
    allow_fallback: bool = True
    """Whether a router may hand this call to a configured fallback engine. Set to False by the
    client once a run has used its allowance, so the ceiling on "$0 runs that quietly cost
    money" is enforced where the run is known rather than where the routing is (L7)."""


@dataclass(frozen=True, slots=True)
class Completion:
    """What an engine returns when it produced *something*."""

    text: str
    model: str
    provider: str
    usage: Usage = field(default_factory=Usage)
    session_id: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)


@runtime_checkable
class Engine(Protocol):
    """A provider. The only thing the rest of the harness knows about a model vendor."""

    name: str
    capabilities: EngineCapabilities

    async def complete(self, request: LLMRequest) -> Outcome[Completion]: ...


def classify_envelope(
    *,
    stdout: bytes,
    stderr: bytes = b"",
    exit_code: int = 0,
    provider: str = "",
) -> Outcome[dict[str, Any]]:
    """Classify a CLI-style JSON envelope. Ported from ``classify_model_result``.

    The ordering matters and is the shell's, for the reasons the shell documents:

    * **No envelope at all is** :attr:`ErrorCategory.UNKNOWN`, not a failure — unless the
      stderr sidecar names a limit, in which case *that* is the classification and it outranks
      "unknown". A zero-byte envelope once classified as a hard failure and discarded a
      completed $2.29 review (#2407).
    * A parseable envelope with ``is_error`` maps 429/503/529 and limit phrasing onto
      transient; anything else is a genuine model failure.
    * A non-JSON envelope is transient only on an unambiguous limit message.
    """
    err_text = stderr.decode("utf-8", "replace")
    out_text = stdout.decode("utf-8", "replace")

    if not stdout.strip():
        if _TRANSIENT_RE.search(err_text):
            return Outcome.fail(
                ErrorCategory.RATE_LIMITED,
                "provider limit reported on stderr with no envelope",
                dependency=f"model:{provider}" if provider else None,
            )
        if _AUTH_RE.search(err_text):
            return Outcome.fail(
                ErrorCategory.AUTH,
                "credentials rejected",
                remedy="refresh the provider credentials; retrying a 403 never succeeds",
            )
        return Outcome.fail(
            ErrorCategory.UNKNOWN,
            "the CLI exited without serialising an envelope",
            remedy=(
                "the model may have run and produced a verdict — this is retried, bounded, "
                "and is NOT reported as a model failure"
            ),
            details={"exit_code": exit_code},
        )

    try:
        payload = json.loads(out_text)
    except json.JSONDecodeError:
        if _TRANSIENT_RE.search(out_text) or _TRANSIENT_RE.search(err_text):
            return Outcome.fail(ErrorCategory.TRANSIENT, "provider limit reported")
        return Outcome.fail(
            ErrorCategory.MODEL_FAILURE,
            "the envelope was not JSON",
            details={"exit_code": exit_code, "head": out_text[:200]},
        )

    if not isinstance(payload, dict):
        return Outcome.fail(ErrorCategory.MODEL_FAILURE, "the envelope was not a JSON object")

    if payload.get("is_error") is True:
        status = payload.get("api_error_status") or payload.get("status") or 0
        message = str(payload.get("result") or payload.get("error") or "")
        try:
            status_int = int(status)
        except (TypeError, ValueError):
            status_int = 0
        if status_int == 429:
            return Outcome.fail(
                ErrorCategory.RATE_LIMITED,
                f"provider rate limit ({status_int})",
                retry_after_s=_retry_after(payload),
            )
        if status_int in _TRANSIENT_STATUSES or _TRANSIENT_RE.search(message):
            return Outcome.fail(ErrorCategory.TRANSIENT, message or f"provider error {status_int}")
        if _AUTH_RE.search(message) or status_int in (401, 403):
            return Outcome.fail(ErrorCategory.AUTH, message or "credentials rejected")
        return Outcome.fail(ErrorCategory.MODEL_FAILURE, message or "provider reported an error")

    return Outcome.ok(payload)


def _retry_after(payload: dict[str, Any]) -> float | None:
    for key in ("retry_after", "retry_after_s", "Retry-After"):
        value = payload.get(key)
        if value is not None:
            try:
                return float(value)
            except (TypeError, ValueError):
                continue
    return None
