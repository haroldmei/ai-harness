"""One engine per model, because locally the roster is two servers.

``AgentRoster.__post_init__`` refuses to construct a roster whose reviewer and implementer share
a model, and the refusal is deliberately not a warning: *a self-review that looks like a review
is worse than no review*. Meanwhile :class:`~ai_harness.llm.client.LLMClient` holds exactly one
:class:`Engine`, and every role reaches it with a different ``model`` string. That works when one
vendor serves every model. It stops working the moment two models are two servers on two ports —
and it never worked for a mixed roster with a local implementer and a hosted reviewer.

So the router dispatches on ``request.model``. Three properties are worth stating:

* **An unmapped model is a construction error, not a default.** This is ``build_engine``'s rule
  one level down: defaulting would send a typo'd model name to whichever engine happened to be
  first, and the resulting review would look exactly like a real one.

* **Capabilities are the intersection.** A caller that reads ``router.capabilities`` is asking
  what it may rely on for *any* route, and the only safe answer is what every route supports.
  Each engine still uses its own capabilities when it builds its own request.

* **Fallback is opt-in, marked, and counted.** When a local route fails in a way a hosted model
  could survive, an explicitly configured fallback may take the call — and the completion carries
  ``raw["fallback"]`` so the client can put it on the span, the report can show it, and a "$0 run"
  that quietly cost money cannot happen (L7). Counting is the *client's* job, because the client
  is the thing that knows which run this is.

Not every failure is worth falling back on. A schema violation will violate the schema again
somewhere else, and a context overflow needs a smaller prompt rather than a bigger wallet.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.engines.protocol import (
    Completion,
    Engine,
    EngineCapabilities,
    LLMRequest,
)

FALLBACK_WORTHY: frozenset[ErrorCategory] = frozenset(
    {
        ErrorCategory.TRANSIENT,
        ErrorCategory.RATE_LIMITED,
        ErrorCategory.ENVIRONMENT,
        ErrorCategory.UNKNOWN,
    }
)
"""Failures a *different* provider could plausibly survive: the server is down, restarting,
saturated, or answered nothing. Deliberately excluded: ``VALIDATION`` (the schema will be
violated again), ``CONTEXT_OVERFLOW`` (a bigger wallet is not a smaller prompt), ``AUTH`` and
``POLICY`` (nothing about them is provider-shaped)."""


class RoutingError(ValueError):
    """Raised at construction. A router that cannot route is never half-built."""


@dataclass
class RoutingEngine:
    """Dispatches by model name, with an optional, marked fallback per model."""

    routes: dict[str, Engine]
    fallbacks: dict[str, Engine] = field(default_factory=dict)
    name: str = "router"
    capabilities: EngineCapabilities = field(default_factory=EngineCapabilities)

    def __post_init__(self) -> None:
        if not self.routes:
            raise RoutingError("a router with no routes cannot answer anything")
        unknown = sorted(set(self.fallbacks) - set(self.routes))
        if unknown:
            raise RoutingError(
                f"fallback(s) configured for unrouted model(s): {', '.join(unknown)}"
            )
        self.capabilities = _intersect(self.routes.values())

    def engine_for(self, model: str) -> Engine:
        try:
            return self.routes[model]
        except KeyError as exc:
            raise RoutingError(
                f"no engine is configured for model {model!r} "
                f"(routed: {', '.join(sorted(self.routes)) or '—'}). Nothing is defaulted: a "
                "typo would silently run this role on another role's model."
            ) from exc

    def requires(self, *models: str) -> None:
        """Assert at startup that every model a roster names can actually be reached."""
        missing = sorted({m for m in models if m and m not in self.routes})
        if missing:
            raise RoutingError(
                f"the roster names model(s) with no engine: {', '.join(missing)}. "
                "Refusing at startup rather than at the first call of that role."
            )

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        primary = self.engine_for(request.model)
        outcome = await primary.complete(request)
        if outcome.is_ok:
            return outcome

        error = outcome.error
        assert error is not None
        fallback = self.fallbacks.get(request.model)
        if fallback is None or not request.allow_fallback:
            return outcome
        if error.category not in FALLBACK_WORTHY:
            return outcome

        second = await fallback.complete(request)
        if second.is_err:
            # Both failed: return the *primary's* failure. The fallback's error describes a
            # provider this roster does not normally use, and blaming it would send whoever
            # reads the escalation to the wrong system.
            return outcome

        completion = second.unwrap()
        return Outcome.ok(
            Completion(
                text=completion.text,
                model=completion.model,
                provider=completion.provider,
                usage=completion.usage,
                session_id=completion.session_id,
                raw={
                    **completion.raw,
                    "fallback": {
                        "from": primary.name,
                        "to": fallback.name,
                        "model": request.model,
                        "category": str(error.category),
                        "reason": error.message,
                    },
                },
            )
        )


def _intersect(engines: object) -> EngineCapabilities:
    items = list(engines)  # type: ignore[call-overload]
    if not items:
        return EngineCapabilities()
    return EngineCapabilities(
        native_structured_output=all(e.capabilities.native_structured_output for e in items),
        prompt_caching=all(e.capabilities.prompt_caching for e in items),
        tool_use=all(e.capabilities.tool_use for e in items),
        reports_cost=all(e.capabilities.reports_cost for e in items),
    )
