"""Metrics — the four questions an operator actually asks.

§26's ordering principle: *build the thing that makes failures visible before the thing that
makes failures rarer.* These are the numbers that make a fleet inspectable rather than merely
running:

* **what is stuck** — runs by state and status, and how long they have been there;
* **what is expensive** — cost per merged MR, which is the number §24.1 wants for the "cost
  increases" risk row and the only one that compares the two engines fairly;
* **what is flaky** — gate pass rates and confirmed flakes;
* **what is broken upstream** — dependency breaker states, so an outage is one glance rather
  than a hundred deferred runs.

Deliberately dependency-free: counters and gauges in memory, rendered as Prometheus text or as
JSON. A metrics backend is a deployment decision, and this makes either possible without
choosing one here.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from decimal import Decimal

from ai_harness.schemas.enums import Disposition, GateStatus, RunStatus, State
from ai_harness.schemas.gates import GateReport
from ai_harness.schemas.run import Run

Labels = tuple[tuple[str, str], ...]


def _labels(**pairs: str) -> Labels:
    return tuple(sorted(pairs.items()))


@dataclass
class Metrics:
    """Counters, gauges and histograms, with no client library attached."""

    counters: dict[tuple[str, Labels], float] = field(default_factory=lambda: defaultdict(float))
    gauges: dict[tuple[str, Labels], float] = field(default_factory=dict)
    observations: dict[tuple[str, Labels], list[float]] = field(
        default_factory=lambda: defaultdict(list)
    )

    def increment(self, name: str, value: float = 1.0, **labels: str) -> None:
        self.counters[(name, _labels(**labels))] += value

    def set(self, name: str, value: float, **labels: str) -> None:
        self.gauges[(name, _labels(**labels))] = value

    def observe(self, name: str, value: float, **labels: str) -> None:
        self.observations[(name, _labels(**labels))].append(value)

    # ── the four questions ───────────────────────────────────────────────────────

    def record_runs(self, runs: list[Run]) -> None:
        """What is stuck, and where."""
        by_position: dict[tuple[str, str], int] = defaultdict(int)
        for run in runs:
            if run.disposition is not None:
                self.increment("harness_runs_finished_total", disposition=run.disposition.value)
                continue
            by_position[(run.state.value, run.status.value)] += 1
        for state in State:
            for status in RunStatus:
                self.set(
                    "harness_runs_active",
                    by_position.get((state.value, status.value), 0),
                    state=state.value,
                    status=status.value,
                )

    def record_gate_report(self, report: GateReport) -> None:
        """What is flaky, and what is merely red."""
        for result in report.results:
            self.increment(
                "harness_gate_results_total",
                gate=result.name,
                status=result.status.value,
                required=str(result.required).lower(),
            )
            if result.flake_confirmed:
                self.increment("harness_gate_flakes_total", gate=result.name)
            if result.promoted:
                self.increment("harness_gate_promotions_total", gate=result.name)
            if result.duration_s is not None:
                self.observe("harness_gate_duration_seconds", result.duration_s, gate=result.name)
        self.observe("harness_suite_wall_clock_seconds", report.wall_clock_s)
        self.set("harness_suite_speedup", report.speedup)

    def record_state_duration(self, state: State, seconds: float, *, outcome: str) -> None:
        self.observe("harness_state_duration_seconds", seconds, state=state.value, outcome=outcome)

    def record_cost(self, usd: Decimal, *, repo: str, state: str, model: str) -> None:
        self.increment("harness_cost_usd_total", float(usd), repo=repo, state=state, model=model)

    def record_gpu(self, reading: object, *, gpu: str = "0") -> None:
        """The card, on the exporter that already exists (#93).

        Nothing here fails when a field is absent: a box without `nvidia-smi` produces an empty
        reading, and an empty reading produces no series rather than a zero. A zero would read
        as "the card is idle", which is a different and much worse claim than "we did not look".
        """
        for name, attribute in (
            ("gpu_utilisation_pct", "utilisation_pct"),
            ("gpu_memory_used_mb", "memory_used_mb"),
            ("gpu_memory_free_mb", "memory_free_mb"),
            ("gpu_temperature_c", "temperature_c"),
            ("gpu_power_w", "power_w"),
        ):
            value = getattr(reading, attribute, None)
            if value is not None:
                self.set(name, float(value), gpu=gpu)
        if getattr(reading, "available", False):
            self.set(
                "gpu_throttling", 1.0 if getattr(reading, "throttling", False) else 0.0, gpu=gpu
            )

    def record_serving(self, metrics: object, *, model: str) -> None:
        """The serving stack's own numbers, on our exporter rather than in a second system."""
        values = getattr(metrics, "values", {})
        for name, value in values.items():
            self.set(name, float(value), model=model)
        mean_ttft = getattr(metrics, "mean_ttft_s", None)
        if mean_ttft is not None:
            self.set("serving_ttft_seconds_mean", float(mean_ttft), model=model)

    def record_swap(self, *, from_model: str, to_model: str, seconds: float) -> None:
        """Time spent loading weights rather than generating — the price of L2, kept visible."""
        self.increment("model_swaps_total", 1.0, from_model=from_model or "-", to_model=to_model)
        self.observe("model_swap_seconds", seconds, to_model=to_model)

    def record_breakers(self, snapshot: dict[str, str]) -> None:
        """What is broken upstream — one glance instead of a hundred deferred runs."""
        for dependency, state in snapshot.items():
            self.set(
                "harness_breaker_open",
                1.0 if state == "open" else 0.0,
                dependency=dependency,
            )

    # ── the number that compares two engines fairly ──────────────────────────────

    def cost_per_merged(self, runs: list[Run]) -> Decimal:
        """Total spend divided by the changes that actually landed.

        Cost per *run* flatters whichever engine escalates more, because an escalated run is
        cheap and useless. §24.1's "cost increases" risk row needs this one.
        """
        merged = [r for r in runs if r.disposition in (Disposition.MERGED, Disposition.DELIVERED)]
        if not merged:
            return Decimal(0)
        total = sum((r.spend_usd for r in runs), Decimal(0))
        return total / len(merged)

    # ── rendering ────────────────────────────────────────────────────────────────

    def render_prometheus(self) -> str:
        lines: list[str] = []
        for (name, labels), value in sorted(self.counters.items()):
            lines.append(f"{name}{_render_labels(labels)} {value}")
        for (name, labels), value in sorted(self.gauges.items()):
            lines.append(f"{name}{_render_labels(labels)} {value}")
        for (name, labels), values in sorted(self.observations.items()):
            if not values:
                continue
            lines.append(f"{name}_count{_render_labels(labels)} {len(values)}")
            lines.append(f"{name}_sum{_render_labels(labels)} {sum(values)}")
        return "\n".join(lines) + "\n"

    def snapshot(self) -> dict[str, float]:
        flat: dict[str, float] = {}
        for (name, labels), value in {**self.counters, **self.gauges}.items():
            flat[f"{name}{_render_labels(labels)}"] = value
        return flat


def _render_labels(labels: Labels) -> str:
    if not labels:
        return ""
    rendered = ",".join(f'{key}="{value}"' for key, value in labels)
    return "{" + rendered + "}"


def gate_pass_rate(reports: list[GateReport], gate: str) -> float:
    """How often this gate passes when it runs. A gate below ~90% is a gate nobody trusts."""
    ran = [r.by_name(gate) for r in reports]
    seen = [result for result in ran if result is not None and result.status is not GateStatus.SKIP]
    if not seen:
        return 0.0
    return sum(1 for result in seen if result.green) / len(seen)
