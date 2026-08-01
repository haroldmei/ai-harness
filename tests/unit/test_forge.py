"""Issues #23 and #24 — the forge protocol, the GitHub mapping, and the fake that misbehaves."""

from __future__ import annotations

import httpx
import pytest

from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.providers.forge.fake import FakeForge, Faults
from ai_harness.providers.forge.github import GitHubForge, _map_response
from ai_harness.providers.forge.labels import (
    CLAIM_LABELS,
    MERGED,
    NEEDS_HUMAN,
    REVIEW_NEEDED,
    label_for,
    managed_labels,
)
from ai_harness.schemas.enums import Disposition, RunStatus, State


def _response(
    status: int, *, headers: dict[str, str] | None = None, json: object = None
) -> httpx.Response:
    return httpx.Response(status, headers=headers or {}, json=json)


# ── the GitHub transport mapping ─────────────────────────────────────────────────


def test_a_rate_limit_is_never_an_auth_failure() -> None:
    """GitHub's secondary limit arrives as a 403; reading it as AUTH would be terminal."""
    limited = _map_response(_response(403, headers={"x-ratelimit-remaining": "0"}))
    assert limited.category is ErrorCategory.RATE_LIMITED
    assert not limited.budget_consuming

    genuine = _map_response(_response(403, headers={"x-ratelimit-remaining": "42"}))
    assert genuine.category is ErrorCategory.AUTH


def test_retry_after_is_carried_through() -> None:
    limited = _map_response(_response(429, headers={"retry-after": "37"}))
    assert limited.error is not None and limited.error.retry_after_s == 37


def test_server_errors_are_transient_and_conflicts_re_route() -> None:
    assert _map_response(_response(502)).category is ErrorCategory.TRANSIENT
    assert _map_response(_response(409)).category is ErrorCategory.REPO_CONFLICT


def test_a_404_carries_its_status_so_callers_can_treat_it_as_absent() -> None:
    outcome = _map_response(_response(404))
    assert outcome.error is not None and outcome.error.details["status"] == 404


def test_an_empty_body_is_success_not_a_parse_error() -> None:
    assert _map_response(httpx.Response(204)).is_ok


async def test_a_missing_token_is_auth_and_never_dispatches() -> None:
    forge = GitHubForge(repo="acme/app", token="")
    result = await forge.get_issue(1)
    assert result.category is ErrorCategory.AUTH


async def test_the_github_adapter_speaks_rest_not_the_gh_binary() -> None:
    """A process per call hides rate limits until they bite."""
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"number": 7, "title": "t", "body": "b", "labels": []})

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        forge = GitHubForge(repo="acme/app", token="t", client=client)
        issue = (await forge.get_issue(7)).unwrap()
    assert issue.number == 7
    assert seen[0].headers["authorization"] == "Bearer t"
    assert str(seen[0].url).endswith("/repos/acme/app/issues/7")


async def test_merged_ness_is_asked_of_the_refs_not_a_state_string() -> None:
    """The shell's merger rebases and fast-forwards: the PR reads CLOSED with a null merge."""

    def handler(request: httpx.Request) -> httpx.Response:
        assert "/compare/" in str(request.url)
        return httpx.Response(200, json={"status": "behind"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        forge = GitHubForge(repo="acme/app", token="t", client=client)
        assert (await forge.is_merged("agent/issue-7", base_ref="main")).unwrap() is True


async def test_creating_an_mr_asks_before_it_acts() -> None:
    """The provider-side MR id is the idempotency token (§9.6)."""
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(f"{request.method} {request.url.path}")
        if request.method == "GET":
            return httpx.Response(
                200,
                json=[
                    {
                        "id": 5,
                        "number": 5,
                        "head": {"ref": "agent/issue-7", "sha": "abc"},
                        "base": {"ref": "main"},
                        "title": "t",
                    }
                ],
            )
        raise AssertionError("must not create when one already exists")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        forge = GitHubForge(repo="acme/app", token="t", client=client)
        mr = (
            await forge.create_mr(head_ref="agent/issue-7", base_ref="main", title="t", body="b")
        ).unwrap()
    assert mr.number == 5
    assert all(call.startswith("GET") for call in calls)


async def test_removing_an_absent_label_is_not_a_failure() -> None:
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(lambda _r: httpx.Response(404, json={}))
    ) as client:
        forge = GitHubForge(repo="acme/app", token="t", client=client)
        assert (await forge.remove_label(1, "wip")).is_ok


# ── labels as a projection ───────────────────────────────────────────────────────


def test_labels_project_the_run_position() -> None:
    assert label_for(State.REVIEW, RunStatus.RUNNING) == REVIEW_NEEDED
    assert label_for(State.COMPLETE, RunStatus.RUNNING, Disposition.MERGED) == MERGED
    assert label_for(State.IMPLEMENT, RunStatus.AWAITING_APPROVAL) == NEEDS_HUMAN


def test_every_state_projects_to_something() -> None:
    for state in State:
        assert label_for(state, RunStatus.RUNNING)


def test_claim_labels_are_a_subset_of_what_the_harness_manages() -> None:
    assert managed_labels() >= CLAIM_LABELS


# ── the fake, and the faults that justify the design ─────────────────────────────


async def test_a_label_write_may_not_be_visible_to_the_next_read() -> None:
    """Which is why a label is a projection and never the source of truth."""
    forge = FakeForge(faults=Faults(label_write_lag=2))
    forge.seed_issue(1)
    await forge.add_labels(1, ["wip"])
    immediately = (await forge.get_issue(1)).unwrap()
    assert "wip" not in immediately.labels

    for _ in range(3):
        await forge.get_issue(1)
    eventually = (await forge.get_issue(1)).unwrap()
    assert "wip" in eventually.labels


async def test_the_search_index_lags_behind_label_churn() -> None:
    forge = FakeForge(faults=Faults(index_lag_ops=2))
    forge.seed_issue(1, labels=["agent"])
    forge.seed_issue(2, labels=["agent"])
    listed = (await forge.list_issues(labels=["agent"])).unwrap()
    assert len(listed) <= 2, "a stale snapshot may under-report, never over-report"


async def test_a_lost_comment_response_still_applied_the_side_effect() -> None:
    """A naive retry double-posts; an idempotency key makes the retry an update."""
    forge = FakeForge(faults=Faults(drop_comment_response=True))
    forge.seed_issue(1)
    first = await forge.comment(1, "starting work", key="run-1-start")
    assert first.is_err and first.category is ErrorCategory.TRANSIENT
    assert len(forge.comments[1]) == 1, "the side effect happened"

    forge.faults.drop_comment_response = False
    retried = await forge.comment(1, "starting work", key="run-1-start")
    assert retried.is_ok
    assert len(forge.comments[1]) == 1, "the retry updated rather than duplicated"


async def test_an_unkeyed_comment_does_duplicate_which_is_why_keys_exist() -> None:
    forge = FakeForge()
    forge.seed_issue(1)
    await forge.comment(1, "hello")
    await forge.comment(1, "hello")
    assert len(forge.comments[1]) == 2


async def test_a_dropped_merge_response_does_not_double_merge() -> None:
    """The case that makes "ask the forge before acting" the only safe protocol."""
    forge = FakeForge(faults=Faults(drop_merge_response=True))
    mr = (
        await forge.create_mr(head_ref="agent/issue-7", base_ref="main", title="t", body="b")
    ).unwrap()
    first = await forge.merge_mr(mr.number)
    assert first.is_err, "the caller believes it failed"
    assert (await forge.is_merged("agent/issue-7", base_ref="main")).unwrap() is True

    forge.faults.drop_merge_response = False
    second = await forge.merge_mr(mr.number)
    assert second.is_ok and second.unwrap().merged
    assert len([m for m in forge.mrs.values() if m.merged]) == 1


async def test_rate_limits_are_injectable_and_non_consuming() -> None:
    forge = FakeForge(faults=Faults(rate_limit_every=2))
    forge.seed_issue(1)
    await forge.get_issue(1)
    limited = await forge.get_issue(1)
    assert limited.category is ErrorCategory.RATE_LIMITED
    assert not limited.budget_consuming


async def test_write_blocking_proves_a_shadow_run_has_no_side_effects() -> None:
    """Phase 2 requires the Python path to be provably side-effect-free while shadowing."""
    forge = FakeForge()
    forge.seed_issue(1)
    forge.writes_blocked = True
    for attempt in (
        forge.add_labels(1, ["wip"]),
        forge.comment(1, "verdict"),
        forge.create_mr(head_ref="h", base_ref="main", title="t", body="b"),
        forge.merge_mr(1),
    ):
        result = await attempt
        assert result.is_err and result.category is ErrorCategory.POLICY
    assert (await forge.get_issue(1)).is_ok, "reads stay allowed"


async def test_the_fake_and_the_protocol_agree() -> None:
    """Both adapters are checked against the same protocol, so neither can drift alone."""
    from ai_harness.providers.forge.protocol import Forge

    assert isinstance(FakeForge(), Forge)
    assert isinstance(GitHubForge(repo="acme/app", token="t"), Forge)


@pytest.mark.parametrize("seed", [1, 2, 3])
async def test_faults_are_deterministic_under_a_seed(seed: int) -> None:
    outcomes = []
    for _ in range(2):
        forge = FakeForge(faults=Faults(rate_limit_every=3, seed=seed))
        forge.seed_issue(1)
        outcomes.append([bool((await forge.get_issue(1)).is_ok) for _ in range(6)])
    assert outcomes[0] == outcomes[1]
