"""Issue #16 — the diagnostic line, against real runner output."""

from __future__ import annotations

from pathlib import Path

import pytest

from ai_harness.quality.reason import (
    NO_DIAGNOSTIC,
    failing_test_ids,
    looks_environmental,
    reason_lines,
    reason_summary,
)

LOGS = Path(__file__).resolve().parents[1] / "fixtures" / "gate_logs"


def _log(name: str) -> str:
    return (LOGS / name).read_text()


def test_a_passing_line_is_never_the_reason_a_gate_failed() -> None:
    """`tail -n1` reported "✓ release-train guards" as the reason `unit` failed."""
    summary = reason_summary(_log("pytest_failure.log"))
    assert "release-train guards" not in summary
    assert "test_invoice_totals_include_tax" in summary or "AssertionError" in summary


def test_a_passing_tests_warning_record_is_filtered_out() -> None:
    """A warning-level structured record containing 'Traceback' is not a failure reason."""
    summary = reason_summary(_log("pytest_failure.log"))
    assert "Sentry" not in summary
    assert all("Sentry" not in line for line in reason_lines(_log("pytest_failure.log")))


def test_the_strong_set_beats_a_broad_match_earlier_in_the_file() -> None:
    lines = reason_lines(_log("pytest_failure.log"))
    assert lines[0].lstrip().startswith(("E ", "FAILED", "✗")), lines[0]


def test_vitest_failures_are_extracted() -> None:
    ids = failing_test_ids(_log("vitest_failure.log"))
    assert "src/components/Cart.test.tsx::applies the discount code" in ids


def test_pytest_failures_are_extracted() -> None:
    ids = failing_test_ids(_log("pytest_failure.log"))
    assert "backend/tests/test_billing.py::test_invoice_totals_include_tax" in ids


def test_playwright_failures_are_extracted() -> None:
    ids = failing_test_ids(_log("playwright_failure.log"))
    assert any("checkout.spec.ts" in i for i in ids)


def test_passing_tests_are_never_extracted_as_failures() -> None:
    ids = failing_test_ids(_log("vitest_failure.log"))
    assert not any("format.test.ts" in i for i in ids)


def test_docker_starvation_is_environmental_not_a_defect() -> None:
    """Invariant 10: "the tooling could not run" is a third outcome."""
    log = _log("docker_starvation.log")
    assert looks_environmental(log)
    assert "Docker daemon" in reason_summary(log)


def test_an_unrecognisable_log_says_so_rather_than_guessing() -> None:
    assert reason_summary("") == NO_DIAGNOSTIC


def test_a_colon_in_the_reason_cannot_shift_the_record_fields() -> None:
    """quality-gates.sh packs results colon-delimited and splits with IFS=':'."""
    assert ":" not in reason_summary("E   AssertionError: expected 200: got 500")


@pytest.mark.parametrize(
    "name", ["pytest_failure.log", "vitest_failure.log", "playwright_failure.log"]
)
def test_extraction_is_deterministic(name: str) -> None:
    log = _log(name)
    assert failing_test_ids(log) == failing_test_ids(log)
    assert reason_summary(log) == reason_summary(log)
