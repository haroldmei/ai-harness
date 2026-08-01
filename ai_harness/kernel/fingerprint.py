"""Stable failure signatures.

Invariant 8: *every self-filing loop needs fingerprint + ledger + global cap* (#2381→#2385).
A fingerprint is what lets the harness say "I have already tried to fix this three times"
instead of filing a fresh blocker for each observed subset of one breakage.

The hard part is not hashing, it is **normalisation**: the same failure must fingerprint
identically across runs, hosts, worktrees, wall-clock times and worker ids, and *differently*
from an unrelated failure. Over-normalising is the dangerous direction — a signature derived
from a string with no distinguishing content matches everything, so
:func:`fingerprint` refuses to produce one (the sanity guard).
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

_SUBSTITUTIONS: tuple[tuple[re.Pattern[str], str], ...] = (
    # Timestamps: ISO-8601, syslog-ish, and bare times.
    (
        re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"),
        "<ts>",
    ),
    (re.compile(r"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"), "<time>"),
    # Durations a runner prints on every line ("in 4.21s", "took 132ms").
    (re.compile(r"\b\d+(?:\.\d+)?\s*(?:ms|s|sec|secs|seconds|m|min)\b"), "<dur>"),
    # Temporary paths and worktrees — the same failure in a different worktree is the same.
    (re.compile(r"/tmp/[^\s:'\"]+"), "<tmp>"),
    (re.compile(r"(?:/[\w.@+-]+)*/(?:worktrees|agent-inbox|harness)-?[\w.-]*"), "<wt>"),
    # Absolute paths → basename. A repo checked out twice must fingerprint once.
    (re.compile(r"(?:/[\w.@+-]+)+/([\w.@+-]+\.\w+)"), r"<path>/\1"),
    # Line:column references drift with every edit above them.
    (re.compile(r":\d+:\d+\b"), ":<line>:<col>"),
    (re.compile(r":\d+\b"), ":<line>"),
    # Identifiers that vary per run: hex ids, uuids, ports, pids, memory addresses.
    (re.compile(r"\b0x[0-9a-fA-F]+\b"), "<addr>"),
    (
        re.compile(
            r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
        ),
        "<uuid>",
    ),
    (re.compile(r"\b[0-9a-f]{7,40}\b"), "<sha>"),
    (re.compile(r"\bport\s*=?\s*\d{2,5}\b", re.I), "port=<port>"),
    (re.compile(r"\bpid[= ]\d+\b", re.I), "pid=<pid>"),
    (re.compile(r"\bworker[- ]?\d+\b", re.I), "worker<n>"),
    # Counts a runner prints on a summary line ("3 failed, 1289 passed").
    (re.compile(r"\b\d+\s+(passed|failed|skipped|errors?|warnings?)\b"), r"<n> \1"),
)

_UNINFORMATIVE = re.compile(r"^[<>\w]*$")
"""A normalised string that is only placeholders carries no signal — refuse to sign it."""

_MIN_INFORMATIVE_CHARS = 12


def normalise(text: str) -> str:
    """Strip everything that varies between two occurrences of the same failure."""
    out = text.strip()
    for pattern, replacement in _SUBSTITUTIONS:
        out = pattern.sub(replacement, out)
    out = re.sub(r"\s+", " ", out)
    return out.strip().lower()


@dataclass(frozen=True, slots=True)
class Fingerprint:
    """A signature plus the normalised text it was derived from, for explainability.

    The ledger stores the signature; ``agent inspect`` shows ``normalised`` so an operator
    can see *why* two failures were treated as the same one.
    """

    signature: str
    normalised: str

    def __str__(self) -> str:
        return self.signature


def fingerprint(*parts: str, scope: str = "") -> Fingerprint | None:
    """Signature for a failure, or ``None`` when the input carries no distinguishing content.

    ``scope`` (typically the gate name) is mixed in but does **not** by itself make a
    signature informative: a fingerprint of "unit" plus an empty diagnostic would match every
    future failure of that gate and silently exhaust its retry cap. Returning ``None`` forces
    the caller to fail closed — the guard that the shell's degenerate-signature bug needed.
    """
    normalised = normalise(" ".join(p for p in parts if p))
    informative = normalised.replace("<", "").replace(">", "").strip()
    if len(informative) < _MIN_INFORMATIVE_CHARS or _UNINFORMATIVE.match(normalised):
        return None
    material = f"{scope}\x1f{normalised}" if scope else normalised
    signature = hashlib.sha256(material.encode()).hexdigest()[:16]
    return Fingerprint(signature=signature, normalised=normalised)


def cluster_signature(gate: str, test_ids: list[str]) -> str:
    """Signature for a *set* of failures.

    One breakage on the base surfaces as a different subset on every branch, so a per-failure
    fingerprint changes as each lane fixes a different part — which is exactly why none of the
    shell's guardrails fired during the #2381→#2385 chain. Signing the sorted set makes the
    subsets of one breakage collapse to one signature.
    """
    material = gate + "\x1f" + "\x1e".join(sorted({normalise(t) for t in test_ids}))
    return hashlib.sha256(material.encode()).hexdigest()[:16]
