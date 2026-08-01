"""Where a key lives, and which paths are allowed to ask (#106).

`state/state.json` was an 83 KB monolith mixing four unrelated concerns — product strategy,
pipeline-testing state, adversarial findings, phase bookkeeping. Every stage that wanted one
field paid for all of it, in tokens when a model reads it and in fragility always, and concurrent
writers from different stages contended on one file (#1699).

Sharding fixed that with one crucial invariant, ported here verbatim: **each shard keeps the
namespace at its original key path.** `.testing.gate_attempts."e2e"` is the same path before and
after; only the *file* it resolves to changes. That is what let call sites migrate one at a time,
and it is why the routing is a function of the top-level key rather than a rewritten schema.

Two things this module refuses, both because the shell learned them the hard way:

* **A key with no owner does not fall back to a write.** `gate_repro_tests` hard-coded
  `state/state.json` for `.open_issues` — which `findings.json` owns — and silently measured zero
  issues (#2387). Here the mapping is total by construction: every path resolves to exactly one
  shard, and the default branch is a named shard rather than an accident.
* **A path is not a program.** The shell rejects operators, whitespace and bare `.` before the
  string reaches `jq`, because a jq path is an expression language and this one comes from a
  caller. The same validation lives here, and it is a parse rather than a regex — the parsed
  segments are what performs the write, so an expression that survived the check still could not
  be executed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

PRODUCT_KEYS: frozenset[str] = frozenset(
    {"axis", "anti_axis", "icp", "wedge_sentence", "product_idea", "kpi_targets"}
)
"""The six product-namespace keys of #1699. Strategy, read by `iterate` on a cold start."""


class Shard(StrEnum):
    STATE = "state.json"
    """The thin index: schema_version, iteration_count, scale_tier, phases, decisions."""
    PRODUCT = "product.json"
    TESTING = "testing.json"
    FINDINGS = "findings.json"
    RELEASE_TRAIN = "release-train.json"
    """Host-local and git-ignored: a weekly cut must not dirty the tree it is about to tag."""


TOP_KEY_SHARDS: dict[str, Shard] = {
    "testing": Shard.TESTING,
    "open_issues": Shard.FINDINGS,
    "release_train": Shard.RELEASE_TRAIN,
}


class PathError(ValueError):
    """A path that will not be executed. Raised before anything is opened."""


_FIELD = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
_UNSAFE = re.compile(r"[\s=|;(){}$`<>&!]")
"""The shell's rejection set, kept exactly. Every character here turns a path into an
expression, and the path arrives from a caller."""


@dataclass(frozen=True, slots=True)
class Segment:
    """One step of a path: a field name, or an array index."""

    key: str | None = None
    index: int | None = None

    @property
    def is_index(self) -> bool:
        return self.index is not None


def parse(path: str) -> list[Segment]:
    """Parse a jq-shaped path into segments, or refuse it.

    Accepts ``.foo``, ``.foo.bar``, ``."foo-bar"``, ``.foo[0]``, ``.foo[0].bar``. Refuses a bare
    ``.`` (a whole-document write is how a caller replaces the state by accident), anything
    containing an operator or whitespace, and anything that does not begin with a concrete field
    or index.
    """
    if not path or not path.startswith("."):
        raise PathError(f"a path must start with '.', got {path!r}")
    if path == ".":
        raise PathError(
            "refusing a bare '.' — a whole-document write replaces the state rather than "
            "changing a field in it"
        )
    if _UNSAFE.search(path):
        raise PathError(
            f"refusing unsafe path {path!r}: it contains an operator or whitespace. Only plain "
            'field/index paths are allowed (.scale_tier, .testing.gate_attempts."e2e", .kill_switches[0])'
        )

    segments: list[Segment] = []
    rest = path
    while rest:
        if rest.startswith("."):
            rest = rest[1:]
            if rest.startswith('"'):
                end = rest.find('"', 1)
                if end == -1:
                    raise PathError(f"unterminated quoted key in {path!r}")
                segments.append(Segment(key=rest[1:end]))
                rest = rest[end + 1 :]
                continue
            match = _FIELD.match(rest)
            if not match:
                raise PathError(
                    f"refusing path {path!r} — must start with a concrete field or index "
                    '(.foo, ."foo-bar", or [0])'
                )
            segments.append(Segment(key=match.group()))
            rest = rest[match.end() :]
            continue
        if rest.startswith("["):
            end = rest.find("]")
            if end == -1:
                raise PathError(f"unterminated index in {path!r}")
            inner = rest[1:end]
            if not inner.isdigit():
                raise PathError(f"refusing non-numeric index {inner!r} in {path!r}")
            segments.append(Segment(index=int(inner)))
            rest = rest[end + 1 :]
            continue
        raise PathError(f"cannot parse {path!r} at {rest!r}")

    if not segments:
        raise PathError(f"no segments in {path!r}")
    if segments[0].is_index:
        raise PathError(f"refusing {path!r} — a path may not begin with an index")
    return segments


def top_key(path: str) -> str:
    """The top-level field name a path addresses."""
    return parse(path)[0].key or ""


def shard_for(path: str) -> Shard:
    """Which shard owns this path. Total by construction — there is no unowned key."""
    key = top_key(path)
    if key in TOP_KEY_SHARDS:
        return TOP_KEY_SHARDS[key]
    if key in PRODUCT_KEYS:
        return Shard.PRODUCT
    return Shard.STATE


def shard_path(directory: Path, path: str) -> Path:
    return directory / shard_for(path).value
