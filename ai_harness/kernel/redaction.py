"""Secret scrubbing, applied on the **write path** of every sink.

The shell harness writes model envelopes to ``/tmp`` and posts gate excerpts to the forge
with no redaction pass; sampling and TTL limit the exposure but nothing removes the secret.
Here, redaction is applied by the logger, the span emitter and the forge comment builder
alike — one implementation, three callers, so a new sink cannot forget it.

Two mechanisms, because either alone leaks:

* **Shape** — patterns that are recognisably credentials wherever they appear.
* **Known values** — the secrets this process was *given* (tokens, passwords from config).
  A token that does not match any shape is still a token, and this catches it.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from typing import Any

MASK = "«redacted»"

_SHAPES: tuple[re.Pattern[str], ...] = (
    # Forge and cloud tokens with recognisable prefixes.
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bglpat-[A-Za-z0-9_-]{16,}\b"),
    re.compile(r"\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    # Bearer / basic authorisation headers.
    re.compile(r"(?i)\b(authorization|proxy-authorization)\s*[:=]\s*\S+"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{12,}"),
    # JWTs.
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    # PEM blocks.
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S),
    # key=value / "key": "value" for secret-shaped names.
    re.compile(
        r"(?i)\b([a-z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|credential)"
        r"[a-z0-9_.-]*)\s*[:=]\s*[\"']?([^\s\"',;]{4,})[\"']?"
    ),
    # Postgres/AMQP-style URLs carrying inline credentials.
    re.compile(r"\b([a-z][a-z0-9+.-]*://)([^\s:/@]+):([^\s@]+)@"),
)

_KV_PATTERN_INDEX = len(_SHAPES) - 2
_URL_PATTERN_INDEX = len(_SHAPES) - 1

_SENSITIVE_KEY = re.compile(
    r"(?i)(password|passwd|secret|token|api[_-]?key|access[_-]?key|credential|authorization)"
)


class Redactor:
    """Scrubs text and structures. Cheap enough to run on every record."""

    def __init__(self, known_values: Iterable[str] = ()) -> None:
        # Sort longest-first so a token that contains another is masked as a whole.
        self._known = sorted((v for v in known_values if v and len(v) >= 4), key=len, reverse=True)

    def with_values(self, values: Iterable[str]) -> Redactor:
        return Redactor([*self._known, *values])

    def text(self, value: str) -> str:
        out = value
        for secret in self._known:
            out = out.replace(secret, MASK)
        for index, pattern in enumerate(_SHAPES):
            if index == _KV_PATTERN_INDEX:
                out = pattern.sub(lambda m: f"{m.group(1)}={MASK}", out)
            elif index == _URL_PATTERN_INDEX:
                out = pattern.sub(lambda m: f"{m.group(1)}{m.group(2)}:{MASK}@", out)
            else:
                out = pattern.sub(MASK, out)
        return out

    def field(self, key: str, value: Any) -> Any:
        """Scrub a single named field. A secret-shaped *name* masks the value outright.

        Sinks log flat key/value pairs, so without this the key-aware masking in :meth:`value`
        would only ever apply one level down — inside a nested mapping — and a top-level
        ``api_key=`` would sail through.
        """
        if _SENSITIVE_KEY.search(key):
            return MASK
        return self.value(value)

    def value(self, value: Any) -> Any:
        """Recursively scrub a JSON-ish structure, masking values under sensitive keys."""
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, Mapping):
            return {
                k: (MASK if isinstance(k, str) and _SENSITIVE_KEY.search(k) else self.value(v))
                for k, v in value.items()
            }
        if isinstance(value, list | tuple | set):
            rendered = [self.value(v) for v in value]
            return type(value)(rendered) if not isinstance(value, set) else set(rendered)
        return value


DEFAULT = Redactor()
"""Shape-only redactor for call sites with no configured secrets (tests, early startup)."""


def redact(value: str) -> str:
    """Shape-only convenience. Prefer a configured :class:`Redactor` where one exists."""
    return DEFAULT.text(value)
