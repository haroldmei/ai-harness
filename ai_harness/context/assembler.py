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

CHARS_PER_TOKEN = 4


def estimate_tokens(text: str) -> int:
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


@dataclass
class AssembledContext:
    """The prompt, plus an account of what was left out of it."""

    prompt: str
    tokens: int
    pinned: list[PinnedFact] = field(default_factory=list)
    dropped_summaries: int = 0
    dropped_retrieved: int = 0
    untrusted_sources: list[str] = field(default_factory=list)

    @property
    def complete(self) -> bool:
        return self.dropped_summaries == 0 and self.dropped_retrieved == 0


@dataclass
class ContextAssembler:
    """Builds a prompt from tiers, spending a budget from the least important tier upward."""

    budget: ContextBudget = field(default_factory=ContextBudget)

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

        spent = estimate_tokens(system.text) + sum(estimate_tokens(f.render()) for f in pinned)
        untrusted_cost = sum(estimate_tokens(u.text) for u in (untrusted or []))
        available = self.budget.usable - spent - untrusted_cost

        for section in active or []:
            prompt.add_trusted(section)
            available -= estimate_tokens(section.text)

        dropped_summaries = 0
        for section in summarised or []:
            cost = estimate_tokens(section.text)
            if cost <= available:
                prompt.add_trusted(section)
                available -= cost
            else:
                dropped_summaries += 1

        dropped_retrieved = 0
        for section in retrieved or []:
            cost = estimate_tokens(section.text)
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
            tokens=estimate_tokens(rendered),
            pinned=list(pinned),
            dropped_summaries=dropped_summaries,
            dropped_retrieved=dropped_retrieved,
            untrusted_sources=prompt.sources,
        )
