#!/usr/bin/env bash
# agent-model-call.sh — shared model-call utilities for agent scripts.
# Source this to get classify_model_result AND the span emitter (agent_trace_span).
#
# NOTE ON `set -`: this is a LIBRARY — it deliberately sets no shell options, because a sourced
# lib must not impose `-e`/`-u` on its caller. See "Shell-option classes" in docs/AGENT-HARNESS.md.
#
# TELEMETRY (#2390). CLAUDE.md requires every `claude` invocation to emit a span via
# scripts/lib/agent-trace.sh. Rather than make each agent script source that lib separately (the
# drift that left the whole PR loop — inbox → reviewer → fixer → merger — emitting nothing), this
# lib pulls it in: every script that classifies a model result also gets `agent_trace_span`, so
# instrumenting a call site is one line at the site and nothing else.
#
# The run id is minted HERE, at source time, in the caller's own shell. That matters: a span
# emitted from inside a `$(…)` command substitution or a `( … )` subshell cannot export
# AGENT_RUN_ID back out, so without this every such call would mint a *fresh* id and the spans of
# one tick would stop nesting under one run. Minting up-front makes the id stable no matter which
# shell context each span is emitted from.
if ! declare -F agent_trace_span >/dev/null 2>&1; then
  # shellcheck source=scripts/lib/agent-trace.sh
  source "$(dirname "${BASH_SOURCE[0]}")/agent-trace.sh"
fi
# Redirect (NOT `$(…)`) so the export lands in THIS shell — see agent_trace_run_id's contract.
agent_trace_run_id >/dev/null 2>&1 || true

# Transient markers, in one place: the CLI phrases these the same way on stdout and stderr, and
# the two branches below used to carry divergent copies of this list.
_MODEL_CALL_TRANSIENT_RE='session limit|usage limit|rate.?limit|overloaded|too many requests|quota'

# _model_call_stderr_for — the stderr sidecar written beside an envelope. Callers use
# `>"$X.json" 2>"$X.stderr"` (reviewer, fixer, inbox) or `>"$X" 2>"$X.err"` (release-train);
# both are probed. Prints nothing when neither exists.
_model_call_stderr_for() { # <envelope-path>
  local f="$1" c
  for c in "${f%.json}.stderr" "${f}.err" "${f}.stderr"; do
    [ -s "$c" ] && { printf '%s' "$c"; return; }
  done
}

# classify_model_result — classifies a `claude -p --output-format json` envelope file.
# Prints: transient | empty | hard | ok
#   transient — rate/usage/session limit, overload, quota (self-healing; retry next tick)
#   empty     — NO envelope at all: the CLI exited without serialising its JSON. We cannot tell
#               whether the model ran, so this is deliberately NOT `hard` — see below.
#   hard      — genuine failure (model ran but produced unusable output)
#   ok        — model ran, output envelope is valid JSON with is_error != true
#
# WHY `empty` IS ITS OWN CLASS (#2407). This returned `hard` for a zero-byte envelope, which made
# the one failure most worth retrying the one guaranteed to escalate. On 2026-07-31 a reviewer run
# on PR #2407 completed a full 7-minute review and emitted a valid verdict — it is still in the
# session transcript, and it parses — but the CLI exited 0 without writing its envelope to stdout.
# The 0-byte file classified `hard`, the reviewer posted "could not produce a verdict — needs a
# human", and ~$2.29 of opus review was discarded. The same signature hit PR #2391 the same day.
# An empty envelope means the harness learned NOTHING, which is the opposite of a verdict of
# "genuine failure"; only a run that produced output can be judged on that output.
#
# `empty` is a NEW value, not a re-labelling of `hard`: every existing caller tests
# `= "transient"`, so all of them treat `empty` exactly as they treated `hard` until they opt in.
# Callers that do opt in MUST bound the retry — an unbounded one spins forever against a CLI that
# is permanently silent (a broken install, dead credentials), which is strictly worse than
# escalating to a human.
classify_model_result() { # <claude-cli-json-file>
  local f="$1" cls errf
  errf="$(_model_call_stderr_for "$f")"

  if [ ! -s "$f" ]; then
    # No envelope. stdout told us nothing, so the sidecar is the only remaining evidence: if the
    # CLI named a limit there, that IS the classification and it outranks `empty`.
    if [ -n "$errf" ] && grep -qiE "$_MODEL_CALL_TRANSIENT_RE" "$errf"; then
      echo transient; return
    fi
    echo empty; return
  fi

  if jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
    cls="$(jq -r '
      if (.is_error == true) then
        (((.api_error_status // .status // 0) | tostring) as $s
         | ((.result // .error // "") | tostring) as $m
         | if (["429","503","529"] | index($s)) != null then "transient"
           elif ($m | test("session limit|usage limit|rate.?limit|overloaded|quota|too many requests"; "i")) then "transient"
           else "hard" end)
      else "ok" end' "$f" 2>/dev/null)"
    echo "${cls:-hard}"; return
  fi

  # Non-JSON envelope (the CLI broke before emitting JSON): an unambiguous transient message is
  # transient; anything else is a hard failure. The sidecar is checked too — the CLI writes its
  # limit notices to stderr, so the marker is more often there than in the truncated stdout.
  if grep -qiE "$_MODEL_CALL_TRANSIENT_RE" "$f" \
     || { [ -n "$errf" ] && grep -qiE "$_MODEL_CALL_TRANSIENT_RE" "$errf"; }; then
    echo transient
  else
    echo hard
  fi
}
