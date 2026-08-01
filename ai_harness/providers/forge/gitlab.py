"""GitLab — the second ``Forge``, and therefore the proof that the seam is one.

W7 said supporting GitLab under the shell harness means a parallel tree, because ``gh`` is
threaded through every stage. Here it is one module, and writing it is what shows the protocol
was a boundary rather than a description of GitHub.

The terminology mapping stops here, which is the point:

* GitLab's *iid* is the number a human sees; its *id* is global. The protocol's ``number`` is the
  iid and its ``id`` is the global one, so ``find_mr_by_head`` returns something usable either
  way and nothing above this file has to know the difference.
* GitLab calls comments *notes*, and its state values are ``opened``/``closed``/``merged`` rather
  than ``open``/``closed``. Both are normalised here.
* Labels are a comma-separated string on the wire, not a list.

Two behaviours match the GitHub adapter deliberately, because they are properties of the
*harness*, not of a provider: an idempotency key embedded as an HTML marker so a retry after a
lost response updates rather than duplicates, and merged-ness asked of the refs rather than of a
state string.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any
from urllib.parse import quote

import httpx

from ai_harness.kernel.outcome import ErrorCategory, ErrorRecord, Outcome
from ai_harness.providers.forge.protocol import Comment, Issue, MergeRequest

API = "https://gitlab.com/api/v4"
MARKER = "<!-- harness-key: {key} -->"


@dataclass
class GitLabForge:
    """One project, one token."""

    project: str
    """``group/project``, or a numeric id. URL-encoded on the way out."""
    token: str = field(default_factory=lambda: os.environ.get("GITLAB_TOKEN", ""))
    base_url: str = API
    client: httpx.AsyncClient | None = None
    name: str = "gitlab"
    timeout_s: float = 30.0

    @property
    def _project_path(self) -> str:
        return quote(str(self.project), safe="")

    async def _call(
        self,
        method: str,
        path: str,
        *,
        json: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
    ) -> Outcome[Any]:
        if not self.token:
            return Outcome.fail(
                ErrorCategory.AUTH,
                "GITLAB_TOKEN is not set",
                remedy="configure a token; this is never retried",
            )
        client = self.client or httpx.AsyncClient(timeout=self.timeout_s)
        owns = self.client is None
        url = f"{self.base_url}/projects/{self._project_path}{path}"
        try:
            response = await client.request(
                method,
                url,
                json=json,
                params=params,
                headers={"PRIVATE-TOKEN": self.token, "content-type": "application/json"},
            )
        except httpx.TimeoutException:
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"gitlab timed out after {self.timeout_s:.0f}s",
                dependency="forge:gitlab.com",
            )
        except httpx.HTTPError as exc:
            return Outcome.fail(
                ErrorCategory.TRANSIENT, f"transport error: {exc}", dependency="forge:gitlab.com"
            )
        finally:
            if owns:
                await client.aclose()
        return _map_response(response)

    # ── issues ───────────────────────────────────────────────────────────────────

    async def list_issues(
        self, *, labels: list[str] | None = None, state: str = "open"
    ) -> Outcome[list[Issue]]:
        params: dict[str, Any] = {"state": _to_gitlab_state(state), "per_page": 100}
        if labels:
            params["labels"] = ",".join(labels)
        return (await self._call("GET", "/issues", params=params)).map(
            lambda rows: [_to_issue(row) for row in rows]
        )

    async def get_issue(self, number: int) -> Outcome[Issue]:
        return (await self._call("GET", f"/issues/{number}")).map(_to_issue)

    async def create_issue(
        self, *, title: str, body: str, labels: list[str] | None = None
    ) -> Outcome[Issue]:
        return (
            await self._call(
                "POST",
                "/issues",
                json={
                    "title": title,
                    "description": body,
                    "labels": ",".join(labels or []),
                },
            )
        ).map(_to_issue)

    async def add_labels(self, number: int, labels: list[str]) -> Outcome[None]:
        existing = await self.get_issue(number)
        if existing.is_err:
            return Outcome.of(existing.error)  # type: ignore[arg-type]
        merged = sorted({*existing.unwrap().labels, *labels})
        return (
            await self._call("PUT", f"/issues/{number}", json={"labels": ",".join(merged)})
        ).map(lambda _: None)

    async def remove_label(self, number: int, label: str) -> Outcome[None]:
        existing = await self.get_issue(number)
        if existing.is_err:
            return Outcome.ok(None)  # already gone is not a failure
        remaining = [name for name in existing.unwrap().labels if name != label]
        return (
            await self._call("PUT", f"/issues/{number}", json={"labels": ",".join(remaining)})
        ).map(lambda _: None)

    async def comment(self, number: int, body: str, *, key: str | None = None) -> Outcome[Comment]:
        payload = body
        if key:
            marker = MARKER.format(key=key)
            payload = f"{body}\n\n{marker}"
            found = await self._find_note(number, marker)
            if found.is_err:
                return Outcome.of(found.error)  # type: ignore[arg-type]
            existing = found.unwrap()
            if existing is not None:
                return (
                    await self._call(
                        "PUT", f"/issues/{number}/notes/{existing.id}", json={"body": payload}
                    )
                ).map(_to_comment)
        return (await self._call("POST", f"/issues/{number}/notes", json={"body": payload})).map(
            _to_comment
        )

    async def _find_note(self, number: int, marker: str) -> Outcome[Comment | None]:
        outcome = await self._call("GET", f"/issues/{number}/notes", params={"per_page": 100})
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        for row in outcome.unwrap():
            if marker in (row.get("body") or ""):
                return Outcome.ok(_to_comment(row))
        return Outcome.ok(None)

    async def close_issue(self, number: int, *, reason: str = "") -> Outcome[None]:
        return (await self._call("PUT", f"/issues/{number}", json={"state_event": "close"})).map(
            lambda _: None
        )

    # ── merge requests ───────────────────────────────────────────────────────────

    async def find_mr_by_head(self, head_ref: str) -> Outcome[MergeRequest | None]:
        outcome = await self._call(
            "GET", "/merge_requests", params={"source_branch": head_ref, "state": "all"}
        )
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        rows = outcome.unwrap()
        return Outcome.ok(_to_mr(rows[0]) if rows else None)

    async def create_mr(
        self, *, head_ref: str, base_ref: str, title: str, body: str, issue: int | None = None
    ) -> Outcome[MergeRequest]:
        existing = await self.find_mr_by_head(head_ref)
        if existing.is_err:
            return Outcome.of(existing.error)  # type: ignore[arg-type]
        found = existing.unwrap()
        if found is not None:
            return Outcome.ok(found)
        return (
            await self._call(
                "POST",
                "/merge_requests",
                json={
                    "source_branch": head_ref,
                    "target_branch": base_ref,
                    "title": title,
                    "description": body,
                },
            )
        ).map(_to_mr)

    async def update_mr(
        self, number: int, *, body: str | None = None, title: str | None = None
    ) -> Outcome[MergeRequest]:
        payload = {k: v for k, v in {"description": body, "title": title}.items() if v is not None}
        return (await self._call("PUT", f"/merge_requests/{number}", json=payload)).map(_to_mr)

    async def merge_mr(self, number: int, *, strategy: str = "merge") -> Outcome[MergeRequest]:
        return (await self._call("PUT", f"/merge_requests/{number}/merge")).map(_to_mr)

    async def get_diff(self, number: int) -> Outcome[str]:
        outcome = await self._call("GET", f"/merge_requests/{number}/changes")
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        changes = outcome.unwrap().get("changes") or []
        return Outcome.ok(
            "\n".join(f"--- {c.get('new_path')}\n{c.get('diff', '')}" for c in changes)
        )

    async def is_merged(self, head_ref: str, *, base_ref: str) -> Outcome[bool]:
        """Asked of the refs, because a rebase-and-fast-forward leaves no merge commit."""
        outcome = await self._call(
            "GET", "/repository/compare", params={"from": base_ref, "to": head_ref}
        )
        if outcome.is_err:
            error = outcome.error
            if error is not None and error.details.get("status") == 404:
                return Outcome.ok(False)
            return Outcome.of(error)  # type: ignore[arg-type]
        # GitLab reports the commits `to` has that `from` does not. None ⇒ already contained.
        return Outcome.ok(not (outcome.unwrap().get("commits") or []))

    async def blocker_closed(self, reference: str) -> Outcome[bool]:
        return (await self.get_issue(int(reference.lstrip("#")))).map(lambda issue: issue.closed)


# ── mapping ──────────────────────────────────────────────────────────────────────


def _map_response(response: httpx.Response) -> Outcome[Any]:
    if response.status_code == 429:
        return Outcome.fail(
            ErrorCategory.RATE_LIMITED,
            "gitlab rate limit",
            retry_after_s=_retry_after(response),
            dependency="forge:gitlab.com",
        )
    if response.status_code in (401, 403):
        return Outcome.fail(
            ErrorCategory.AUTH,
            f"gitlab rejected the credential ({response.status_code})",
            remedy="refresh the token; retrying a 403 burns quota and never succeeds",
        )
    if response.status_code >= 500:
        return Outcome.fail(
            ErrorCategory.TRANSIENT,
            f"gitlab error {response.status_code}",
            dependency="forge:gitlab.com",
        )
    if response.status_code == 409:
        return Outcome.fail(ErrorCategory.REPO_CONFLICT, f"gitlab conflict: {response.text[:200]}")
    if response.status_code >= 400:
        return Outcome.of(
            ErrorRecord(
                category=ErrorCategory.TOOL_FAILURE,
                message=f"gitlab {response.status_code}: {response.text[:200]}",
                details={"status": response.status_code},
            )
        )
    if response.status_code == 204 or not response.content:
        return Outcome.ok({})
    try:
        return Outcome.ok(response.json())
    except ValueError:
        return Outcome.fail(ErrorCategory.TOOL_FAILURE, "gitlab response was not JSON")


def _retry_after(response: httpx.Response) -> float | None:
    value = response.headers.get("retry-after") or response.headers.get("ratelimit-reset")
    if value is None:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _to_gitlab_state(state: str) -> str:
    return {"open": "opened", "closed": "closed", "all": "all"}.get(state, state)


def _from_gitlab_state(state: str) -> str:
    return {"opened": "open", "closed": "closed", "merged": "merged"}.get(state, state)


def _parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _to_issue(row: dict[str, Any]) -> Issue:
    return Issue(
        number=int(row["iid"]),
        title=row.get("title") or "",
        body=row.get("description") or "",
        labels=list(row.get("labels") or []),
        state=_from_gitlab_state(row.get("state") or "opened"),
        created_at=_parse_time(row.get("created_at")),
        url=row.get("web_url") or "",
    )


def _to_mr(row: dict[str, Any]) -> MergeRequest:
    return MergeRequest(
        id=str(row.get("id") or row.get("iid")),
        number=int(row["iid"]),
        head_ref=row.get("source_branch") or "",
        base_ref=row.get("target_branch") or "",
        title=row.get("title") or "",
        state=_from_gitlab_state(row.get("state") or "opened"),
        labels=list(row.get("labels") or []),
        head_sha=row.get("sha") or "",
        merged=(row.get("state") == "merged"),
        url=row.get("web_url") or "",
    )


def _to_comment(row: dict[str, Any]) -> Comment:
    return Comment(
        id=str(row.get("id", "")),
        body=row.get("body") or "",
        author=(row.get("author") or {}).get("username", ""),
        created_at=_parse_time(row.get("created_at")),
    )
