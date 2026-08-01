"""The capability broker — the one door every tool call goes through.

§18.4. Resolve the capability, evaluate the policy, enforce path containment, execute, audit.
The shell harness has none of this: nine call sites, ``bypassPermissions``, and a model with a
filesystem and push credentials.

Three properties are the point:

* **No tool executes without passing through here.** An unregistered tool is denied — the
  absence of a rule is never permission.
* **A denial is** :attr:`ErrorCategory.POLICY`, **which is never retried.** A policy decision
  is not a transient condition, and retrying one burns budget to be told the same thing.
* **Approval is a park, not a prompt.** ``REQUIRE_APPROVAL`` returns ``NEEDS_HUMAN`` with the
  specific evidence — the path, the command, the capability — so the request a human sees is
  answerable without re-deriving what the harness already knew.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.observability.audit import AuditLog
from ai_harness.policies.engine import PolicyEngine, Request
from ai_harness.schemas.enums import Capability, Decision
from ai_harness.security.paths import contained
from ai_harness.tools.registry import ToolRegistry

ToolFn = Callable[..., Awaitable[Outcome[Any]]]


@dataclass(frozen=True, slots=True)
class ToolCall:
    """One attempted action, in the terms the broker reasons about."""

    tool: str
    arguments: dict[str, Any] = field(default_factory=dict)
    paths: list[str] = field(default_factory=list)
    command: str = ""
    reason: str = ""


@dataclass
class ToolBroker:
    """Capability resolution, policy check, containment, execution, audit."""

    policy: PolicyEngine
    registry: ToolRegistry = field(default_factory=ToolRegistry)
    audit: AuditLog = field(default_factory=AuditLog)
    workspace: Path | None = None
    run_id: str = ""
    state: str = ""
    actor: str = "implementer"
    handlers: dict[str, ToolFn] = field(default_factory=dict)
    read_only: bool = False
    """ANALYSE runs read-only. Enforced here, not requested in the prompt."""

    def handle(self, name: str, fn: ToolFn) -> ToolBroker:
        self.handlers[name] = fn
        return self

    async def invoke(self, call: ToolCall) -> Outcome[Any]:
        capability = self.registry.capability_for(call.tool, command=call.command)
        if capability is None:
            return self._refuse(
                call,
                Capability.READ_REPO,
                f"{call.tool!r} is not a registered tool",
                "the absence of a rule is not permission",
            )

        if self.read_only and call.tool not in self.registry.read_only_tools():
            return self._refuse(
                call,
                capability,
                f"{call.tool!r} is not read-only",
                "this state has read-only access; the restriction is enforced, not requested",
            )

        contained_paths = self._contain(call)
        if contained_paths.is_err:
            assert contained_paths.error is not None
            self.audit.write(
                run_id=self.run_id,
                state=self.state,
                actor=self.actor,
                tool=call.tool,
                capability=capability,
                decision=Decision.DENY,
                arguments=call.arguments,
                outcome="denied",
                reason=contained_paths.error.message,
            )
            return Outcome.of(contained_paths.error)

        verdict = self.policy.evaluate(
            Request(
                capability=capability,
                paths=call.paths,
                reason=call.reason,
                detail={"tool": call.tool, "command": call.command},
            )
        )

        if verdict.denied:
            return self._refuse(call, verdict.capability, verdict.reason, "", verdict.evidence)

        if verdict.needs_approval:
            self.audit.write(
                run_id=self.run_id,
                state=self.state,
                actor=self.actor,
                tool=call.tool,
                capability=verdict.capability,
                decision=Decision.REQUIRE_APPROVAL,
                arguments=call.arguments,
                outcome="parked",
                reason=verdict.reason,
                evidence=verdict.evidence,
            )
            return Outcome.fail(
                ErrorCategory.NEEDS_HUMAN,
                f"{verdict.capability.value} requires approval: {verdict.reason}",
                remedy=(
                    "approve with `agent approve <run>`, or deny it — the run is parked and "
                    "holds no lease while it waits"
                ),
                details={
                    "capability": verdict.capability.value,
                    "tool": call.tool,
                    "evidence": verdict.evidence,
                },
            )

        handler = self.handlers.get(call.tool)
        if handler is None:
            return self._refuse(
                call,
                verdict.capability,
                f"{call.tool!r} is permitted but has no implementation",
                "a permitted tool with no handler is a configuration error, not a silent no-op",
            )

        result = await handler(**call.arguments)
        self.audit.write(
            run_id=self.run_id,
            state=self.state,
            actor=self.actor,
            tool=call.tool,
            capability=verdict.capability,
            decision=Decision.ALLOW,
            arguments=call.arguments,
            outcome="ok" if result.is_ok else str(result.category),
            reason=verdict.reason,
        )
        return result

    def _contain(self, call: ToolCall) -> Outcome[list[str]]:
        """Every path must resolve inside the workspace — traversal, symlink and all."""
        if self.workspace is None or not call.paths:
            return Outcome.ok(list(call.paths))
        resolved: list[str] = []
        for path in call.paths:
            outcome = contained(self.workspace, path)
            if outcome.is_err:
                return Outcome.of(outcome.error)  # type: ignore[arg-type]
            resolved.append(str(outcome.unwrap()))
        return Outcome.ok(resolved)

    def _refuse(
        self,
        call: ToolCall,
        capability: Capability,
        reason: str,
        remedy: str,
        evidence: list[str] | None = None,
    ) -> Outcome[Any]:
        self.audit.write(
            run_id=self.run_id,
            state=self.state,
            actor=self.actor,
            tool=call.tool,
            capability=capability,
            decision=Decision.DENY,
            arguments=call.arguments,
            outcome="denied",
            reason=reason,
            evidence=evidence or [],
        )
        return Outcome.fail(
            ErrorCategory.POLICY,
            reason,
            remedy=remedy or "a policy denial is not a transient condition; it is never retried",
            details={"tool": call.tool, "capability": capability.value},
        )
