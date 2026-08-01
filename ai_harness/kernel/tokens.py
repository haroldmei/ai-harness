"""Counting tokens honestly, when the window is small enough for the answer to matter.

``estimate_tokens`` is ``len(text) // 4``. Against a hosted 200k-token model that is harmless:
being 20% wrong about a 30k prompt changes nothing. Against a 32k local window it is the
difference between a prompt that fits and a ``400`` — and the error is not symmetric. Counting
*high* costs some context; counting *low* costs the call.

Two counters, and the difference between them is the point:

* an *exact* counter asks the model's own tokenizer. It costs a round trip, and it is what the
  pre-flight check uses on the fully assembled prompt — once, on the thing about to be sent. The
  one that speaks to a vLLM server lives in :mod:`ai_harness.llm.serving.tokenize`, because
  transport belongs next to the transport.
* :class:`CalibratedCounter` — here, because it is pure arithmetic and both the context layer and
  the engine layer need it — is used *while assembling*, where a round trip per candidate section
  would cost more than it saves. It starts at the four-characters-per-token heuristic and learns
  the model's real ratio from usage the harness already reports, keeping a safety margin that
  shrinks as evidence accumulates. Under-counting is the failure that costs a call, so the margin
  is applied in the direction that fits *less*.

A counter always says whether it is exact. A caller that needs certainty — the pre-flight — can
insist; a caller that needs speed does not have to pretend.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Protocol

DEFAULT_CHARS_PER_TOKEN = 4.0
"""The historical heuristic, kept as the starting point rather than as the answer. Real code
tokenises at roughly 3.2-3.6 characters per token, which is why the heuristic under-counts
exactly the material the harness sends most of."""

MIN_CHARS_PER_TOKEN = 1.5
MAX_CHARS_PER_TOKEN = 8.0
"""Bounds on what calibration may learn. A ratio outside these is a measurement bug -- an empty
prompt, a cached-prefix accounting quirk -- and adopting it would silently break every budget."""

INITIAL_MARGIN = 0.15
"""Applied on top of the estimate while uncalibrated: 15% fewer tokens of context, in exchange
for not discovering the window at the wire."""


class TokenCounter(Protocol):
    """How many tokens is this text, and do you actually know?"""

    exact: bool

    def count(self, text: str) -> int: ...


@dataclass
class CalibratedCounter:
    """A heuristic that learns, and is conservative until it has.

    Calibration comes from data the harness already has: every completion reports the prompt
    tokens the server counted, and the prompt's length in characters is on the span. No extra
    call is made to learn this.
    """

    chars_per_token: float = DEFAULT_CHARS_PER_TOKEN
    samples: int = 0
    exact: bool = False
    model: str = ""

    @property
    def margin(self) -> float:
        """Shrinks with evidence: 15% at zero samples, ~2% once the ratio is established."""
        if self.samples >= 20:
            return 0.02
        if self.samples >= 5:
            return 0.05
        return INITIAL_MARGIN

    def count(self, text: str) -> int:
        if not text:
            return 0
        estimate = len(text) / self.chars_per_token
        return max(math.ceil(estimate * (1 + self.margin)), 1)

    def calibrate(self, *, characters: int, tokens: int) -> None:
        """Learn from one real (characters, server-counted tokens) pair."""
        if characters <= 0 or tokens <= 0:
            return
        observed = characters / tokens
        if not (MIN_CHARS_PER_TOKEN <= observed <= MAX_CHARS_PER_TOKEN):
            return
        # A running mean, not the latest value: one unusual prompt (a lockfile, a minified
        # bundle) must not move every subsequent budget.
        self.samples += 1
        weight = 1.0 / min(self.samples, 20)
        self.chars_per_token += (observed - self.chars_per_token) * weight
