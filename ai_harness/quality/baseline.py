"""Inherited red — judge a branch by the failures it *adds*.

Invariant 9. On a red base, every lane fails in files it never touched, and a triage that is
correct by its own rules calls each one "a pre-existing breakage — file a blocker". One
breakage became a five-deep chain of blocked issues (#2381→#2385), each blocked behind the
next, none mergeable, because every guardrail keyed on a fingerprint that *changed* as each
lane fixed a different subset.

The fix is upstream of triage, and it is fail-closed by construction. All three rules are
preserved exactly:

1. a baseline is consulted **only** when it was recorded for the exact base commit — no
   baseline for that sha means every failure is new;
2. a failure with no extractable test id is **not** forgivable — you cannot forgive what you
   cannot name;
3. a run *on* the base **records** rather than consults, so a red base can never forgive
   itself.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from ai_harness.quality.reason import failing_test_ids, normalise_test_id


class BaselineStatus(StrEnum):
    FORGIVEN = "forgiven"
    """Every failure was already red on this exact base."""
    NEW_FAILURES = "new_failures"
    NO_BASELINE = "no_baseline"
    """Unknown ⇒ fail closed: the gate stays red."""
    NOT_FORGIVABLE = "not_forgivable"
    """Failures exist that carry no extractable test id."""


@dataclass(frozen=True, slots=True)
class BaselineVerdict:
    status: BaselineStatus
    new_failures: list[str]
    forgiven: list[str]

    @property
    def may_forgive(self) -> bool:
        return self.status is BaselineStatus.FORGIVEN


class BaselineStore:
    """Failing test ids per ``(gate, base_sha)``, on disk, namespaced per repository."""

    def __init__(self, directory: str | Path) -> None:
        self._dir = Path(directory)

    def _path(self, gate: str, sha: str) -> Path:
        return self._dir / f"{sha}" / f"{gate}.json"

    def record(self, gate: str, sha: str, log_text: str) -> list[str]:
        """Record what is red **on the base**. Called by a run on the base, never by a branch."""
        ids = failing_test_ids(log_text)
        path = self._path(gate, sha)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"gate": gate, "base_sha": sha, "tests": ids}, indent=2))
        return ids

    def load(self, gate: str, sha: str) -> list[str] | None:
        path = self._path(gate, sha)
        if not path.exists():
            return None
        try:
            payload = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            # An unreadable baseline is not an empty baseline: fail closed.
            return None
        tests = payload.get("tests")
        return [str(t) for t in tests] if isinstance(tests, list) else None

    def evaluate(self, gate: str, sha: str, log_text: str) -> BaselineVerdict:
        """Which of this branch's failures are new? Unknown always means "all of them"."""
        observed = failing_test_ids(log_text)
        baseline = self.load(gate, sha)

        if baseline is None:
            return BaselineVerdict(BaselineStatus.NO_BASELINE, observed, [])
        if not observed:
            # The gate failed but nothing named a test — an import error, a crashed runner, a
            # timeout. Not forgivable: forgiveness requires identifying what was already red.
            return BaselineVerdict(BaselineStatus.NOT_FORGIVABLE, [], [])

        known = {normalise_test_id(t) for t in baseline}
        new = [t for t in observed if t not in known]
        forgiven = [t for t in observed if t in known]
        if new:
            return BaselineVerdict(BaselineStatus.NEW_FAILURES, new, forgiven)
        return BaselineVerdict(BaselineStatus.FORGIVEN, [], forgiven)
