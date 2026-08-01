"""The Anthropic Messages API as an engine.

Reports tokens (including cache reads, which dominate the review⇄fix rounds) but not cost, so
:mod:`ai_harness.llm.pricing` prices it. Transport errors are mapped onto the same taxonomy the
CLI engine uses — one classifier, several mappings.
"""

from __future__ import annotations

import os
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

API_URL = "https://api.anthropic.com/v1/messages"
API_VERSION = "2023-06-01"


@dataclass
class AnthropicAPIEngine:
    api_key: str = field(default_factory=lambda: os.environ.get("ANTHROPIC_API_KEY", ""))
    base_url: str = API_URL
    client: httpx.AsyncClient | None = None
    name: str = "anthropic"
    capabilities: EngineCapabilities = field(
        default_factory=lambda: EngineCapabilities(
            native_structured_output=True,
            prompt_caching=True,
            tool_use=True,
            reports_cost=False,
        )
    )

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        if not self.api_key:
            return Outcome.fail(
                ErrorCategory.AUTH,
                "ANTHROPIC_API_KEY is not set",
                remedy="configure the credential; this is never retried",
            )

        body: dict[str, Any] = {
            "model": request.model or "claude-opus-5",
            "max_tokens": request.max_tokens,
            "temperature": request.temperature,
            "messages": [{"role": "user", "content": request.prompt}],
        }
        if request.system:
            body["system"] = request.system
        if request.stop:
            body["stop_sequences"] = request.stop

        client = self.client or httpx.AsyncClient(timeout=request.timeout_s)
        owns_client = self.client is None
        try:
            response = await client.post(
                self.base_url,
                json=body,
                headers={
                    "x-api-key": self.api_key,
                    "anthropic-version": API_VERSION,
                    "content-type": "application/json",
                },
            )
        except httpx.TimeoutException:
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"request exceeded {request.timeout_s:.0f}s",
                dependency=f"model:{self.name}",
            )
        except httpx.HTTPError as exc:
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"transport error: {exc}",
                dependency=f"model:{self.name}",
            )
        finally:
            if owns_client:
                await client.aclose()

        return self._map_response(response, request)

    def _map_response(self, response: httpx.Response, request: LLMRequest) -> Outcome[Completion]:
        if response.status_code == 429:
            return Outcome.fail(
                ErrorCategory.RATE_LIMITED,
                "rate limited",
                retry_after_s=_retry_after(response),
                dependency=f"model:{self.name}",
            )
        if response.status_code in (401, 403):
            return Outcome.fail(
                ErrorCategory.AUTH, f"credentials rejected ({response.status_code})"
            )
        if response.status_code >= 500:
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"provider error {response.status_code}",
                dependency=f"model:{self.name}",
            )
        if response.status_code >= 400:
            return Outcome.fail(
                ErrorCategory.MODEL_FAILURE,
                f"request rejected ({response.status_code}): {response.text[:200]}",
            )

        try:
            payload = response.json()
        except ValueError:
            return Outcome.fail(ErrorCategory.MODEL_FAILURE, "response was not JSON")

        blocks = payload.get("content") or []
        text = "".join(b.get("text", "") for b in blocks if isinstance(b, dict))
        if not text.strip():
            # No content is UNKNOWN, not a model failure — the same rule as an empty envelope.
            return Outcome.fail(
                ErrorCategory.UNKNOWN,
                "the response carried no content",
                details={"stop_reason": payload.get("stop_reason")},
            )

        usage_payload = payload.get("usage") or {}
        usage = Usage(
            input_tokens=int(usage_payload.get("input_tokens", 0) or 0),
            output_tokens=int(usage_payload.get("output_tokens", 0) or 0),
            cache_read_tokens=int(usage_payload.get("cache_read_input_tokens", 0) or 0),
            cache_write_tokens=int(usage_payload.get("cache_creation_input_tokens", 0) or 0),
        )
        return Outcome.ok(
            Completion(
                text=text,
                model=str(payload.get("model") or request.model),
                provider=self.name,
                usage=usage,
                raw=payload,
            )
        )


def _retry_after(response: httpx.Response) -> float | None:
    value = response.headers.get("retry-after")
    if value is None:
        return None
    try:
        return float(value)
    except ValueError:
        return None
