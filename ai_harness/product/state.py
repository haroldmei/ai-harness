"""The product build's blackboard, ported from `state-init/set/decide.sh` (#106).

`build-product-v2`, `build-product`, `iterate` and `signal-iterate` drive a build by writing
fields into `state/`. The shell does that with `jq` and an atomic rename, and the skills read the
result with `jq` — so the *format* is an interface, not an implementation detail. A reordered key
or a changed indent is a broken read, which is why the writer here matches `jq`'s output byte for
byte and a test asserts it against a recorded corpus.

**The lock is a port, not an improvement.** `state-set.sh` already takes a `flock` per shard file
and says why: a set is a read-modify-write, and `mv` makes the replacement atomic without doing
anything about two readers racing between the read and the write. That is a lost update the
moment two builds run in parallel. The same lock, at the same granularity — per shard, so writes
to different shards still proceed concurrently — is reproduced here.

Everything else is the shell's behaviour, including the parts that look odd: `set` creates
intermediate objects the way `jq`'s assignment does, `init` merges defaults *under* an existing
document rather than over it, `init` then shards the monolith and thins the index to a pointer
map, and `decide` appends to both `decisions.md` and the `decisions` array because different
consumers read each.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.product.shards import Segment, Shard, parse, shard_for

DEFAULT_IDEA = "an unnamed product"

DEFAULT_TESTING: dict[str, Any] = {
    "gate_attempts": {},
    "open_issues_drained": False,
    "adversarial_rounds": 0,
    "last_mutation_score": None,
    "last_verdict": None,
    "last_run_at": None,
}


def default_document(*, idea: str, now: str) -> dict[str, Any]:
    """The shape `state-init.sh` writes. Key order is part of the contract — `jq` preserves
    insertion order, the skills read the file, and a diff that reorders keys reads as a change."""
    return {
        "schema_version": 1,
        "started_at": now,
        "product_idea": idea,
        "wedge_sentence": None,
        "icp": None,
        "axis": None,
        "anti_axis": None,
        "scale_tier": "launch",
        "current_phase": "iterate",
        "phase_status": {},
        "critic_verdicts": {},
        "kill_switches": [],
        "decisions": [],
        "open_issues": [],
        "kpi_targets": {},
        "testing": dict(DEFAULT_TESTING),
        "signal_sources": {
            "posthog": {"enabled": False, "last_pull": None},
            "sentry": {"enabled": False, "last_pull": None},
            "support": {"enabled": False, "last_pull": None},
        },
        "ml": {
            "enabled": False,
            "tier": "dashboard",
            "task": None,
            "relational": False,
            "online": False,
            "regulated": False,
            "tracking": None,
            "registry": None,
            "serving": None,
            "orchestrator": None,
            "monitoring": None,
            "decision": None,
            "feasibility": {"verdict": None, "reasons": [], "checked_at": None},
            "baseline": {"metric": None, "value": None, "higher_is_better": True},
            "best_run": {
                "id": None,
                "metric": None,
                "value": None,
                "data_version": None,
                "code_version": None,
            },
            "gate_metrics": {},
        },
    }


def dumps(document: Any) -> str:
    """Render exactly as ``jq .`` does: two-space indent, UTF-8, one trailing newline.

    The skills read these files with `jq`, so the format is an interface. `ensure_ascii=False`
    because `jq` emits UTF-8 rather than escapes, and an escaped accent is a different byte
    sequence for anything diffing the file.
    """
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


@contextlib.contextmanager
def _locked(target: Path) -> Iterator[None]:
    """Hold an exclusive lock for a shard's read-modify-write.

    The shell's atomic rename makes each write complete and still loses updates: two concurrent
    callers both read the old document, and the second rename discards the first's change. The
    lock is what makes the pair correct, and it is released by the kernel if the process dies.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    lock = target.with_suffix(target.suffix + ".lock")
    handle = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(handle, fcntl.LOCK_UN)
        os.close(handle)


def _atomic_write(target: Path, text: str) -> None:
    """Temp file in the same directory, then rename. A partial write is never observable.

    `mkstemp` in the *target's* directory rather than `$TMPDIR`, because a rename across
    filesystems is a copy — and a copy is exactly the non-atomic write this avoids.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temporary, target)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise


def assign(document: Any, segments: list[Segment], value: Any) -> Any:
    """Assign at a path, creating what is missing — `jq`'s ``=`` semantics.

    `jq` creates intermediate objects for a missing field and extends an array with nulls up to
    an assigned index. Both are reproduced, because a build script that sets
    `.ml.feasibility.verdict` on a document without `.ml` expects it to appear rather than to
    fail.
    """
    head, *tail = segments
    if head.is_index:
        index = head.index or 0
        items: list[Any] = list(document) if isinstance(document, list) else []
        while len(items) <= index:
            items.append(None)
        items[index] = value if not tail else assign(items[index], tail, value)
        return items

    key = head.key or ""
    fields: dict[str, Any] = dict(document) if isinstance(document, dict) else {}
    fields[key] = value if not tail else assign(fields.get(key), tail, value)
    return fields


def read_path(document: Any, segments: list[Segment]) -> Any:
    for segment in segments:
        if segment.is_index:
            if not isinstance(document, list) or segment.index is None:
                return None
            index = segment.index
            document = document[index] if 0 <= index < len(document) else None
        else:
            if not isinstance(document, dict):
                return None
            document = document.get(segment.key or "")
    return document


@dataclass
class ProductState:
    """The sharded blackboard for one product build."""

    directory: Path
    clock: Clock = field(default_factory=SystemClock)

    # ── files ────────────────────────────────────────────────────────────────────

    @property
    def index(self) -> Path:
        return self.directory / Shard.STATE.value

    @property
    def decisions_md(self) -> Path:
        return self.directory / "decisions.md"

    def shard(self, path: str) -> Path:
        return self.directory / shard_for(path).value

    def load(self, shard: Shard) -> dict[str, Any]:
        target = self.directory / shard.value
        if not target.exists():
            return {}
        try:
            loaded = json.loads(target.read_text(encoding="utf-8"))
        except ValueError as exc:
            raise StateError(f"{target} is not valid JSON: {exc}") from exc
        return loaded if isinstance(loaded, dict) else {}

    # ── the three verbs ──────────────────────────────────────────────────────────

    def init(self, idea: str = DEFAULT_IDEA) -> dict[str, Any]:
        """Create or upgrade the state, then shard it.

        Merge order is the shell's and matters: **the existing document wins.** Defaults fill
        missing fields; they never overwrite a value a build already decided. Then
        :meth:`migrate` runs, exactly as `state-init.sh` calls `state_migrate` — an init on an
        already-sharded tree has to be a no-op, not a re-monolith.
        """
        now = self.clock.now().strftime("%Y-%m-%dT%H:%M:%SZ")
        defaults = default_document(idea=idea, now=now)

        with _locked(self.index):
            existing = self.load(Shard.STATE)
            _atomic_write(self.index, dumps({**defaults, **existing}))

        self._init_signals(now)
        return self.migrate()

    def _init_signals(self, now: str) -> None:
        """`signals.json` is created once and never migrated — it has no monolith to come from."""
        target = self.directory / "signals.json"
        if target.exists():
            return
        _atomic_write(
            target,
            dumps(
                {
                    "initialized_at": now,
                    "last_full_pull": None,
                    "behavior": {
                        "funnel_conversion": None,
                        "activation_24h": None,
                        "retention_d7": None,
                    },
                    "failure": {"top_issues": [], "crash_free_rate": None},
                    "voice": {"themes": []},
                }
            ),
        )

    def migrate(self) -> dict[str, Any]:
        """Shard the monolith and thin the index. Idempotent, and re-runnable concurrently.

        The rule that makes it safe to re-run: **an existing shard is authoritative.** A stage
        that wrote `.testing.gate_attempts` after the first migration must not have it clobbered
        by a second one lifting a stale copy out of the index.
        """
        index = self.load(Shard.STATE)

        testing = self.load(Shard.TESTING).get("testing")
        if testing is None:
            testing = index.get("testing", dict(DEFAULT_TESTING))
        self._write_shard(Shard.TESTING, {"testing": testing})

        findings = self.load(Shard.FINDINGS).get("open_issues")
        if findings is None:
            findings = index.get("open_issues", [])
        self._write_shard(Shard.FINDINGS, {"open_issues": findings})

        product = self.load(Shard.PRODUCT)
        if not product:
            product = {
                key: index.get(key, {} if key == "kpi_targets" else None) for key in _PRODUCT_ORDER
            }
        self._write_shard(Shard.PRODUCT, product)

        release_train = self.directory / Shard.RELEASE_TRAIN.value
        if not release_train.exists():
            self._write_shard(Shard.RELEASE_TRAIN, {})

        thinned = {key: value for key, value in index.items() if key not in SHARDED_KEYS}
        thinned["schema_version"] = INDEX_SCHEMA_VERSION
        thinned["pointers"] = dict(POINTERS)
        with _locked(self.index):
            _atomic_write(self.index, dumps(thinned))
        return thinned

    def _write_shard(self, shard: Shard, document: Any) -> None:
        target = self.directory / shard.value
        with _locked(target):
            _atomic_write(target, dumps(document))

    def set(self, path: str, value: Any) -> Path:
        """Set one field, in the shard that owns it. Returns the file that changed."""
        segments = parse(path)
        target = self.shard(path)
        if not self.index.exists():
            raise StateError(
                f"{self.index} not found — run `agent product init` first. Writing a field into "
                "an uninitialised state would create a document with no schema_version, which "
                "every reader treats as a fresh build"
            )
        with _locked(target):
            document = self.load(shard_for(path))
            _atomic_write(target, dumps(assign(document, segments, value)))
        return target

    def get(self, path: str) -> Any:
        return read_path(self.load(shard_for(path)), parse(path))

    def decide(self, phase: str, decision: str, reason: str) -> str:
        """Record a decision in both places that read it.

        `decisions.md` is what a human reads and `.decisions` is what the builder reads. The
        shell writes both, and writing only one would leave the two disagreeing about what was
        decided — which is worse than either alone.
        """
        date = self.clock.now().strftime("%Y-%m-%d")
        line = f"- [{date}] {phase}: {decision} — because {reason}"

        with _locked(self.index):
            document = self.load(Shard.STATE)
            entries = list(document.get("decisions") or [])
            entries.append({"date": date, "phase": phase, "decision": decision, "reason": reason})
            document["decisions"] = entries
            _atomic_write(self.index, dumps(document))

        self.decisions_md.parent.mkdir(parents=True, exist_ok=True)
        with self.decisions_md.open("a", encoding="utf-8") as stream:
            stream.write(line + "\n")
        return line

    def show(self) -> dict[str, Any]:
        """Every shard, merged for reading. Never written back — that is what `set` is for."""
        merged: dict[str, Any] = {}
        for shard in Shard:
            merged.update(self.load(shard))
        return merged


class StateError(RuntimeError):
    """Raised before anything is written."""


_PRODUCT_ORDER = ("axis", "anti_axis", "icp", "wedge_sentence", "product_idea", "kpi_targets")
"""The order `product.json` carries its keys in — `state_migrate`'s, exactly. Insertion order is
the file's diff order, and a reordered shard reads as a change nobody made."""

SHARDED_KEYS = ("testing", "open_issues", *_PRODUCT_ORDER)
"""What `state_migrate` strips out of the index once each has an owning shard."""

POINTERS = {
    "product": "state/product.json",
    "testing": "state/testing.json",
    "findings": "state/findings.json",
}

INDEX_SCHEMA_VERSION = 2
"""The index is stamped v2 by migration. v1 is the pre-shard monolith, and the number is how a
reader tells whether `.open_issues` being absent means "none" or "look in findings.json"."""
