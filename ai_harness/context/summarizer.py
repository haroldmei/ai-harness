"""The constrained summariser (§17.1).

A summariser that may compress *anything* will eventually compress away the acceptance
criterion, the failed approach nobody should retry, or the finding that was already resolved.
So this one is constrained to preserve exactly six categories, and its prompt says so:

1. decisions taken, 2. constraints that still bind, 3. file references, 4. unresolved risks,
5. review findings and their state, 6. required follow-ups.

Anything else may be dropped. The summariser runs on a cheap model — it is a compression step,
not a reasoning one — and its output is a :class:`Trusted` section, because the harness wrote
the instruction that produced it and the material it compresses has already been through the
trust boundary.
"""

from __future__ import annotations

from dataclasses import dataclass

from ai_harness.context.trust import Trusted

REQUIRED_CATEGORIES = (
    "decisions",
    "constraints",
    "file references",
    "unresolved risks",
    "review findings",
    "required follow-ups",
)

TEMPLATE = """Compress the material below for reuse in a later step of the same run.

Preserve, and only these:
{categories}

Drop everything else: narration, restated code, and anything already resolved.
Never invent a detail that is not in the material.
If a category has nothing in it, write "none".

Material:
{material}
"""


@dataclass(frozen=True, slots=True)
class SummaryRequest:
    """What to compress, and the prompt that constrains how."""

    material: str
    template_id: str = "summariser-v1"

    def prompt(self) -> str:
        categories = "\n".join(f"- {name}" for name in REQUIRED_CATEGORIES)
        return TEMPLATE.format(categories=categories, material=self.material)


def as_section(summary: str) -> Trusted:
    """Wrap a produced summary for the summarised tier."""
    return Trusted("Summary of earlier steps in this run:\n" + summary.strip())


def missing_categories(summary: str) -> list[str]:
    """Which required categories the summary failed to mention.

    Checked rather than trusted: a summariser that quietly drops "unresolved risks" produces a
    context that looks complete and is not, and the next state has no way to know.
    """
    lowered = summary.lower()
    return [name for name in REQUIRED_CATEGORIES if name.split()[0] not in lowered]
