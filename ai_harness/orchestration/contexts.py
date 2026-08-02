"""``Run`` → the context each state expects.

Every subgraph takes a typed context and reaches for nothing global, which is what makes them
testable — and it leaves exactly one thing undone, the same shape as :mod:`ai_harness.wiring`:
something must actually *assemble* those contexts. Until this module existed
``deps.context_builder`` was ``None``, which means ``machine.py`` handed each subgraph the ``Run``
itself and every state failed on the first attribute it looked for.

Three rules, in the order they matter:

1. **The workspace path is derived, never stored.** ``worktree_for()`` is a pure function of the
   repository and the branch, so any worker on any host computes the same path for the same run.
   Persisting it would make the path a fact that can disagree with the filesystem, and a worker
   that dies between materialising and recording would strand a tree nothing could find.

2. **Cross-state facts come from the checkpoint ledger.** VALIDATE's gate report and REVIEW's
   verdict are needed by INTEGRATE, which runs in a *different dispatch, possibly on a different
   host*. They are read back out of the checkpoints that recorded them rather than carried in
   memory — the same source ``agent replay`` reads, so what INTEGRATE saw is what a human sees.

3. **Untrusted content is marked where it enters.** The issue title and body arrive from the
   forge and are attacker-controlled; they are handed to the subgraphs as data, and it is the
   agents' prompt builders that fence them. This module never concatenates them into anything.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.config import HarnessConfig
from ai_harness.persistence.sql import SqlStore
from ai_harness.providers.forge.protocol import Forge, Issue
from ai_harness.providers.git.protocol import GitClient
from ai_harness.schemas.enums import Brief, GateSet, Isolation, MergeStrategy, Risk, State
from ai_harness.schemas.gates import GateReport
from ai_harness.schemas.plan import WorkPlan
from ai_harness.schemas.review import ReviewResult
from ai_harness.schemas.run import Run
from ai_harness.subgraphs.analyse import AnalyseContext
from ai_harness.subgraphs.implement import ImplementContext
from ai_harness.subgraphs.integrate import IntegrateContext
from ai_harness.subgraphs.prepare import PrepareContext
from ai_harness.subgraphs.review import ReviewContext
from ai_harness.subgraphs.validate import ValidateContext

WORKTREE_ROOT = Path("/tmp/ai-harness-worktrees")
"""Outside the repository on purpose: a worktree under the primary checkout is a directory the
gates would scan, the linter would lint, and a careless ``git clean`` would delete."""


def worktree_for(repo: str, branch: str, *, root: Path | None = None) -> Path:
    """Where this run's tree lives. Pure, so every worker agrees without being told."""
    slug = f"{repo}/{branch}".replace("/", "-").replace("_", "-").strip("-").lower()
    return (root or WORKTREE_ROOT) / slug


@dataclass
class ContextBuilder:
    """Assembles the context for whichever state the run is in.

    Constructed once by the composition root and called per dispatch. It holds only collaborators
    — the run is the argument, and nothing about a previous run survives in here.
    """

    config: HarnessConfig
    store: SqlStore
    git: GitClient
    forge: Forge | None = None
    worktree_root: Path | None = None
    _issues: dict[tuple[str, int], Issue] = field(default_factory=dict, init=False)

    async def __call__(self, run: Run, deps: Any) -> Any:
        state = run.state
        if state is State.PREPARE:
            return await self.prepare(run)
        if state is State.ANALYSE:
            return await self.analyse(run)
        if state is State.IMPLEMENT:
            return await self.implement(run)
        if state is State.VALIDATE:
            return await self.validate(run)
        if state is State.REVIEW:
            return await self.review(run)
        if state is State.INTEGRATE:
            return await self.integrate(run)
        # COMPLETE is terminal and never dispatched (`machine.py` returns on `transition
        # .terminal`), so there is no context to build for it. Returning the run keeps this
        # total rather than raising in a place that would park the run for the wrong reason.
        return run

    # ── the facts every context needs ────────────────────────────────────────────

    def branch_for(self, run: Run) -> str:
        profile = self._profile(run)
        return run.branch or profile.branch_for(run.request.issue or run.run_id[:8])

    def workspace_for(self, run: Run) -> Path:
        return worktree_for(run.request.repo, self.branch_for(run), root=self.worktree_root)

    def _profile(self, run: Run):  # type: ignore[no-untyped-def]
        # The run's own profile wins: a run started under one convention must not change shape
        # because the repository's config was edited while it was in flight.
        return run.request.profile if run.request.profile.name else self.config.profile

    async def _issue(self, run: Run) -> Issue | None:
        number = run.request.issue
        if number is None or self.forge is None:
            return None
        key = (run.request.repo, number)
        if key not in self._issues:
            fetched = await self.forge.get_issue(number)
            if fetched.is_err:
                return None
            self._issues[key] = fetched.unwrap()
        return self._issues[key]

    async def _diff(self, run: Run) -> str:
        """The branch's own diff against its base, from the worktree."""
        workspace = self.workspace_for(run)
        if not workspace.exists() or not run.base_sha:
            return ""
        result = await self.git.run("diff", f"{run.base_sha}...HEAD", cwd=workspace)
        return result.unwrap().stdout if result.is_ok else ""

    # ── cross-state facts, read back from the ledger ──────────────────────────────

    async def _last_payload(self, run: Run, state: State) -> dict[str, Any]:
        """The most recent checkpoint payload written *by* ``state``.

        Read rather than remembered: INTEGRATE may run on a different host from the VALIDATE
        that produced the report it cites.
        """
        for checkpoint in reversed(await self.store.checkpoints(run.run_id)):
            if checkpoint.state is state and checkpoint.result:
                return dict(checkpoint.result)
        return {}

    async def _gate_report(self, run: Run) -> GateReport | None:
        payload = await self._last_payload(run, State.VALIDATE)
        raw = payload.get("report")
        if not raw:
            return None
        try:
            report = GateReport(**(json.loads(raw) if isinstance(raw, str) else raw))
        except Exception:
            # A report we cannot parse is the same as no report: INTEGRATE's evidence block
            # loses detail, and nothing else changes. It must never park a run.
            return None
        if not report.results and not report.no_gates_discovered:
            # And a report that says *nothing* is also no report. Pydantic ignores unknown keys,
            # so a corrupted payload parses into a default `GateReport` whose every field looks
            # benign — including `profile_discovered=False`, which would tell INTEGRATE the gates
            # were declared and let `FF_ONLY` merge on the strength of an empty object.
            return None
        return report

    async def _review(self, run: Run) -> ReviewResult | None:
        payload = await self._last_payload(run, State.REVIEW)
        raw = payload.get("review")
        if not raw:
            return None
        try:
            return ReviewResult(**(json.loads(raw) if isinstance(raw, str) else raw))
        except Exception:
            return None

    async def _plan(self, run: Run) -> WorkPlan | None:
        payload = await self._last_payload(run, State.ANALYSE)
        raw = payload.get("plan")
        if not raw:
            return None
        try:
            return WorkPlan(**(json.loads(raw) if isinstance(raw, str) else raw))
        except Exception:
            # No plan means IMPLEMENT builds from the issue alone. Worse, and not a reason to
            # park: the attempt cap is what stops a run that cannot converge.
            return None

    async def _prior_findings(self, run: Run) -> tuple[str, ...]:
        payload = await self._last_payload(run, State.REVIEW)
        findings = payload.get("findings") or []
        return tuple(
            f"{item.get('severity')} {item.get('citation')}: {item.get('title')}"
            for item in findings
            if isinstance(item, dict)
        )

    # ── the six contexts ─────────────────────────────────────────────────────────

    async def prepare(self, run: Run) -> PrepareContext:
        profile = self._profile(run)
        policy = run.request.policy
        return PrepareContext(
            run_id=run.run_id,
            repo=run.request.repo,
            workspace=self.workspace_for(run),
            branch=self.branch_for(run),
            base_ref=f"{profile.remote}/{run.request.base_branch or profile.default_branch}",
            remote=profile.remote,
            issue_number=run.request.issue,
            holder=run.lease_holder or "harness",
            workspaces=tuple(profile.workspaces),
            allow_install_without_lockfile=not policy.allow_deps_install_with_lockfile,
            isolation=policy.require_isolation,
            allow_degraded_isolation=policy.allow_degraded_isolation,
        )

    async def analyse(self, run: Run) -> AnalyseContext:
        issue = await self._issue(run)
        profile = self._profile(run)
        live_base = await self.git.rev_parse(
            f"{profile.remote}/{run.request.base_branch or profile.default_branch}"
        )
        return AnalyseContext(
            run_id=run.run_id,
            repo=run.request.repo,
            base_sha=run.base_sha,
            issue_title=issue.title if issue else run.request.title,
            issue_body=issue.body if issue else run.request.body,
            issue_number=run.request.issue,
            attempt=run.counters.plan_attempts + 1,
            approval_threshold=Risk.HIGH,
            protected_paths=tuple(profile.protected_paths),
            prior_failure=run.last_error or "",
            prior_findings=await self._prior_findings(run),
            gate_report=await self._gate_report(run),
            live_base_sha=live_base.unwrap_or("") if live_base.is_ok else "",
            run_spend=run.spend_view(),
        )

    async def implement(self, run: Run) -> ImplementContext:
        profile = self._profile(run)
        policy = run.request.policy
        # A review that requested changes is a FIX brief; gates that went red with fault=self is
        # a REPAIR. Both are visible in the ledger, so the brief is derived rather than guessed.
        brief = Brief.BUILD
        if run.counters.review_rounds:
            brief = Brief.FIX
        if run.counters.self_repair_attempts:
            brief = Brief.REPAIR

        issue = await self._issue(run)
        report = await self._gate_report(run)
        failures = [r for r in report.results if not r.green] if report else []
        return ImplementContext(
            run_id=run.run_id,
            repo=run.request.repo,
            workspace=self.workspace_for(run),
            branch=self.branch_for(run),
            base_sha=run.base_sha,
            brief=brief,
            attempt=run.counters.implement_attempts + 1,
            max_files=policy.approval.max_files_changed,
            max_lines=policy.approval.max_lines_changed,
            protected_paths=tuple(profile.protected_paths),
            provisioned_paths=tuple(profile.provisioned_paths),
            remote=profile.remote,
            empty_streak=run.counters.empty_envelope_streak,
            plan=await self._plan(run),
            issue_title=issue.title if issue else run.request.title,
            issue_body=issue.body if issue else run.request.body,
            issue_number=run.request.issue,
            findings=await self._prior_findings(run),
            # The diagnostic line, never `tail -n1`: the gate result already carries the reason
            # the extractor pulled out of the log.
            gate_failure="; ".join(f"{r.name}: {r.reason}" for r in failures[:3]),
        )

    async def validate(self, run: Run) -> ValidateContext:
        return ValidateContext(
            run_id=run.run_id,
            repo=run.request.repo,
            workspace=self.workspace_for(run),
            base_sha=run.base_sha,
            head_sha=run.head_sha,
            gate_set=run.request.gate_set or GateSet.FULL,
            diff_text=await self._diff(run),
            env_defers=run.counters.env_defers,
            self_repairs=run.counters.self_repair_attempts,
        )

    async def review(self, run: Run) -> ReviewContext:
        issue = await self._issue(run)
        from ai_harness.security.sandbox import probe

        policy = run.request.policy
        sandbox = probe(policy.require_isolation, allow_degraded=policy.allow_degraded_isolation)
        return ReviewContext(
            run_id=run.run_id,
            repo=run.request.repo,
            base_sha=run.base_sha,
            head_sha=run.head_sha,
            issue_title=issue.title if issue else run.request.title,
            issue_body=issue.body if issue else run.request.body,
            acceptance_criteria=issue.body if issue else run.request.body,
            issue_number=run.request.issue,
            diff_text=await self._diff(run),
            round=run.counters.review_rounds + 1,
            max_rounds=self.config.bounds.pr_max_rounds,
            empty_streak=run.counters.empty_envelope_streak,
            prior_findings=list(await self._prior_findings(run)),
            isolation=sandbox.chosen if sandbox.isolated else Isolation.NONE,
            clone_path=self.workspace_for(run),
            run_spend=run.spend_view(),
        )

    async def integrate(self, run: Run) -> IntegrateContext:
        issue = await self._issue(run)
        profile = self._profile(run)
        report = await self._gate_report(run)
        return IntegrateContext(
            run_id=run.run_id,
            repo=run.request.repo,
            workspace=self.workspace_for(run),
            branch=self.branch_for(run),
            base_ref=run.request.base_branch or profile.default_branch,
            base_sha=run.base_sha,
            head_sha=run.head_sha,
            issue_number=run.request.issue,
            title=issue.title if issue else run.request.title,
            strategy=run.request.effective_merge_strategy() or MergeStrategy.MR_ONLY,
            gate_report=report,
            review=await self._review(run),
            generated_paths=tuple(profile.generated_paths),
            resolver_attempts=run.counters.resolver_attempts,
            # `FF_ONLY` is refused unless the gates were DECLARED rather than inferred, and this
            # is where that fact reaches the decision (§19.2 rung 3/4 mark `discovered`).
            gates_were_discovered=bool(report and not report.profile_discovered)
            if report is not None
            else False,
        )
