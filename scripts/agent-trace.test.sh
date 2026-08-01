#!/usr/bin/env bash
# Unit tests for scripts/lib/agent-trace.sh — the per-call token/cost/duration telemetry helper
# (issue #1693). Verifies field extraction, outcome inference, robustness to malformed/older-CLI
# envelopes, run_id nesting, atomic concurrent appends, and that the wiring into all 10 call sites
# is present. No `claude` and no network — feeds the emitter synthetic CLI JSON envelopes.
#
#   Run: bash scripts/agent-trace.test.sh     (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

command -v jq >/dev/null || { echo "jq required for this test" >&2; exit 2; }

# ── Fresh sandbox + source the lib. Pin AGENT_TRACE_DIR so spans never touch the real repo. ─────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AGENT_TRACE_DIR="$WORK/traces"
# shellcheck source=scripts/lib/agent-trace.sh
source "$ROOT/scripts/lib/agent-trace.sh"

MONTH="$(date -u +%Y%m)"
SPANS="$AGENT_TRACE_DIR/spans-${MONTH}.jsonl"
last_span() { tail -1 "$SPANS"; }

# ── Scenario 1: a full success envelope maps every field ────────────────────────────────────────
echo "Scenario 1 — full success envelope → all fields captured"
export AGENT_RUN_ID="tick-unit-1"
cat > "$WORK/ok.json" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"duration_ms":42000,"num_turns":7,
 "result":"done","session_id":"sess-abc","total_cost_usd":0.1234,
 "usage":{"input_tokens":100,"output_tokens":400,"cache_read_input_tokens":300,"cache_creation_input_tokens":200}}
EOF
agent_trace_span "$WORK/ok.json" inbox-build issue=1693 model=opus
s="$(last_span)"
eq "stage recorded"               "$(jq -r '.stage' <<<"$s")"                "inbox-build"
eq "run_id recorded"              "$(jq -r '.run_id' <<<"$s")"               "tick-unit-1"
eq "issue coerced to a number"    "$(jq -r '.issue' <<<"$s")"                "1693"
eq "model recorded"               "$(jq -r '.model' <<<"$s")"                "opus"
eq "input_tokens"                 "$(jq -r '.input_tokens' <<<"$s")"         "100"
eq "output_tokens"                "$(jq -r '.output_tokens' <<<"$s")"        "400"
eq "cache_read_tokens (renamed)"  "$(jq -r '.cache_read_tokens' <<<"$s")"    "300"
eq "cache_creation_tokens"        "$(jq -r '.cache_creation_tokens' <<<"$s")" "200"
eq "total_cost_usd"               "$(jq -r '.total_cost_usd' <<<"$s")"       "0.1234"
eq "duration_ms"                  "$(jq -r '.duration_ms' <<<"$s")"          "42000"
eq "num_turns"                    "$(jq -r '.num_turns' <<<"$s")"            "7"
eq "session_id"                   "$(jq -r '.session_id' <<<"$s")"           "sess-abc"
eq "engine defaults to claude"    "$(jq -r '.engine' <<<"$s")"               "claude"
eq "outcome inferred ok"          "$(jq -r '.outcome' <<<"$s")"              "ok"
eq "absent pr is null"            "$(jq -r '.pr' <<<"$s")"                    "null"
jq -e . <<<"$s" >/dev/null 2>&1 && ok "span is valid JSON" || bad "span must be valid JSON"

# ── Scenario 2: a transient-limit envelope → outcome inferred 'transient' ────────────────────────
echo "Scenario 2 — transient limit envelope → outcome=transient"
echo '{"is_error":true,"api_error_status":429,"result":"You'\''ve hit your session limit · resets 3pm"}' > "$WORK/lim.json"
agent_trace_span "$WORK/lim.json" review pr=42
eq "outcome transient (429/limit)" "$(jq -r '.outcome' <<<"$(last_span)")" "transient"
eq "pr coerced to number"          "$(jq -r '.pr' <<<"$(last_span)")"      "42"
eq "no tokens → input null"        "$(jq -r '.input_tokens' <<<"$(last_span)")" "null"

# ── Scenario 3: a genuine (non-limit) error → outcome inferred 'hard' ────────────────────────────
echo "Scenario 3 — hard error envelope → outcome=hard"
echo '{"is_error":true,"api_error_status":500,"result":"internal error"}' > "$WORK/err.json"
agent_trace_span "$WORK/err.json" fix pr=7
eq "outcome hard (500/no-limit)" "$(jq -r '.outcome' <<<"$(last_span)")" "hard"

# ── Scenario 4: an empty envelope (CLI crashed pre-JSON) still emits ONE line, never fails ───────
echo "Scenario 4 — empty envelope → one line, null telemetry, no crash"
: > "$WORK/empty.json"
before="$(wc -l < "$SPANS")"
agent_trace_span "$WORK/empty.json" adversarial; rc=$?
eq "emitter returns 0 even on empty envelope" "$rc" "0"
eq "still appended exactly one line" "$(( $(wc -l < "$SPANS") - before ))" "1"
eq "empty → null tokens"  "$(jq -r '.output_tokens' <<<"$(last_span)")" "null"
eq "empty → null outcome" "$(jq -r '.outcome' <<<"$(last_span)")"       "null"

# ── Scenario 5: an older CLI omitting usage/cost → those fields null, others captured ────────────
echo "Scenario 5 — older CLI (no usage/cost) → graceful null fields"
echo '{"is_error":false,"session_id":"s2","num_turns":3}' > "$WORK/old.json"
agent_trace_span "$WORK/old.json" verify-fix round=2
s="$(last_span)"
eq "old CLI: outcome still ok"   "$(jq -r '.outcome' <<<"$s")"       "ok"
eq "old CLI: session captured"   "$(jq -r '.session_id' <<<"$s")"    "s2"
eq "old CLI: num_turns captured" "$(jq -r '.num_turns' <<<"$s")"     "3"
eq "old CLI: cost is null"       "$(jq -r '.total_cost_usd' <<<"$s")" "null"
eq "round coerced to number"     "$(jq -r '.round' <<<"$s")"          "2"

# ── Scenario 5b: `attempt` is a distinct axis from `round` (#2390 review round 2) — a caller can
# pass both (fixer's fix-repair: PR-loop round + self-repair ordinal) or just `attempt` alone
# (merger: no PR-loop round known) without either clobbering the other. ─────────────────────────
echo "Scenario 5b — attempt= is a distinct axis from round="
agent_trace_span "$WORK/old.json" fix-repair round=3 attempt=2
s="$(last_span)"
eq "round preserved alongside attempt" "$(jq -r '.round' <<<"$s")"   "3"
eq "attempt coerced to number"         "$(jq -r '.attempt' <<<"$s")" "2"
agent_trace_span "$WORK/old.json" merge-rebase attempt=1
eq "attempt alone: round null"    "$(jq -r '.round' <<<"$(last_span)")"   "null"
eq "attempt alone: attempt set"   "$(jq -r '.attempt' <<<"$(last_span)")" "1"

# ── Scenario 6: explicit outcome overrides inference ────────────────────────────────────────────
echo "Scenario 6 — explicit outcome= wins over inference"
agent_trace_span "$WORK/ok.json" merge-resolve pr=9 outcome=stuck
eq "explicit outcome respected" "$(jq -r '.outcome' <<<"$(last_span)")" "stuck"

# ── Scenario 7: model falls back to the envelope's modelUsage key when not passed ────────────────
echo "Scenario 7 — model inferred from modelUsage when not passed explicitly"
echo '{"is_error":false,"modelUsage":{"claude-opus-4-8":{"inputTokens":5}}}' > "$WORK/mu.json"
agent_trace_span "$WORK/mu.json" scout-producer
eq "model from modelUsage" "$(jq -r '.model' <<<"$(last_span)")" "claude-opus-4-8"

# ── Scenario 8: run_id nesting — sibling calls share the exported run_id ─────────────────────────
echo "Scenario 8 — run_id nesting (hierarchical spans)"
export AGENT_RUN_ID="tick-shared"
agent_trace_span "$WORK/ok.json" scout-critic
agent_trace_span "$WORK/ok.json" scout-pass2
n_shared="$(jq -rs '[.[] | select(.run_id=="tick-shared")] | length' "$SPANS")"
eq "both sibling calls share one run_id" "$n_shared" "2"
# When AGENT_RUN_ID is unset, the emitter MINTS and exports one, still shared within the process.
unset AGENT_RUN_ID
agent_trace_span "$WORK/ok.json" scout-producer
minted="$(jq -r '.run_id' <<<"$(last_span)")"
[ -n "$minted" ] && [ "$minted" != "null" ] && ok "mints a run_id when none is set" || bad "should mint a run_id"
eq "minted id was exported for reuse" "${AGENT_RUN_ID:-}" "$minted"

# ── Scenario 9: the JSONL is jq-aggregatable per stage / model / pr (the acceptance query) ───────
echo "Scenario 9 — jq answers tokens+cost per stage"
per_stage_cost="$(jq -rs '[.[] | select(.stage=="inbox-build")] | map(.total_cost_usd // 0) | add' "$SPANS")"
eq "per-stage cost sum via jq" "$per_stage_cost" "0.1234"

# ── Scenario 10: concurrent appends never interleave (atomic single-line writes) ─────────────────
echo "Scenario 10 — concurrent emits stay line-atomic"
CONC="$WORK/conc"; export AGENT_TRACE_DIR="$CONC"
for i in $(seq 1 40); do ( agent_trace_span "$WORK/ok.json" review pr="$i" ) & done
wait
CSPANS="$CONC/spans-${MONTH}.jsonl"
eq "all 40 concurrent spans landed"      "$(wc -l < "$CSPANS")"                         "40"
eq "every line is a valid JSON object"   "$(jq -rs '[.[] | select(type=="object")] | length' "$CSPANS")" "40"
export AGENT_TRACE_DIR="$WORK/traces"

# ── Scenario 11: the span census is DERIVED from the tree, not hand-listed (#1984, #2390) ────────
# History of this scenario is the whole argument for how it is now written:
#   • It first asserted all 10 stages emitted a span. 7d418560 reverted the stage scripts, so those
#     call sites vanished and the assertions tested a feature that wasn't in the tree.
#   • #1984 replaced that with two HAND-MAINTAINED lists (INSTRUMENTED / NOT_INSTRUMENTED). That is
#     a tripwire only for the scripts someone remembered to list: `release-train.sh` was instrumented
#     later and appeared in NEITHER list, so it was never checked at all. Meanwhile the whole PR loop
#     sat in NOT_INSTRUMENTED and the suite happily certified the gap as "correct" for months, even
#     though CLAUDE.md had required a span per `claude` call the entire time (#2390).
#
# A hand-maintained census cannot detect the script nobody added to it. So the list is now DERIVED:
# discover every script that actually invokes the `claude` CLI, then require a span from each. A new
# claude-invoking script is therefore gated the day it lands — it cannot be "forgotten" into a list.
echo "Scenario 11 — every claude-invoking script emits a span (census derived from the tree)"

# A `claude -p` invocation in this repo is always `--output-format json` (the span emitter needs the
# JSON envelope). Match that on a NON-COMMENT line: both libs below discuss the flag in prose, and a
# comment must never count as an invocation — nor as instrumentation.
#
# `grep -c`, never `grep -q`, on the downstream side of this pipe. Under `set -o pipefail` (line 9)
# a `grep -q` exits on its FIRST match, the upstream `grep -v` then dies of SIGPIPE, and pipefail
# reports the whole pipeline as FAILED even though the pattern matched. The bug is load-bearing on
# where the match sits: agent-pr-fixer/-merger/release-train match early enough that the upstream
# still had output to write, so a `-q` census silently dropped exactly those three scripts and
# "found" 5 of 8 invokers. `grep -c` drains its input, so it cannot misreport.
# `--` before the pattern: it starts with a dash and would otherwise be parsed as grep options.
matches() { grep -vE '^[[:space:]]*#' "$1" | grep -cE -- "$2"; }  # → count on stdout, never SIGPIPE
CLAUDE_INVOKERS=()
for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh; do
  case "$(basename "$f")" in *.test.sh) continue ;; esac
  [ "$(matches "$f" '--output-format json')" -gt 0 ] && CLAUDE_INVOKERS+=("$f")
done
# Guard the discovery itself: if the signature ever stops matching, the loop below would vacuously
# pass over an empty set — the exact "gate that gates nothing" failure #2387 was filed for.
[ "${#CLAUDE_INVOKERS[@]}" -ge 8 ] \
  && ok "discovered ${#CLAUDE_INVOKERS[@]} claude-invoking scripts" \
  || bad "census found only ${#CLAUDE_INVOKERS[@]} claude invokers — the discovery signature has rotted"

for f in "${CLAUDE_INVOKERS[@]}"; do
  b="$(basename "$f")"
  # 1. The emitter must be REACHABLE: either sourced directly, or transitively via
  #    lib/agent-model-call.sh (which sources agent-trace.sh for every one of its callers, #2390).
  if [ "$(matches "$f" 'source .*/lib/agent-(trace|model-call)\.sh')" -gt 0 ]; then
    ok "$b sources the trace lib (directly or via agent-model-call.sh)"
  else
    bad "$b invokes claude but sources neither lib/agent-trace.sh nor lib/agent-model-call.sh"
  fi
  # 2. It must actually CALL the emitter — sourcing the lib and never emitting is the same blindness.
  if [ "$(matches "$f" 'agent_trace_span')" -gt 0 ]; then
    ok "$b emits at least one span"
  else
    bad "$b invokes claude but never calls agent_trace_span (CLAUDE.md requires a span per call)"
  fi
done

# 3. Per-call-site accounting: a script with N invocations needs N spans. agent-pr-fixer has two
#    claude calls (fix + self-repair) and agent-scout three (producer + critic + p0 pass-2), so a
#    single span per FILE would still leave most of the spend unmeasured.
for f in "${CLAUDE_INVOKERS[@]}"; do
  b="$(basename "$f")"
  calls="$(matches "$f" '--output-format json')"
  spans="$(matches "$f" 'agent_trace_span')"
  [ "$spans" -ge "$calls" ] \
    && ok "$b: $spans span(s) ≥ $calls claude call(s)" \
    || bad "$b: only $spans span(s) for $calls claude call(s) — an invocation goes uncounted"
done

# 4. Every stage in the documented enum must be emitted by some PRODUCTION script (and by a real
#    agent_trace_span call — an incidental `echo <stage>` must not satisfy this). Exclude *.test.sh
#    from the glob like the census loop above does: without that exclusion this very scenario's own
#    fixtures (the `agent_trace_span "$2" review|fix|merge-rebase pr=1` lines below) satisfy the
#    assertion regardless of whether any production script emits the stage. `[^|]*` is widened to
#    `.*` because the merger emits its stage via a `$([ … ] && echo A || echo B)` ternary on the SAME
#    line as the `agent_trace_span` call — the real emission sits on the far side of that `||`, which
#    `[^|]*` can never cross (verified: collapsing the merger to always emit merge-resolve still left
#    this loop green under the old pattern, because it was reading fixtures instead).
for stage in inbox-build review fix fix-repair merge-rebase merge-resolve \
             scout-producer scout-critic scout-pass2 verify-fix adversarial release-train-fix; do
  found=0
  for f in "$ROOT"/scripts/*.sh; do
    case "$(basename "$f")" in *.test.sh) continue ;; esac
    if grep -qE "agent_trace_span.*\b${stage}\b" "$f"; then found=1; break; fi
  done
  [ "$found" -eq 1 ] \
    && ok "stage '$stage' is emitted" || bad "stage '$stage' is never emitted"
done

# 5. The docs must not contradict the tree. CLAUDE.md's parenthetical claimed for months that only
#    verify-loop + adversarial-loop were instrumented while release-train.sh already was — the
#    census is part of the contract, so a stale census is a failing test, not a cosmetic nit.
if grep -q 'only .verify-loop.sh. + .adversarial-loop.sh. are instrumented today' "$ROOT/CLAUDE.md"; then
  bad "CLAUDE.md still claims only verify-loop + adversarial-loop are instrumented — that census is stale"
else
  ok "CLAUDE.md's span census is not the stale two-script claim"
fi

# 6. Prompt fingerprinting (#1701) at every site: a span with no template_id cannot be attributed to
#    a prompt version, which is what makes cost regressions diagnosable rather than merely visible.
for f in "${CLAUDE_INVOKERS[@]}"; do
  b="$(basename "$f")"
  [ "$(matches "$f" 'template=')" -gt 0 ] \
    && ok "$b fingerprints its prompt (template=)" \
    || bad "$b must pass template= so its spans are attributable to a prompt version"
done

# ── Scenario 11b: run-id stability across subshells — the trap the wiring had to avoid ────────────
# agent_trace_span is frequently called from inside `$( … )` / `( … )`: the merger's resolver returns
# its verdict on stdout, and the reviewer runs its model in a `( cd … )` subshell. A span emitted
# there CANNOT export AGENT_RUN_ID back to the parent, so if the id were minted lazily at first emit,
# every such call would mint a fresh one and a tick's spans would stop nesting under a single run.
# lib/agent-model-call.sh mints it at SOURCE time in the caller's own shell to make that impossible.
echo "Scenario 11b — one run id per process, even for spans emitted from subshells"
# Driven in a CHILD bash (not a `( … )` here) for two reasons: it needs a pristine shell with no
# AGENT_RUN_ID inherited from the scenarios above, and a `( … )` would increment PASS/FAIL inside a
# subshell where the counters die — a self-defeating way to write a tripwire.
SUBDIR="$WORK/subshell-traces"
echo '{"is_error":false,"usage":{"input_tokens":1}}' > "$WORK/sub.json"
env -u AGENT_RUN_ID AGENT_TRACE_DIR="$SUBDIR" bash -c '
  set -uo pipefail
  source "$1/scripts/lib/agent-model-call.sh"
  [ -n "${AGENT_RUN_ID:-}" ] || { echo "NO_RUN_ID_AT_SOURCE_TIME"; exit 1; }
  agent_trace_span "$2" review pr=1                        # parent shell
  ( agent_trace_span "$2" fix pr=1 )                       # ( … )   — the reviewer'"'"'s shape
  _="$(agent_trace_span "$2" merge-rebase pr=1)"           # $( … )  — the merger'"'"'s shape
' _ "$ROOT" "$WORK/sub.json" >"$WORK/sub.out" 2>&1
grep -q NO_RUN_ID_AT_SOURCE_TIME "$WORK/sub.out" \
  && bad "agent-model-call.sh must mint AGENT_RUN_ID at source time" \
  || ok "sourcing agent-model-call.sh mints a run id up front"
SUBSPANS="$SUBDIR/spans-${MONTH}.jsonl"
eq "all 3 spans recorded"       "$(wc -l < "$SUBSPANS" 2>/dev/null | tr -d ' ')"          "3"
eq "…and all share ONE run id"  "$(jq -rs '[.[].run_id] | unique | length' "$SUBSPANS" 2>/dev/null)" "1"

# ── Scenario 12: privacy-safe prompt fingerprint fields (#1701) ──────────────────────────────────
echo "Scenario 12 — spans carry template_id / prompt_sha256 / prompt_bytes, never the raw text"
export AGENT_RUN_ID="tick-fp"
PROMPT_A='You are agent-pr-reviewer. Review this diff for correctness.'
agent_trace_span "$WORK/ok.json" review pr=1 template=reviewer-v1 prompt="$PROMPT_A"
s="$(last_span)"
want_sha="$(printf '%s' "$PROMPT_A" | sha256sum | awk '{print $1}')"
want_bytes="$(printf '%s' "$PROMPT_A" | wc -c | tr -d ' ')"
eq "template_id recorded"         "$(jq -r '.template_id' <<<"$s")"   "reviewer-v1"
eq "prompt_sha256 = sha256(text)" "$(jq -r '.prompt_sha256' <<<"$s")" "$want_sha"
eq "prompt_bytes = byte length"   "$(jq -r '.prompt_bytes' <<<"$s")"  "$want_bytes"
# The raw prompt text must NEVER appear in the span line — only its digest.
grep -q 'Review this diff' <<<"$s" && bad "span leaked raw prompt text" || ok "span carries no raw prompt text"
# Identical prompts across calls hash identically (exposes verbatim re-sends); different differ.
agent_trace_span "$WORK/ok.json" fix pr=1 template=fixer-v1 prompt="$PROMPT_A"
eq "verbatim re-send → same hash" "$(jq -r '.prompt_sha256' <<<"$(last_span)")" "$want_sha"
agent_trace_span "$WORK/ok.json" fix pr=1 template=fixer-v1 prompt="${PROMPT_A} EXTRA"
[ "$(jq -r '.prompt_sha256' <<<"$(last_span)")" != "$want_sha" ] \
  && ok "changed prompt → different hash" || bad "changed prompt must change the hash"
# A prompt_file= source hashes the file contents.
printf 'scout producer prompt body' > "$WORK/prompt-security.txt"
agent_trace_span "$WORK/ok.json" scout-producer template=scout-security-v1 prompt_file="$WORK/prompt-security.txt"
eq "prompt_file hashed" "$(jq -r '.prompt_sha256' <<<"$(last_span)")" \
  "$(sha256sum "$WORK/prompt-security.txt" | awk '{print $1}')"
# Absent fingerprint args → null fields (older call sites keep working).
agent_trace_span "$WORK/ok.json" adversarial
s="$(last_span)"
eq "no template → null"     "$(jq -r '.template_id' <<<"$s")"   "null"
eq "no prompt → null sha"   "$(jq -r '.prompt_sha256' <<<"$s")" "null"
eq "no prompt → null bytes" "$(jq -r '.prompt_bytes' <<<"$s")"  "null"

# ── Scenario 13: acceptance — reconstruct a stuck flow from spans alone (no raw text) ────────────
echo "Scenario 13 — a stuck-PR flow is reconstructable from spans alone"
export AGENT_TRACE_DIR="$WORK/flow"; export AGENT_RUN_ID="tick-stuck-77"
agent_trace_span "$WORK/ok.json"  review pr=77 round=1 template=reviewer-v1 prompt="review round 1"
agent_trace_span "$WORK/ok.json"  fix    pr=77 round=1 template=fixer-v1    prompt="fix round 1"
agent_trace_span "$WORK/err.json" review pr=77 round=2 template=reviewer-v1 prompt="review round 2" outcome=stuck
FLOW="$WORK/flow/spans-${MONTH}.jsonl"
# Every span for the run carries stage+round+template+size+outcome — enough to replay the flow.
eq "3 spans for the stuck run" "$(jq -rs '[.[]|select(.run_id=="tick-stuck-77")]|length' "$FLOW")" "3"
recon="$(jq -rs '[.[]|select(.run_id=="tick-stuck-77")]
  | sort_by(.round,.stage)
  | map("\(.stage)/r\(.round)/\(.template_id)/\(.prompt_bytes)b/\(.outcome)")|join(" → ")' "$FLOW")"
echo "    reconstructed: $recon"
[ -n "$recon" ] && grep -q 'reviewer-v1' <<<"$recon" && grep -q 'stuck' <<<"$recon" \
  && ok "flow (stage/round/template/size/outcome) reconstructed from spans" \
  || bad "could not reconstruct the flow from spans"
export AGENT_TRACE_DIR="$WORK/traces"

# ── Scenario 14: conditional retention classification (#1701) ────────────────────────────────────
echo "Scenario 14 — classify: error / expensive / sample / drop"
RET="$WORK/ret"; mkdir -p "$RET"
echo '{"is_error":true,"result":"boom"}'                         > "$RET/agent-err.json"
echo '{"is_error":false,"total_cost_usd":1.50,"duration_ms":10}' > "$RET/agent-costly.json"
echo '{"is_error":false,"total_cost_usd":0.01,"duration_ms":900000}' > "$RET/agent-slow.json"
echo '{"is_error":false,"total_cost_usd":0.01,"duration_ms":10}'  > "$RET/agent-cheap.json"
eq "error envelope → error"       "$(agent_trace_classify "$RET/agent-err.json")"    "error"
eq "over cost threshold → expensive" "$(agent_trace_classify "$RET/agent-costly.json")" "expensive"
eq "over duration threshold → expensive" "$(agent_trace_classify "$RET/agent-slow.json")" "expensive"
cheap_cls="$(agent_trace_classify "$RET/agent-cheap.json")"
case "$cheap_cls" in sample|drop) ok "ordinary success → sample|drop ($cheap_cls)";; *) bad "cheap success class was '$cheap_cls'";; esac
# RETAIN_ALL forces retention of everything (stuck/needs-human tick).
eq "RETAIN_ALL forces keep" "$(AGENT_TRACE_RETAIN_ALL=1 agent_trace_classify "$RET/agent-cheap.json")" "error"
# A prompt-<k>.txt inherits its sibling envelope's class.
: > "$RET/prompt-err.txt"; : > "$RET/prompt-cheap.txt"
eq "prompt inherits error sibling" "$(agent_trace_classify "$RET/prompt-err.txt")" "error"

# ── Scenario 15: sweep deletes drop-class now, keeps error/expensive; RETAIN_ALL keeps all ──────
echo "Scenario 15 — end-of-tick sweep honours the sampling rules"
SW="$WORK/sweep"; mkdir -p "$SW"
echo '{"is_error":true}'                        > "$SW/agent-err.json";   : > "$SW/prompt-err.txt"
echo '{"is_error":false,"total_cost_usd":2.0}'  > "$SW/agent-exp.json"
# Force a deterministic drop: pin sample pct to 0 so every ordinary success is dropped.
echo '{"is_error":false,"total_cost_usd":0.0}'  > "$SW/agent-ok.json";    : > "$SW/prompt-ok.txt"
AGENT_TRACE_SAMPLE_PCT=0 agent_trace_sweep "$SW"
[ -f "$SW/agent-err.json" ]  && ok "error transcript kept"          || bad "error transcript deleted"
[ -f "$SW/prompt-err.txt" ]  && ok "error's prompt sibling kept"    || bad "error prompt deleted"
[ -f "$SW/agent-exp.json" ]  && ok "expensive transcript kept"      || bad "expensive transcript deleted"
[ ! -f "$SW/agent-ok.json" ] && ok "dropped ordinary success"       || bad "ordinary success not dropped"
[ ! -f "$SW/prompt-ok.txt" ] && ok "dropped success's prompt sibling" || bad "success prompt not dropped"
# Pin sample pct to 100 → nothing is dropped.
echo '{"is_error":false,"total_cost_usd":0.0}'  > "$SW/agent-ok2.json"
AGENT_TRACE_SAMPLE_PCT=100 agent_trace_sweep "$SW"
[ -f "$SW/agent-ok2.json" ] && ok "100% sample keeps successes" || bad "100% sample dropped a success"
# RETAIN_ALL keeps everything even at 0% sample.
echo '{"is_error":false}' > "$SW/agent-ok3.json"
AGENT_TRACE_SAMPLE_PCT=0 AGENT_TRACE_RETAIN_ALL=1 agent_trace_sweep "$SW"
[ -f "$SW/agent-ok3.json" ] && ok "RETAIN_ALL keeps success at 0% sample" || bad "RETAIN_ALL dropped a success"

# ── Scenario 16: TTL prune ages out old transcripts by class; spares fresh; never touches spans ──
echo "Scenario 16 — TTL prune: errors 14d, sampled successes 3d"
PR="$WORK/prune"; mkdir -p "$PR"
echo '{"is_error":true}'  > "$PR/agent-olderr.json"
echo '{"is_error":false}' > "$PR/agent-oldok.json"
echo '{"is_error":true}'  > "$PR/agent-fresherr.json"
old_err=$(( $(date -u +%s) - 15*86400 ))   # 15 days old
old_ok=$((  $(date -u +%s) - 4*86400 ))    # 4 days old
touch -d "@$old_err" "$PR/agent-olderr.json" 2>/dev/null || touch -t "$(date -u -d @$old_err +%Y%m%d%H%M 2>/dev/null || date -r $old_err +%Y%m%d%H%M)" "$PR/agent-olderr.json"
touch -d "@$old_ok"  "$PR/agent-oldok.json"  2>/dev/null || touch -t "$(date -u -d @$old_ok +%Y%m%d%H%M 2>/dev/null || date -r $old_ok +%Y%m%d%H%M)" "$PR/agent-oldok.json"
agent_trace_prune "$PR"
[ ! -f "$PR/agent-olderr.json" ]   && ok "15d error pruned (>14d)"        || bad "15d error not pruned"
[ ! -f "$PR/agent-oldok.json" ]    && ok "4d success pruned (>3d)"        || bad "4d success not pruned"
[ -f "$PR/agent-fresherr.json" ]   && ok "fresh error retained"          || bad "fresh error wrongly pruned"
# Prune must never touch the spans JSONL.
[ -f "$SPANS" ] && ok "prune left the spans JSONL untouched" || bad "prune deleted spans"

# ── Scenario 17: retention/sampling wiring — currently UNWIRED by design (#1984) ─────────────────
# agent_trace_sweep/prune are defined in the lib (Scenarios 15/16/18 exercise their behaviour
# directly) but the pipeline/scout hooks that called them were reverted by 7d418560. Asserting the
# hooks exist would fail on a tree that is behaving as documented, so this asserts the documented
# state instead — and trips if someone re-lands the wiring without updating docs/AGENT-HARNESS.md.
echo "Scenario 17 — retention hooks are unwired, and the docs say so"
if grep -qE 'agent_trace_(prune|sweep)' "$ROOT/scripts/agent-pipeline.sh" "$ROOT/scripts/agent-scout.sh"; then
  bad "retention is now wired — update the 'Current wiring' note in docs/AGENT-HARNESS.md and flip this assertion"
else
  ok "pipeline/scout do not call prune/sweep, as documented"
fi
grep -q 'wired into nothing' "$ROOT/docs/AGENT-HARNESS.md" \
  && ok "AGENT-HARNESS.md records the retention hooks as unwired" \
  || bad "docs/AGENT-HARNESS.md must state that the retention hooks are unwired"
# The two live call sites fingerprint their prompts.
for f in verify-loop adversarial-loop; do
  grep -q 'template=' "$ROOT/scripts/$f.sh" && ok "$f.sh fingerprints its prompt" || bad "$f.sh must pass template="
done

# ── Scenario 18: retention hardening — fail-safe on bad inputs, transcript-only scope ────────────
echo "Scenario 18 — sweep fails safe on malformed pct and never touches scratch/ledger json"
HD="$WORK/harden"; mkdir -p "$HD"
echo '{"is_error":false,"total_cost_usd":0.0}' > "$HD/agent-ok.json"
# A malformed sample pct must NOT delete (the cost/duration knobs already fail toward over-retain).
AGENT_TRACE_SAMPLE_PCT='8%'    agent_trace_sweep "$HD"; [ -f "$HD/agent-ok.json" ] && ok "malformed pct '8%' → keep" || bad "malformed pct deleted a transcript"
AGENT_TRACE_SAMPLE_PCT='eight' agent_trace_sweep "$HD"; [ -f "$HD/agent-ok.json" ] && ok "non-numeric pct → keep"  || bad "non-numeric pct deleted a transcript"
eq "malformed pct classifies as sample" "$(AGENT_TRACE_SAMPLE_PCT='x' agent_trace_classify "$HD/agent-ok.json")" "sample"
# Scout scratch (cand/verdict/matrix) and .jsonl ledgers are NOT transcripts — never swept, even at 0%.
echo '{"candidates":[]}'      > "$HD/cand-security.json"
echo '{"verdicts":[]}'        > "$HD/verdict-security.json"
echo '[]'                     > "$HD/matrix-req.json"
echo '{"ledger":1}'           > "$HD/ledger.jsonl"
echo '{"is_error":false}'     > "$HD/critic-security.json"   # a real transcript → sampled
AGENT_TRACE_SAMPLE_PCT=0 agent_trace_sweep "$HD"
[ -f "$HD/cand-security.json" ]    && ok "scratch cand-*.json preserved"    || bad "swept a scratch cand file"
[ -f "$HD/verdict-security.json" ] && ok "scratch verdict-*.json preserved" || bad "swept a scratch verdict file"
[ -f "$HD/matrix-req.json" ]       && ok "scratch matrix-*.json preserved"  || bad "swept a scratch matrix file"
[ -f "$HD/ledger.jsonl" ]          && ok ".jsonl ledger preserved"          || bad "swept a .jsonl ledger"
[ ! -f "$HD/critic-security.json" ] && ok "critic-*.json IS a transcript (swept at 0%)" || bad "critic transcript not swept"

# ── Scenario 17: session-checkpointing tags — resumed (bool) + result (disposition) (#1700) ──────
echo "Scenario 17 — spans carry resumed (cold vs resumed) + result (round disposition)"
export AGENT_TRACE_DIR="$WORK/traces"; export AGENT_RUN_ID="tick-1700"
agent_trace_span "$WORK/ok.json" fix pr=17 round=1 resumed=0 result=pushed
s="$(last_span)"
eq "resumed=0 → false"          "$(jq -r '.resumed' <<<"$s")" "false"
eq "result recorded (pushed)"   "$(jq -r '.result'  <<<"$s")" "pushed"
agent_trace_span "$WORK/ok.json" fix pr=17 round=2 resumed=1 result=stuck
s="$(last_span)"
eq "resumed=1 → true"           "$(jq -r '.resumed' <<<"$s")" "true"
eq "result recorded (stuck)"    "$(jq -r '.result'  <<<"$s")" "stuck"
# Absent → null (every pre-#1700 call site keeps working unchanged).
agent_trace_span "$WORK/ok.json" review pr=17
s="$(last_span)"
eq "no resumed arg → null"      "$(jq -r '.resumed' <<<"$s")" "null"
eq "no result arg → null"       "$(jq -r '.result'  <<<"$s")" "null"

echo
echo "agent-trace: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
