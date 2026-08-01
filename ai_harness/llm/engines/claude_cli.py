"""The ``claude`` CLI as an engine.

This is the engine the shell harness uses at all nine of its call sites, and it is kept for
continuity of behaviour and cost reporting. One difference is deliberate: the shell passes
``--permission-mode bypassPermissions`` everywhere, which is how untrusted issue text reaches
a model with full tool access in a tree holding push credentials (W9). Here the permission
mode is configuration with a conservative default, and isolation is the runtime's job (§18.2)
rather than a flag's.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
from dataclasses import dataclass, field
from decimal import Decimal

from ai_harness.kernel.outcome import ErrorCategory, Outcome
from ai_harness.llm.engines.protocol import (
    Completion,
    EngineCapabilities,
    LLMRequest,
    Usage,
    classify_envelope,
)


@dataclass
class ClaudeCLIEngine:
    """Subprocess engine over ``claude -p --output-format json``."""

    binary: str = "claude"
    permission_mode: str = "default"
    extra_args: list[str] = field(default_factory=list)
    cwd: str | None = None
    env: dict[str, str] | None = None
    name: str = "claude-cli"
    capabilities: EngineCapabilities = field(
        default_factory=lambda: EngineCapabilities(
            native_structured_output=False,
            prompt_caching=True,
            tool_use=True,
            reports_cost=True,
        )
    )

    def _argv(self, request: LLMRequest) -> list[str]:
        argv = [self.binary, "-p", request.prompt, "--output-format", "json"]
        if request.model:
            argv += ["--model", request.model]
        if self.permission_mode:
            argv += ["--permission-mode", self.permission_mode]
        argv += self.extra_args
        return argv

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        argv = self._argv(request)
        try:
            process = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self.cwd,
                env={**os.environ, **(self.env or {})},
            )
        except FileNotFoundError:
            return Outcome.fail(
                ErrorCategory.ENVIRONMENT,
                f"{self.binary} is not installed or not on PATH",
                remedy=f"install the {self.binary} CLI, or configure a different engine",
                dependency=f"model:{self.name}",
            )

        try:
            stdout, stderr = await asyncio.wait_for(
                process.communicate(), timeout=request.timeout_s
            )
        except TimeoutError:
            # Kill the process group, not the process: a bare kill orphans the children that
            # are exactly the ones that wedge.
            _terminate(process)
            return Outcome.fail(
                ErrorCategory.TRANSIENT,
                f"{self.binary} exceeded {request.timeout_s:.0f}s",
                dependency=f"model:{self.name}",
            )

        classified = classify_envelope(
            stdout=stdout,
            stderr=stderr,
            exit_code=process.returncode or 0,
            provider=self.name,
        )
        if classified.is_err:
            assert classified.error is not None
            return Outcome.of(classified.error)

        payload = classified.unwrap()
        usage_payload = payload.get("usage") or {}
        reported = payload.get("total_cost_usd", payload.get("cost_usd"))
        usage = Usage(
            input_tokens=int(usage_payload.get("input_tokens", 0) or 0),
            output_tokens=int(usage_payload.get("output_tokens", 0) or 0),
            cache_read_tokens=int(usage_payload.get("cache_read_input_tokens", 0) or 0),
            cache_write_tokens=int(usage_payload.get("cache_creation_input_tokens", 0) or 0),
            reported_usd=Decimal(str(reported)) if reported is not None else None,
        )
        return Outcome.ok(
            Completion(
                text=str(payload.get("result", "")),
                model=str(payload.get("model") or request.model or "unknown"),
                provider=self.name,
                usage=usage,
                session_id=payload.get("session_id"),
                raw=payload,
            )
        )


def _terminate(process: asyncio.subprocess.Process) -> None:
    with contextlib.suppress(ProcessLookupError):
        process.kill()
