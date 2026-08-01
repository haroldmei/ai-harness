"""``ScriptedLLM`` — the direct descendant of the ``claude`` stub in ``scripts/*.test.sh``.

Every suite that needs a model uses this: recorded envelopes, keyed by ``template_id`` and
call ordinal, replayed in order. Zero network, zero cost, and completely deterministic — which
is what makes it possible to assert on *decisions* rather than on plausible-looking text.

:data:`PATHOLOGICAL` is the library of shapes that actually broke the shell harness. Every one
of them has an assertion somewhere in the suite.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ai_harness.kernel.outcome import Outcome
from ai_harness.llm.engines.protocol import (
    Completion,
    EngineCapabilities,
    LLMRequest,
    Usage,
    classify_envelope,
)


@dataclass
class Envelope:
    """A recorded provider response, at the transport level."""

    stdout: bytes = b""
    stderr: bytes = b""
    exit_code: int = 0

    @classmethod
    def result(cls, text: str, **fields: object) -> Envelope:
        """A successful ``claude -p --output-format json`` envelope carrying ``text``."""
        import json

        payload: dict[str, object] = {"type": "result", "is_error": False, "result": text}
        payload.update(fields)
        return cls(stdout=json.dumps(payload).encode())

    @classmethod
    def error(cls, **fields: object) -> Envelope:
        import json

        payload: dict[str, object] = {"type": "result", "is_error": True}
        payload.update(fields)
        return cls(stdout=json.dumps(payload).encode())


PATHOLOGICAL: dict[str, Envelope] = {
    # The CLI exited 0 without serialising its JSON. Learned nothing — retry, bounded (#2407).
    "empty_envelope": Envelope(stdout=b"", exit_code=0),
    "rate_limited": Envelope.error(api_error_status=429, result="rate limit exceeded"),
    "overloaded": Envelope.error(api_error_status=529, result="overloaded"),
    "auth_rejected": Envelope.error(api_error_status=401, result="invalid api key"),
    "fenced_json": Envelope.result('```json\n{"verdict": "approve", "summary": "ok"}\n```'),
    # The #2419 shape: pretty-printed bare object that a naive range extractor cut to "{".
    "pretty_bare_object": Envelope.result('{\n  "verdict": "approve",\n  "summary": "fine"\n}'),
    "self_contradiction": Envelope.result(
        '{"verdict": "approve", "summary": "ok", "findings": ['
        '{"severity": "blocker", "title": "race", "file": "a.py", "line": 9}]}'
    ),
    "prose_wrapped": Envelope.result(
        'Here is my review:\n{"verdict": "request_changes", "summary": "needs work"}\nHope that helps!'
    ),
    "truncated": Envelope.result('{"verdict": "appr'),
    "brace_only": Envelope.result("{"),
    "not_json": Envelope(stdout=b"Segmentation fault", exit_code=139),
    "braces_in_strings": Envelope.result(
        '{"verdict": "comment", "summary": "use {} sparingly, prefer [] here"}'
    ),
}


@dataclass
class ScriptedLLM:
    """Replays envelopes. ``script`` maps ``template_id`` to the responses for that template."""

    script: dict[str, list[Envelope]] = field(default_factory=dict)
    default: list[Envelope] = field(default_factory=list)
    name: str = "scripted"
    capabilities: EngineCapabilities = field(
        default_factory=lambda: EngineCapabilities(reports_cost=True)
    )
    calls: list[LLMRequest] = field(default_factory=list)
    _cursor: dict[str, int] = field(default_factory=dict)

    async def complete(self, request: LLMRequest) -> Outcome[Completion]:
        self.calls.append(request)
        envelopes = self.script.get(request.template_id)
        # The default list is a single ordered script, keyed once: a repair carries a derived
        # template id ("…+repair"), and keying the cursor by that id would replay the first
        # envelope forever instead of advancing to the model's next answer.
        cursor_key = request.template_id if envelopes else "__default__"
        envelopes = envelopes or self.default
        if not envelopes:
            raise AssertionError(
                f"ScriptedLLM has no envelope for template {request.template_id!r} "
                f"(call {len(self.calls)})"
            )
        index = self._cursor.get(cursor_key, 0)
        envelope = envelopes[min(index, len(envelopes) - 1)]
        self._cursor[cursor_key] = index + 1

        classified = classify_envelope(
            stdout=envelope.stdout,
            stderr=envelope.stderr,
            exit_code=envelope.exit_code,
            provider=self.name,
        )
        if classified.is_err:
            assert classified.error is not None
            return Outcome.of(classified.error)

        payload = classified.unwrap()
        usage_payload = payload.get("usage") or {}
        usage = Usage(
            input_tokens=int(usage_payload.get("input_tokens", 0)),
            output_tokens=int(usage_payload.get("output_tokens", 0)),
            cache_read_tokens=int(usage_payload.get("cache_read_input_tokens", 0)),
        )
        return Outcome.ok(
            Completion(
                text=str(payload.get("result", "")),
                model=request.model or "scripted",
                provider=self.name,
                usage=usage,
                session_id=str(payload.get("session_id")) if payload.get("session_id") else None,
                raw=payload,
            )
        )
