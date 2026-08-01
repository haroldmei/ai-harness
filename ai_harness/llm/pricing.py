"""Prices, with an ``effective_from`` so history stays correct.

A2 in §2: the ``claude`` CLI reports cost, other providers report tokens only. Where a provider
reports cost we trust it; where it does not we price the tokens from this table. Rates carry an
effective date so a run priced last month does not silently re-price when a rate changes —
``agent cost --since`` must not rewrite the past.

Cache reads are priced separately because they are the dominant saving on the review⇄fix
rounds, and a cost report that hides them makes prompt-prefix work look worthless.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime
from decimal import Decimal

from ai_harness.llm.engines.protocol import Usage

MTOK = Decimal(1_000_000)


@dataclass(frozen=True, slots=True)
class Rate:
    """USD per million tokens."""

    input_: Decimal
    output: Decimal
    cache_read: Decimal = Decimal(0)
    cache_write: Decimal = Decimal(0)
    effective_from: date = date(2025, 1, 1)


_TABLE: dict[tuple[str, str], list[Rate]] = {
    ("anthropic", "claude-opus-5"): [
        Rate(Decimal("15"), Decimal("75"), Decimal("1.50"), Decimal("18.75"))
    ],
    ("anthropic", "claude-sonnet-5"): [
        Rate(Decimal("3"), Decimal("15"), Decimal("0.30"), Decimal("3.75"))
    ],
    ("anthropic", "claude-haiku-4-5-20251001"): [
        Rate(Decimal("1"), Decimal("5"), Decimal("0.10"), Decimal("1.25"))
    ],
    ("openai", "gpt-5"): [Rate(Decimal("10"), Decimal("30"))],
}

UNKNOWN_MODEL_RATE = Rate(Decimal("5"), Decimal("25"))
"""Used when a model is unpriced. Deliberately not zero: an unknown price must not read as free."""


def rate_for(provider: str, model: str, at: datetime | None = None) -> tuple[Rate, bool]:
    """The applicable rate, and whether it was a real entry rather than the fallback."""
    when = (at or datetime.now(UTC)).date()
    rates = _TABLE.get((provider, model))
    if not rates:
        # Providers version model ids; match the longest configured prefix.
        candidates = [
            (key, value)
            for key, value in _TABLE.items()
            if key[0] == provider and model.startswith(key[1])
        ]
        if candidates:
            rates = max(candidates, key=lambda item: len(item[0][1]))[1]
    if not rates:
        return UNKNOWN_MODEL_RATE, False
    applicable = [r for r in rates if r.effective_from <= when] or rates
    return max(applicable, key=lambda r: r.effective_from), True


def price(usage: Usage, *, provider: str, model: str, at: datetime | None = None) -> Decimal:
    """Cost for one call. A provider-reported cost wins; otherwise the table prices it."""
    if usage.reported_usd is not None:
        return usage.reported_usd
    rate, _known = rate_for(provider, model, at)
    return (
        Decimal(usage.input_tokens) * rate.input_
        + Decimal(usage.output_tokens) * rate.output
        + Decimal(usage.cache_read_tokens) * rate.cache_read
        + Decimal(usage.cache_write_tokens) * rate.cache_write
    ) / MTOK


def is_priced(provider: str, model: str) -> bool:
    """False when the fallback rate would be used — surfaced so the gap is visible."""
    return rate_for(provider, model)[1]
