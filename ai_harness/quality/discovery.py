"""The gate discovery ladder — *discover, do not invent* (§19.1).

The repository owns its gates. The harness finds them, orders them, runs them and interprets
them; it may *add* tests but never *weaken* what exists, and it never writes CI configuration
autonomously (Q9 — a proposal goes in the MR body instead).

Five rungs, most authoritative first. Rung 5 is a hard rule: **a repository with no
discoverable gate is not one the harness can autonomously deliver into.** It can still open an
MR under ``MR_ONLY``, carrying an explicit ``no_gates_discovered`` banner on the evidence
block — what it cannot do is merge ungated.

Provenance travels with the profile: anything inferred from CI config or a manifest is marked
``discovered``, and that mark reaches the checkpoint and the MR.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from ai_harness.quality.registry import build_profile
from ai_harness.schemas.enums import DiscoveryRung, Tier
from ai_harness.schemas.gates import GateProfile, GateSpec

HARNESS_CONFIG = Path(".harness/gates.yaml")

ENTRY_POINTS: tuple[tuple[str, list[str]], ...] = (
    ("scripts/quality-gates.sh", ["bash", "scripts/quality-gates.sh"]),
    ("Makefile", ["make", "check"]),
    ("justfile", ["just", "ci"]),
    ("tox.ini", ["tox"]),
    ("noxfile.py", ["nox"]),
)


@dataclass(frozen=True, slots=True)
class Discovery:
    """The profile, the rung that produced it, and why the rungs above it did not match."""

    profile: GateProfile
    rung: DiscoveryRung
    considered: list[str]

    @property
    def escalates(self) -> bool:
        return self.rung is DiscoveryRung.NONE


def discover(root: str | Path, *, tier: Tier = Tier.LAUNCH) -> Discovery:
    """Walk the ladder. Pure: the same tree always yields the same profile."""
    base = Path(root)
    considered: list[str] = []

    explicit = _from_harness_config(base, tier)
    if explicit is not None:
        return Discovery(explicit, DiscoveryRung.HARNESS_CONFIG, considered)
    considered.append(f"{HARNESS_CONFIG} not present")

    entry = _from_entry_point(base, tier)
    if entry is not None:
        return Discovery(entry, DiscoveryRung.ENTRY_POINT, considered)
    considered.append("no gate entry point (quality-gates.sh, make check, just ci, tox, nox)")

    ci = _from_ci_config(base, tier)
    if ci is not None:
        return Discovery(ci, DiscoveryRung.CI_CONFIG, considered)
    considered.append("no parseable CI workflow")

    manifest = _from_manifest(base, tier)
    if manifest is not None:
        return Discovery(manifest, DiscoveryRung.MANIFEST, considered)
    considered.append("no recognisable manifest (pyproject.toml, package.json, go.mod, Cargo.toml)")

    return Discovery(GateProfile(tier=tier), DiscoveryRung.NONE, considered)


def _from_harness_config(base: Path, tier: Tier) -> GateProfile | None:
    path = base / HARNESS_CONFIG
    if not path.exists():
        return None
    data = yaml.safe_load(path.read_text()) or {}
    if not isinstance(data, dict):
        return None
    profile = GateProfile(**data)
    return profile.model_copy(
        update={
            "tier": Tier(data.get("tier", tier)),
            "discovered": False,
            "rung": DiscoveryRung.HARNESS_CONFIG,
        }
    )


def _from_entry_point(base: Path, tier: Tier) -> GateProfile | None:
    for marker, command in ENTRY_POINTS:
        path = base / marker
        if not path.exists():
            continue
        if marker == "Makefile" and "check:" not in path.read_text():
            continue
        if marker == "justfile" and "ci:" not in path.read_text():
            continue
        names = _shell_registry_names(path) if marker.endswith("quality-gates.sh") else []
        profile = build_profile(names, tier=tier) if names else GateProfile(tier=tier)
        return profile.model_copy(
            update={
                "entry_point": command,
                "discovered": False,
                "rung": DiscoveryRung.ENTRY_POINT,
                "notes": [f"gate entry point: {' '.join(command)}"],
            }
        )
    return None


def _shell_registry_names(path: Path) -> list[str]:
    """Read the ``GATES=(…)`` registry so the adapter knows what it may ask for."""
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("GATES=("):
            inner = stripped[len("GATES=(") :].rstrip(")")
            return [name for name in inner.split() if name]
    return []


def _from_ci_config(base: Path, tier: Tier) -> GateProfile | None:
    specs: list[GateSpec] = []
    for workflow in sorted((base / ".github/workflows").glob("*.yml")) + sorted(
        (base / ".github/workflows").glob("*.yaml")
    ):
        specs += _specs_from_github_workflow(workflow)
    gitlab = base / ".gitlab-ci.yml"
    if gitlab.exists():
        specs += _specs_from_gitlab(gitlab)
    if not specs:
        return None
    return GateProfile(
        tier=tier,
        gates=specs,
        full_set=[s.name for s in specs],
        discovered=True,
        rung=DiscoveryRung.CI_CONFIG,
        notes=["inferred from CI configuration — requiredness is a guess, not a contract"],
    )


def _specs_from_github_workflow(path: Path) -> list[GateSpec]:
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError:
        return []
    if not isinstance(data, dict):
        return []
    specs: list[GateSpec] = []
    for job_name, job in (data.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            run = step.get("run")
            if not run:
                continue
            label = str(step.get("name") or job_name)
            specs.append(
                GateSpec(
                    name=_slug(f"{job_name}-{label}"),
                    kind="shell",
                    command=["bash", "-lc", str(run)],
                )
            )
    return specs


def _specs_from_gitlab(path: Path) -> list[GateSpec]:
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError:
        return []
    if not isinstance(data, dict):
        return []
    specs: list[GateSpec] = []
    for name, job in data.items():
        if not isinstance(job, dict) or "script" not in job:
            continue
        script = job["script"]
        lines = script if isinstance(script, list) else [script]
        specs.append(
            GateSpec(
                name=_slug(str(name)), kind="shell", command=["bash", "-lc", " && ".join(lines)]
            )
        )
    return specs


def _from_manifest(base: Path, tier: Tier) -> GateProfile | None:
    specs: list[GateSpec] = []

    pyproject = base / "pyproject.toml"
    if pyproject.exists():
        text = pyproject.read_text()
        if "pytest" in text:
            specs.append(GateSpec(name="unit", kind="pytest", command=["pytest"]))
        if "ruff" in text:
            specs.append(GateSpec(name="lint", kind="shell", command=["ruff", "check", "."]))
        if "mypy" in text:
            specs.append(GateSpec(name="typecheck", kind="shell", command=["mypy"]))

    package_json = base / "package.json"
    if package_json.exists():
        try:
            scripts = (json.loads(package_json.read_text()) or {}).get("scripts") or {}
        except (OSError, json.JSONDecodeError):
            scripts = {}
        for script_name, gate_name in (
            ("test", "unit"),
            ("lint", "lint"),
            ("typecheck", "typecheck"),
            ("build", "build"),
        ):
            if script_name in scripts:
                specs.append(
                    GateSpec(name=gate_name, kind="shell", command=["npm", "run", script_name])
                )

    if (base / "go.mod").exists():
        specs.append(GateSpec(name="unit", kind="go_test", command=["go", "test", "./..."]))
    if (base / "Cargo.toml").exists():
        specs.append(GateSpec(name="unit", kind="shell", command=["cargo", "test"]))

    if not specs:
        return None

    deduped: dict[str, GateSpec] = {}
    for spec in specs:
        deduped.setdefault(spec.name, spec)
    ordered = list(deduped.values())
    return GateProfile(
        tier=tier,
        gates=ordered,
        full_set=[s.name for s in ordered],
        discovered=True,
        rung=DiscoveryRung.MANIFEST,
        notes=["inferred from the package manifest — no explicit gate contract exists"],
    )


def _slug(value: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "-" for c in value.strip().lower()).strip("-")


def describe(discovery: Discovery) -> dict[str, Any]:
    """What ``agent gates discover`` prints: the rung, and why the higher rungs did not match."""
    return {
        "rung": discovery.rung.value,
        "gates": [g.name for g in discovery.profile.gates],
        "entry_point": discovery.profile.entry_point,
        "inferred": discovery.profile.discovered,
        "considered": discovery.considered,
        "escalates": discovery.escalates,
        "notes": discovery.profile.notes,
    }
