"""Issue #25 — the git client, against real git in tmp.

Real git, never a mock: every behaviour that matters here is a property of git itself, and a
fake would agree with whatever the code happened to do.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.providers.git.cli import GitCLI

ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "harness",
    "GIT_AUTHOR_EMAIL": "harness@example.invalid",
    "GIT_COMMITTER_NAME": "harness",
    "GIT_COMMITTER_EMAIL": "harness@example.invalid",
}


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True, env=ENV
    ).stdout.strip()


@pytest.fixture
def clone(tmp_path: Path, bare_origin: Path) -> Path:
    work = tmp_path / "work"
    subprocess.run(
        ["git", "clone", "-q", str(bare_origin), str(work)], check=True, capture_output=True
    )
    _git(work, "config", "user.email", "harness@example.invalid")
    _git(work, "config", "user.name", "harness")
    return work


@pytest.fixture
def git(clone: Path) -> GitCLI:
    return GitCLI(root=clone)


# ── queries ──────────────────────────────────────────────────────────────────────


async def test_rev_parse_and_fetch(git: GitCLI) -> None:
    head = await git.rev_parse("HEAD")
    assert head.is_ok and len(head.unwrap()) == 40
    assert (await git.fetch()).is_ok


async def test_an_unknown_ref_is_an_outcome_not_an_exception(git: GitCLI) -> None:
    result = await git.rev_parse("refs/heads/nope")
    assert result.is_err
    assert result.category is ErrorCategory.TOOL_FAILURE


async def test_ancestry_and_merge_base(git: GitCLI, clone: Path) -> None:
    base = await git.rev_parse("HEAD")
    (clone / "a.txt").write_text("a\n")
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "a")
    head = await git.rev_parse("HEAD")
    assert (await git.is_ancestor(base.unwrap(), head.unwrap())).unwrap() is True
    assert (await git.is_ancestor(head.unwrap(), base.unwrap())).unwrap() is False
    assert (await git.merge_base(base.unwrap(), head.unwrap())).unwrap() == base.unwrap()


async def test_dirty_detection_and_diffstat(git: GitCLI, clone: Path) -> None:
    assert (await git.status_is_dirty()).unwrap() is False
    (clone / "a.txt").write_text("one\ntwo\n")
    assert (await git.status_is_dirty()).unwrap() is True
    base = await git.rev_parse("HEAD")
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "a")
    stat = (await git.diff_stat(base.unwrap())).unwrap()
    assert stat.files_changed == 1 and stat.insertions == 2 and stat.paths == ["a.txt"]


async def test_conflict_markers_are_found_in_the_tree(git: GitCLI, clone: Path) -> None:
    """Invariant 18: the tree is the evidence, never the resolver's verdict string."""
    assert (await git.has_conflict_markers()).unwrap() == []
    (clone / "conflicted.py").write_text("x = 1\n<<<<<<< HEAD\ny = 2\n=======\ny = 3\n>>>>>>> b\n")
    _git(clone, "add", "-A")
    assert (await git.has_conflict_markers()).unwrap() == ["conflicted.py"]


# ── worktrees ────────────────────────────────────────────────────────────────────


async def test_a_branch_backed_worktree_persists_its_ref(git: GitCLI, tmp_path: Path) -> None:
    """The builder's case: the branch must survive cleanup so the MR can point at it."""
    info = await git.add_worktree(tmp_path / "wt", "HEAD", branch="agent/issue-7")
    assert info.is_ok and info.unwrap().branch == "agent/issue-7"
    assert (await git.remove_worktree(tmp_path / "wt")).is_ok
    assert (await git.rev_parse("agent/issue-7")).is_ok, "the ref must outlive the worktree"


async def test_a_detached_worktree_never_touches_the_ref(
    git: GitCLI, tmp_path: Path, clone: Path
) -> None:
    """`-B` fails with "Cannot force update the current branch" when it is checked out."""
    checked_out = _git(clone, "rev-parse", "--abbrev-ref", "HEAD")
    failed = await git.add_worktree(tmp_path / "wt1", "HEAD", branch=checked_out)
    assert failed.is_err, "reproducing the shell's -B failure mode"

    detached = await git.add_worktree(tmp_path / "wt2", "HEAD", detach=True)
    assert detached.is_ok and detached.unwrap().detached


async def test_worktrees_are_listed_with_their_heads(git: GitCLI, tmp_path: Path) -> None:
    await git.add_worktree(tmp_path / "wt", "HEAD", branch="agent/issue-8")
    listed = (await git.list_worktrees()).unwrap()
    paths = {w.path.name for w in listed}
    assert "wt" in paths
    assert any(w.branch == "agent/issue-8" for w in listed)


async def test_removing_a_worktree_twice_is_not_an_error(git: GitCLI, tmp_path: Path) -> None:
    await git.add_worktree(tmp_path / "wt", "HEAD", branch="b")
    assert (await git.remove_worktree(tmp_path / "wt")).is_ok
    assert (await git.remove_worktree(tmp_path / "wt")).is_ok, "cleanup must be idempotent"


# ── writes ───────────────────────────────────────────────────────────────────────


async def test_commit_all_returns_none_when_there_is_nothing_to_commit(git: GitCLI) -> None:
    """A clean tree is a signal the harness reads as "the model declined to change anything"."""
    assert (await git.commit_all("nothing")).unwrap() is None


async def test_commit_all_stages_everything_including_new_files(git: GitCLI, clone: Path) -> None:
    (clone / "new.py").write_text("print('hi')\n")
    sha = (await git.commit_all("add new")).unwrap()
    assert sha is not None and len(sha) == 40
    assert (await git.status_is_dirty()).unwrap() is False


async def test_tagging_survives_worktree_removal(git: GitCLI, tmp_path: Path, clone: Path) -> None:
    """Invariant 14: tag before gating, so cleanup cannot orphan the commit (#1764/#2152/#2196)."""
    info = (await git.add_worktree(tmp_path / "wt", "HEAD", detach=True)).unwrap()
    (info.path / "fix.py").write_text("fixed = True\n")
    sha = (await git.commit_all("the fix", cwd=info.path)).unwrap()
    assert sha is not None
    assert (await git.tag("harness/run1/IMPLEMENT", cwd=info.path)).is_ok

    await git.remove_worktree(info.path)
    assert (await git.rev_parse("harness/run1/IMPLEMENT")).unwrap() == sha, (
        "the commit is reachable"
    )
    assert (await git.delete_tag("harness/run1/IMPLEMENT")).is_ok


# ── rebase ───────────────────────────────────────────────────────────────────────


async def _diverge(
    git: GitCLI, clone: Path, *, path: str, base_text: str, branch_text: str
) -> None:
    base_branch = _git(clone, "rev-parse", "--abbrev-ref", "HEAD")
    _git(clone, "checkout", "-q", "-b", "feature")
    (clone / path).write_text(branch_text)
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "branch change")
    _git(clone, "checkout", "-q", base_branch)
    (clone / path).write_text(base_text)
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "base change")
    _git(clone, "checkout", "-q", "feature")


async def test_a_clean_rebase_reports_rebased(git: GitCLI, clone: Path) -> None:
    base_branch = _git(clone, "rev-parse", "--abbrev-ref", "HEAD")
    _git(clone, "checkout", "-q", "-b", "feature")
    (clone / "feature.py").write_text("f = 1\n")
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "feature")
    _git(clone, "checkout", "-q", base_branch)
    (clone / "unrelated.py").write_text("u = 1\n")
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "base")
    _git(clone, "checkout", "-q", "feature")

    result = (await git.rebase_onto(base_branch, generated_paths=[])).unwrap()
    assert result.rebased and not result.conflicted_paths


async def test_a_generated_file_conflict_resolves_by_taking_the_base(
    git: GitCLI, clone: Path
) -> None:
    """Take base + regenerate. Three shell sites do this with drifted path lists; here, one."""
    await _diverge(
        git,
        clone,
        path="openapi.json",
        base_text='{"v": "base"}\n',
        branch_text='{"v": "branch"}\n',
    )
    base_branch = "main"
    result = (await git.rebase_onto(base_branch, generated_paths=["openapi.json"])).unwrap()
    assert result.rebased and result.generated_only
    assert result.conflicted_paths == ["openapi.json"]
    assert (clone / "openapi.json").read_text() == '{"v": "base"}\n'


async def test_a_product_conflict_is_left_for_the_resolver(git: GitCLI, clone: Path) -> None:
    await _diverge(
        git, clone, path="app.py", base_text="x = 'base'\n", branch_text="x = 'branch'\n"
    )
    result = (await git.rebase_onto("main", generated_paths=["openapi.json"])).unwrap()
    assert not result.rebased and result.needs_resolver
    assert result.conflicted_paths == ["app.py"]
    assert (await git.status_is_dirty()).unwrap() is False, (
        "a failed rebase must be aborted cleanly"
    )


# ── push ─────────────────────────────────────────────────────────────────────────


async def test_push_advances_the_remote(git: GitCLI, clone: Path, bare_origin: Path) -> None:
    (clone / "pushed.py").write_text("p = 1\n")
    await git.commit_all("push me")
    assert (await git.push("HEAD:main")).is_ok
    assert _git(bare_origin, "rev-parse", "main") == (await git.rev_parse("HEAD")).unwrap()


async def test_a_compare_and_swap_push_refuses_when_the_remote_moved(
    git: GitCLI, clone: Path, bare_origin: Path, tmp_path: Path
) -> None:
    """Fast-forward only: if main moved, bail and re-gate — never force."""
    stale = (await git.rev_parse("HEAD")).unwrap()

    other = tmp_path / "other"
    subprocess.run(
        ["git", "clone", "-q", str(bare_origin), str(other)], check=True, capture_output=True
    )
    _git(other, "config", "user.email", "other@example.invalid")
    _git(other, "config", "user.name", "other")
    (other / "theirs.py").write_text("t = 1\n")
    _git(other, "add", "-A")
    _git(other, "commit", "-m", "theirs")
    _git(other, "push", "-q", "origin", "main")

    (clone / "ours.py").write_text("o = 1\n")
    await git.commit_all("ours")
    result = await git.push("HEAD:main", expect_remote_sha=stale)
    assert result.is_err and result.category is ErrorCategory.REPO_CONFLICT
    assert result.error is not None and "moved" in result.error.message
    assert _git(bare_origin, "rev-parse", "main") != (await git.rev_parse("HEAD")).unwrap()


async def test_a_non_fast_forward_push_is_a_repo_conflict_not_a_crash(
    git: GitCLI, clone: Path, bare_origin: Path, tmp_path: Path
) -> None:
    other = tmp_path / "other"
    subprocess.run(
        ["git", "clone", "-q", str(bare_origin), str(other)], check=True, capture_output=True
    )
    _git(other, "config", "user.email", "o@example.invalid")
    _git(other, "config", "user.name", "o")
    (other / "theirs.py").write_text("t = 1\n")
    _git(other, "add", "-A")
    _git(other, "commit", "-m", "theirs")
    _git(other, "push", "-q", "origin", "main")

    (clone / "ours.py").write_text("o = 1\n")
    await git.commit_all("ours")
    result = await git.push("HEAD:main")
    assert result.is_err and result.category is ErrorCategory.REPO_CONFLICT


def test_force_push_is_a_separate_method_not_a_flag() -> None:
    """Policy gates GIT_FORCE_PUSH; a boolean parameter would let a caller reach it by accident."""
    import inspect

    assert "force" not in inspect.signature(GitCLI.push).parameters
    assert hasattr(GitCLI, "force_push_with_lease")
