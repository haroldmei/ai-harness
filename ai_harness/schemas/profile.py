"""``RepoProfile`` — the module that breaks the host-project coupling (W12).

Roughly a dozen host-project assumptions are hardcoded across the shell harness: two named
documentation and state files treated as auto-resolvable conflict paths,
three fixed workspace directory names, a fixed compose-project prefix, and the host's own
build-skill name interpolated into the build prompt. Every one of them is a field here, and
per Q2 we assume *external* repositories so the coupling cannot creep back.

Two of these lists exist in the shell in three and four *drifted* copies (§3.14). Here they
exist once.
"""

from __future__ import annotations

from pydantic import BaseModel, Field

from ai_harness.schemas.enums import MergeStrategy, Tier


class RepoProfile(BaseModel):
    """Everything the harness must know about a repository that it cannot infer safely."""

    model_config = {"extra": "forbid"}

    name: str = ""
    default_branch: str = "main"
    remote: str = "origin"

    branch_prefix: str = "agent/issue-"
    """``agent/issue-N``. The mapping is conventional and bidirectional, with no stored table."""

    workspaces: list[str] = Field(default_factory=list)
    """e.g. ``["backend", "frontend", "mobile"]`` — used by deps provisioning and reset lists."""

    gate_entry_point: list[str] | None = None
    tier: Tier = Tier.LAUNCH

    generated_paths: list[str] = Field(default_factory=list)
    """Conflicts here are resolved by *take base + regenerate*, never by a model.

    Drifted across three shell sites (the inbox lists four paths, the pipeline and merger
    three). One list, one behaviour.
    """

    provisioned_paths: list[str] = Field(
        default_factory=lambda: ["node_modules", ".env", ".venv", "*/node_modules"]
    )
    """Artefacts that must never enter a commit.

    Drifted across four shell sites. A directory-only ``.gitignore`` does not match a
    *symlink* named ``node_modules``, which is how provisioned symlinks got committed.
    """

    env_files: list[str] = Field(default_factory=list)
    compose_project_prefix: str = "harness"
    merge_strategy: MergeStrategy = MergeStrategy.MR_ONLY
    """Q1: MR_ONLY ships as the default; FF_ONLY is opt-in per repository."""

    build_skill: str | None = None
    """The repo's own build convention, if it has one. Never hardcoded in a prompt template."""

    protected_paths: list[str] = Field(
        default_factory=lambda: [
            ".github/workflows/**",
            "**/migrations/**",
            "**/alembic/**",
            "infra/**",
            "**/*.tf",
            "Dockerfile*",
            "docker-compose*.yml",
        ]
    )
    """Touching one of these routes to approval regardless of how green the gates are."""

    engine: str = "shell"
    """Per-repo cutover flag (``shell`` | ``python``). §24 Phase 3 flips this, and only this."""

    def branch_for(self, issue: int | str) -> str:
        return f"{self.branch_prefix}{issue}"

    def issue_from_branch(self, branch: str) -> int | None:
        import re

        match = re.search(r"issue[-/](\d+)", branch)
        return int(match.group(1)) if match else None
