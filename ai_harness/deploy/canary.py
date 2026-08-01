"""The canary flow — implemented, available, and reachable only by two deliberate human acts.

`canary-deploy.sh` exists because `gcloud run deploy` routes 100% of traffic to the new revision
the moment it goes Ready. A revision that *boots* but fails its smoke check therefore serves the
broken build to every user, and the workflow it replaced only `exit 1`d — it never moved traffic
back. The five verbs, in the order they must happen:

1. ``pin_healthy`` — record the revision serving **now**, before anything is deployed. This is
   the step that is easy to leave out and impossible to add later: after the deploy there is no
   longer a way to ask which revision was the good one.
2. ``deploy`` — `--no-traffic --tag=canary`. The prior revision keeps serving 100%; the new one
   is reachable only at its private canary URL.
3. ``smoke`` — the **canary** URL. Smoking the live URL tests the revision you are replacing,
   which passes every time and proves nothing.
4. ``promote`` — smoke passed: shift 100% of traffic and drop the tag.
5. ``rollback`` — smoke failed: traffic was never shifted, so nothing is broken; pin explicitly
   back to the recorded last-healthy revision anyway, and **fail loudly**. Belt and braces, and
   the loud failure matters because a deploy that silently did nothing looks like a success.

Two harness rules on top of the script's own:

* **Promotion requires an approval and a policy override.** ``DEPLOY_PROD`` is ``DENY`` in the
  standard policy. :meth:`Canary.promote` re-checks at the moment of promotion rather than
  trusting a decision made before the smoke ran — the approval is for promoting *this* result.
* **First deploy has no rollback target**, and that is reported rather than papered over. The
  `--no-traffic` deploy means the possibly-broken revision never served, so nothing is broken;
  but there is also nothing to promote, and a caller must know which of those it is in.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.deploy.smoke import Smoker
from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.observability.logging import Logger
from ai_harness.policies.engine import PolicyEngine, Request
from ai_harness.schemas.deploy import SmokeCheck, SmokeReport
from ai_harness.schemas.enums import Capability
from ai_harness.schemas.policy import Policy

CANARY_TAG = "canary"


@dataclass(frozen=True, slots=True)
class CanaryState:
    """The recorded last-healthy revision, per service.

    On disk because `pin-healthy` (pre-deploy) and `rollback` (post-failure) run in separate
    processes in the shell, and because a rollback target that lived only in memory would be
    gone at exactly the moment it is needed.
    """

    directory: Path

    def path(self, service: str) -> Path:
        return self.directory / f"{service}.last-healthy"

    def record(self, service: str, revision: str) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path(service).write_text(revision)

    def healthy(self, service: str) -> str:
        path = self.path(service)
        return path.read_text().strip() if path.exists() else ""


@dataclass
class Canary:
    """The canary lifecycle over an injected cloud CLI."""

    runner: Any
    """A :class:`~ai_harness.providers.deploy.script.ScriptProvider` — the CLI, as argv."""
    state: CanaryState
    workspace: Path = field(default_factory=Path.cwd)
    smoker: Smoker = field(default_factory=Smoker)
    logger: Logger = field(default_factory=Logger)
    region: str = "us-central1"
    project: str = ""
    tag: str = CANARY_TAG

    # ── 1. pin the rollback target, before anything changes ──────────────────────

    async def pin_healthy(self, service: str) -> Outcome[str]:
        described = await self._describe(service)
        if described.is_err:
            return Outcome.of(described.error)  # type: ignore[arg-type]
        revision = _serving_revision(described.unwrap())
        self.state.record(service, revision)
        if not revision:
            self.logger.warning(
                "no prior serving revision — a first deploy has no rollback target",
                service=service,
            )
        return Outcome.ok(revision)

    # ── 2. deploy without taking traffic ─────────────────────────────────────────

    async def deploy(self, service: str, image: str) -> Outcome[str]:
        run = await self.runner.invoke(
            self.workspace,
            argv=[
                *self.runner.command,
                "run",
                "deploy",
                service,
                f"--image={image}",
                *self._location(),
                "--no-traffic",
                f"--tag={self.tag}",
            ],
        )
        if not run.ok:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"the canary deploy exited {run.returncode}",
                details={"stderr": run.stderr[-2000:]},
            )
        return Outcome.ok(run.stdout)

    # ── 3. smoke the canary URL, never the live one ──────────────────────────────

    async def smoke(
        self, service: str, checks: list[SmokeCheck] | None = None
    ) -> Outcome[SmokeReport]:
        described = await self._describe(service)
        if described.is_err:
            return Outcome.of(described.error)  # type: ignore[arg-type]
        url = _canary_url(described.unwrap(), self.tag)
        if not url:
            return Outcome.fail(
                ErrorCategory.TOOL_FAILURE,
                f"no canary URL for {service} — did the deploy step run?",
                remedy="smoking the live URL instead would test the revision being replaced",
            )
        return Outcome.ok(await self.smoker.run(url, checks))

    # ── 4. promote — the approval-gated step ─────────────────────────────────────

    async def promote(
        self, service: str, *, policy: Policy, approved: bool = False
    ) -> Outcome[str]:
        """Shift 100% of traffic. Denied by the standard policy; never promotes unapproved.

        The check is here rather than at the start of the flow because the approval is for
        promoting *this* smoke result. An approval granted before the canary was even built
        would be a blank cheque for whatever it turned out to be.
        """
        verdict = PolicyEngine(policy=policy).evaluate(
            Request(capability=Capability.DEPLOY_PROD, reason=f"promote canary for {service}")
        )
        if verdict.denied:
            return Outcome.fail(
                ErrorCategory.POLICY,
                f"promoting {service} is denied by the {policy.name} policy",
                remedy="production is out of scope by default (§2); this needs a policy override",
            )
        if not approved:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"promoting {service} requires an approval",
                remedy="the canary is healthy and holding at 0% traffic; nothing is at risk",
            )

        shifted = await self.runner.invoke(
            self.workspace,
            argv=[
                *self.runner.command,
                "run",
                "services",
                "update-traffic",
                service,
                *self._location(),
                "--to-latest",
            ],
        )
        if not shifted.ok:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"failed to shift traffic for {service}",
                details={"stderr": shifted.stderr[-2000:]},
            )
        # Dropping the tag frees the private URL. A failure here is non-fatal: traffic has
        # already moved, and reporting it as a failed promotion would be wrong.
        await self._remove_tag(service)
        return Outcome.ok(shifted.stdout)

    # ── 5. rollback — safe by construction, and loud anyway ──────────────────────

    async def rollback(self, service: str) -> Outcome[str]:
        """Pin traffic back to the recorded last-healthy revision, then fail.

        Because the deploy used ``--no-traffic`` the prior revision was never displaced, so this
        is a guaranteed-safe explicit re-pin rather than a scramble. It still returns a failure:
        the deploy did not succeed, and a workflow that went green here would ship the belief
        that it had.
        """
        await self._remove_tag(service)
        healthy = self.state.healthy(service)
        if not healthy:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"no last-healthy revision recorded for {service}",
                remedy=(
                    "the --no-traffic deploy means the broken revision never served, so nothing "
                    "is broken — but there is also no prior revision to promote"
                ),
            )
        pinned = await self.runner.invoke(
            self.workspace,
            argv=[
                *self.runner.command,
                "run",
                "services",
                "update-traffic",
                service,
                *self._location(),
                f"--to-revisions={healthy}=100",
            ],
        )
        if not pinned.ok:
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"ROLLBACK FAILED for {service} — manual intervention required",
                details={"stderr": pinned.stderr[-2000:]},
            )
        return Outcome.fail(
            ErrorCategory.TOOL_FAILURE,
            f"rolled back {service} to {healthy}: the canary did not pass its smoke checks",
            remedy="traffic is safe; the deploy is still a failure and must go red",
            details={"restored": healthy},
        )

    # ── plumbing ─────────────────────────────────────────────────────────────────

    def _location(self) -> list[str]:
        args = [f"--region={self.region}"]
        if self.project:
            args.append(f"--project={self.project}")
        return args

    async def _describe(self, service: str) -> Outcome[dict[str, Any]]:
        run = await self.runner.invoke(
            self.workspace,
            argv=[
                *self.runner.command,
                "run",
                "services",
                "describe",
                service,
                *self._location(),
                "--format=json",
            ],
        )
        if not run.ok:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"could not describe {service} (exit {run.returncode})",
                details={"stderr": run.stderr[-2000:]},
            )
        try:
            parsed = json.loads(run.stdout or "{}")
        except ValueError:
            return Outcome.fail(ErrorCategory.TOOL_FAILURE, "the CLI did not return JSON")
        return Outcome.ok(parsed if isinstance(parsed, dict) else {})

    async def _remove_tag(self, service: str) -> None:
        await self.runner.invoke(
            self.workspace,
            argv=[
                *self.runner.command,
                "run",
                "services",
                "update-traffic",
                service,
                *self._location(),
                f"--remove-tags={self.tag}",
            ],
        )


def _serving_revision(described: dict[str, Any]) -> str:
    """The revision taking the most production traffic — the one that was healthy.

    Tagged entries are excluded: a tagged revision is reachable at its own URL while holding no
    production traffic, which is exactly what a canary is, and rolling back *to* one would pin
    traffic to the revision that just failed.
    """
    traffic = ((described.get("status") or {}).get("traffic")) or []
    untagged = [entry for entry in traffic if not entry.get("tag")]
    if not untagged:
        return ""
    best = max(untagged, key=lambda entry: entry.get("percent") or 0)
    return str(best.get("revisionName") or "")


def _canary_url(described: dict[str, Any], tag: str) -> str:
    traffic = ((described.get("status") or {}).get("traffic")) or []
    for entry in traffic:
        if entry.get("tag") == tag and entry.get("url"):
            return str(entry["url"])
    return ""
