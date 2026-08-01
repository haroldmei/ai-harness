"""The job request and the run — the durable identity of a unit of work."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field

from ai_harness.schemas.enums import GateSet, MergeStrategy, State, Tier
from ai_harness.schemas.policy import Policy
from ai_harness.schemas.profile import RepoProfile


class JobRequest(BaseModel):
    """What a caller asks for. Validated before a lease is taken."""

    model_config = {"extra": "forbid"}

    repo: str = Field(min_length=1)
    """``owner/name`` for a forge, or a local path for a detached run."""
    issue: int | None = None
    title: str = ""
    body: str = ""
    """Untrusted content. It reaches a prompt only through the trust-fencing layer (§18.1)."""
    forge: str = "github"
    base_branch: str | None = None
    branch: str | None = None

    profile: RepoProfile = Field(default_factory=RepoProfile)
    policy: Policy = Field(default_factory=Policy)
    tier: Tier | None = None
    gate_set: GateSet = GateSet.FULL
    merge_strategy: MergeStrategy | None = None
    dry_run: bool = False
    requested_by: str = "cli"
    requested_at: datetime | None = None

    def effective_merge_strategy(self) -> MergeStrategy:
        return self.merge_strategy or self.profile.merge_strategy or self.policy.merge_strategy

    def effective_tier(self) -> Tier:
        return self.tier or self.profile.tier

    def start_state(self) -> State:
        return State.PREPARE
