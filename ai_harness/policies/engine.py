"""Policy evaluation — allow, deny, or require approval.

§18.4. The shell harness runs every model call with ``--permission-mode bypassPermissions`` at
all nine call sites: there is no policy, only a flag that turns policy off. Here every action
resolves to a :class:`~ai_harness.schemas.enums.Capability` and every capability is evaluated
against the run's policy before anything happens.

Two rules make the evaluation trustworthy rather than decorative:

* **Unknown fails closed** (§7.4). A capability the policy does not mention is denied, so
  adding a capability to the code without adding it to the policy makes runs stop, not spread.
* **Context can only tighten, never loosen.** A path-based rule may escalate ``ALLOW`` to
  ``REQUIRE_APPROVAL`` — writing to ``.github/workflows`` is not an ordinary write — but no
  context may turn a ``DENY`` into anything else. Otherwise every deny is one clever argument
  away from an allow.
"""

from __future__ import annotations

import fnmatch
from dataclasses import dataclass, field

from ai_harness.schemas.enums import Capability, Decision
from ai_harness.schemas.policy import Policy

WRITE_CAPABILITIES = frozenset(
    {
        Capability.WRITE_WORKSPACE,
        Capability.INSTALL_DEPS,
        Capability.GIT_PUSH,
        Capability.GIT_FORCE_PUSH,
        Capability.FORGE_COMMENT,
        Capability.FORGE_MERGE,
        Capability.MODIFY_CI,
        Capability.MODIFY_MIGRATIONS,
        Capability.DEPLOY_DEV,
        Capability.DEPLOY_PROD,
    }
)

PATH_CAPABILITIES: tuple[tuple[str, Capability], ...] = (
    (".github/workflows/**", Capability.MODIFY_CI),
    (".gitlab-ci.yml", Capability.MODIFY_CI),
    ("**/migrations/**", Capability.MODIFY_MIGRATIONS),
    ("**/alembic/**", Capability.MODIFY_MIGRATIONS),
)
"""Paths whose modification *is* a different capability, whatever tool touched them."""


@dataclass(frozen=True, slots=True)
class Request:
    """What is about to happen, described in the terms policy is written in."""

    capability: Capability
    paths: list[str] = field(default_factory=list)
    reason: str = ""
    detail: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class Verdict:
    """The decision, and the evidence a human would need to overturn it."""

    decision: Decision
    capability: Capability
    reason: str
    evidence: list[str] = field(default_factory=list)

    @property
    def allowed(self) -> bool:
        return self.decision is Decision.ALLOW

    @property
    def denied(self) -> bool:
        return self.decision is Decision.DENY

    @property
    def needs_approval(self) -> bool:
        return self.decision is Decision.REQUIRE_APPROVAL


@dataclass
class PolicyEngine:
    """Evaluates a request against one policy and one repository profile."""

    policy: Policy
    protected_paths: list[str] = field(default_factory=list)

    def evaluate(self, request: Request) -> Verdict:
        capability = self._effective_capability(request)
        base = self.policy.decide(capability)

        if base is Decision.DENY:
            # A deny is terminal. No context, path or argument may soften it.
            return Verdict(
                decision=Decision.DENY,
                capability=capability,
                reason=f"{capability.value} is denied by the {self.policy.name} policy",
                evidence=list(request.paths),
            )

        protected = self._protected(request.paths)
        if protected and base is Decision.ALLOW:
            return Verdict(
                decision=Decision.REQUIRE_APPROVAL,
                capability=capability,
                reason="the change touches protected paths",
                evidence=protected,
            )

        if base is Decision.REQUIRE_APPROVAL:
            return Verdict(
                decision=Decision.REQUIRE_APPROVAL,
                capability=capability,
                reason=request.reason or f"{capability.value} requires approval",
                evidence=list(request.paths),
            )

        return Verdict(decision=Decision.ALLOW, capability=capability, reason="permitted")

    def _effective_capability(self, request: Request) -> Capability:
        """A write to CI configuration is ``MODIFY_CI``, not ``WRITE_WORKSPACE``.

        Resolving the capability from *what is touched* rather than from *which tool ran* is
        what stops a generic file-write tool being a way around the CI rule.
        """
        if request.capability is not Capability.WRITE_WORKSPACE:
            return request.capability
        for pattern, capability in PATH_CAPABILITIES:
            if any(_matches(path, pattern) for path in request.paths):
                return capability
        return request.capability

    def _protected(self, paths: list[str]) -> list[str]:
        patterns = self.protected_paths or self._profile_defaults()
        return [path for path in paths if any(_matches(path, p) for p in patterns)]

    def _profile_defaults(self) -> list[str]:
        from ai_harness.schemas.profile import RepoProfile

        return RepoProfile().protected_paths


def _matches(path: str, pattern: str) -> bool:
    """``fnmatch`` with ``**`` handled the way a reader expects it to be."""
    if fnmatch.fnmatch(path, pattern):
        return True
    if "**/" in pattern:
        return fnmatch.fnmatch(path, pattern.replace("**/", "")) or fnmatch.fnmatch(
            f"x/{path}", pattern
        )
    return False
