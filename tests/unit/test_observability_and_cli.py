"""Issues #18 and #19 — logging with redaction, and the read-only CLI."""

from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path

from typer.testing import CliRunner

from ai_harness.cli.main import EXIT_CONFIG, EXIT_NO_GATES, EXIT_OK, EXIT_RED, app
from ai_harness.kernel.clock import FrozenClock
from ai_harness.observability.logging import (
    JsonlSpanSink,
    Logger,
    MemorySink,
    configure,
    retention_days,
    summarise_cost,
)
from ai_harness.schemas.telemetry import Span

runner = CliRunner()


# ── logging ──────────────────────────────────────────────────────────────────────


def test_records_are_structured_and_carry_bound_context() -> None:
    sink = MemorySink()
    log = Logger(sink=sink, clock=FrozenClock()).bind(run_id="r1", state="REVIEW")
    log.info("gate finished", gate="unit", status="pass")
    record = sink.records[0]
    assert record["event"] == "gate finished"
    assert record["run_id"] == "r1" and record["state"] == "REVIEW"
    assert record["level"] == "info" and record["ts"].startswith("2026-01-01")


def test_a_planted_secret_never_reaches_a_sink() -> None:
    """Redaction is applied at the sink, so a caller that forgets is still safe."""
    sink = MemorySink()
    log = configure(level="info", secrets=["s3cret-value"], sink=sink)
    log.info("gate log", excerpt="connecting with token s3cret-value and ghp_" + "A" * 36)
    rendered = json.dumps(sink.records[0])
    assert "s3cret-value" not in rendered and "ghp_A" not in rendered


def test_sensitive_keys_are_masked_by_name() -> None:
    sink = MemorySink()
    Logger(sink=sink).info("call", api_key="whatever-this-is", note="fine")
    assert sink.records[0]["api_key"] != "whatever-this-is"
    assert sink.records[0]["note"] == "fine"


def test_a_broken_sink_never_fails_the_caller() -> None:
    class _Exploding:
        def write(self, record: dict[str, object]) -> None:
            raise RuntimeError("disk full")

    Logger(sink=_Exploding()).error("this must not raise")


def test_level_filtering() -> None:
    sink = MemorySink()
    log = Logger(sink=sink, level="warning")
    log.info("dropped")
    log.error("kept")
    assert [r["event"] for r in sink.records] == ["kept"]


# ── retention ────────────────────────────────────────────────────────────────────


def test_errors_and_expensive_calls_are_always_retained() -> None:
    failed = Span(span_id="s", run_id="r", name="llm", outcome="unknown")
    expensive = Span(span_id="s", run_id="r", name="llm", outcome="ok", usd=Decimal("2.29"))
    assert retention_days(failed) == 14
    assert retention_days(expensive) == 14


def test_sampling_is_deterministic_on_content() -> None:
    """The same failure must be retained or dropped consistently, not coin-flipped."""
    span = Span(
        span_id="s1",
        run_id="r",
        name="llm",
        outcome="ok",
        template_id="reviewer-v1",
        prompt_sha256="a" * 64,
    )
    twin = Span(
        span_id="s2",
        run_id="r2",
        name="llm",
        outcome="ok",
        template_id="reviewer-v1",
        prompt_sha256="a" * 64,
    )
    assert retention_days(span) == retention_days(twin)


def test_the_sample_rate_is_roughly_eight_percent() -> None:
    kept = 0
    total = 500
    for n in range(total):
        span = Span(
            span_id=f"s{n}",
            run_id="r",
            name="llm",
            outcome="ok",
            template_id=f"t{n}",
            prompt_sha256=f"{n:064d}",
        )
        kept += retention_days(span) is not None
    assert 0.02 <= kept / total <= 0.16, kept / total


def test_the_span_sink_drops_what_retention_rejects() -> None:
    sink = MemorySink()
    span_sink = JsonlSpanSink(logger=Logger(sink=sink, clock=FrozenClock()))
    span_sink.emit(Span(span_id="s", run_id="r", name="llm", outcome="unknown"))
    assert len(span_sink.kept) == 1 and sink.records
    assert sink.records[0]["retention_days"] == 14


def test_cost_summary_reports_cache_reads_separately() -> None:
    spans = [
        Span(
            span_id="a",
            run_id="r",
            name="llm",
            usd=Decimal("1.5"),
            cache_read_tokens=1000,
            template_id="reviewer-v1",
        ),
        Span(span_id="b", run_id="r", name="llm", usd=Decimal("0.5"), template_id="planner-v1"),
    ]
    summary = summarise_cost(spans)
    assert summary["usd"] == "2.0"
    assert summary["cache_read_tokens"] == 1000
    assert summary["by_template"]["reviewer-v1"] == "1.5"


# ── the CLI ──────────────────────────────────────────────────────────────────────


SPINE = """#!/usr/bin/env bash
json=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json="$2"; shift 2;;
    --tier|--only|--skip) shift 2;;
    *) shift;;
  esac
done
cat > "$json" <<'EOF'
[{"gate":"typecheck","status":"pass","reason":"","duration_s":3},
 {"gate":"lint","status":"pass","reason":"","duration_s":1}]
EOF
exit 0
"""


def _repo(tmp_path: Path, spine: str = SPINE) -> Path:
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    path = scripts / "quality-gates.sh"
    path.write_text("GATES=(typecheck lint)\n" + spine)
    path.chmod(0o755)
    return tmp_path


def test_gates_discover_reports_the_rung(tmp_path: Path) -> None:
    result = runner.invoke(app, ["gates", "discover", str(_repo(tmp_path)), "--json"])
    assert result.exit_code == EXIT_OK
    assert json.loads(result.stdout)["rung"] == "entry_point"


def test_gates_discover_exits_distinctly_when_nothing_is_found(tmp_path: Path) -> None:
    result = runner.invoke(app, ["gates", "discover", str(tmp_path)])
    assert result.exit_code == EXIT_NO_GATES
    assert "escalates" in result.stdout or "no gates discovered" in result.stdout


def test_gates_run_is_green_on_a_passing_spine(tmp_path: Path) -> None:
    result = runner.invoke(app, ["gates", "run", str(_repo(tmp_path)), "--only", "typecheck,lint"])
    assert result.exit_code == EXIT_OK
    assert "all required gates pass" in result.stdout


def test_gates_run_emits_a_schema_valid_report(tmp_path: Path) -> None:
    result = runner.invoke(
        app, ["gates", "run", str(_repo(tmp_path)), "--only", "typecheck,lint", "--json"]
    )
    payload = json.loads(result.stdout)
    assert payload["tier"] == "launch"
    assert {row["name"] for row in payload["results"]} == {"typecheck", "lint"}


def test_gates_run_is_red_when_a_required_gate_fails(tmp_path: Path) -> None:
    spine = SPINE.replace('"gate":"lint","status":"pass"', '"gate":"lint","status":"fail"')
    result = runner.invoke(
        app, ["gates", "run", str(_repo(tmp_path, spine)), "--only", "typecheck,lint"]
    )
    assert result.exit_code == EXIT_RED


def test_a_mistyped_tier_aborts_rather_than_running_a_weaker_set(tmp_path: Path) -> None:
    result = runner.invoke(app, ["gates", "run", str(_repo(tmp_path)), "--tier", "lanuch"])
    assert result.exit_code == EXIT_CONFIG
    assert "unknown tier" in result.output


def test_config_show_prints_effective_values(tmp_path: Path) -> None:
    result = runner.invoke(app, ["config", "show", str(tmp_path)])
    assert result.exit_code == 0
    assert json.loads(result.stdout)["bounds"]["pr_max_rounds"] == 4


def test_config_shell_env_is_sourceable(tmp_path: Path) -> None:
    result = runner.invoke(app, ["config", "shell-env", str(tmp_path)])
    assert "export PR_MAX_ROUNDS=4" in result.stdout
    assert "export QG_GATE_TIMEOUT=3600" in result.stdout


def test_config_policy_prints_a_shipped_policy() -> None:
    result = runner.invoke(app, ["config", "policy", "readonly"])
    assert json.loads(result.stdout)["capabilities"]["git_push"] == "deny"


def test_an_unknown_policy_name_exits_with_the_config_code() -> None:
    result = runner.invoke(app, ["config", "policy", "yolo"])
    assert result.exit_code == EXIT_CONFIG
