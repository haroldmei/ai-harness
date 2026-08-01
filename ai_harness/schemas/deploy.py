"""Deployment contracts. The subgraph that produces these lands in Phase 6 (§20)."""

from __future__ import annotations

from pydantic import BaseModel, Field


class DeploymentResult(BaseModel):
    """What was deployed, where, and whether it answered."""

    environment: str = "dev"
    provider: str = "compose"
    project: str = ""
    """The compose project name — private per run, so two runs never share a stack."""
    url: str | None = None
    port_band: int | None = None
    """Offset per slot, never probed: two runs probing from a shared base pick the same port."""
    deployed_sha: str = ""
    healthy: bool = False
    smoke_passed: bool = False
    logs: list[str] = Field(default_factory=list)
