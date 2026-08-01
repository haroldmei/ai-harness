"""Gate contracts — where "skip is not pass" is enforced by a validator, not by a caller.

Two rules are structural here because forgetting either has already shipped red code:

* **Skip ≠ pass** (invariant 11). A gate required at this tier that returned 77 is a
  ``FAIL``. It is promoted in :class:`GateResult`'s validator so no adapter, runner or
  reporter can be the one place that forgets.
* **Allow-list vs deny-list** (§19.3). A required gate merely *absent* from ``--only`` is an
  honest skip — the deployed lanes legitimately scope to ``--only unit``. One removed via
  ``--skip`` is a failure, because that is the "dodge the hard gate" move.
"""

from __future__ import annotations

from pydantic import BaseModel, Field, model_validator

from ai_harness.schemas.enums import (
    DiscoveryRung,
    GateSelection,
    GateSet,
    GateStatus,
    Tier,
)

TIER_ORDER: tuple[Tier, ...] = (Tier.TOY, Tier.PREVIEW, Tier.LAUNCH, Tier.SCALE)


def tier_at_least(tier: Tier, minimum: Tier) -> bool:
    return TIER_ORDER.index(tier) >= TIER_ORDER.index(minimum)


class GateSpec(BaseModel):
    """One gate, as discovered or configured. Data — the harness never invents a gate."""

    name: str
    kind: str = "shell"
    command: list[str] | None = None
    workdir: str = "."
    env: dict[str, str] = Field(default_factory=dict)
    resource: str = "cpu"
    """``stack`` gates boot containers and bind ports, so they get their own semaphore."""
    timeout_s: int = 3600
    after: list[str] = Field(default_factory=list)
    required_from_tier: Tier | None = None
    advisory: bool = False
    baseline: bool = False
    flake_retries: int = 0
    """Confirmation re-runs, never blind retries."""
    artefacts: list[str] = Field(default_factory=list)

    def required_at(self, tier: Tier) -> bool:
        if self.advisory or self.required_from_tier is None:
            return False
        return tier_at_least(tier, self.required_from_tier)


class GateProfile(BaseModel):
    """The gate set for a repository, plus how it was arrived at."""

    tier: Tier = Tier.LAUNCH
    fast_set: list[str] = Field(default_factory=lambda: ["typecheck", "lint", "unit"])
    full_set: list[str] | None = None
    gates: list[GateSpec] = Field(default_factory=list)
    cpu_jobs: int = 3
    stack_jobs: int = 2
    discovered: bool = False
    rung: DiscoveryRung = DiscoveryRung.NONE
    entry_point: list[str] | None = None
    notes: list[str] = Field(default_factory=list)

    @property
    def no_gates_discovered(self) -> bool:
        """Rung 5. The run escalates; it does not merge ungated."""
        return not self.gates and self.entry_point is None

    def names_for(self, gate_set: GateSet) -> list[str]:
        if gate_set is GateSet.FAST:
            return list(self.fast_set)
        if self.full_set is not None:
            return list(self.full_set)
        return [g.name for g in self.gates]

    def required_names(self) -> set[str]:
        return {g.name for g in self.gates if g.required_at(self.tier)}


class GateResult(BaseModel):
    """One gate's outcome, with the promotion applied at construction time."""

    name: str
    raw_status: GateStatus
    required: bool = False
    selection: GateSelection = GateSelection.RAN
    reason: str = ""
    duration_s: float | None = None
    exit_code: int | None = None
    artefacts: list[str] = Field(default_factory=list)
    failing_tests: list[str] = Field(default_factory=list)
    flake_confirmed: bool = False
    inherited: bool = False
    """True when the baseline for this exact base sha already carried this failure."""

    status: GateStatus = GateStatus.PASS
    promoted: bool = False
    """Set when the validator turned a skip into a failure. Shown in the report, never hidden."""

    @model_validator(mode="after")
    def _apply_promotions(self) -> GateResult:
        status = self.raw_status
        promoted = False

        if status is GateStatus.SKIP and self.required:
            if self.selection is GateSelection.NOT_SELECTED:
                # Honest skip: the caller scoped the run and never claimed this gate ran.
                pass
            else:
                # Ran and returned 77 (tooling/inputs absent), or was deny-listed away.
                status = GateStatus.FAIL
                promoted = True
        elif status is GateStatus.SKIP and self.selection is GateSelection.DENY_LISTED:
            promoted = False

        if status in (GateStatus.TIMEOUT, GateStatus.ERROR):
            status = GateStatus.FAIL

        object.__setattr__(self, "status", status)
        object.__setattr__(self, "promoted", promoted)
        if promoted and not self.reason:
            object.__setattr__(
                self,
                "reason",
                "required at this tier but did not run — a skipped required check is a failure",
            )
        return self

    @property
    def green(self) -> bool:
        return self.status in (GateStatus.PASS, GateStatus.SKIP) or self.inherited


class GateReport(BaseModel):
    """The verdict for one commit under one gate set."""

    commit_sha: str = ""
    base_sha: str = ""
    tier: Tier = Tier.LAUNCH
    gate_set: GateSet = GateSet.FULL
    results: list[GateResult] = Field(default_factory=list)
    wall_clock_s: float = 0.0
    gate_time_s: float = 0.0
    profile_discovered: bool = False
    no_gates_discovered: bool = False

    @property
    def failures(self) -> list[GateResult]:
        return [r for r in self.results if r.status is GateStatus.FAIL and not r.inherited]

    @property
    def required_failures(self) -> list[GateResult]:
        return [r for r in self.failures if r.required]

    @property
    def green(self) -> bool:
        """No required gate failed, and nothing was silently missing.

        A report with no gates at all is **not** green: rung 5 escalates rather than
        merging ungated.
        """
        if self.no_gates_discovered or not self.results:
            return False
        return not self.required_failures

    @property
    def speedup(self) -> float:
        return self.gate_time_s / self.wall_clock_s if self.wall_clock_s > 0 else 1.0

    def by_name(self, name: str) -> GateResult | None:
        return next((r for r in self.results if r.name == name), None)

    def regression_against(self, base: GateReport) -> list[GateResult]:
        """The failures this branch *adds* — the only ones it can be blamed for."""
        base_failing = {r.name for r in base.failures}
        return [r for r in self.failures if r.name not in base_failing]


class GateIntegrityCheck(BaseModel):
    """The anti-weakening check (§19.5). Any non-empty field is blocking, gates or no gates."""

    deleted_tests: list[str] = Field(default_factory=list)
    skipped_tests: list[str] = Field(default_factory=list)
    weakened_assertions: list[str] = Field(default_factory=list)
    loosened_config: list[str] = Field(default_factory=list)
    ci_modified: bool = False

    @property
    def clean(self) -> bool:
        return not (
            self.deleted_tests
            or self.skipped_tests
            or self.weakened_assertions
            or self.loosened_config
            or self.ci_modified
        )

    def evidence(self) -> list[str]:
        out: list[str] = []
        out += [f"deleted test: {t}" for t in self.deleted_tests]
        out += [f"newly skipped: {t}" for t in self.skipped_tests]
        out += [f"weakened assertions: {t}" for t in self.weakened_assertions]
        out += [f"loosened config: {t}" for t in self.loosened_config]
        if self.ci_modified:
            out.append("CI configuration modified")
        return out


class AdversarialFinding(BaseModel):
    """One thing an adversarial pass found. Advisory: it informs, it does not fail a build."""

    title: str
    location: str = ""
    """``path:line`` where the finding lives, when it has one."""
    severity: str = "p2"
    repro_test: str = ""
    """The path to a failing test that demonstrates it.

    `adversarial-loop.sh` requires this for a finding to count, and so does the scout's bug
    engine: a bug nobody can reproduce is a claim, and a claim costs more to triage than it
    saves. Empty here means the finding is reported but carries no evidence anyone can run.
    """
    body: str = ""
    fingerprint: str = ""

    @property
    def reproducible(self) -> bool:
        return bool(self.repro_test)


class AdversarialReport(BaseModel):
    """What the loop-until-dry stage concluded."""

    rounds: int = 0
    findings: list[AdversarialFinding] = Field(default_factory=list)
    dry_streak: int = 0
    exhausted: bool = False
    """True when the round cap stopped it rather than the attacker running dry.

    Reported rather than hidden: "we stopped looking" and "there was nothing left to find" are
    very different states to hand to a reviewer, and a bare finding count conflates them.
    """

    @property
    def reproducible(self) -> list[AdversarialFinding]:
        return [finding for finding in self.findings if finding.reproducible]
