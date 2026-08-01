"""Loop-until-dry — the optional adversarial stage of ``VALIDATE`` (§3.16, Appendix A).

`adversarial-loop.sh` exists because a single adversarial pass finds the shallow bugs and stops.
Comprehensive coverage needs repeated rounds until the attacker comes up empty, which is a
different stopping condition from "N rounds": a counter stops in the middle of a productive
streak, and it also keeps paying for rounds after the well is dry.

So: keep going until ``dry_stop`` **consecutive** rounds add nothing new, or ``max_rounds``.
Two rounds rather than one because a single empty round is weak evidence — an attacker can miss
a whole area once and find three things in it next time.

Three properties carried over exactly:

* **Dedup across the whole run, not per round.** Findings are identified by fingerprint, and a
  finding already seen does not reset the dry counter. Deduping per round would make any
  repeatedly-reported bug an infinite loop.
* **The counter resets on *new* findings only**, which is what makes "dry" mean dry.
* **It is advisory.** The loop never fails a run by itself; it produces findings, and the gates
  and the review decide what they are worth. A stage that could fail a build on an adversarial
  opinion would make every model tantrum a red build.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ai_harness.kernel.fingerprint import fingerprint
from ai_harness.observability.logging import Logger
from ai_harness.schemas.gates import AdversarialFinding, AdversarialReport


@dataclass
class AdversarialLoop:
    """Runs an attacker repeatedly until it stops finding anything new."""

    attacker: Any
    """``async (round_number) -> list[AdversarialFinding]``. A skill, an agent, or a script."""
    max_rounds: int = 5
    dry_stop: int = 2
    logger: Logger = field(default_factory=Logger)

    async def run(self) -> AdversarialReport:
        seen: set[str] = set()
        findings: list[AdversarialFinding] = []
        dry = 0
        rounds = 0

        while rounds < self.max_rounds and dry < self.dry_stop:
            rounds += 1
            produced = list(await self.attacker(rounds))
            fresh = []
            for finding in produced:
                signature = _signature(finding)
                if signature in seen:
                    continue
                seen.add(signature)
                fresh.append(finding.model_copy(update={"fingerprint": signature}))

            if fresh:
                # Any new finding resets the counter: the attacker is still productive, and
                # stopping now would leave the deeper half of the space unexplored.
                dry = 0
                findings.extend(fresh)
            else:
                dry += 1
            self.logger.info(
                "adversarial round",
                round=rounds,
                new=len(fresh),
                dry_streak=dry,
                total=len(findings),
            )

        return AdversarialReport(
            rounds=rounds,
            findings=findings,
            dry_streak=dry,
            exhausted=rounds >= self.max_rounds and dry < self.dry_stop,
        )


def _signature(finding: AdversarialFinding) -> str:
    """Stable across rewording, so the same bug found twice is one finding."""
    computed = fingerprint(finding.title, finding.location, scope="adversarial")
    return computed.signature if computed is not None else finding.title.strip().lower()
