"""The local engine — same wire format as OpenAI, entirely different failure modes.

``openai_api.py`` already speaks OpenAI-compatible chat completions, and its docstring says out
loud that ``base_url`` is configuration precisely so a local server can be pointed at. That is
the *transport*, and it is why this module is short. It is not the engine, because what differs
between a hosted API and a process on this box is not the wire format — it is what goes wrong:

* **A prompt longer than the window** is a deterministic 400 that a hosted 200k model never
  produced. Mapping it onto ``MODEL_FAILURE`` would blame the model for arithmetic the caller
  can do, escalate a run that needed one smaller assembly, and charge budget for a call that
  never generated a token. It gets :attr:`~ai_harness.kernel.outcome.ErrorCategory.CONTEXT_OVERFLOW`,
  carrying both numbers.

* **The server is holding a different model** is ``ENVIRONMENT``. Nobody's prompt is at fault
  and no retry helps; somebody started the wrong unit.

* **The queue is full** on a single GPU is back-pressure from *ourselves*, not a vendor saying
  "later". It is ``TRANSIENT`` against the serving dependency, so the breaker defers the run at
  zero cost, rather than ``RATE_LIMITED``, which would make the harness sit out a
  ``Retry-After`` that nobody sent.

* **A restarting server** — a swap, a crash, an OOM — is ``TRANSIENT`` with a dependency name,
  which is what makes a model reload a pause rather than a lost run.

Everything else the harness already knew how to do.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Any

import httpx

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.engines.protocol import (
    Completion,
    EngineCapabilities,
    LLMRequest,
    Usage,
)

DEFAULT_BASE_URL = "http://127.0.0.1:8000/v1"

_OVERFLOW_RE = re.compile(
    r"maximum context length|longer than the maximum|context length exceeded|"
    r"decrease max_tokens|reduce the length of the messages",
    re.IGNORECASE,
)
"""vLLM has phrased this at least four ways across releases. Matching one of them and calling
the rest a model failure is the same defect the shell harness had with limit messages."""

_NO_MODEL_RE = re.compile(
    r"model .* does not exist|the model .* is not|unknown model|no model named", re.IGNORECASE
)

_SATURATED_RE = re.compile(
    r"queue is full|too many requests in queue|server is overloaded|capacity", re.IGNORECASE
)

_TOKENS_RE = re.compile(r"(\d[\d,]{2,})")


@dataclass
class VLLMEngine:
    """A locally served, OpenAI-compatible model.

    ``capabilities`` defaults to the conservative reading — no native structured output — and is
    *replaced* by :mod:`ai_harness.llm.serving.probe` at startup when a constrained call proves
    the server supports it. A capability asserted by configuration is a capability that silently
    stops being true when the server is restarted with different flags (L4).
    """

    base_url: str = DEFAULT_BASE_URL
    api_key: str = field(default_factory=lambda: os.environ.get("VLLM_API_KEY", ""))
    """Optional: vLLM accepts ``--api-key``. Empty is normal on a loopback-only endpoint."""
    client: httpx.AsyncClient | None = None
    name: str = "local"
    max_model_len: int | None = None
    """The server's declared window, when known. Used to reject before the wire, not after."""
    capabilities: EngineCapabilities = field(
        default_factory=lambda: EngineCapabilities(
            native_structured_output=False,
            prompt_caching=True,
            tool_use=False,
            reports_cost=False,
        )
    )

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        messages: list[dict[str, str]] = []
        if request.system:
            messages.append({"role": "system", "content": request.system})
        messages.append({"role": "user", "content": request.prompt})

        body: dict[str, Any] = {
            "model": request.model,
            "messages": messages,
            "max_tokens": request.max_tokens,
            "temperature": request.temperature,
        }
        if request.stop:
            body["stop"] = list(request.stop)
        if request.schema is not None and self.capabilities.native_structured_output:
            # Guided decoding, taken only when the probe proved it exists. The same code path as
            # every other engine: selected by capability, never by a provider check at the call
            # site. Without it the extraction ladder does the work, more slowly.
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": "output", "schema": request.schema, "strict": False},
            }

        client = self.client or httpx.AsyncClient(timeout=request.timeout_s)
        owns = self.client is None
        try:
            response = await client.post(
                f"{self.base_url}/chat/completions", json=body, headers=self._headers()
            )
        except httpx.TimeoutException:
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"the local model did not answer within {request.timeout_s:.0f}s",
                remedy=(
                    "a long generation on a serial GPU is normal; if this repeats, the timeout "
                    "is derived from a decode rate the box is no longer achieving"
                ),
                dependency=f"model:{self.name}",
            )
        except httpx.HTTPError as exc:
            # A connection refused mid-run is usually a swap or a crash-restart, not a defect in
            # the prompt. Naming the dependency is what lets the breaker defer the whole run.
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"the serving endpoint at {self.base_url} is not answering: {exc}",
                remedy="check `agent serving check`; a model swap looks exactly like this for a few seconds",
                dependency=f"model:{self.name}",
            )
        finally:
            if owns:
                await client.aclose()

        return self._map(response, request)

    def _headers(self) -> dict[str, str]:
        headers = {"content-type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _map(self, response: httpx.Response, request: LLMRequest) -> Outcome[Completion]:
        text_body = response.text[:500]

        if response.status_code == 400:
            if _OVERFLOW_RE.search(text_body):
                return self._overflow(text_body, request)
            if _NO_MODEL_RE.search(text_body):
                return self._wrong_model(text_body, request)
            return Outcome.fail(
                ErrorCategory.MODEL_FAILURE,
                f"the server rejected the request: {text_body[:200]}",
            )
        if response.status_code == 404:
            return self._wrong_model(text_body, request)
        if response.status_code in (401, 403):
            return Outcome.fail(
                ErrorCategory.AUTH,
                f"the local server rejected the credential ({response.status_code})",
                remedy="the serving unit was started with --api-key; set VLLM_API_KEY to match",
            )
        if response.status_code == 429 or _SATURATED_RE.search(text_body):
            # Back-pressure from our own single GPU. Deliberately not RATE_LIMITED: there is no
            # vendor quota to sit out, and the breaker's deferral is the right response.
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                "the local server is saturated — this box serves one request at a time",
                remedy="admission control should have prevented a second in-flight call (#89)",
                dependency=f"model:{self.name}",
            )
        if response.status_code >= 500:
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"the local server errored ({response.status_code}): {text_body[:200]}",
                remedy="an OOM during generation looks like this; check the window against the KV budget",
                dependency=f"model:{self.name}",
            )
        if response.status_code >= 400:
            return Outcome.fail(
                ErrorCategory.MODEL_FAILURE,
                f"request rejected ({response.status_code}): {text_body[:200]}",
            )

        try:
            payload = response.json()
        except ValueError:
            return Outcome.fail(ErrorCategory.MODEL_FAILURE, "the response was not JSON")
        if not isinstance(payload, dict):
            return Outcome.fail(ErrorCategory.MODEL_FAILURE, "the response was not a JSON object")

        choices = payload.get("choices") or []
        first = choices[0] if choices else {}
        text = ((first.get("message") or {}).get("content") or "") if choices else ""
        finish = first.get("finish_reason") if choices else None

        if not text.strip():
            # No content is UNKNOWN, not a model failure — the #2407 rule, which does not stop
            # applying because the provider is now local.
            return Outcome.fail(
                ErrorCategory.UNKNOWN,
                "the local model returned no content",
                remedy="this is retried and bounded; it is NOT reported as a model failure",
                details={"finish_reason": finish},
            )

        usage_payload = payload.get("usage") or {}
        cached = (usage_payload.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
        usage = Usage(
            input_tokens=int(usage_payload.get("prompt_tokens", 0) or 0),
            output_tokens=int(usage_payload.get("completion_tokens", 0) or 0),
            # vLLM's automatic prefix cache is the local analogue of provider prompt caching, and
            # it is the reason the tier ordering in §17.3 still earns its keep with no vendor
            # billing to save. Recorded so the saving stays visible rather than merely believed.
            cache_read_tokens=int(cached or 0),
        )
        return Outcome.ok(
            Completion(
                text=text,
                model=str(payload.get("model") or request.model),
                provider=self.name,
                usage=usage,
                raw={"finish_reason": finish, "truncated": finish == "length"},
            )
        )

    def _overflow(self, body: str, request: LLMRequest) -> Outcome[Completion]:
        numbers = [int(n.replace(",", "")) for n in _TOKENS_RE.findall(body)]
        declared = self.max_model_len or (max(numbers) if numbers else None)
        requested = max(numbers) if numbers else None
        if (
            declared is not None
            and requested is not None
            and requested == declared
            and len(numbers) > 1
        ):
            requested = sorted(numbers)[-1]
        return Outcome.fail(
            ErrorCategory.CONTEXT_OVERFLOW,
            f"the prompt exceeds {request.model or self.name}'s window",
            remedy=(
                "assemble less and try once — retrying the same prompt fails identically. "
                "The assembler owns this: pinned facts stay, summaries and retrieval go (L6)"
            ),
            details={
                "declared_window": declared,
                "requested_tokens": requested,
                "max_tokens": request.max_tokens,
                "template_id": request.template_id,
                "server_said": body[:200],
            },
        )

    def _wrong_model(self, body: str, request: LLMRequest) -> Outcome[Completion]:
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            f"{self.base_url} is not serving {request.model!r}",
            remedy=(
                "the serving unit is up but holding a different model — `agent serving check`, "
                "and remember only one model is resident at a time (L2)"
            ),
            details={"server_said": body[:200]},
            dependency=f"model:{self.name}",
        )
