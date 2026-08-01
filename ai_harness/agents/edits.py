"""Anchored edits — the same whole-file semantics, a fifth of the output tokens.

``FileEdit`` is a whole-file write, and its reason is sound: *a patch that does not apply cleanly
is a second failure mode, and the model has the file in front of it*. What changed is the price.
At the pessimistic 30 tok/s a 400-line file is about 90 seconds of generation, and a five-file
change is a ten-minute IMPLEMENT before a single test has run. Most of those tokens are the model
retyping lines it was given.

So the model may *express* an edit compactly, and this module turns it back into a whole file
before anything else in the system sees it. Three properties are load-bearing:

* **The broker still receives whole-file writes.** Containment, capability checks and the audit
  trail are untouched, and there is no second write path to keep in step with the first.
* **An anchor that does not match exactly once is a validation failure**, carrying the anchor, and
  it goes through the repair loop that already exists. A patch that half-applies is the failure
  mode whole-file writes were chosen to avoid; ambiguity is refused rather than guessed.
* **Small files stay whole.** Below the threshold, rewriting costs fewer tokens than describing
  the change — anchors carry their own overhead, and a 20-line file is cheaper to restate.
"""

from __future__ import annotations

from dataclasses import dataclass

from pydantic import BaseModel, Field, model_validator

WHOLE_FILE_THRESHOLD_LINES = 40
"""Below this, a whole-file rewrite is the cheaper *and* safer expression. The number is a
token-count judgement, not a style preference: an anchored hunk costs its anchor twice."""


class AnchoredEdit(BaseModel):
    """Replace an exact, unique region of a file.

    ``anchor`` is matched literally — not as a regex, not fuzzily, not after normalising
    whitespace. Every relaxation of that rule is a way for an edit to land somewhere the model
    did not mean, and the model is looking at the file it is describing.
    """

    model_config = {"extra": "forbid"}

    path: str = Field(min_length=1)
    anchor: str = Field(min_length=1)
    """The text to replace, copied verbatim from the file."""
    replacement: str
    intent: str = ""

    @model_validator(mode="after")
    def _anchor_is_distinctive(self) -> AnchoredEdit:
        if not self.anchor.strip():
            raise ValueError("an anchor of pure whitespace matches everywhere and means nothing")
        return self


class EditError(ValueError):
    """An anchor that did not match exactly once. Carries what was tried, for the repair."""

    def __init__(self, message: str, *, path: str, anchor: str, occurrences: int) -> None:
        super().__init__(message)
        self.path = path
        self.anchor = anchor
        self.occurrences = occurrences


@dataclass(frozen=True, slots=True)
class Rematerialised:
    """One anchored edit, turned back into the whole file the broker will be given."""

    path: str
    content: str
    intent: str
    saved_characters: int
    """How much smaller the model's output was than the file it changed. The measurement that
    says whether this was worth doing (#88)."""


def apply_anchor(current: str, edit: AnchoredEdit) -> Rematerialised:
    """Produce the full file with ``anchor`` replaced. Raises when that is not unambiguous."""
    occurrences = current.count(edit.anchor)
    if occurrences == 0:
        raise EditError(
            f"the anchor was not found in {edit.path}; it must be copied verbatim from the file",
            path=edit.path,
            anchor=edit.anchor,
            occurrences=0,
        )
    if occurrences > 1:
        raise EditError(
            f"the anchor appears {occurrences} times in {edit.path}; extend it until it is "
            "unique rather than relying on which one is meant",
            path=edit.path,
            anchor=edit.anchor,
            occurrences=occurrences,
        )
    content = current.replace(edit.anchor, edit.replacement, 1)
    return Rematerialised(
        path=edit.path,
        content=content,
        intent=edit.intent,
        saved_characters=max(len(current) - (len(edit.anchor) + len(edit.replacement)), 0),
    )


def prefers_whole_file(current: str) -> bool:
    """Whether this file is small enough that restating it is the cheaper expression."""
    return current.count("\n") + 1 <= WHOLE_FILE_THRESHOLD_LINES
