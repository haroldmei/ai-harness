"""The health contract: *serving*, not *started*.

A process that has bound its port is not a model that can answer. vLLM accepts connections while
it is still loading weights and compiling graphs, and on a 30B 4-bit model that window is tens of
seconds — long enough for a worker to start, claim a run, spend a lease and then discover the
model is not there yet. So readiness here is defined as **a token came back**, and nothing else
counts.

Three facts are collected in one round trip because all three are startup conditions and a
partial answer is not useful: is it reachable, is it serving the name the roster uses, and is it
serving the revision that was pinned.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import httpx

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.serving.models import ModelSpec, check_revision


@dataclass(frozen=True, slots=True)
class ServerHealth:
    """What one server said about itself. ``ready`` is the only field worth acting on."""

    base_url: str
    reachable: bool = False
    ready: bool = False
    served: tuple[str, ...] = ()
    revision: str | None = None
    max_model_len: int | None = None
    latency_s: float = 0.0
    detail: str = ""
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class HealthClient:
    """Reads a vLLM server's health, model card and first token."""

    base_url: str
    client: httpx.AsyncClient | None = None
    clock: Clock = field(default_factory=SystemClock)
    timeout_s: float = 10.0
    ready_timeout_s: float = 120.0
    """A cold model answers its first token slowly; that is loading, not failure."""

    async def check(self, spec: ModelSpec | None = None) -> Outcome[ServerHealth]:
        client = self.client or httpx.AsyncClient(timeout=self.timeout_s)
        owns = self.client is None
        try:
            return await self._check(client, spec)
        finally:
            if owns:
                await client.aclose()

    async def _check(
        self, client: httpx.AsyncClient, spec: ModelSpec | None
    ) -> Outcome[ServerHealth]:
        try:
            models = await client.get(f"{self.base_url}/models")
        except httpx.HTTPError as exc:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"no serving endpoint at {self.base_url}: {exc}",
                remedy="start the serving unit for this model, or configure a cloud roster",
                dependency="serving",
            )
        if models.status_code >= 400:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{self.base_url}/models answered {models.status_code}",
                dependency="serving",
            )

        payload = _json(models)
        cards = payload.get("data") or []
        served = tuple(str(card.get("id", "")) for card in cards if card.get("id"))
        card = _card(cards, spec.name if spec else None)
        health = ServerHealth(
            base_url=self.base_url,
            reachable=True,
            served=served,
            revision=_revision(card),
            max_model_len=_int_or_none(card.get("max_model_len")),
            raw=payload,
        )

        if spec is not None:
            if spec.name not in served:
                return Outcome.fail(
                    ErrorCategory.ENVIRONMENT,
                    f"{self.base_url} serves {', '.join(served) or 'nothing'}, not {spec.name!r}",
                    remedy="the serving unit is up but holding a different model — check which unit is running",
                    details={"served": list(served)},
                )
            revision = check_revision(spec, health.revision)
            if revision.is_err:
                assert revision.error is not None
                return Outcome.of(revision.error)

        return Outcome.ok(health)

    async def ready(self, spec: ModelSpec) -> Outcome[ServerHealth]:
        """Health, plus one token. Readiness is measured, never assumed."""
        checked = await self.check(spec)
        if checked.is_err:
            return checked
        health = checked.unwrap()

        client = self.client or httpx.AsyncClient(timeout=self.ready_timeout_s)
        owns = self.client is None
        started = self.clock.monotonic()
        try:
            response = await client.post(
                f"{self.base_url}/chat/completions",
                json={
                    "model": spec.name,
                    "messages": [{"role": "user", "content": "ready?"}],
                    "max_tokens": 1,
                    "temperature": 0.0,
                },
            )
        except httpx.HTTPError as exc:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{spec.name} is loaded but not answering: {exc}",
                remedy="the model is probably still loading; readiness is first token, not bound port",
                dependency="serving",
            )
        finally:
            if owns:
                await client.aclose()

        if response.status_code >= 400:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{spec.name} refused a one-token probe ({response.status_code})",
                details={"body": response.text[:200]},
                dependency="serving",
            )

        body = _json(response)
        choices = body.get("choices") or []
        if not choices:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{spec.name} answered the readiness probe with no choices",
                dependency="serving",
            )

        return Outcome.ok(
            ServerHealth(
                base_url=health.base_url,
                reachable=True,
                ready=True,
                served=health.served,
                revision=health.revision,
                max_model_len=health.max_model_len,
                latency_s=self.clock.monotonic() - started,
                detail="first token returned",
                raw=health.raw,
            )
        )


def _json(response: httpx.Response) -> dict[str, Any]:
    try:
        payload = response.json()
    except ValueError:
        return {}
    return payload if isinstance(payload, dict) else {}


def _card(cards: list[dict[str, Any]], name: str | None) -> dict[str, Any]:
    for entry in cards:
        if name is None or entry.get("id") == name:
            return entry
    return {}


def _revision(card: dict[str, Any]) -> str | None:
    for key in ("revision", "root_revision", "model_revision"):
        value = card.get(key)
        if value:
            return str(value)
    permission = card.get("permission")
    if isinstance(permission, list) and permission:
        value = permission[0].get("revision") if isinstance(permission[0], dict) else None
        if value:
            return str(value)
    return None


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
