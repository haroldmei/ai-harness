"""Issues #26, #27, #28 — worktrees, the resume policy, deps verification and teardown."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from ai_harness.kernel.clock import FrozenClock
from ai_harness.kernel.lease import FlockLeaseBackend, LeaseManager
from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.providers.git.cli import GitCLI
from ai_harness.schemas.enums import Disposition
from ai_harness.schemas.policy import FailurePolicy
from ai_harness.workspace.cleanup import PRESERVED_MARKER, Teardown, WorktreeSweeper
from ai_harness.workspace.deps import (
    DepsProvisioner,
    Ecosystem,
    remedy_for,
    undeclared_imports,
)
from ai_harness.workspace.generated import ConflictPolicy
from ai_harness.workspace.session import WorktreeSession
from ai_harness.workspace.worktree import Strategy, WorktreeManager

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
def manager(clone: Path, tmp_path: Path) -> WorktreeManager:
    clock = FrozenClock()
    return WorktreeManager(
        git=GitCLI(root=clone),
        leases=LeaseManager(FlockLeaseBackend(tmp_path / "locks", clock=clock), clock=clock),
        repo_key="testrepo",
        conflicts=ConflictPolicy(generated_paths=["openapi.json", "docs/generated/*"]),
    )


def _publish_branch(clone: Path, branch: str, *, path: str, text: str) -> str:
    """Push a branch to origin, as an interrupted earlier attempt would have left behind."""
    base = _git(clone, "rev-parse", "--abbrev-ref", "HEAD")
    _git(clone, "checkout", "-q", "-b", branch)
    (clone / path).write_text(text)
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", f"work on {branch}")
    sha = _git(clone, "rev-parse", "HEAD")
    _git(clone, "push", "-q", "origin", branch)
    _git(clone, "checkout", "-q", base)
    _git(clone, "branch", "-q", "-D", branch)
    return sha


# ── materialisation and resume ───────────────────────────────────────────────────


async def test_a_fresh_workspace_starts_from_the_base(
    manager: WorktreeManager, tmp_path: Path
) -> None:
    result = await manager.materialise(path=tmp_path / "wt", branch="agent/issue-1")
    assert result.is_ok
    workspace = result.unwrap()
    assert workspace.strategy is Strategy.FRESH and not workspace.resumed
    assert (workspace.path / "README.md").exists()


async def test_an_interrupted_attempt_is_resumed_not_discarded(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    """A killed build's work survives because the branch was pushed before gating."""
    _publish_branch(clone, "agent/issue-2", path="wip.py", text="half = 'done'\n")
    result = await manager.materialise(path=tmp_path / "wt", branch="agent/issue-2")
    assert result.is_ok
    workspace = result.unwrap()
    assert workspace.resumed
    assert (workspace.path / "wip.py").read_text() == "half = 'done'\n"


async def test_a_branch_already_merged_into_the_base_is_not_resumed(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    """Guard 1: resuming a merged branch rebuilds work that has already landed."""
    _publish_branch(clone, "agent/issue-3", path="landed.py", text="landed = True\n")
    _git(clone, "merge", "-q", "--no-edit", "origin/agent/issue-3")
    _git(clone, "push", "-q", "origin", "main")

    result = await manager.materialise(path=tmp_path / "wt", branch="agent/issue-3")
    assert result.unwrap().strategy is Strategy.FRESH


async def test_a_stale_branch_is_rebased_onto_the_live_base(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    """Guard 2 — the converse check the shell was missing (#2138)."""
    _publish_branch(clone, "agent/issue-4", path="branch.py", text="b = 1\n")
    (clone / "moved.py").write_text("m = 1\n")
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "base moved")
    _git(clone, "push", "-q", "origin", "main")

    result = await manager.materialise(path=tmp_path / "wt", branch="agent/issue-4")
    workspace = result.unwrap()
    assert workspace.strategy is Strategy.RESUMED_REBASED
    assert (workspace.path / "branch.py").exists(), "the branch's work survives the rebase"
    assert (workspace.path / "moved.py").exists(), "and it now sits on the live base"


async def test_a_generated_file_conflict_does_not_discard_the_branch(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    _publish_branch(clone, "agent/issue-5", path="openapi.json", text='{"v": "branch"}\n')
    (clone / "openapi.json").write_text('{"v": "base"}\n')
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "regenerate on base")
    _git(clone, "push", "-q", "origin", "main")

    workspace = (await manager.materialise(path=tmp_path / "wt", branch="agent/issue-5")).unwrap()
    assert workspace.strategy is Strategy.RESUMED_REBASED
    assert (workspace.path / "openapi.json").read_text() == '{"v": "base"}\n'


async def test_a_product_conflict_discards_and_starts_clean(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    """Handing a half-rebased tree to a model is worse than starting over."""
    _publish_branch(clone, "agent/issue-6", path="app.py", text="x = 'branch'\n")
    (clone / "app.py").write_text("x = 'base'\n")
    _git(clone, "add", "-A")
    _git(clone, "commit", "-m", "base changed the same file")
    _git(clone, "push", "-q", "origin", "main")

    workspace = (await manager.materialise(path=tmp_path / "wt", branch="agent/issue-6")).unwrap()
    assert workspace.strategy is Strategy.DISCARDED_AND_FRESH
    assert (workspace.path / "app.py").read_text() == "x = 'base'\n"


async def test_resume_can_be_switched_off(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    """Guard 3: the operator's escape hatch (AGENT_RESUME=0 in the shell)."""
    _publish_branch(clone, "agent/issue-7", path="wip.py", text="w = 1\n")
    manager.allow_resume = False
    workspace = (await manager.materialise(path=tmp_path / "wt", branch="agent/issue-7")).unwrap()
    assert workspace.strategy is Strategy.FRESH


async def test_worktree_creation_is_serialised_repo_wide(
    manager: WorktreeManager, tmp_path: Path
) -> None:
    """Parallel `git worktree add` races on the shared .git/worktrees admin area."""
    backend = manager.leases
    async with backend.hold("worktree:testrepo", ttl_s=60, holder="other-worker") as held:
        assert held is not None
        blocked = await manager.materialise(path=tmp_path / "wt", branch="agent/issue-8")
    assert blocked.is_err and blocked.category is ErrorCategory.TRANSIENT


async def test_a_detached_worktree_is_available_for_the_fixer_shape(
    manager: WorktreeManager, tmp_path: Path
) -> None:
    result = await manager.detached_at(path=tmp_path / "wt", ref="origin/main")
    assert result.is_ok and result.unwrap().detached


# ── teardown ─────────────────────────────────────────────────────────────────────


async def test_escalation_preserves_the_worktree_with_a_marker(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    workspace = (await manager.materialise(path=tmp_path / "wt", branch="agent/issue-9")).unwrap()
    (workspace.path / "fix.py").write_text("fixed = True\n")
    git = GitCLI(root=clone)
    await git.commit_all("the fix", cwd=workspace.path)

    report = (
        await Teardown(git=git, policy=FailurePolicy(), clock=FrozenClock()).finish(
            run_id="r1",
            state="IMPLEMENT",
            workspace=workspace.path,
            branch="agent/issue-9",
            disposition=Disposition.ESCALATED,
        )
    ).unwrap()

    assert report.preserved and not report.removed
    assert (workspace.path / PRESERVED_MARKER).exists()
    assert report.tagged == "harness/r1/IMPLEMENT"


async def test_work_is_tagged_before_anything_can_remove_it(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    """Invariant 14 — #1764, #2152, #2196: finished fixes lost to an unconditional cleanup."""
    workspace = (await manager.materialise(path=tmp_path / "wt", branch="agent/issue-10")).unwrap()
    (workspace.path / "fix.py").write_text("fixed = True\n")
    git = GitCLI(root=clone)
    sha = (await git.commit_all("the fix", cwd=workspace.path)).unwrap()

    await Teardown(git=git, policy=FailurePolicy(), clock=FrozenClock()).finish(
        run_id="r2",
        state="IMPLEMENT",
        workspace=workspace.path,
        branch="agent/issue-10",
        disposition=Disposition.MERGED,
        may_push=False,
    )
    assert (await git.rev_parse("harness/r2/IMPLEMENT")).unwrap() == sha


async def test_artefacts_are_flushed_before_cleanup(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    workspace = (await manager.materialise(path=tmp_path / "wt", branch="agent/issue-11")).unwrap()
    order: list[str] = []

    async def flush() -> list[str]:
        order.append("flush")
        return ["gate-log:abc123"]

    report = (
        await Teardown(git=GitCLI(root=clone), policy=FailurePolicy(), clock=FrozenClock()).finish(
            run_id="r3",
            state="VALIDATE",
            workspace=workspace.path,
            branch="agent/issue-11",
            disposition=Disposition.MERGED,
            may_push=False,
            flush_artefacts=flush,
        )
    ).unwrap()
    assert order == ["flush"] and report.artefacts == ["gate-log:abc123"]


async def test_the_sweeper_removes_only_expired_worktrees(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    """Q10: 72h — long enough for a working day plus a weekend."""
    clock = FrozenClock()
    root = tmp_path / "preserved"
    root.mkdir()
    fresh = root / "run-fresh"
    stale = root / "run-stale"
    for path in (fresh, stale):
        path.mkdir()
    (stale / PRESERVED_MARKER).write_text(f"preserved_at: {clock.now().isoformat()}\n")
    clock.advance(73 * 3600)
    (fresh / PRESERVED_MARKER).write_text(f"preserved_at: {clock.now().isoformat()}\n")

    removed = await WorktreeSweeper(root=root, git=GitCLI(root=clone), clock=clock).sweep()
    assert removed == [stale]
    assert fresh.exists() and not stale.exists()


async def test_the_session_preserves_when_a_caller_raises(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    """Defaulting the other way would delete evidence exactly when something went wrong."""
    session = WorktreeSession(manager=manager, git=GitCLI(root=clone), clock=FrozenClock())
    with pytest.raises(RuntimeError):
        async with session.open(
            run_id="r4", state="IMPLEMENT", path=tmp_path / "wt", branch="agent/issue-12"
        ) as (created, _result):
            assert created.is_ok
            raise RuntimeError("the state blew up")
    assert (tmp_path / "wt" / PRESERVED_MARKER).exists()


async def test_the_session_cleans_up_on_success(
    manager: WorktreeManager, clone: Path, tmp_path: Path
) -> None:
    session = WorktreeSession(manager=manager, git=GitCLI(root=clone), clock=FrozenClock())
    async with session.open(
        run_id="r5", state="INTEGRATE", path=tmp_path / "wt", branch="agent/issue-13"
    ) as (created, result):
        assert created.is_ok
        result.disposition = Disposition.MERGED
        result.may_push = False
    assert not (tmp_path / "wt").exists()


# ── dependencies ─────────────────────────────────────────────────────────────────


def test_ecosystems_are_detected_from_their_manifests(tmp_path: Path) -> None:
    (tmp_path / "package.json").write_text('{"name": "app"}')
    (tmp_path / "package-lock.json").write_text("{}")
    provisioner = DepsProvisioner(root=tmp_path)
    assert [s.ecosystem for s in provisioner.detect()] == [Ecosystem.NPM]


def test_a_pyproject_without_a_lockfile_is_not_claimed_by_uv_or_poetry(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text("[project]\nname='x'\n")
    assert DepsProvisioner(root=tmp_path).detect() == []


async def test_installing_without_a_lockfile_is_policy_gated(tmp_path: Path) -> None:
    """Q8: adding a dependency is a supply-chain decision."""
    (tmp_path / "package.json").write_text('{"name": "app"}')
    result = await DepsProvisioner(root=tmp_path).provision()
    assert result.is_err and result.category is ErrorCategory.POLICY
    assert result.error is not None and "lockfile" in result.error.message


async def test_no_manifest_means_nothing_to_provision(tmp_path: Path) -> None:
    report = (await DepsProvisioner(root=tmp_path).provision()).unwrap()
    assert report.ok and report.ecosystem is None


async def test_a_missing_toolchain_is_environment_not_a_code_defect(tmp_path: Path) -> None:
    (tmp_path / "go.mod").write_text("module example.com/x\n")
    (tmp_path / "go.sum").write_text("")
    provisioner = DepsProvisioner(root=tmp_path)
    provisioner.env = {"PATH": "/nonexistent"}
    result = await provisioner.provision()
    if result.is_err:
        assert result.category is ErrorCategory.ENVIRONMENT
    else:
        assert not result.unwrap().ok


def test_undeclared_imports_are_extracted_from_any_runner(tmp_path: Path) -> None:
    """The split that decides where the run goes: environment problem, or code defect."""
    assert undeclared_imports("ModuleNotFoundError: No module named 'widgets'") == ["widgets"]
    assert undeclared_imports("Error: Cannot find module 'lodash'") == ["lodash"]
    assert undeclared_imports("everything resolved fine") == []


def test_the_remedy_is_cause_specific() -> None:
    """Telling a human to chase the wrong cause wastes the escalation."""
    code_defect = remedy_for("ModuleNotFoundError: No module named 'widgets'", Ecosystem.PIP)
    network = remedy_for("npm ERR! code ECONNREFUSED", Ecosystem.NPM)
    other = remedy_for("added 1200 packages", Ecosystem.NPM)
    assert "code defect" in code_defect
    assert "registry or the network" in network
    assert "does not resolve" in other
    assert len({code_defect, network, other}) == 3


async def test_install_exit_zero_is_not_evidence_the_install_landed(tmp_path: Path) -> None:
    """Invariant 16 (#2124, #2438): verification is a separate step, and it is the one that counts."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    npm = bin_dir / "npm"
    npm.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "ci" ]; then exit 0; fi\n'
        'if [ "$1" = "ls" ]; then echo "npm ERR! missing: lodash@4.0.0, required by app"; exit 1; fi\n'
        "exit 0\n"
    )
    npm.chmod(0o755)
    (tmp_path / "package.json").write_text('{"name": "app"}')
    (tmp_path / "package-lock.json").write_text("{}")

    provisioner = DepsProvisioner(root=tmp_path, env={"PATH": f"{bin_dir}:{os.environ['PATH']}"})
    report = (await provisioner.provision()).unwrap()
    assert report.installed, "the install exited zero"
    assert not report.verified, "and the tree still does not resolve"
    assert not report.ok
    assert report.unresolved and "lodash" in report.unresolved[0]
    assert not report.is_code_defect
