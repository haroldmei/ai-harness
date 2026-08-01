"""An OpenAI-compatible engine — the second implementation that validates the boundary.

Q5: the design assumes at least two providers because the reviewer must differ from the
implementer, but the shell harness is Anthropic-only. **A boundary validated by intent is not
validated.** Writing a second engine is what proves the seam is real, and it did its job: the
capability differences below (native structured output, no cost reporting, a different rate-limit
shape) are exactly the places a single-provider design would have leaked assumptions.

Points at any OpenAI-compatible endpoint — the API itself, or a local server, or a gateway —
because ``base_url`` is configuration rather than a constant.
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

DEFAULT_URL = "https://api.openai.com/v1/chat/completions"


@dataclass
class OpenAIEngine:
    """Chat-completions over HTTP, mapped onto the harness's own taxonomy."""

    api_key: str = field(default_factory=lambda: os.environ.get("OPENAI_API_KEY", ""))
    base_url: str = DEFAULT_URL
    client: httpx.AsyncClient | None = None
    name: str = "openai"
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
                "OPENAI_API_KEY is not set",
                remedy="configure the credential; this is never retried",
            )

        messages: list[dict[str, str]] = []
        if request.system:
            messages.append({"role": "system", "content": request.system})
        messages.append({"role": "user", "content": request.prompt})

        body: dict[str, Any] = {
            "model": request.model or "gpt-5",
            "messages": messages,
            "max_completion_tokens": request.max_tokens,
        }
        if request.schema is not None:
            # Native structured output where the engine has it — the same code path, selected
            # by capability rather than by a provider check at the call site.
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": "output", "schema": request.schema, "strict": False},
            }

        client = self.client or httpx.AsyncClient(timeout=request.timeout_s)
        owns = self.client is None
        try:
            response = await client.post(
                self.base_url,
                json=body,
                headers={
                    "Authorization": f"Bearer {self.api_key}",
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
                ErrorCategory.TRANSIENT, f"transport error: {exc}", dependency=f"model:{self.name}"
            )
        finally:
            if owns:
                await client.aclose()

        return self._map(response, request)

    def _map(self, response: httpx.Response, request: LLMRequest) -> Outcome[Completion]:
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

        choices = payload.get("choices") or []
        text = ""
        if choices:
            text = (choices[0].get("message") or {}).get("content") or ""
        if not text.strip():
            # No content is UNKNOWN, not a model failure — the same rule as an empty envelope.
            return Outcome.fail(
                ErrorCategory.UNKNOWN,
                "the response carried no content",
                details={"finish_reason": choices[0].get("finish_reason") if choices else None},
            )

        usage_payload = payload.get("usage") or {}
        cached = (usage_payload.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
        usage = Usage(
            input_tokens=int(usage_payload.get("prompt_tokens", 0) or 0),
            output_tokens=int(usage_payload.get("completion_tokens", 0) or 0),
            cache_read_tokens=int(cached or 0),
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
