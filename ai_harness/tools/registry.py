"""Tool → capability mapping.

Policy is written about *capabilities*, not about commands, so the mapping has to live
somewhere explicit. Two properties matter:

* **An unregistered tool has no capability, and therefore no permission.** Adding a tool
  without declaring what it is for makes it unusable rather than unrestricted.
* **A tool's capability can depend on its arguments.** ``shell`` running the test command is
  ``RUN_TESTS``; ``shell`` running ``npm install`` is ``INSTALL_DEPS``; ``shell`` running
  ``curl`` is ``NETWORK``. Mapping the *tool* alone would make ``shell`` a way to do anything.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from ai_harness.schemas.enums import Capability

_INSTALL = re.compile(
    r"\b(npm|pnpm|yarn|pip|pip3|poetry|uv|cargo|go|gem|bundle)\b.*\b"
    r"(install|add|ci|sync|fetch|get|download)\b"
)
_NETWORK = re.compile(r"\b(curl|wget|nc|ssh|scp|rsync|http|https)\b")
_GIT_WRITE = re.compile(r"\bgit\b.*\b(push|remote add|config --global)\b")
_TEST = re.compile(r"\b(pytest|jest|vitest|go test|cargo test|npm (run )?test|make (test|check))\b")


@dataclass(frozen=True, slots=True)
class ToolSpec:
    name: str
    capability: Capability
    description: str = ""
    read_only: bool = False


DEFAULT_TOOLS: tuple[ToolSpec, ...] = (
    ToolSpec("fs.read", Capability.READ_REPO, "read a file inside the workspace", read_only=True),
    ToolSpec("fs.list", Capability.READ_REPO, "list a directory", read_only=True),
    ToolSpec("fs.search", Capability.READ_REPO, "exact search", read_only=True),
    ToolSpec("fs.write", Capability.WRITE_WORKSPACE, "write a file inside the workspace"),
    ToolSpec("fs.delete", Capability.WRITE_WORKSPACE, "delete a file inside the workspace"),
    ToolSpec("shell", Capability.RUN_TESTS, "run a command in the sandbox"),
    ToolSpec("git.read", Capability.READ_REPO, "git log, diff, status", read_only=True),
    ToolSpec("git.commit", Capability.WRITE_WORKSPACE, "commit staged work"),
    ToolSpec("git.push", Capability.GIT_PUSH, "push a branch"),
    ToolSpec("git.force_push", Capability.GIT_FORCE_PUSH, "force-push with lease"),
    ToolSpec("forge.read", Capability.READ_REPO, "read issues and MRs", read_only=True),
    ToolSpec("forge.comment", Capability.FORGE_COMMENT, "post a comment"),
    ToolSpec("forge.merge", Capability.FORGE_MERGE, "merge an MR"),
    ToolSpec("http.get", Capability.NETWORK, "fetch a URL"),
    ToolSpec("deploy.dev", Capability.DEPLOY_DEV, "deploy to a development environment"),
    ToolSpec("deploy.prod", Capability.DEPLOY_PROD, "deploy to production"),
)


@dataclass
class ToolRegistry:
    """The tools this harness knows about, and what each one is *for*."""

    tools: dict[str, ToolSpec] = field(
        default_factory=lambda: {spec.name: spec for spec in DEFAULT_TOOLS}
    )

    def register(self, spec: ToolSpec) -> ToolRegistry:
        self.tools[spec.name] = spec
        return self

    def spec_for(self, name: str) -> ToolSpec | None:
        return self.tools.get(name)

    def capability_for(self, name: str, *, command: str = "") -> Capability | None:
        """The capability this invocation actually exercises.

        ``None`` means the tool is unregistered — which the broker turns into a denial, not
        into a default.
        """
        spec = self.tools.get(name)
        if spec is None:
            return None
        if spec.name != "shell":
            return spec.capability
        return self._shell_capability(command)

    def _shell_capability(self, command: str) -> Capability:
        """``shell`` is whatever it runs. Mapping the tool alone would make it a bypass."""
        lowered = command.lower()
        if _INSTALL.search(lowered):
            return Capability.INSTALL_DEPS
        if _GIT_WRITE.search(lowered):
            return Capability.GIT_PUSH
        if _NETWORK.search(lowered):
            return Capability.NETWORK
        if _TEST.search(lowered):
            return Capability.RUN_TESTS
        return Capability.RUN_TESTS

    def read_only_tools(self) -> set[str]:
        return {name for name, spec in self.tools.items() if spec.read_only}
