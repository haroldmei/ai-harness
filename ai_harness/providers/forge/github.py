"""GitHub over the REST API.

Deliberately **not** the ``gh`` binary. The shell shells out to ``gh`` roughly a hundred times,
which costs a process per call, makes rate limits invisible until they bite, and forces every
answer through ``--jq``. Speaking to the API directly means a 429 arrives as a 429, with its
``Retry-After``, and lands in the taxonomy as :attr:`ErrorCategory.RATE_LIMITED` — never
consuming a budget.

Comments are idempotent by construction: an optional ``key`` is embedded as an HTML marker and
searched for before posting. The shell's markers (``<!-- pr-loop-round: N -->``) are the same
idea, written by one stage and read by two others with no schema; here one method owns both
halves.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

import httpx

from ai_harness.kernel.outcome import ErrorCategory, ErrorRecord, Outcome
from ai_harness.providers.forge.protocol import Comment, Issue, MergeRequest

API = "https://api.github.com"
MARKER = "<!-- harness-key: {key} -->"


@dataclass
class GitHubForge:
    """One repository, one token."""

    repo: str
    token: str = field(default_factory=lambda: os.environ.get("GITHUB_TOKEN", ""))
    base_url: str = API
    client: httpx.AsyncClient | None = None
    name: str = "github"
    timeout_s: float = 30.0

    # ── transport ────────────────────────────────────────────────────────────────

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
                "GITHUB_TOKEN is not set",
                remedy="configure a token; this is never retried",
            )
        client = self.client or httpx.AsyncClient(timeout=self.timeout_s)
        owns = self.client is None
        url = path if path.startswith("http") else f"{self.base_url}{path}"
        try:
            response = await client.request(
                method,
                url,
                json=json,
                params=params,
                headers={
                    "Authorization": f"Bearer {self.token}",
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                },
            )
        except httpx.TimeoutException:
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"github timed out after {self.timeout_s:.0f}s",
                dependency="forge:github.com",
            )
        except httpx.HTTPError as exc:
            return Outcome.fail(
                ErrorCategory.TRANSIENT, f"transport error: {exc}", dependency="forge:github.com"
            )
        finally:
            if owns:
                await client.aclose()
        return _map_response(response)

    # ── issues ───────────────────────────────────────────────────────────────────

    async def list_issues(
        self, *, labels: list[str] | None = None, state: str = "open"
    ) -> Outcome[list[Issue]]:
        params: dict[str, Any] = {"state": state, "per_page": 100}
        if labels:
            params["labels"] = ",".join(labels)
        outcome = await self._call("GET", f"/repos/{self.repo}/issues", params=params)
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        return Outcome.ok([_to_issue(row) for row in outcome.unwrap() if "pull_request" not in row])

    async def get_issue(self, number: int) -> Outcome[Issue]:
        return (await self._call("GET", f"/repos/{self.repo}/issues/{number}")).map(_to_issue)

    async def add_labels(self, number: int, labels: list[str]) -> Outcome[None]:
        outcome = await self._call(
            "POST", f"/repos/{self.repo}/issues/{number}/labels", json={"labels": labels}
        )
        return outcome.map(lambda _: None)

    async def remove_label(self, number: int, label: str) -> Outcome[None]:
        outcome = await self._call("DELETE", f"/repos/{self.repo}/issues/{number}/labels/{label}")
        if (
            outcome.is_err
            and outcome.error is not None
            and outcome.error.details.get("status") == 404
        ):
            return Outcome.ok(None)  # already absent — removing twice is not a failure
        return outcome.map(lambda _: None)

    async def comment(self, number: int, body: str, *, key: str | None = None) -> Outcome[Comment]:
        """Post once. With a ``key``, a retry after a lost response updates rather than duplicates."""
        payload = body
        if key:
            marker = MARKER.format(key=key)
            payload = f"{body}\n\n{marker}"
            existing = await self._find_comment(number, marker)
            if existing.is_err:
                return Outcome.of(existing.error)  # type: ignore[arg-type]
            found = existing.unwrap()
            if found is not None:
                updated = await self._call(
                    "PATCH",
                    f"/repos/{self.repo}/issues/comments/{found.id}",
                    json={"body": payload},
                )
                return updated.map(_to_comment)
        created = await self._call(
            "POST", f"/repos/{self.repo}/issues/{number}/comments", json={"body": payload}
        )
        return created.map(_to_comment)

    async def _find_comment(self, number: int, marker: str) -> Outcome[Comment | None]:
        outcome = await self._call(
            "GET", f"/repos/{self.repo}/issues/{number}/comments", params={"per_page": 100}
        )
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        for row in outcome.unwrap():
            if marker in (row.get("body") or ""):
                return Outcome.ok(_to_comment(row))
        return Outcome.ok(None)

    async def close_issue(self, number: int, *, reason: str = "") -> Outcome[None]:
        payload: dict[str, Any] = {"state": "closed"}
        if reason:
            payload["state_reason"] = reason
        return (await self._call("PATCH", f"/repos/{self.repo}/issues/{number}", json=payload)).map(
            lambda _: None
        )

    # ── merge requests ───────────────────────────────────────────────────────────

    async def find_mr_by_head(self, head_ref: str) -> Outcome[MergeRequest | None]:
        owner = self.repo.split("/")[0]
        outcome = await self._call(
            "GET",
            f"/repos/{self.repo}/pulls",
            params={"head": f"{owner}:{head_ref}", "state": "all", "per_page": 10},
        )
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        rows = outcome.unwrap()
        return Outcome.ok(_to_mr(rows[0]) if rows else None)

    async def create_mr(
        self, *, head_ref: str, base_ref: str, title: str, body: str, issue: int | None = None
    ) -> Outcome[MergeRequest]:
        """Create, or return the existing MR for this head — the idempotency token is theirs."""
        existing = await self.find_mr_by_head(head_ref)
        if existing.is_err:
            return Outcome.of(existing.error)  # type: ignore[arg-type]
        found = existing.unwrap()
        if found is not None:
            return Outcome.ok(found)
        return (
            await self._call(
                "POST",
                f"/repos/{self.repo}/pulls",
                json={"head": head_ref, "base": base_ref, "title": title, "body": body},
            )
        ).map(_to_mr)

    async def update_mr(
        self, number: int, *, body: str | None = None, title: str | None = None
    ) -> Outcome[MergeRequest]:
        payload = {k: v for k, v in {"body": body, "title": title}.items() if v is not None}
        return (await self._call("PATCH", f"/repos/{self.repo}/pulls/{number}", json=payload)).map(
            _to_mr
        )

    async def merge_mr(self, number: int, *, strategy: str = "merge") -> Outcome[MergeRequest]:
        outcome = await self._call(
            "PUT", f"/repos/{self.repo}/pulls/{number}/merge", json={"merge_method": strategy}
        )
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        return (await self._call("GET", f"/repos/{self.repo}/pulls/{number}")).map(_to_mr)

    async def get_diff(self, number: int) -> Outcome[str]:
        outcome = await self._call("GET", f"/repos/{self.repo}/pulls/{number}/files")
        if outcome.is_err:
            return Outcome.of(outcome.error)  # type: ignore[arg-type]
        chunks = [f"--- {row.get('filename')}\n{row.get('patch', '')}" for row in outcome.unwrap()]
        return Outcome.ok("\n".join(chunks))

    async def is_merged(self, head_ref: str, *, base_ref: str) -> Outcome[bool]:
        """Reachability, not a state string.

        The shell merger rebases and fast-forwards, so the PR shows ``CLOSED`` with a null merge
        commit and no ``Closes #N`` keyword ever fires. Comparing refs is the only answer that
        survives that.
        """
        outcome = await self._call("GET", f"/repos/{self.repo}/compare/{base_ref}...{head_ref}")
        if outcome.is_err:
            error = outcome.error
            if error is not None and error.details.get("status") == 404:
                return Outcome.ok(False)
            return Outcome.of(error)  # type: ignore[arg-type]
        status = outcome.unwrap().get("status")
        return Outcome.ok(status in ("identical", "behind"))

    async def blocker_closed(self, reference: str) -> Outcome[bool]:
        number = int(reference.lstrip("#"))
        return (await self.get_issue(number)).map(lambda issue: issue.closed)


# ── mapping ──────────────────────────────────────────────────────────────────────


def _map_response(response: httpx.Response) -> Outcome[Any]:
    if response.status_code == 429 or (
        response.status_code == 403 and response.headers.get("x-ratelimit-remaining") == "0"
    ):
        # A secondary rate limit arrives as a 403 with the remaining count at zero. Reading it
        # as AUTH would be terminal — and it is the single most common transient there is.
        return Outcome.fail(
            ErrorCategory.RATE_LIMITED,
            "github rate limit",
            retry_after_s=_retry_after(response),
            dependency="forge:github.com",
        )
    if response.status_code in (401, 403):
        return Outcome.fail(
            ErrorCategory.AUTH,
            f"github rejected the credential ({response.status_code})",
            remedy="refresh the token; retrying a 403 burns quota and never succeeds",
        )
    if response.status_code >= 500:
        return Outcome.fail(
            ErrorCategory.TRANSIENT,
            f"github error {response.status_code}",
            dependency="forge:github.com",
        )
    if response.status_code == 409:
        return Outcome.fail(
            ErrorCategory.REPO_CONFLICT,
            f"github conflict: {response.text[:200]}",
        )
    if response.status_code >= 400:
        return Outcome.of(
            ErrorRecord(
                category=ErrorCategory.TOOL_FAILURE,
                message=f"github {response.status_code}: {response.text[:200]}",
                details={"status": response.status_code},
            )
        )
    if response.status_code == 204 or not response.content:
        return Outcome.ok({})
    try:
        return Outcome.ok(response.json())
    except ValueError:
        return Outcome.fail(ErrorCategory.TOOL_FAILURE, "github response was not JSON")


def _retry_after(response: httpx.Response) -> float | None:
    for header in ("retry-after", "x-ratelimit-reset"):
        value = response.headers.get(header)
        if not value:
            continue
        try:
            number = float(value)
        except ValueError:
            continue
        return number if header == "retry-after" else max(number - _now_epoch(), 0.0)
    return None


def _now_epoch() -> float:
    from time import time

    return time()


def _parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _to_issue(row: dict[str, Any]) -> Issue:
    return Issue(
        number=int(row["number"]),
        title=row.get("title") or "",
        body=row.get("body") or "",
        labels=[label["name"] for label in row.get("labels", []) if isinstance(label, dict)],
        state=row.get("state") or "open",
        created_at=_parse_time(row.get("created_at")),
        url=row.get("html_url") or "",
    )


def _to_mr(row: dict[str, Any]) -> MergeRequest:
    head = row.get("head") or {}
    base = row.get("base") or {}
    return MergeRequest(
        id=str(row.get("id") or row.get("number")),
        number=int(row["number"]),
        head_ref=head.get("ref") or "",
        base_ref=base.get("ref") or "",
        title=row.get("title") or "",
        state=row.get("state") or "open",
        labels=[label["name"] for label in row.get("labels", []) if isinstance(label, dict)],
        head_sha=head.get("sha") or "",
        merged=bool(row.get("merged") or row.get("merged_at")),
        url=row.get("html_url") or "",
    )


def _to_comment(row: dict[str, Any]) -> Comment:
    return Comment(
        id=str(row.get("id", "")),
        body=row.get("body") or "",
        author=(row.get("user") or {}).get("login", ""),
        created_at=_parse_time(row.get("created_at")),
    )
