"""Structured logging, with redaction on the write path.

OpenTelemetry export is deliberately deferred to Phase 5 — JSON logs suffice below ~10 runs a
day — but the *fields* are fixed now, because they become the span attributes later and a
rename after the fact loses history.

Two contracts, both taken from the shell harness and both tested rather than trusted:

* **Redaction happens here**, at the sink, not at each call site. A secret that reaches a log
  record has already escaped; a caller who forgets to redact must still be safe.
* **Telemetry never fails the caller.** A broken sink is logged nowhere and swallowed —
  losing a log line is survivable, losing a run because logging raised is not.

Retention is conditional, exactly as ``lib/agent-trace.sh`` had it: errors and expensive calls
for 14 days, a deterministic ~8% content-hash sample for 3 days, the rest dropped at the end of
the tick. The sample is content-hashed rather than random so the *same* failure is retained or
dropped consistently across runs.
"""

from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any, Protocol, TextIO

from ai_harness.kernel.clock import Clock, SystemClock
from ai_harness.kernel.redaction import Redactor
from ai_harness.schemas.telemetry import Span

LEVELS = {"debug": 10, "info": 20, "warning": 30, "error": 40}

ERROR_TTL_DAYS = 14
SAMPLE_TTL_DAYS = 3
SAMPLE_RATE = 0.08


class LogSink(Protocol):
    def write(self, record: dict[str, Any]) -> None: ...


@dataclass
class StreamSink:
    """One JSON object per line. The default, and what CI reads."""

    stream: TextIO = field(default_factory=lambda: sys.stderr)

    def write(self, record: dict[str, Any]) -> None:
        self.stream.write(json.dumps(record, default=str) + "\n")
        self.stream.flush()


@dataclass
class MemorySink:
    """Collects records. Used by the tests that assert a secret never reaches a sink."""

    records: list[dict[str, Any]] = field(default_factory=list)

    def write(self, record: dict[str, Any]) -> None:
        self.records.append(record)


@dataclass
class Logger:
    """A logger bound to a context. ``bind`` returns a new logger; nothing is global."""

    sink: LogSink = field(default_factory=StreamSink)
    redactor: Redactor = field(default_factory=Redactor)
    clock: Clock = field(default_factory=SystemClock)
    level: str = "info"
    context: dict[str, Any] = field(default_factory=dict)

    def bind(self, **fields: Any) -> Logger:
        return Logger(
            sink=self.sink,
            redactor=self.redactor,
            clock=self.clock,
            level=self.level,
            context={**self.context, **fields},
        )

    def log(self, level: str, event: str, **fields: Any) -> None:
        if LEVELS.get(level, 0) < LEVELS.get(self.level, 20):
            return
        try:
            record = {
                "ts": self.clock.now().isoformat(),
                "level": level,
                "event": self.redactor.text(event),
                **{k: self.redactor.field(k, v) for k, v in {**self.context, **fields}.items()},
            }
            self.sink.write(record)
        except Exception:  # telemetry never fails the caller
            return

    def debug(self, event: str, **fields: Any) -> None:
        self.log("debug", event, **fields)

    def info(self, event: str, **fields: Any) -> None:
        self.log("info", event, **fields)

    def warning(self, event: str, **fields: Any) -> None:
        self.log("warning", event, **fields)

    def error(self, event: str, **fields: Any) -> None:
        self.log("error", event, **fields)


def retention_days(span: Span) -> int | None:
    """How long to keep a span, or ``None`` to drop it at the end of the tick.

    An error or an expensive call is always kept — those are the ones an operator comes back
    for. The rest are sampled on a content hash so the decision is stable and reproducible.
    """
    if span.outcome not in (None, "ok"):
        return ERROR_TTL_DAYS
    if span.expensive:
        return ERROR_TTL_DAYS
    material = f"{span.template_id}:{span.prompt_sha256}:{span.name}".encode()
    bucket = int(hashlib.sha256(material).hexdigest()[:8], 16) / 0xFFFFFFFF
    return SAMPLE_TTL_DAYS if bucket < SAMPLE_RATE else None


@dataclass
class JsonlSpanSink:
    """Writes spans as JSONL, applying the retention decision and redacting attributes."""

    logger: Logger
    kept: list[Span] = field(default_factory=list)
    dropped: int = 0

    def emit(self, span: Span) -> None:
        try:
            ttl = retention_days(span)
            if ttl is None:
                self.dropped += 1
                return
            self.kept.append(span)
            payload = span.model_dump(mode="json")
            payload["retention_days"] = ttl
            self.logger.log("info", "span", **payload)
        except Exception:  # the same contract: never fail the caller
            return


def summarise_cost(spans: list[Span]) -> dict[str, Any]:
    """What ``agent cost`` reports for a set of spans.

    Cache reads are reported separately because they are the dominant saving across the
    review⇄fix rounds, and a report that hides them makes stable-prefix work look worthless.
    """
    total = sum((s.usd for s in spans), Decimal(0))
    return {
        "calls": len(spans),
        "usd": str(total),
        "input_tokens": sum(s.input_tokens for s in spans),
        "output_tokens": sum(s.output_tokens for s in spans),
        "cache_read_tokens": sum(s.cache_read_tokens for s in spans),
        "by_template": {
            template: str(sum((s.usd for s in spans if s.template_id == template), Decimal(0)))
            for template in sorted({s.template_id or "" for s in spans})
        },
    }


def configure(
    *,
    level: str = "info",
    secrets: list[str] | None = None,
    sink: LogSink | None = None,
    clock: Clock | None = None,
) -> Logger:
    """Build the root logger. Called once, at startup, from the CLI."""
    return Logger(
        sink=sink or StreamSink(),
        redactor=Redactor(secrets or []),
        clock=clock or SystemClock(),
        level=level if level in LEVELS else "info",
    )


def now_iso(clock: Clock | None = None) -> str:
    return (clock or SystemClock()).now().isoformat()


__all__ = [
    "JsonlSpanSink",
    "LogSink",
    "Logger",
    "MemorySink",
    "StreamSink",
    "configure",
    "retention_days",
    "summarise_cost",
]
