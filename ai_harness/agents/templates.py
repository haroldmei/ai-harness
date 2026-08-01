"""Which prompt a model gets, decided once, at construction.

What the shipped prompts get right is not model-specific: the adversarial framing, the explicit
non-goals, the falsifiability requirement, the decision rule. What *is* model-specific is how
much implicit instruction-following they assume. A frontier model reads "reply with one JSON
object and nothing else" and complies; a 4-bit 30B does better with the schema shown, an example
in front of it, and half the prose.

Per Q13 and L12 a local variant is a **new template id**, never an edit to the existing file:

* the span stays content-addressed, so a regression is attributable to the version that caused
  it rather than to "the reviewer prompt", and
* rolling back to a hosted roster does not silently inherit prompts tuned for a smaller model.

Selection happens at construction rather than at the call site. An ``if`` where the prompt is
rendered is an ``if`` that will eventually disagree with the ``if`` next to it, which is exactly
how the shell harness ended up with four classifiers.
"""

from __future__ import annotations

from ai_harness.agents.base import PROMPTS

LOCAL_FAMILIES: tuple[str, ...] = (
    "qwen",
    "devstral",
    "codestral",
    "mistral",
    "starcoder",
    "llama",
    "deepseek",
    "codellama",
    "granite",
)
"""Model-name fragments that mean "an open-weights model of the size this box can serve".

Matching on the *name* is a heuristic, and it is the right kind: the served-model name comes
from the registry this repository controls, and the fallback when it does not match is the
stricter prompt rather than a broken one.
"""

LOCAL_SUFFIX = "-local"


def is_local_family(model: str) -> bool:
    lowered = model.lower()
    return any(family in lowered for family in LOCAL_FAMILIES)


def template_for(base_template_id: str, model: str) -> str:
    """The template id this (base, model) pair should use.

    Falls back to the base when no variant exists on disk. A missing variant must not be a
    failure: it means this role has not been tuned for a local model yet, and the strict prompt
    is a worse fit rather than a broken one.
    """
    if not is_local_family(model):
        return base_template_id
    candidate = f"{base_template_id}{LOCAL_SUFFIX}"
    if (PROMPTS / f"{candidate}.md").exists():
        return candidate
    return base_template_id
