"""The model registry: what is served, from which revision, and with which flags.

Two things live here, and they are the two things a serving stack usually gets wrong.

**Pinning.** A model upgrade changes the behaviour of every agent in the system at once. That is
a deployment, and the same reasoning Q13 applies to prompt templates applies with more force to
weights: a regression is only attributable if the version is. So a spec names a *revision
digest*, not a tag, and :func:`check_revision` refuses a server that loaded something else. The
failure mode this prevents is the shell harness's worst class of outage in a new costume — the
thing was running, but not the thing you thought.

**Arithmetic instead of folklore.** vLLM's flags are usually copied from a blog post written
against a different card. Here ``--max-model-len``, ``--gpu-memory-utilization`` and the KV
dtype are *derived* from three declared numbers — the weights' footprint, the KV bytes per token
and the card's VRAM — and :attr:`ServingPlan.workings` carries the derivation so the number can
be argued with. A model that does not fit says so, with both sides of the inequality, instead of
starting and OOM-ing on the first long diff.

The GPU is deliberately modelled as *one* resource with *one* resident model (L2). Nothing here
can express two co-resident models, because 24 GB cannot hold the pair this phase selected and a
config that can express an impossible state eventually reaches it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, Field, ValidationError, model_validator

from ai_harness.kernel.outcome import ErrorCategory, Outcome

BYTES_PER_GB = 1024**3

LEN_GRANULARITY = 1024
"""``max_model_len`` is rounded down to this. A window of 31 712 is a number nobody can reason
about; 31 744 is the same window and reads as a decision."""

MIN_KV_GB = 2.0
"""Below this there is no useful context left, and the honest answer is that the model does not
fit this card — not a server that starts and fails on the first real diff."""


class GpuSpec(BaseModel):
    """The card, and how much of it the harness may take."""

    model_config = {"extra": "forbid", "frozen": True}

    name: str = "RTX 4090"
    vram_gb: float = Field(default=24.0, gt=0)
    reserve_gb: float = Field(default=1.0, ge=0)
    """Left for the display server, the compositor and CUDA's own overhead. On a headless box
    this can be lowered; on a workstation somebody is also using, it cannot."""

    @property
    def usable_gb(self) -> float:
        return max(self.vram_gb - self.reserve_gb, 0.0)


class ModelSpec(BaseModel):
    """One served model. Every field is a fact about the artefact, not a preference."""

    model_config = {"extra": "forbid", "frozen": True}

    name: str = Field(min_length=1)
    """The ``--served-model-name``. This, not the repo id, is what a roster names."""
    repo_id: str = Field(min_length=1)
    revision: str = Field(min_length=7)
    """A commit digest. A tag is not a pin — it moves, and then nothing is attributable."""
    quantisation: str = "awq-4bit"
    weights_gb: float = Field(gt=0)
    kv_bytes_per_token: int = Field(gt=0)
    """Measured, or computed as ``2 * layers * kv_heads * head_dim * dtype_bytes``. Declared
    rather than inferred because inferring it requires loading the model to find out."""
    native_max_model_len: int = Field(gt=0)
    activation_gb: float = Field(default=1.5, gt=0)
    """Transient allocations during a forward pass. Not free, and not part of the KV cache."""
    kv_cache_dtype: str = "fp8"
    cap_max_model_len: int | None = Field(default=None, gt=0)
    """An operator ceiling below what the card can hold. A window the KV cache *fits* is not
    automatically a window worth using: prefill time grows with it, and on a serial GPU that
    time comes out of the same budget as the tests."""
    port: int = Field(default=8000, gt=0, lt=65536)
    roles: tuple[str, ...] = ()
    """Which roster roles this model may play. Empty means "any" — the roster still decides."""
    extra_args: tuple[str, ...] = ()

    def fits(self, gpu: GpuSpec) -> bool:
        return self.kv_budget_gb(gpu) >= MIN_KV_GB

    def kv_budget_gb(self, gpu: GpuSpec) -> float:
        return gpu.usable_gb - self.weights_gb - self.activation_gb

    def plan(self, gpu: GpuSpec) -> ServingPlan:
        """Derive the flags, and keep the derivation."""
        kv_gb = self.kv_budget_gb(gpu)
        by_cache = int(kv_gb * BYTES_PER_GB // self.kv_bytes_per_token)
        ceilings = [self.native_max_model_len, max(by_cache, 0)]
        if self.cap_max_model_len is not None:
            ceilings.append(self.cap_max_model_len)
        max_len = min(ceilings)
        max_len -= max_len % LEN_GRANULARITY
        used_gb = self.weights_gb + self.activation_gb + max(kv_gb, 0.0)
        utilisation = min(round(used_gb / gpu.vram_gb, 3), 0.97)

        workings = [
            f"{gpu.name}: {gpu.vram_gb:.1f} GB - {gpu.reserve_gb:.1f} GB reserved "
            f"= {gpu.usable_gb:.1f} GB usable",
            f"weights ({self.quantisation}) {self.weights_gb:.1f} GB + activations "
            f"{self.activation_gb:.1f} GB ⇒ {kv_gb:.1f} GB for the KV cache",
            f"{kv_gb:.1f} GB ÷ {self.kv_bytes_per_token} B/token ({self.kv_cache_dtype}) "
            f"= {by_cache} tokens the cache can hold",
            f"min(cache {by_cache}, native {self.native_max_model_len}"
            + (f", operator cap {self.cap_max_model_len}" if self.cap_max_model_len else "")
            + f") ⇒ --max-model-len {max_len}",
            f"--gpu-memory-utilization {utilisation}",
        ]
        return ServingPlan(
            spec=self, gpu=gpu, max_model_len=max_len, utilisation=utilisation, workings=workings
        )


@dataclass(frozen=True, slots=True)
class ServingPlan:
    """The flags one model is served with, and why they are those flags."""

    spec: ModelSpec
    gpu: GpuSpec
    max_model_len: int
    utilisation: float
    workings: list[str] = field(default_factory=list)

    @property
    def base_url(self) -> str:
        """Loopback, always (L3). The endpoint is not reachable off this host."""
        return f"http://127.0.0.1:{self.spec.port}/v1"

    def argv(self, *, binary: str = "vllm") -> list[str]:
        return [
            binary,
            "serve",
            self.spec.repo_id,
            "--revision",
            self.spec.revision,
            "--served-model-name",
            self.spec.name,
            "--host",
            "127.0.0.1",
            "--port",
            str(self.spec.port),
            "--max-model-len",
            str(self.max_model_len),
            "--gpu-memory-utilization",
            str(self.utilisation),
            "--kv-cache-dtype",
            self.spec.kv_cache_dtype,
            "--enable-prefix-caching",
            *self.spec.extra_args,
        ]


class RegistryError(ValueError):
    """Raised at load. A registry that cannot be trusted is never half-built."""


class ModelRegistry(BaseModel):
    """Every model this host can serve, and the card they contend for."""

    model_config = {"extra": "forbid"}

    gpu: GpuSpec = Field(default_factory=GpuSpec)
    models: list[ModelSpec] = Field(default_factory=list)

    @model_validator(mode="after")
    def _check(self) -> ModelRegistry:
        names = [m.name for m in self.models]
        duplicates = {n for n in names if names.count(n) > 1}
        if duplicates:
            raise ValueError(f"duplicate served-model name(s): {', '.join(sorted(duplicates))}")
        # Distinct ports even though only one model is ever resident: a swap that reuses a port
        # cannot be told apart from a server that failed to release it, and the difference
        # matters exactly when something has gone wrong.
        ports = [m.port for m in self.models]
        clashing = {p for p in ports if ports.count(p) > 1}
        if clashing:
            raise ValueError(
                f"port(s) {sorted(clashing)} are claimed by more than one model; a swap that "
                "reuses a port is indistinguishable from a server that failed to release it"
            )
        return self

    def get(self, name: str) -> ModelSpec:
        for spec in self.models:
            if spec.name == name:
                return spec
        raise RegistryError(
            f"no model named {name!r} in the registry (have: {', '.join(m.name for m in self.models) or '—'})"
        )

    def plan(self, name: str) -> ServingPlan:
        return self.get(name).plan(self.gpu)

    def unservable(self) -> list[tuple[ModelSpec, str]]:
        """Models that do not fit this card, with the arithmetic that says so."""
        problems: list[tuple[ModelSpec, str]] = []
        for spec in self.models:
            if not spec.fits(self.gpu):
                problems.append(
                    (
                        spec,
                        f"{spec.name} needs {spec.weights_gb:.1f} GB of weights + "
                        f"{spec.activation_gb:.1f} GB of activations, leaving "
                        f"{spec.kv_budget_gb(self.gpu):.1f} GB of KV cache on a "
                        f"{self.gpu.usable_gb:.1f} GB budget — below the {MIN_KV_GB:.1f} GB floor",
                    )
                )
        return problems

    def for_role(self, role: str) -> list[ModelSpec]:
        return [m for m in self.models if not m.roles or role in m.roles]


DEFAULT_REGISTRY_PATH = Path(".harness/models.yaml")


def load_registry(path: Path | None = None, *, root: Path | None = None) -> ModelRegistry:
    """Load and validate the registry. A bad value fails here, with its field path."""
    base = root or Path.cwd()
    file_path = path or (base / DEFAULT_REGISTRY_PATH)
    try:
        text = file_path.read_text()
    except OSError as exc:
        raise RegistryError(f"cannot read {file_path}: {exc}") from exc
    try:
        data: Any = yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:
        raise RegistryError(f"{file_path} is not valid YAML: {exc}") from exc
    if not isinstance(data, dict):
        raise RegistryError(f"{file_path} must contain a mapping at the top level")
    try:
        return ModelRegistry(**data)
    except ValidationError as exc:
        lines = [f"invalid model registry in {file_path}:"]
        for item in exc.errors():
            location = ".".join(str(part) for part in item["loc"]) or "<root>"
            lines.append(f"  {location}: {item['msg']}")
        raise RegistryError("\n".join(lines)) from exc


def check_revision(spec: ModelSpec, reported: str | None) -> Outcome[str]:
    """Confirm the server loaded the pinned revision.

    ``None`` — a server that does not report one — is a failure, not a pass. "We could not tell"
    and "it matches" are different answers, and only one of them is safe to build a week of
    autonomous merges on.
    """
    if not reported:
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            f"the server did not report a revision for {spec.name}",
            remedy=(
                "start the server with --revision so the loaded weights are attributable; "
                "an unreported revision is not the same as a matching one"
            ),
        )
    if not (reported.startswith(spec.revision) or spec.revision.startswith(reported)):
        return Outcome.fail(
            ErrorCategory.ENVIRONMENT,
            f"{spec.name} is serving revision {reported} but {spec.revision} is pinned",
            remedy="restart the serving unit, or update the pin deliberately — a model upgrade is a deployment",
            details={"expected": spec.revision, "actual": reported},
        )
    return Outcome.ok(reported)
