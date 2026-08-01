"""Smoke checks — against the **deployed** URL, never a local one.

This is the whole lesson of `canary-deploy.sh`, and it is worth stating plainly because the
mistake is so easy to make: `gcloud run deploy` sends 100% of traffic to the new revision the
moment it is Ready, so a revision that *boots* but fails its smoke check serves the broken build
to every user. The prior workflow only `exit 1`d — it never moved traffic back.

The rule that follows: smoke the URL the new code is actually reachable at. Smoking the live URL
tests the revision you are replacing, which passes every time and proves nothing.

Two smaller properties, both from the same script:

* **Retries with a delay**, because a cold revision is not a broken one — but the budget is
  bounded and every attempt is recorded, so "it eventually answered" and "it answered" are
  distinguishable afterwards.
* **A transport error is a failed check, not an exception.** A deployment that refuses
  connections is exactly what smoke exists to catch; raising there would turn the most
  important negative result into a crash.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import httpx

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.observability.logging import Logger
from ai_harness.schemas.deploy import SmokeCheck, SmokeOutcome, SmokeReport

DEFAULT_CHECKS: tuple[SmokeCheck, ...] = (
    SmokeCheck(name="root", path="/"),
    SmokeCheck(name="health", path="/health"),
)


@dataclass
class Smoker:
    """Runs checks against a deployed base URL."""

    client: httpx.AsyncClient | None = None
    clock: Clock = field(default_factory=SystemClock)
    logger: Logger = field(default_factory=Logger)

    async def run(self, base_url: str, checks: list[SmokeCheck] | None = None) -> SmokeReport:
        selected = list(checks) if checks else list(DEFAULT_CHECKS)
        if not base_url:
            return SmokeReport(
                url="",
                checks=[
                    SmokeOutcome(name=check.name, passed=False, reason="no deployed URL to smoke")
                    for check in selected
                ],
            )
        outcomes = [await self._one(base_url, check) for check in selected]
        return SmokeReport(url=base_url, checks=outcomes)

    async def _one(self, base_url: str, check: SmokeCheck) -> SmokeOutcome:
        url = f"{base_url.rstrip('/')}{check.path}"
        client = self.client or httpx.AsyncClient(timeout=check.timeout_s)
        owns = self.client is None
        status: int | None = None
        reason = ""
        try:
            for attempt in range(1, max(check.retries, 1) + 1):
                try:
                    response = await client.get(url)
                    status = response.status_code
                    if status == check.expect_status and (
                        not check.expect_body or check.expect_body in response.text
                    ):
                        return SmokeOutcome(
                            name=check.name, passed=True, status=status, attempts=attempt, url=url
                        )
                    reason = (
                        f"expected {check.expect_status}, got {status}"
                        if status != check.expect_status
                        else f"body did not contain {check.expect_body!r}"
                    )
                except httpx.HTTPError as exc:
                    # A refused connection is the finding, not an error to propagate.
                    reason = f"{type(exc).__name__}: {exc}"
                if attempt < max(check.retries, 1):
                    await self.clock.sleep(check.delay_s)
            return SmokeOutcome(
                name=check.name,
                passed=False,
                status=status,
                attempts=max(check.retries, 1),
                url=url,
                reason=reason,
            )
        finally:
            if owns:
                await client.aclose()
