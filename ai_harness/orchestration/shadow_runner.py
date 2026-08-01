"""The shadow observation runner (#76) — the piece that lets the week actually happen.

Phase 2 built `compare()` and `ShadowComparator`, and both were tested. What did not exist was
anything that *called* them outside a test: no path took a real pull request, ran the Python
reviewer against it, read what the shell reviewer had already decided, and recorded the pair.
Without that, "at least a week of real PRs observed" was not a task waiting to be started — it
was a task with no tool.

Three properties, and the first is the one everything else rests on:

* **The Python path cannot write.** It is handed a write-blocked forge, and a blocked write is
  an *error* rather than a silently skipped call. The shell path keeps posting and keeps owning
  the label; shadow mode that could post is not shadow mode.

* **The shell decision is read, not re-derived.** It is already on the pull request — the shell
  reviewer posted it. Re-running the shell reviewer would double the cost and, worse, compare
  the Python path against a *second* shell opinion rather than the one that actually governed
  the PR.

* **Both decisions are priced.** §24.1's "cost increases" risk row needs the two paths compared
  on the same reviews, and the only moment both numbers exist together is here.

A failure on the Python side is recorded as ``SHELL_ONLY`` with the reason, not dropped. "The
Python reviewer crashed on 3% of PRs" is exactly the kind of thing a week of observation is for,
and a runner that skipped those would report a flattering agreement rate over the survivors.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field, replace
from decimal import Decimal
from typing import Any

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.observability.logging import Logger
from ai_harness.orchestration.shadow import compare
from ai_harness.providers.forge.protocol import Forge
from ai_harness.schemas.enums import Verdict
from ai_harness.schemas.shadow import Comparison, Decision
from ai_harness.subgraphs.review import ReviewContext

VERDICT_MARKERS: tuple[tuple[re.Pattern[str], Verdict], ...] = (
    (re.compile(r"\brequest[_ -]?changes\b", re.I), Verdict.REQUEST_CHANGES),
    (re.compile(r"\bchanges[_ -]?requested\b", re.I), Verdict.REQUEST_CHANGES),
    (re.compile(r"\bapprove[d]?\b", re.I), Verdict.APPROVE),
    (re.compile(r"\bcomment\b", re.I), Verdict.COMMENT),
)
"""How the shell reviewer's verdict is read back off the pull request.

This is exactly the log-scraping the port exists to end (W13), and it is here on purpose and
only here: the shell reviewer is the thing being compared against, so its output format is the
interface whether anyone likes it or not. It disappears when the shell reviewer does.
"""

BLOCKING_MARKER = re.compile(r"^\s*[-*]\s*\**\s*blocking\b", re.I | re.M)


@dataclass(frozen=True, slots=True)
class Observation:
    """One PR, observed. ``recorded`` is false when the comparison could not be stored."""

    comparison: Comparison
    recorded: bool = True


@dataclass
class ShadowRunner:
    """Runs the Python reviewer beside the shell one, records the pair, writes nothing."""

    reviewer: Any
    """Anything with ``execute(ReviewContext)`` — the bound REVIEW subgraph, or a double."""
    forge: Forge
    """Must be write-blocked. :meth:`observe` asserts it rather than trusting the caller."""
    store: Any
    repo: str
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)
    bot_authors: tuple[str, ...] = ("github-actions", "agent", "harness")

    async def observe(
        self, number: int, *, run_id: str = "", round_: int = 1
    ) -> Outcome[Observation]:
        """Observe one pull request. Never writes to the forge, and says so if it could."""
        if not _write_blocked(self.forge):
            return Outcome.fail(
                ErrorCategory.POLICY,
                "refusing to observe with a forge that can write",
                remedy=(
                    "shadow mode requires a write-blocked forge; the shell path owns the label "
                    "and a Python path that could post is not a shadow"
                ),
            )

        mr = await self.forge.find_mr_by_head(f"pr/{number}")
        diff = await self.forge.get_diff(number)
        if diff.is_err:
            return Outcome.of(diff.error)  # type: ignore[arg-type]

        found = mr.unwrap() if mr.is_ok else None
        head_sha = found.head_sha if found is not None else ""
        identity = run_id or f"pr-{number}"

        shell = await self._shell_decision(number)
        python = await self._python_decision(number, diff.unwrap(), head_sha, round_)

        comparison = compare(
            run_id=identity, head_sha=head_sha, round_=round_, shell=shell, python=python
        )
        # `compare()` decides the agreement; the runner only stamps where and when, which are
        # facts it owns and the comparison logic has no business knowing.
        comparison = replace(comparison, repo=self.repo, observed_at=self.clock.now())

        try:
            stored = await self.store.observe(comparison, repo=self.repo)
        except Exception as exc:
            # An unrecordable observation is reported, never swallowed: the whole criterion is
            # a *count* of observations, and one that vanished would quietly shorten the week.
            self.logger.warning("could not record a comparison", pr=number, error=str(exc))
            return Outcome.ok(Observation(comparison=comparison, recorded=False))

        self.logger.info(
            "observed",
            pr=number,
            agreement=stored.agreement.value,
            shell=stored.shell.verdict.value if stored.shell.verdict else None,
            python=stored.python.verdict.value if stored.python.verdict else None,
        )
        return Outcome.ok(Observation(comparison=stored))

    # ── the two decisions ────────────────────────────────────────────────────────

    async def _shell_decision(self, number: int) -> Decision:
        """Read what the shell reviewer already decided. Do not re-run it."""
        issue = await self.forge.get_issue(number)
        if issue.is_err:
            return Decision.absent("shell", "could not read the pull request")

        body = issue.unwrap().body or ""
        verdict = _verdict_from(body)
        if verdict is None:
            return Decision.absent("shell", "no shell verdict found on the pull request")
        return Decision(
            engine="shell",
            verdict=verdict,
            blocking=len(BLOCKING_MARKER.findall(body)),
            usd=Decimal(0),
        )

    async def _python_decision(
        self, number: int, diff_text: str, head_sha: str, round_: int
    ) -> Decision:
        outcome = await self.reviewer.execute(
            ReviewContext(
                run_id=f"shadow-{number}",
                repo=self.repo,
                base_sha="",
                head_sha=head_sha,
                diff_text=diff_text,
                issue_number=number,
                round=round_,
            )
        )
        if outcome.is_err:
            message = outcome.error.message if outcome.error else "the Python reviewer failed"
            return Decision.absent("python", message)

        result = outcome.unwrap()
        review = result.payload.get("review") or {}
        verdict_value = review.get("verdict")
        if verdict_value is None:
            return Decision.absent("python", "the Python reviewer produced no verdict")
        return Decision(
            engine="python",
            verdict=Verdict(verdict_value),
            blocking=len(review.get("blocking_findings") or []),
            downgraded=bool(review.get("downgraded")),
            usd=result.usd,
        )


def _verdict_from(text: str) -> Verdict | None:
    for pattern, verdict in VERDICT_MARKERS:
        if pattern.search(text):
            return verdict
    return None


def _write_blocked(forge: Forge) -> bool:
    """True when this forge refuses writes.

    Checked rather than trusted, because the cost of getting it wrong is the Python path posting
    on a real pull request during what everyone believes is an observation-only week.
    """
    return bool(getattr(forge, "writes_blocked", False))
