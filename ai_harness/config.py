"""Configuration: layered, validated at startup, and printable.

W14: the shell harness's configuration surface is **391 distinct ``${VAR:-default}`` knobs**
across ``scripts/`` and ``scripts/lib/`` (the design doc estimated ~180; the real number is
larger). None of them is validated, discoverable or documented in one place, and a typo is
discovered by the behaviour it silently changes — ``--tier lanuch`` ran a weaker gate set and
printed "all gates pass".

Here configuration is a schema. Precedence, lowest to highest:

1. defaults declared on the models;
2. ``.harness/config.yaml`` in the repository (committed, reviewable);
3. environment variables prefixed ``HARNESS_`` (``__`` nests);
4. explicit CLI arguments.

:data:`Bounds` carries every numeric bound from §3.11 in one place, and
:meth:`HarnessConfig.shell_env` renders the subset the existing shell scripts read — the
first shared-schema beachhead of Phase 0, and the reason a mixed shell/Python rollout cannot
disagree about, say, ``PR_MAX_ROUNDS``.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, Field, ValidationError
from pydantic_settings import (
    BaseSettings,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
    YamlConfigSettingsSource,
)

from ai_harness.schemas.enums import Tier
from ai_harness.schemas.policy import Policy
from ai_harness.schemas.profile import RepoProfile

DEFAULT_CONFIG_PATH = Path(".harness/config.yaml")
POLICY_DIR = Path("policies/rules")


class ConfigError(RuntimeError):
    """Raised at startup, with the field path. Never at use."""


class Bounds(BaseModel):
    """Every bound of §3.11, once.

    The shell values are the defaults, so the port starts by behaving identically. Each field
    maps to the environment variable the shell reads, in :data:`SHELL_ENV_NAMES`.
    """

    model_config = {"extra": "forbid"}

    pipeline_max_rounds: int = 10
    pipeline_rearm_max: int = 3
    pipeline_max_open_prs: int = 3
    pipeline_escalate_stuck_hours: int = 6
    pr_max_rounds: int = 4
    pr_empty_envelope_retries: int = 2
    pr_fixer_max_self_repair: int = 3
    pr_fixer_deps_max_retry: int = 3
    pr_merger_max_env_defer: int = 3
    merger_resolver_retries: int = 3
    triage_max_attempts: int = 3
    triage_max_open: int = 5
    triage_max_self_repair: int = 2
    triage_max_transient: int = 8
    gate_timeout_s: int = 3600
    cpu_jobs: int = 3
    stack_jobs: int = 2


SHELL_ENV_NAMES: dict[str, str] = {
    # Verified against scripts/*.sh — every name here is read by the shell today.
    "pipeline_max_rounds": "PIPELINE_MAX_ROUNDS",
    "pipeline_rearm_max": "PIPELINE_REARM_MAX",
    "pipeline_max_open_prs": "PIPELINE_MAX_OPEN_PRS",
    "pipeline_escalate_stuck_hours": "PIPELINE_ESCALATE_STUCK_HOURS",
    "pr_max_rounds": "PR_MAX_ROUNDS",
    "pr_empty_envelope_retries": "PR_EMPTY_ENVELOPE_RETRIES",
    "pr_fixer_max_self_repair": "PR_FIXER_MAX_SELF_REPAIR",
    "pr_fixer_deps_max_retry": "PR_FIXER_DEPS_MAX_RETRY",
    "pr_merger_max_env_defer": "PR_MERGER_MAX_ENV_DEFER",
    "merger_resolver_retries": "MERGER_RESOLVER_RETRIES",
    "triage_max_attempts": "TRIAGE_MAX_ATTEMPTS",
    "triage_max_open": "TRIAGE_MAX_OPEN",
    "triage_max_self_repair": "TRIAGE_MAX_SELF_REPAIR",
    "triage_max_transient": "TRIAGE_MAX_TRANSIENT",
    "gate_timeout_s": "QG_GATE_TIMEOUT",
    "cpu_jobs": "QG_CPU_JOBS",
    "stack_jobs": "QG_STACK_JOBS",
}


class Roster(BaseModel):
    """Which model plays which role.

    ``FR-075`` in the shell refuses to start when the reviewer and fixer models match:
    *independent review needs a different model*. The refusal lives in the roster validator
    (Phase 2) rather than in two scripts' preambles.
    """

    model_config = {"extra": "forbid"}

    engine: str = "claude-cli"
    planner_model: str = "claude-sonnet-5"
    implementer_model: str = "claude-sonnet-5"
    reviewer_model: str = "claude-opus-5"
    conflict_resolver_model: str = "claude-opus-5"
    triager_model: str = "claude-haiku-4-5-20251001"


class HarnessConfig(BaseSettings):
    """The whole effective configuration for one invocation."""

    model_config = SettingsConfigDict(
        env_prefix="HARNESS_",
        env_nested_delimiter="__",
        extra="forbid",
        validate_default=True,
    )

    repo_path: Path = Path()
    forge: str = "github"
    tier: Tier | None = None
    log_level: str = "info"
    log_format: str = "json"
    state_dir: Path = Path(".harness/state")
    lease_dir: Path = Path("/tmp/ai-harness-leases")
    database_url: str = "sqlite:///.harness/state/harness.db"
    """Q3: SQLite and Postgres behind one protocol; the local CLI needs no server."""

    profile: RepoProfile = Field(default_factory=RepoProfile)
    policy: Policy = Field(default_factory=Policy)
    bounds: Bounds = Field(default_factory=Bounds)
    roster: Roster = Field(default_factory=Roster)

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        """Precedence, highest first: CLI (init) → environment → config file → defaults.

        The file must sit *below* the environment: an operator who exports an override for one
        run should not have to edit a committed file to get it.
        """
        return (
            init_settings,
            env_settings,
            dotenv_settings,
            YamlConfigSettingsSource(settings_cls),
            file_secret_settings,
        )

    def effective_tier(self) -> Tier:
        return self.tier or self.profile.tier

    def shell_env(self) -> dict[str, str]:
        """The knobs the existing shell scripts read, rendered from this config.

        Sourcing this in the shell stages is the Phase 0 beachhead: one schema, two engines,
        no drift in the bound that decides how many rounds a PR gets.
        """
        env = {name: str(getattr(self.bounds, field)) for field, name in SHELL_ENV_NAMES.items()}
        env["TIER"] = self.effective_tier().value
        env["PR_REVIEWER_MODEL"] = self.roster.reviewer_model
        env["PR_FIXER_MODEL"] = self.roster.implementer_model
        return env

    def describe(self) -> dict[str, Any]:
        """What ``agent config show`` prints: the effective values, not the file."""
        return self.model_dump(mode="json")


def _read_yaml(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text()
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc
    try:
        data = yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:
        raise ConfigError(f"{path} is not valid YAML: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"{path} must contain a mapping at the top level")
    return data


def load_config(
    path: Path | None = None,
    *,
    root: Path | None = None,
    overrides: dict[str, Any] | None = None,
) -> HarnessConfig:
    """Load and **validate** the configuration. A bad value fails here, with its field path."""
    base = root or Path.cwd()
    file_path = path or (base / DEFAULT_CONFIG_PATH)
    if file_path.exists():
        _read_yaml(file_path)  # fail early, and blame the *file* for malformed YAML

    init: dict[str, Any] = {k: v for k, v in (overrides or {}).items() if v is not None}
    init.setdefault("repo_path", base)

    # A per-call subclass is how a dynamic path reaches the YAML source while keeping the
    # source *order* — and therefore the precedence — declared once, on the base class.
    class _Config(HarnessConfig):
        model_config = SettingsConfigDict(
            **{**HarnessConfig.model_config, "yaml_file": str(file_path)}
        )

    try:
        return _Config(**init)
    except ValidationError as exc:
        raise ConfigError(_render(exc, file_path)) from exc


def load_policy(name_or_path: str, *, root: Path | None = None) -> Policy:
    """A named shipped policy (``standard``/``permissive``/``readonly``) or a path to one."""
    base = root or Path.cwd()
    candidate = Path(name_or_path)
    if not candidate.exists():
        candidate = base / POLICY_DIR / f"{name_or_path}.yaml"
    if not candidate.exists():
        packaged = Path(__file__).parent.parent / POLICY_DIR / f"{name_or_path}.yaml"
        candidate = packaged
    if not candidate.exists():
        raise ConfigError(f"no policy named {name_or_path!r} (looked in {POLICY_DIR}/)")
    try:
        return Policy(**_read_yaml(candidate))
    except ValidationError as exc:
        raise ConfigError(_render(exc, candidate)) from exc


def load_profile(path: Path) -> RepoProfile:
    try:
        return RepoProfile(**_read_yaml(path))
    except ValidationError as exc:
        raise ConfigError(_render(exc, path)) from exc


def _render(error: ValidationError, source: Path) -> str:
    lines = [f"invalid configuration in {source}:"]
    for item in error.errors():
        location = ".".join(str(part) for part in item["loc"]) or "<root>"
        lines.append(f"  {location}: {item['msg']}")
    return "\n".join(lines)
