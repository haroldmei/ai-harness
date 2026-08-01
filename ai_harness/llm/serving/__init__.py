"""Serving — the model as local infrastructure rather than someone else's API.

Until Phase 7 the model was a URL and a credential. It is now a process on this box holding
17 GB of VRAM, and the facts that decide whether it works — which revision is loaded, how much
cache is left for context, whether it is *ready* rather than merely *running* — are facts about
this machine. This package owns them.
"""

from ai_harness.llm.serving.health import HealthClient, ServerHealth
from ai_harness.llm.serving.models import (
    GpuSpec,
    ModelRegistry,
    ModelSpec,
    ServingPlan,
    load_registry,
)

__all__ = [
    "GpuSpec",
    "HealthClient",
    "ModelRegistry",
    "ModelSpec",
    "ServerHealth",
    "ServingPlan",
    "load_registry",
]
