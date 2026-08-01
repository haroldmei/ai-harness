"""The model's own tokenizer, over the wire.

:class:`~ai_harness.kernel.tokens.CalibratedCounter` is good enough to *budget* with. It is not
good enough to promise with, and L6 promises: no request reaches the server above the window. So
the fully assembled prompt is counted once, exactly, by the thing that will tokenise it.

Every exact count is also a calibration sample, which is why the estimate converges on the real
ratio without a single call being made for the purpose of learning it.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import httpx

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.kernel.tokens import CalibratedCounter, TokenCounter


@dataclass
class ServerCounter:
    """The model's own tokenizer, over ``/tokenize``. Exact, and worth one round trip."""

    base_url: str
    model: str
    client: httpx.AsyncClient | None = None
    timeout_s: float = 30.0
    exact: bool = True
    fallback: CalibratedCounter = field(default_factory=CalibratedCounter)

    def count(self, text: str) -> int:
        """The synchronous path falls back to the calibrated estimate, and says so.

        The assembler is synchronous and runs inside the event loop; a blocking HTTP call per
        section would be both slow and a lie about where the time goes. :meth:`count_exact` is
        the honest answer, and the pre-flight is where it is needed.
        """
        return self.fallback.count(text)

    async def count_exact(self, text: str) -> Outcome[int]:
        root = self.base_url[: -len("/v1")] if self.base_url.endswith("/v1") else self.base_url
        client = self.client or httpx.AsyncClient(timeout=self.timeout_s)
        owns = self.client is None
        try:
            response = await client.post(
                f"{root}/tokenize", json={"model": self.model, "prompt": text}
            )
        except httpx.HTTPError as exc:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"the tokenizer endpoint did not answer: {exc}",
                remedy="counting falls back to the calibrated estimate, which is not exact",
                dependency="serving",
            )
        finally:
            if owns:
                await client.aclose()

        if response.status_code >= 400:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"the tokenizer endpoint answered {response.status_code}",
            )
        try:
            payload = response.json()
        except ValueError:
            return Outcome.fail(ErrorCategory.ENVIRONMENT, "the tokenizer answered non-JSON")

        count = payload.get("count")
        if count is None:
            tokens = payload.get("tokens")
            count = len(tokens) if isinstance(tokens, list) else None
        if count is None:
            return Outcome.fail(ErrorCategory.ENVIRONMENT, "the tokenizer reported no count")

        characters = len(text)
        self.fallback.calibrate(characters=characters, tokens=int(count))
        return Outcome.ok(int(count))


def counter_for(*, base_url: str | None, model: str) -> TokenCounter:
    """A server counter where there is a server, and a learning estimate everywhere else."""
    if base_url:
        return ServerCounter(base_url=base_url, model=model)
    return CalibratedCounter(model=model)
