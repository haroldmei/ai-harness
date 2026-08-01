"""``agent scout`` — the producer half, with the five disciplines that keep triage cheap.

`agent-scout.sh` is 901 lines and most of them are the disciplines rather than the scanning.
They are what make an unattended issue-producer tolerable instead of a spam generator, and they
are ported here because each one was learned from an accept-rate that was too low:

1. **EVIDENCE** — every candidate cites ``file:line``, and the citation is *re-verified* against
   the working tree before filing. A model that hallucinates a line number produces an issue
   nobody can act on, and the check costs one file read.
2. **CRITIC** — a *different* model refutes each candidate before it is filed: false gap,
   already built, stale spec, imagined, duplicate, low value. Same-model self-review agrees with
   itself, which is the same reason the reviewer and the implementer may not share a model.
3. **DEDUP** — a stable fingerprint per finding, checked against open **and closed** issues.
   Closed matters more than open: re-filing something a human already rejected is the fastest
   way to lose their attention.
4. **RATE-LIMIT** — at most ``max_issues`` per run, and *found nothing files nothing*. A scout
   that always files something is a scout that files noise.
5. **ISOLATION** — it reads, and it files. It never pushes, never edits, and cannot start a run.

The last one is a layering contract (``the scout cannot start a run``), not a comment. If it
could enqueue work, a low-confidence finding would become an unattended code change, and the
economics that make a scout worth running — cheap to reject — would be gone.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.kernel.fingerprint import fingerprint
from ai_harness.kernel.outcome import Outcome
from ai_harness.observability.logging import Logger
from ai_harness.providers.forge.protocol import Forge, Issue
from ai_harness.schemas.scout import ScoutCandidate, ScoutReport, ScoutVerdict

PROPOSED = "proposed"
SPECULATIVE = "proposed-speculative"
FINGERPRINT_MARKER = "<!-- scout-fingerprint: {value} -->"

_CITATION = re.compile(r"^(?P<path>[^\s:]+):(?P<line>\d+)$")


@dataclass
class Scout:
    """One pass: produce → verify evidence → critique → dedup → rank → file, bounded."""

    forge: Forge
    workspace: Path
    producer: Any = None
    """``async (workspace) -> list[ScoutCandidate]``. A wrapped script or an agent."""
    critic: Any = None
    """``async (candidate) -> ScoutVerdict``. A *different* model from the producer."""
    logger: Logger = field(default_factory=Logger)
    max_issues: int = 5
    speculative_threshold: float = 0.5
    labels: list[str] = field(default_factory=list)

    async def scan(self) -> Outcome[ScoutReport]:
        report = ScoutReport()
        if self.producer is None:
            return Outcome.ok(report)

        candidates: list[ScoutCandidate] = list(await self.producer(self.workspace))
        report = report.model_copy(update={"produced": len(candidates)})
        if not candidates:
            # Found nothing files nothing. Stated explicitly because the tempting behaviour —
            # "file the best of a bad batch" — is what destroys an accept rate.
            return Outcome.ok(report)

        seen = await self._existing()
        kept: list[ScoutCandidate] = []
        dropped: dict[str, int] = {}

        for candidate in candidates:
            stamped = candidate.model_copy(update={"fingerprint": _fingerprint(candidate)})

            reason = self._evidence_holds(stamped)
            if reason:
                dropped[reason] = dropped.get(reason, 0) + 1
                continue

            if stamped.fingerprint in seen:
                dropped["duplicate"] = dropped.get("duplicate", 0) + 1
                continue

            if self.critic is not None:
                verdict: ScoutVerdict = await self.critic(stamped)
                if verdict.refuted:
                    dropped[verdict.reason or "refuted"] = (
                        dropped.get(verdict.reason or "refuted", 0) + 1
                    )
                    continue
                stamped = stamped.model_copy(update={"confidence": verdict.confidence})

            seen.add(stamped.fingerprint)
            kept.append(stamped)

        ranked = sorted(kept, key=lambda c: c.rank, reverse=True)
        filed = await self._file(ranked[: self.max_issues])
        return Outcome.ok(
            report.model_copy(
                update={
                    "filed": [issue.number for issue in filed],
                    "dropped": dropped,
                    "withheld": max(len(ranked) - self.max_issues, 0),
                }
            )
        )

    # ── discipline 1: the citation must survive a read ───────────────────────────

    def _evidence_holds(self, candidate: ScoutCandidate) -> str:
        """Re-verify ``file:line`` locally. A hallucinated citation is not evidence."""
        if not candidate.evidence:
            return "no evidence"
        match = _CITATION.match(candidate.evidence.strip())
        if match is None:
            return "unparseable evidence"
        path = self.workspace / match.group("path")
        if not path.is_file():
            return "cited a file that does not exist"
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            return "cited a file that cannot be read"
        if not 1 <= int(match.group("line")) <= len(lines):
            return "cited a line past the end of the file"
        return ""

    # ── discipline 3: dedup against open AND closed ──────────────────────────────

    async def _existing(self) -> set[str]:
        """Fingerprints already filed — closed ones included.

        Re-filing something a human closed is worse than re-filing something still open: the
        first wasted their attention once and is about to do it again.
        """
        found: set[str] = set()
        for state in ("open", "closed"):
            listed = await self.forge.list_issues(state=state)
            if listed.is_err:
                continue
            for issue in listed.unwrap():
                marker = re.search(r"<!-- scout-fingerprint: ([0-9a-f]+) -->", issue.body or "")
                if marker:
                    found.add(marker.group(1))
        return found

    # ── discipline 4 and the speculative tier ────────────────────────────────────

    async def _file(self, candidates: list[ScoutCandidate]) -> list[Issue]:
        filed: list[Issue] = []
        for candidate in candidates:
            speculative = candidate.confidence < self.speculative_threshold
            labels = [
                SPECULATIVE if speculative else PROPOSED,
                *self.labels,
                *candidate.labels,
            ]
            body = (
                f"{candidate.body}\n\n"
                f"**Evidence:** `{candidate.evidence}`\n"
                f"**Engine:** {candidate.engine} · **Severity:** {candidate.severity} · "
                f"**Confidence:** {candidate.confidence:.2f} · **Rank:** {candidate.rank:.2f}\n\n"
                + FINGERPRINT_MARKER.format(value=candidate.fingerprint)
            )
            created = await self.forge.create_issue(title=candidate.title, body=body, labels=labels)
            if created.is_err:
                self.logger.warning("could not file a finding", title=candidate.title)
                continue
            filed.append(created.unwrap())
        return filed


def _fingerprint(candidate: ScoutCandidate) -> str:
    """Stable across reruns and across trivial rewording.

    Built from the engine, the cited location and the normalised title — whitespace collapsed,
    numbers and paths masked by the kernel's own normaliser, trailing punctuation dropped.

    What this deliberately does **not** do is semantic clustering. `agent-scout.sh` additionally
    clusters near-duplicates across a batch with a model; that is a genuinely harder problem and
    an exact-match fingerprint is the part worth having first, because it is the part that
    cannot produce a false merge. Two findings this treats as distinct may still be the same
    defect described differently, and the critic's ``duplicate`` verdict is the second line of
    defence for exactly that.
    """
    computed = fingerprint(
        candidate.engine, candidate.evidence, candidate.title.strip().rstrip(".!?,;: ")
    )
    return computed.signature if computed is not None else ""
