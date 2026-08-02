"""The extraction ladder.

Invariant 5: **each rung must PARSE, not merely be non-empty.** PR #2419 went
``review-stuck`` because a hand-rolled ``sed`` range returned the single character ``{`` —
non-empty, so the raw fallback never ran, and a completed review was thrown away over one
brace.

The rungs, in order, each validated by an actual parse before it is accepted:

1. the whole response is JSON;
2. a fenced ```json block (any fenced block, in document order);
3. a balanced-bracket scan, string- and escape-aware, longest candidate first.

Anything that does not parse falls through to the next rung. When every rung fails, the caller
gets a ``VALIDATION`` failure carrying the raw text as evidence — never a silent empty dict.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from enum import StrEnum
from typing import Any


class Rung(StrEnum):
    RAW = "raw"
    FENCED = "fenced"
    BRACKET_SCAN = "bracket_scan"
    NONE = "none"


@dataclass(frozen=True, slots=True)
class Extraction:
    """What was extracted, and which rung produced it — recorded on the span."""

    value: Any
    rung: Rung
    candidates_tried: int = 0

    @property
    def found(self) -> bool:
        return self.rung is not Rung.NONE


def escape_control_characters_in_strings(text: str) -> str:
    """Escape raw newlines, tabs and carriage returns that appear *inside* JSON strings.

    A model writing a multi-line code anchor emits the code as it reads — with real newlines
    inside the string literal — which is invalid JSON. The ladder then falls through to whatever
    partial object a bracket scan can salvage, and the schema complains about a field that was
    never missing: the observed failure was ``summary: Field required`` on output whose first key
    *was* ``summary``.

    This is a repair of the *encoding*, never of the content: it walks the text in one pass,
    tracks whether it is inside a string, and rewrites only the control characters that JSON
    forbids there. Everything else — including the escaping the model got right, often in the
    same string — is passed through untouched. The result still has to parse to count as a rung.
    """
    out: list[str] = []
    in_string = False
    escaped = False
    for char in text:
        if escaped:
            out.append(char)
            escaped = False
            continue
        if char == "\\":
            out.append(char)
            escaped = in_string
            continue
        if char == '"':
            in_string = not in_string
            out.append(char)
            continue
        if in_string and char in _CONTROL:
            out.append(_CONTROL[char])
            continue
        out.append(char)
    return "".join(out)


_CONTROL = {"\n": "\\n", "\r": "\\r", "\t": "\\t"}


def _try_parse(text: str) -> Any | None:
    stripped = text.strip()
    if not stripped:
        return None
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        return None


def _fenced_blocks(text: str) -> list[str]:
    blocks: list[str] = []
    index = 0
    while True:
        start = text.find("```", index)
        if start == -1:
            return blocks
        newline = text.find("\n", start)
        if newline == -1:
            return blocks
        end = text.find("```", newline)
        if end == -1:
            blocks.append(text[newline + 1 :])
            return blocks
        blocks.append(text[newline + 1 : end])
        index = end + 3


def _balanced_candidates(text: str) -> list[str]:
    """Every balanced ``{...}`` / ``[...]`` region, string-aware, longest first.

    String awareness is the point: a brace inside ``"reason": "use {} sparingly"`` must not
    close the object, and a naive scan (or a ``sed`` range) gets exactly that wrong.
    """
    candidates: list[str] = []
    openers = {"{": "}", "[": "]"}
    for start, char in enumerate(text):
        if char not in openers:
            continue
        depth = 0
        in_string = False
        escaped = False
        for index in range(start, len(text)):
            current = text[index]
            if in_string:
                if escaped:
                    escaped = False
                elif current == "\\":
                    escaped = True
                elif current == '"':
                    in_string = False
                continue
            if current == '"':
                in_string = True
            elif current in openers:
                depth += 1
            elif current in openers.values():
                depth -= 1
                if depth == 0:
                    candidates.append(text[start : index + 1])
                    break
    return sorted(set(candidates), key=len, reverse=True)


def extract_json(text: str) -> Extraction:
    """Run the ladder. Every rung must parse; a non-empty non-parse is not an answer."""
    tried = 0

    parsed = _try_parse(text)
    tried += 1
    if parsed is not None:
        return Extraction(value=parsed, rung=Rung.RAW, candidates_tried=tried)

    for block in _fenced_blocks(text):
        tried += 1
        parsed = _try_parse(block)
        if parsed is not None:
            return Extraction(value=parsed, rung=Rung.FENCED, candidates_tried=tried)

    # Repair the WHOLE document before scanning it for fragments. Ordering is the whole content
    # of this rung: a bracket scan happily parses an inner object — one element of
    # `anchored_edits`, say — and that object is valid JSON, so the ladder accepts it and the
    # schema then reports `summary: Field required` about a document whose first key is
    # `summary`. Salvaging a fragment must be the *last* resort, after re-escaping has been
    # tried, or a recoverable document is silently replaced by a piece of itself.
    repaired = escape_control_characters_in_strings(text)
    if repaired != text:
        tried += 1
        parsed = _try_parse(repaired)
        if parsed is not None:
            return Extraction(value=parsed, rung=Rung.RAW, candidates_tried=tried)
        for block in _fenced_blocks(repaired):
            tried += 1
            parsed = _try_parse(block)
            if parsed is not None:
                return Extraction(value=parsed, rung=Rung.FENCED, candidates_tried=tried)

    for candidate in [*_balanced_candidates(text), *_balanced_candidates(repaired)]:
        tried += 1
        parsed = _try_parse(candidate)
        if parsed is not None:
            return Extraction(value=parsed, rung=Rung.BRACKET_SCAN, candidates_tried=tried)

    return Extraction(value=None, rung=Rung.NONE, candidates_tried=tried)


def extract_object(text: str) -> Extraction:
    """As :func:`extract_json`, but a bare scalar or list is not an acceptable answer.

    A schema-bearing call wants an object. Accepting ``42`` because it parses is the same
    class of bug as accepting ``{``: syntactically fine, semantically nothing.
    """
    result = extract_json(text)
    if result.found and not isinstance(result.value, dict):
        for candidate in _balanced_candidates(text):
            parsed = _try_parse(candidate)
            if isinstance(parsed, dict):
                return Extraction(
                    value=parsed, rung=Rung.BRACKET_SCAN, candidates_tried=result.candidates_tried
                )
        return Extraction(value=None, rung=Rung.NONE, candidates_tried=result.candidates_tried)
    return result
