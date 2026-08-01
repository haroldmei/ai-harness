"""``FakeForge`` — an in-memory forge that *misbehaves on purpose*.

A fake that always succeeds tests nothing about idempotency. This one injects exactly the
failure shapes that made ``find_mr_by_head`` and idempotency keys necessary in the first place:

* **label writes are eventually consistent** — a read straight after a write may miss it, which
  is why a label is a projection and never the source of truth;
* **the search index lags label churn** — ``list_issues`` serves a snapshot from N operations
  ago, the behaviour that makes a claim-by-label race;
* **a comment can be posted and the response lost** — the side effect happened, the caller saw
  a timeout, and a naive retry double-posts;
* **a merge can succeed while the response is dropped** — the case that makes "ask the forge
  before acting" the only safe integration protocol.

Faults are deterministic under a seed, so a failing test fails the same way twice.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import UTC, datetime

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.providers.forge.protocol import Comment, Issue, MergeRequest


@dataclass
class Faults:
    """Which misbehaviours are switched on."""

    label_write_lag: int = 0
    """Reads miss a label write for this many subsequent reads."""
    index_lag_ops: int = 0
    """``list_issues`` serves the snapshot from this many operations ago."""
    drop_comment_response: bool = False
    """Apply the side effect, then report a timeout to the caller."""
    drop_merge_response: bool = False
    rate_limit_every: int = 0
    """Return RATE_LIMITED on every Nth call, to exercise the non-consuming path."""
    seed: int = 1234


@dataclass
class FakeForge:
    """In-memory GitHub/GitLab, with the fault modes of §23."""

    issues: dict[int, Issue] = field(default_factory=dict)
    mrs: dict[int, MergeRequest] = field(default_factory=dict)
    comments: dict[int, list[Comment]] = field(default_factory=dict)
    merged_refs: set[str] = field(default_factory=set)
    faults: Faults = field(default_factory=Faults)
    name: str = "fake"

    calls: int = 0
    writes_blocked: bool = False
    """Shadow mode: assert that a comparison run has no side effects at all."""

    _pending_labels: list[tuple[int, list[str], int]] = field(default_factory=list)
    _index: list[dict[int, Issue]] = field(default_factory=list)
    _rng: random.Random = field(default_factory=lambda: random.Random(1234))
    _next_id: int = 1000

    # ── helpers ──────────────────────────────────────────────────────────────────

    def seed_issue(
        self, number: int, *, title: str = "", body: str = "", labels: list[str] | None = None
    ) -> Issue:
        issue = Issue(
            number=number,
            title=title or f"issue {number}",
            body=body,
            labels=list(labels or []),
            created_at=datetime(2026, 1, 1, tzinfo=UTC),
            url=f"https://fake/issues/{number}",
        )
        self.issues[number] = issue
        self._index.append(dict(self.issues))
        return issue

    def _tick(self) -> Outcome[None] | None:
        self.calls += 1
        self._settle_labels()
        if self.faults.rate_limit_every and self.calls % self.faults.rate_limit_every == 0:
            return Outcome.fail(
                ErrorCategory.RATE_LIMITED,
                "fake rate limit",
                retry_after_s=1.0,
                dependency="forge:fake",
            )
        return None

    def _settle_labels(self) -> None:
        still_pending: list[tuple[int, list[str], int]] = []
        for number, labels, due in self._pending_labels:
            if self.calls >= due:
                issue = self.issues.get(number)
                if issue is not None:
                    self.issues[number] = Issue(
                        number=issue.number,
                        title=issue.title,
                        body=issue.body,
                        labels=sorted({*issue.labels, *labels}),
                        state=issue.state,
                        created_at=issue.created_at,
                        url=issue.url,
                    )
            else:
                still_pending.append((number, labels, due))
        self._pending_labels = still_pending

    def _guard_write(self) -> Outcome[None] | None:
        if self.writes_blocked:
            return Outcome.fail(
                ErrorCategory.POLICY,
                "this run is in shadow mode and may not write to the forge",
            )
        return None

    # ── issues ───────────────────────────────────────────────────────────────────

    async def list_issues(
        self, *, labels: list[str] | None = None, state: str = "open"
    ) -> Outcome[list[Issue]]:
        limited = self._tick()
        if limited is not None:
            return Outcome.of(limited.error)  # type: ignore[arg-type]
        snapshot = self.issues
        if self.faults.index_lag_ops and len(self._index) > self.faults.index_lag_ops:
            snapshot = self._index[-self.faults.index_lag_ops - 1]
        found = [
            issue
            for issue in snapshot.values()
            if issue.state == state and (not labels or set(labels) <= set(issue.labels))
        ]
        self._index.append(dict(self.issues))
        return Outcome.ok(found)

    async def get_issue(self, number: int) -> Outcome[Issue]:
        limited = self._tick()
        if limited is not None:
            return Outcome.of(limited.error)  # type: ignore[arg-type]
        issue = self.issues.get(number)
        if issue is None:
            return Outcome.fail(ErrorCategory.PERMANENT, f"no issue {number}")
        return Outcome.ok(issue)

    async def add_labels(self, number: int, labels: list[str]) -> Outcome[None]:
        blocked = self._guard_write()
        if blocked is not None:
            return blocked
        limited = self._tick()
        if limited is not None:
            return limited
        # The write is accepted now and becomes visible later — read-after-write may miss it.
        self._pending_labels.append(
            (number, list(labels), self.calls + self.faults.label_write_lag)
        )
        self._settle_labels()
        return Outcome.ok(None)

    async def remove_label(self, number: int, label: str) -> Outcome[None]:
        blocked = self._guard_write()
        if blocked is not None:
            return blocked
        limited = self._tick()
        if limited is not None:
            return limited
        issue = self.issues.get(number)
        if issue is not None:
            self.issues[number] = Issue(
                number=issue.number,
                title=issue.title,
                body=issue.body,
                labels=[label_ for label_ in issue.labels if label_ != label],
                state=issue.state,
                created_at=issue.created_at,
                url=issue.url,
            )
        return Outcome.ok(None)

    async def comment(self, number: int, body: str, *, key: str | None = None) -> Outcome[Comment]:
        blocked = self._guard_write()
        if blocked is not None:
            return Outcome.of(blocked.error)  # type: ignore[arg-type]
        limited = self._tick()
        if limited is not None:
            return Outcome.of(limited.error)  # type: ignore[arg-type]

        existing = self.comments.setdefault(number, [])
        if key is not None:
            for index, comment in enumerate(existing):
                if comment.body.endswith(f"<!-- harness-key: {key} -->"):
                    updated = Comment(id=comment.id, body=_with_key(body, key), author="harness")
                    existing[index] = updated
                    return Outcome.ok(updated)

        created = Comment(id=str(self._mint()), body=_with_key(body, key), author="harness")
        existing.append(created)
        if self.faults.drop_comment_response:
            # The side effect landed; the caller is told it timed out.
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                "the response was lost after the comment was posted",
                dependency="forge:fake",
            )
        return Outcome.ok(created)

    async def close_issue(self, number: int, *, reason: str = "") -> Outcome[None]:
        blocked = self._guard_write()
        if blocked is not None:
            return blocked
        self._tick()
        issue = self.issues.get(number)
        if issue is not None:
            self.issues[number] = Issue(
                number=issue.number,
                title=issue.title,
                body=issue.body,
                labels=issue.labels,
                state="closed",
                created_at=issue.created_at,
                url=issue.url,
            )
        return Outcome.ok(None)

    # ── merge requests ───────────────────────────────────────────────────────────

    async def find_mr_by_head(self, head_ref: str) -> Outcome[MergeRequest | None]:
        limited = self._tick()
        if limited is not None:
            return Outcome.of(limited.error)  # type: ignore[arg-type]
        for mr in self.mrs.values():
            if mr.head_ref == head_ref:
                return Outcome.ok(mr)
        return Outcome.ok(None)

    async def create_mr(
        self, *, head_ref: str, base_ref: str, title: str, body: str, issue: int | None = None
    ) -> Outcome[MergeRequest]:
        blocked = self._guard_write()
        if blocked is not None:
            return Outcome.of(blocked.error)  # type: ignore[arg-type]
        existing = await self.find_mr_by_head(head_ref)
        if existing.is_err:
            return existing  # type: ignore[return-value]
        if existing.unwrap() is not None:
            return Outcome.ok(existing.unwrap())  # type: ignore[arg-type]
        number = self._mint()
        mr = MergeRequest(
            id=str(number),
            number=number,
            head_ref=head_ref,
            base_ref=base_ref,
            title=title,
            issue=issue,
            url=f"https://fake/pull/{number}",
        )
        self.mrs[number] = mr
        return Outcome.ok(mr)

    async def update_mr(
        self, number: int, *, body: str | None = None, title: str | None = None
    ) -> Outcome[MergeRequest]:
        blocked = self._guard_write()
        if blocked is not None:
            return Outcome.of(blocked.error)  # type: ignore[arg-type]
        mr = self.mrs.get(number)
        if mr is None:
            return Outcome.fail(ErrorCategory.PERMANENT, f"no MR {number}")
        updated = MergeRequest(
            id=mr.id,
            number=mr.number,
            head_ref=mr.head_ref,
            base_ref=mr.base_ref,
            title=title or mr.title,
            state=mr.state,
            labels=mr.labels,
            head_sha=mr.head_sha,
            merged=mr.merged,
            url=mr.url,
            issue=mr.issue,
        )
        self.mrs[number] = updated
        return Outcome.ok(updated)

    async def merge_mr(self, number: int, *, strategy: str = "merge") -> Outcome[MergeRequest]:
        blocked = self._guard_write()
        if blocked is not None:
            return Outcome.of(blocked.error)  # type: ignore[arg-type]
        mr = self.mrs.get(number)
        if mr is None:
            return Outcome.fail(ErrorCategory.PERMANENT, f"no MR {number}")
        if mr.merged:
            return Outcome.ok(mr)
        merged = MergeRequest(
            id=mr.id,
            number=mr.number,
            head_ref=mr.head_ref,
            base_ref=mr.base_ref,
            title=mr.title,
            state="closed",
            labels=mr.labels,
            head_sha=mr.head_sha,
            merged=True,
            url=mr.url,
            issue=mr.issue,
        )
        self.mrs[number] = merged
        self.merged_refs.add(mr.head_ref)
        if self.faults.drop_merge_response:
            # It merged. The caller does not know that.
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                "the response was lost after the merge succeeded",
                dependency="forge:fake",
            )
        return Outcome.ok(merged)

    async def get_diff(self, number: int) -> Outcome[str]:
        self._tick()
        return Outcome.ok(f"--- diff for MR {number}\n+pass\n")

    async def is_merged(self, head_ref: str, *, base_ref: str) -> Outcome[bool]:
        self._tick()
        return Outcome.ok(head_ref in self.merged_refs)

    async def blocker_closed(self, reference: str) -> Outcome[bool]:
        number = int(reference.lstrip("#"))
        issue = self.issues.get(number)
        return Outcome.ok(issue is not None and issue.closed)

    def _mint(self) -> int:
        self._next_id += 1
        return self._next_id


def _with_key(body: str, key: str | None) -> str:
    return f"{body}\n\n<!-- harness-key: {key} -->" if key else body
