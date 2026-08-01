"""``FakeVLLM`` — the local server's fault modes, on demand.

The same argument as ``FakeForge`` (#24): a double that only does the happy path tests the
mapping nobody gets wrong. These are the modes that actually happen on one workstation with one
card, and each of them maps to a *different* category — which is the entire content of the local
engine, and therefore the entire thing worth testing.

It answers at the transport level, so tests exercise the real :class:`VLLMEngine` rather than a
parallel implementation of it.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from enum import StrEnum

import httpx


class Fault(StrEnum):
    NONE = "none"
    OVERFLOW = "overflow"
    """A prompt longer than the window. Deterministic, and the caller can fix it."""
    WRONG_MODEL = "wrong_model"
    """The unit that is up is holding the other model — the cost of one resident model (L2)."""
    SATURATED = "saturated"
    """A second in-flight call on a box that serves one at a time."""
    RESTARTING = "restarting"
    """A swap, a crash-restart, or an OOM kill. Connection refused, then fine again."""
    OOM = "oom"
    """The window fitted on paper and not in VRAM. A 500 mid-generation."""
    EMPTY = "empty"
    """Content-free response — the #2407 shape, which is UNKNOWN and not a model failure."""
    TRUNCATED = "truncated"
    """``finish_reason: length``. Valid transport, unusable JSON, and a repair loop's cause."""
    NO_CREDENTIAL = "no_credential"


@dataclass
class FakeVLLM:
    """A scripted local server. ``faults`` are consumed in order, then ``NONE`` forever."""

    model: str = "qwen3-coder-30b"
    max_model_len: int = 65536
    text: str = '{"ok": true}'
    faults: list[Fault] = field(default_factory=list)
    requests: list[httpx.Request] = field(default_factory=list)
    prompt_tokens: int = 1200
    completion_tokens: int = 64
    cached_tokens: int = 0

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self.transport())

    @property
    def handler(self) -> Callable[[httpx.Request], httpx.Response]:
        return self.handle

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        fault = self.faults.pop(0) if self.faults else Fault.NONE

        if request.url.path.endswith("/models"):
            return httpx.Response(
                200,
                json={
                    "data": [
                        {
                            "id": self.model,
                            "revision": "a" * 40,
                            "max_model_len": self.max_model_len,
                        }
                    ]
                },
            )

        match fault:
            case Fault.OVERFLOW:
                return httpx.Response(
                    400,
                    json={
                        "object": "error",
                        "message": (
                            f"This model's maximum context length is {self.max_model_len} tokens. "
                            f"However, you requested {self.max_model_len + 4096} tokens. "
                            "Please reduce the length of the messages."
                        ),
                        "type": "BadRequestError",
                    },
                )
            case Fault.WRONG_MODEL:
                return httpx.Response(
                    404,
                    json={
                        "object": "error",
                        "message": "The model `devstral-24b` does not exist.",
                    },
                )
            case Fault.SATURATED:
                return httpx.Response(
                    429, json={"object": "error", "message": "queue is full, try again"}
                )
            case Fault.RESTARTING:
                raise httpx.ConnectError("connection refused", request=request)
            case Fault.OOM:
                return httpx.Response(
                    500,
                    json={"object": "error", "message": "CUDA out of memory during forward pass"},
                )
            case Fault.NO_CREDENTIAL:
                return httpx.Response(401, json={"object": "error", "message": "Unauthorized"})
            case Fault.EMPTY:
                return httpx.Response(
                    200,
                    json={
                        "model": self.model,
                        "choices": [{"message": {"content": ""}, "finish_reason": "stop"}],
                        "usage": {"prompt_tokens": self.prompt_tokens, "completion_tokens": 0},
                    },
                )
            case Fault.TRUNCATED:
                return httpx.Response(200, json=self._body(finish="length", text=self.text[:6]))
            case _:
                return httpx.Response(200, json=self._body())

    def _body(self, *, finish: str = "stop", text: str | None = None) -> dict[str, object]:
        return {
            "model": self.model,
            "choices": [
                {
                    "message": {"content": self.text if text is None else text},
                    "finish_reason": finish,
                }
            ],
            "usage": {
                "prompt_tokens": self.prompt_tokens,
                "completion_tokens": self.completion_tokens,
                "prompt_tokens_details": {"cached_tokens": self.cached_tokens},
            },
        }
