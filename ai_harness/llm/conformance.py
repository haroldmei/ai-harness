"""Does this model, with this prompt, produce output the harness can use?

Everything else in Phase 7 is about making a local model *possible*. This is the measurement of
whether it is *good enough*, and it deliberately measures the cheap half — schema conformance —
because that half is where a small model fails first and fails silently. A model that returns
prose around its JSON is not obviously broken: the extraction ladder recovers it, the repair loop
recovers more, and the only symptom is that a review round takes four minutes instead of one.

Four numbers per (model, template):

* **first-pass validity** — the fraction that validated with zero repairs. This is the one that
  decides whether guided decoding is worth the flags.
* **repair rate** — repairs per call. Each repair is a full re-generation, so at 30 tok/s this is
  the difference between a fifteen-minute REVIEW and a five-minute one.
* **refusal rate** — calls that produced nothing usable after the repair budget. These escalate,
  and a model that escalates one call in ten cannot run unattended.
* **rung distribution** — which extraction rung produced the answer. All-``raw`` means the model
  emits clean JSON; a tail on ``bracket_scan`` means it is wrapping output in prose and the
  ladder is carrying it.

The baseline is committed so that a model upgrade, a prompt change or a flag change is compared
rather than merely observed (Q13, L12).
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field

from pydantic import BaseModel

from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.llm.engines.protocol import Engine, LLMRequest
from ai_harness.llm.extract import Rung
from ai_harness.llm.structured import call_structured


@dataclass(frozen=True, slots=True)
class ConformanceCase:
    """One prompt, one schema, one expected shape of answer."""

    name: str
    template_id: str
    prompt: str
    model_type: type[BaseModel]
    system: str = ""
    max_tokens: int = 2048


@dataclass(frozen=True, slots=True)
class CaseResult:
    name: str
    valid: bool
    repairs: int
    rung: Rung
    category: ErrorCategory | None = None

    @property
    def first_pass(self) -> bool:
        return self.valid and self.repairs == 0


@dataclass
class ConformanceReport:
    """What one model does with one prompt family, in numbers a baseline can be compared to."""

    model: str
    template_id: str
    guided_decoding: bool = False
    results: list[CaseResult] = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.results)

    @property
    def first_pass_rate(self) -> float:
        return self._rate(sum(1 for r in self.results if r.first_pass))

    @property
    def valid_rate(self) -> float:
        return self._rate(sum(1 for r in self.results if r.valid))

    @property
    def refusal_rate(self) -> float:
        return self._rate(sum(1 for r in self.results if not r.valid))

    @property
    def repairs_per_call(self) -> float:
        return self._rate(sum(r.repairs for r in self.results))

    @property
    def rungs(self) -> dict[str, int]:
        return dict(Counter(str(r.rung) for r in self.results if r.valid))

    def _rate(self, count: int) -> float:
        return round(count / self.total, 3) if self.total else 0.0

    def as_row(self) -> str:
        return (
            f"| {self.model} | {self.template_id} | {'yes' if self.guided_decoding else 'no'} | "
            f"{self.total} | {self.first_pass_rate:.0%} | {self.valid_rate:.0%} | "
            f"{self.repairs_per_call:.2f} | {self.refusal_rate:.0%} | "
            f"{', '.join(f'{k}:{v}' for k, v in sorted(self.rungs.items())) or '—'} |"
        )


HEADER = (
    "| model | template | guided | cases | first pass | valid | repairs/call | refused | rungs |\n"
    "|---|---|---|---:|---:|---:|---:|---:|---|"
)


async def run_conformance(
    engine: Engine,
    cases: list[ConformanceCase],
    *,
    model: str,
    repair_limit: int = 2,
) -> ConformanceReport:
    """Run every case once. Nothing is retried beyond the harness's own repair budget.

    Retrying a failed case outside the repair loop would measure the *best* of several draws,
    and what runs unattended is a single draw.
    """
    template = cases[0].template_id if cases else ""
    report = ConformanceReport(
        model=model,
        template_id=template,
        guided_decoding=engine.capabilities.native_structured_output,
    )
    for case in cases:
        request = LLMRequest(
            prompt=case.prompt,
            system=case.system,
            model=model,
            max_tokens=case.max_tokens,
            template_id=case.template_id,
            schema=case.model_type.model_json_schema(),
        )
        outcome = await call_structured(engine, request, case.model_type, repair_limit=repair_limit)
        if outcome.is_ok:
            structured = outcome.unwrap()
            report.results.append(
                CaseResult(
                    name=case.name,
                    valid=True,
                    repairs=structured.repairs,
                    rung=structured.rung,
                )
            )
        else:
            report.results.append(
                CaseResult(
                    name=case.name,
                    valid=False,
                    repairs=repair_limit,
                    rung=Rung.NONE,
                    category=outcome.category,
                )
            )
    return report


def render(reports: list[ConformanceReport], *, title: str = "Conformance") -> str:
    lines = [f"## {title}", "", HEADER]
    lines += [report.as_row() for report in reports]
    lines += [
        "",
        "`first pass` is the fraction that validated with zero repairs — the number that decides "
        "whether guided decoding earns its flags. A repair is a full re-generation, so at 30 tok/s "
        "`repairs/call` is wall-clock, not cents.",
        "",
    ]
    return "\n".join(lines)
