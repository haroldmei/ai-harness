"""Tiered context assembly (§17.1).

W5: every shell call is a fresh ``claude -p`` with the diff cut at ``head -c 60000``. No
summarisation, no retrieval, no session reuse — and the model cannot see what it was silently
denied.

Six tiers, in a fixed order, because the order is what makes provider prompt caching hit:

1. the **system/role contract** — trusted, and identical across every round;
2. **pinned facts** — acceptance criteria, ``base_sha``, branch, protected paths. These are
   never evicted. Losing the acceptance criterion is how a fixer starts drifting from the
   issue, and the shell re-fetches it from the forge on every reviewer invocation precisely
   because it has nowhere to pin it;
3. the **active tier** — what this state is working on, verbatim;
4. the **summarised tier** — older material, compressed to the six categories of §17.1;
5. the **retrieved tier** — repository chunks for this state's query;
6. **untrusted content** — fenced and provenance-marked, last, because it is the part that
   changes every round.

Everything below the pinned tier is subject to the budget. Nothing is dropped silently: what
did not fit is reported on the bundle and can be stated to the model.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ai_harness.context.trust import Trusted, TrustedPrompt, Untrusted
from ai_harness.kernel.tokens import CalibratedCounter, TokenCounter

CHARS_PER_TOKEN = 4


def estimate_tokens(text: str) -> int:
    """The original heuristic, kept for callers with no model in hand.

    Everything that *budgets* now goes through a :class:`~ai_harness.context.tokens.TokenCounter`
    instead: against a 32k window this under-counts code by roughly 20%, and under-counting is
    the direction that costs a call rather than some context (L6).
    """
    return max(len(text) // CHARS_PER_TOKEN, 1)


@dataclass(frozen=True, slots=True)
class PinnedFact:
    """A fact that must survive every eviction, with the name the model will see."""

    label: str
    value: str

    def render(self) -> str:
        return f"{self.label}: {self.value}"


@dataclass
class ContextBudget:
    max_tokens: int = 120_000
    reserve_for_output: int = 8_000

    @property
    def usable(self) -> int:
        return max(self.max_tokens - self.reserve_for_output, 1_000)

    @classmethod
    def for_model(cls, *, window: int, max_output_tokens: int = 8_000) -> ContextBudget:
        """The budget one served model actually has.

        The default 120 000 was a hosted model's window written down once. Locally the window is
        a property of the weights, the KV cache and the flags the unit was started with, so it is
        passed in from the registry or the probe rather than assumed — and the output reservation
        is subtracted from *that*, because a window is shared between the prompt and the answer.
        """
        return cls(
            max_tokens=window, reserve_for_output=min(max_output_tokens, max(window // 4, 1))
        )


@dataclass
class AssembledContext:
    """The prompt, plus an account of what was left out of it."""

    prompt: str
    tokens: int
    pinned: list[PinnedFact] = field(default_factory=list)
    dropped_summaries: int = 0
    dropped_retrieved: int = 0
    untrusted_sources: list[str] = field(default_factory=list)
    exact_tokens: bool = False
    """Whether :attr:`tokens` came from the model's tokenizer or from an estimate."""
    reassembled: bool = False
    """True when this is the second, smaller assembly after the first did not fit (L6)."""

    @property
    def complete(self) -> bool:
        return self.dropped_summaries == 0 and self.dropped_retrieved == 0


@dataclass
class ContextAssembler:
    """Builds a prompt from tiers, spending a budget from the least important tier upward."""

    budget: ContextBudget = field(default_factory=ContextBudget)
    counter: TokenCounter = field(default_factory=CalibratedCounter)
    """How tokens are counted while spending the budget. The default learns; a server counter
    is exact. Either way the *unit* is tokens rather than characters over four."""

    def assemble(
        self,
        *,
        system: Trusted,
        pinned: list[PinnedFact],
        active: list[Trusted] | None = None,
        summarised: list[Trusted] | None = None,
        retrieved: list[Trusted] | None = None,
        untrusted: list[Untrusted] | None = None,
    ) -> AssembledContext:
        prompt = TrustedPrompt()
        prompt.add_trusted(system)

        # Pinned facts are added before the budget is consulted at all. They are small, and a
        # context that fits by forgetting the acceptance criterion has not fitted.
        if pinned:
            prompt.add_trusted(
                Trusted(
                    "Facts that remain true for this run:\n" + "\n".join(f.render() for f in pinned)
                )
            )

        count = self.counter.count
        spent = count(system.text) + sum(count(f.render()) for f in pinned)
        untrusted_cost = sum(count(u.text) for u in (untrusted or []))
        available = self.budget.usable - spent - untrusted_cost

        for section in active or []:
            prompt.add_trusted(section)
            available -= count(section.text)

        dropped_summaries = 0
        for section in summarised or []:
            cost = count(section.text)
            if cost <= available:
                prompt.add_trusted(section)
                available -= cost
            else:
                dropped_summaries += 1

        dropped_retrieved = 0
        for section in retrieved or []:
            cost = count(section.text)
            if cost <= available:
                prompt.add_trusted(section)
                available -= cost
            else:
                dropped_retrieved += 1

        if dropped_summaries or dropped_retrieved:
            prompt.add_trusted(
                Trusted(
                    f"Context note: {dropped_summaries} summary section(s) and "
                    f"{dropped_retrieved} retrieved chunk(s) did not fit the budget and are NOT "
                    "shown. Say so if your conclusion would depend on them."
                )
            )

        for content in untrusted or []:
            prompt.add_untrusted(content)

        rendered = prompt.render()
        return AssembledContext(
            prompt=rendered,
            tokens=count(rendered),
            exact_tokens=self.counter.exact,
            pinned=list(pinned),
            dropped_summaries=dropped_summaries,
            dropped_retrieved=dropped_retrieved,
            untrusted_sources=prompt.sources,
        )


SHRINK = 0.85
"""How much smaller the second attempt is. Deliberately a step rather than a search: a binary
search over assemblies would be several assemblies, and the tiers below the pinned facts are
*supposed* to be the compressible part."""


def fit(
    assembler: ContextAssembler,
    *,
    window: int,
    max_output_tokens: int = 8_000,
    **sections: object,
) -> AssembledContext:
    """Assemble within a real window, re-assembling **once** if the first attempt does not fit.

    This is the caller-side half of L6. The engine refuses an oversized prompt before the wire;
    something has to make a smaller one, and only this layer knows what may be dropped — pinned
    facts stay, summaries and retrieval go, and what was withheld is stated in the prompt.

    One retry, not a loop: if a budget 15% smaller still does not fit, the problem is not the
    budget. It is a diff or an issue body that is too large for this model, and pretending
    otherwise by shrinking six more times just spends wall-clock before the same escalation.
    """
    assembler.budget = ContextBudget.for_model(window=window, max_output_tokens=max_output_tokens)
    first = assembler.assemble(**sections)  # type: ignore[arg-type]
    if first.tokens <= assembler.budget.usable:
        return first

    assembler.budget = ContextBudget(
        max_tokens=int(window * SHRINK), reserve_for_output=assembler.budget.reserve_for_output
    )
    second = assembler.assemble(**sections)  # type: ignore[arg-type]
    second.reassembled = True
    return second
