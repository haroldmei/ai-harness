"""The forge seam (§12.1).

W7: ``gh`` is threaded through every shell stage, so supporting GitLab means a parallel tree.
The protocol is the seam; GitHub is the first implementation and GitLab (Phase 5) is the proof
that the seam is real rather than aspirational.

Two contracts are worth stating because they are what the shell gets wrong:

* **The provider-side MR id is the idempotency token.** Before creating anything, ask the forge
  whether an MR already exists for this head ref. That single query is what makes ``INTEGRATE``
  safe to re-enter after a dropped response.
* **Merged-ness is a durable signal, not a keyword.** The shell's merger rebases and
  fast-forwards, so GitHub reports the PR as ``CLOSED`` with a null merge commit and no
  ``Closes #N`` keyword ever fires. :meth:`Forge.is_merged` therefore asks about the *head
  ref's* reachability, not about a PR's state string.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Protocol, runtime_checkable

from ai_harness.kernel.outcome import Outcome


@dataclass(frozen=True, slots=True)
class Issue:
    number: int
    title: str
    body: str
    """Untrusted content. It reaches a prompt only through the trust-fencing layer (§18.1)."""
    labels: list[str] = field(default_factory=list)
    state: str = "open"
    created_at: datetime | None = None
    url: str = ""

    @property
    def closed(self) -> bool:
        return self.state != "open"


@dataclass(frozen=True, slots=True)
class MergeRequest:
    """A PR or an MR. The terminology mapping stops at the adapter."""

    id: str
    number: int
    head_ref: str
    base_ref: str
    title: str
    state: str = "open"
    labels: list[str] = field(default_factory=list)
    head_sha: str = ""
    merged: bool = False
    url: str = ""
    issue: int | None = None


@dataclass(frozen=True, slots=True)
class Comment:
    id: str
    body: str
    author: str = ""
    created_at: datetime | None = None


@runtime_checkable
class Forge(Protocol):
    """Everything the harness asks of a code-hosting provider."""

    name: str

    # ── issues ───────────────────────────────────────────────────────────────────
    async def list_issues(
        self, *, labels: list[str] | None = None, state: str = "open"
    ) -> Outcome[list[Issue]]: ...

    async def get_issue(self, number: int) -> Outcome[Issue]: ...

    async def add_labels(self, number: int, labels: list[str]) -> Outcome[None]: ...

    async def remove_label(self, number: int, label: str) -> Outcome[None]: ...

    async def comment(self, number: int, body: str, *, key: str | None = None) -> Outcome[Comment]:
        """Post a comment. ``key`` makes it idempotent: the same key never posts twice."""
        ...

    async def close_issue(self, number: int, *, reason: str = "") -> Outcome[None]: ...

    # ── merge requests ───────────────────────────────────────────────────────────
    async def find_mr_by_head(self, head_ref: str) -> Outcome[MergeRequest | None]:
        """The idempotency query. Ask before creating, always."""
        ...

    async def create_mr(
        self, *, head_ref: str, base_ref: str, title: str, body: str, issue: int | None = None
    ) -> Outcome[MergeRequest]: ...

    async def update_mr(
        self, number: int, *, body: str | None = None, title: str | None = None
    ) -> Outcome[MergeRequest]: ...

    async def merge_mr(self, number: int, *, strategy: str = "merge") -> Outcome[MergeRequest]: ...

    async def get_diff(self, number: int) -> Outcome[str]: ...

    async def is_merged(self, head_ref: str, *, base_ref: str) -> Outcome[bool]:
        """Did this head land on the base? Asked of the refs, never of a keyword."""
        ...

    async def blocker_closed(self, reference: str) -> Outcome[bool]:
        """Has the blocking issue been closed? The BLOCKED status polls this."""
        ...
