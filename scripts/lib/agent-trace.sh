#!/usr/bin/env bash
# agent-trace.sh — shared per-call token/cost/duration telemetry for the agent harness (#1693).
#
# Every `claude -p --output-format json` turn in the pipeline emits a JSON envelope carrying
# `.total_cost_usd`, `.usage.{input,output,cache_read_input,cache_creation_input}_tokens`,
# `.num_turns`, `.duration_ms` and `.session_id`. The stage scripts historically parsed that
# envelope ONLY for failure classification (classify_model_result) and then discarded the cost
# fields into an ephemeral /tmp log. This lib captures them instead: source it, then call
# `agent_trace_span <envelope-file> <stage> [key=val …]` right after each invocation. One JSONL
# span is appended to state/traces/spans-YYYYMM.jsonl per call, so `jq` can answer tokens+cost
# per stage / model / issue / PR / round.
#
# CONTRACT
#   • It NEVER fails the caller. A missing jq, an unparseable/empty envelope, an older CLI that
#     omits fields, or an unwritable traces dir all degrade to a best-effort no-op (or null
#     fields) — instrumentation must not break a build stage.
#   • Spans nest under a run id: AGENT_RUN_ID is minted once per pipeline tick (agent-pipeline.sh)
#     and inherited by every child stage process, so all of a tick's calls share one run_id;
#     anything invoked standalone mints its own here. This gives hierarchical spans.
#
# Overridable env: AGENT_TRACE_DIR (exact output dir — used by tests), AGENT_TRACE_ROOT (repo
# root whose state/traces/ receives spans), AGENT_RUN_ID (the per-tick id).
#
# NOTE ON `set -`: this file is a LIBRARY and deliberately sets NO shell options. A sourced lib
# runs in the CALLER's shell, so a `set -e` here would silently abort every "collector" script
# (the gate and agent stages) at its first *tolerated* failure — the ones that must survive a
# failing step in order to report, classify or clean up. Signal failure with return codes only.
# This is a deliberate design choice, not an oversight: do not "fix" it by adding `set -e`.
# See "Shell-option classes" in docs/AGENT-HARNESS.md (#2390).

# Absolute fallback anchor: the repo that OWNS this lib (resolved at source time). At emit time the
# traces dir is resolved preferring, in order: AGENT_TRACE_DIR (exact dir — tests) → AGENT_TRACE_ROOT
# → the caller's $ROOT (so a stage script's own repo/sandbox owns its spans) → this fallback. Using
# an absolute path means a caller that has cd'd into a throwaway worktree for the model turn still
# writes to the right state/traces/.
_AGENT_TRACE_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"

# Mint (once) and export a run id. Exported so child stage processes that inherit the env nest
# under the same id. A pipeline tick sets AGENT_RUN_ID before fanning out; standalone callers get
# a fresh id here (UTC stamp + pid + a little entropy).
agent_trace_run_id() {
  if [ -z "${AGENT_RUN_ID:-}" ]; then
    AGENT_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
    export AGENT_RUN_ID
  fi
  printf '%s' "$AGENT_RUN_ID"
}

# Append exactly one JSONL span for a completed claude CLI turn.
#   agent_trace_span <envelope-json-file> <stage> [issue=N] [pr=N] [round=N] [attempt=N] \
#                    [model=M] [outcome=ok|transient|hard|…] [engine=claude]
# `stage` is the enum: inbox-build|review|fix|fix-repair|merge-rebase|merge-resolve|scout-producer|
# scout-critic|scout-pass2|verify-fix|adversarial|release-train-fix. Unknown context keys are
# ignored. If `outcome` is omitted it is inferred from the envelope (ok / transient / hard),
# matching classify_model_result. NOTE `engine=` names the CLI (claude), NOT a scout engine — the
# scout engine belongs in `template=` (scout-<engine>-v1), or the six engines look like six CLIs.
#
# `round` vs `attempt`: these are TWO DISTINCT AXES, never conflate them (#2390 review). `round` is
# always the PR-LOOP round (the `<!-- pr-loop-round: N -->` marker) when the caller has one — it is
# the join key across stages of the SAME pr, so a `fix` and a `fix-repair` span for the same PR-loop
# round MUST carry the same `round` value even though they are separate `claude` turns. `attempt` is
# a retry ORDINAL within a single stage invocation (self-repair attempt, conflict-resolver attempt,
# release-train try) — it resets per invocation and is not joinable across stages. A caller that has
# no PR-loop round (the merger) just omits `round` and passes `attempt` alone.
agent_trace_span() {
  local envelope="${1:-}" stage="${2:-unknown}"
  shift 2 2>/dev/null || true
  {
    command -v jq >/dev/null 2>&1 || return 0

    local run_id issue="" pr="" round="" attempt="" model="" outcome="" engine="claude" kv
    # Privacy-safe prompt fingerprinting (#1701): record a NON-CONTENT digest of the prompt —
    # `template_id` (e.g. reviewer-v1, scout-security-v1), `prompt_sha256`, `prompt_bytes` — so a
    # stuck-PR investigation can reconstruct the flow (stage/round/template/size/outcome) from the
    # spans alone, without keeping the raw prompt text. Identical hashes across calls also expose
    # verbatim re-sends. Source of the digest is, in precedence order: an explicit
    # prompt_sha256=/prompt_bytes= pair (tests / pre-computed), else the prompt string (prompt=…),
    # else a prompt file (prompt_file=…, e.g. scout's archived prompt-<engine>.txt).
    local template="" prompt_str="" prompt_file="" prompt_sha256="" prompt_bytes="" _have_pstr=0
    # Session checkpointing (#1700): `resumed` (0/1 — was this call a `--resume` of a prior session
    # rather than a cold start) and `result` (the round's terminal disposition:
    # pushed|no-change|stuck|transient) let a report compare cold vs resumed fix rounds on both cost
    # (the token fields already here) AND success rate. Both are optional and null when not passed,
    # so every existing call site is unaffected.
    local resumed="" result=""
    # Ensure AGENT_RUN_ID is minted+exported in THIS shell (NOT a `$(…)` subshell, or the export
    # would be lost and each standalone call would mint a fresh id — breaking the shared-run_id
    # nesting that scout/verify/adversarial rely on). Redirecting a function call is not a subshell.
    agent_trace_run_id >/dev/null
    run_id="${AGENT_RUN_ID:-}"
    for kv in "$@"; do
      case "$kv" in
        issue=*)   issue="${kv#issue=}";;
        pr=*)      pr="${kv#pr=}";;
        round=*)   round="${kv#round=}";;
        attempt=*) attempt="${kv#attempt=}";;
        model=*)   model="${kv#model=}";;
        outcome=*) outcome="${kv#outcome=}";;
        engine=*)  engine="${kv#engine=}";;
        template=*)      template="${kv#template=}";;
        prompt=*)        prompt_str="${kv#prompt=}"; _have_pstr=1;;
        prompt_file=*)   prompt_file="${kv#prompt_file=}";;
        prompt_sha256=*) prompt_sha256="${kv#prompt_sha256=}";;
        prompt_bytes=*)  prompt_bytes="${kv#prompt_bytes=}";;
        resumed=*)       resumed="${kv#resumed=}";;
        result=*)        result="${kv#result=}";;
      esac
    done

    # Derive the prompt digest from whichever source was supplied (best-effort; a missing hasher
    # or unreadable file just leaves the field null — telemetry must never fail the caller).
    if [ -z "$prompt_sha256" ] || [ -z "$prompt_bytes" ]; then
      if [ "$_have_pstr" = 1 ]; then
        [ -z "$prompt_bytes" ]  && prompt_bytes="$(printf '%s' "$prompt_str" | wc -c | tr -d ' ')"
        [ -z "$prompt_sha256" ] && prompt_sha256="$(printf '%s' "$prompt_str" | _agent_trace_sha256)"
      elif [ -n "$prompt_file" ] && [ -s "$prompt_file" ]; then
        [ -z "$prompt_bytes" ]  && prompt_bytes="$(wc -c < "$prompt_file" | tr -d ' ')"
        [ -z "$prompt_sha256" ] && prompt_sha256="$(_agent_trace_sha256 < "$prompt_file")"
      fi
    fi

    local dir="${AGENT_TRACE_DIR:-${AGENT_TRACE_ROOT:-${ROOT:-$_AGENT_TRACE_LIB_ROOT}}/state/traces}"
    mkdir -p "$dir" 2>/dev/null || return 0
    local ts month file
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    month="$(date -u +%Y%m)"
    file="$dir/spans-${month}.jsonl"

    # Only feed jq a real object envelope; anything else (empty, stderr noise, non-JSON, older CLI)
    # collapses to {} so the span still emits with null telemetry + an inferred/passed outcome.
    local env_json='{}'
    if [ -s "$envelope" ] && jq -e 'type=="object"' "$envelope" >/dev/null 2>&1; then
      env_json="$(cat "$envelope")"
    fi

    local line
    line="$(jq -cn \
      --argjson env "$env_json" \
      --arg ts "$ts" --arg run_id "$run_id" --arg stage "$stage" \
      --arg issue "$issue" --arg pr "$pr" --arg round "$round" --arg attempt "$attempt" \
      --arg model "$model" --arg engine "$engine" --arg outcome "$outcome" \
      --arg template "$template" --arg psha "$prompt_sha256" --arg pbytes "$prompt_bytes" \
      --arg resumed "$resumed" --arg result "$result" '
      def blank(v): if v == "" then null else v end;
      def num(v): if v == "" then null else (v | tonumber? // null) end;
      def flag(v): if v == "" then null elif (v == "1" or v == "true") then true else false end;
      ($env.usage // {}) as $u
      | {
          ts: $ts,
          run_id: blank($run_id),
          stage: $stage,
          engine: blank($engine),
          issue: num($issue),
          pr: num($pr),
          round: num($round),
          attempt: num($attempt),
          template_id: blank($template),
          prompt_sha256: blank($psha),
          prompt_bytes: num($pbytes),
          model: (blank($model) // ($env.modelUsage // {} | keys_unsorted | (.[0] // null))),
          num_turns: ($env.num_turns // null),
          input_tokens: ($u.input_tokens // null),
          output_tokens: ($u.output_tokens // null),
          cache_read_tokens: ($u.cache_read_input_tokens // null),
          cache_creation_tokens: ($u.cache_creation_input_tokens // null),
          total_cost_usd: ($env.total_cost_usd // null),
          duration_ms: ($env.duration_ms // null),
          session_id: ($env.session_id // null),
          resumed: flag($resumed),
          result: blank($result),
          outcome: (blank($outcome) //
            (if ($env | has("is_error")) then
               (if ($env.is_error == true) then
                  ((($env.api_error_status // $env.status // 0) | tostring) as $s
                   | (($env.result // $env.error // "") | tostring) as $m
                   | if (["429","503","529"] | index($s)) != null then "transient"
                     elif ($m | test("session limit|usage limit|rate.?limit|overloaded|quota|too many requests"; "i")) then "transient"
                     else "hard" end)
                else "ok" end)
             else null end))
        }' 2>/dev/null)" || return 0

    [ -n "$line" ] || return 0
    # A single short line via O_APPEND is atomic (< PIPE_BUF), so concurrent stages never interleave.
    printf '%s\n' "$line" >> "$file" 2>/dev/null || return 0
  } 2>/dev/null || return 0
  return 0
}

# ───────────────────────────────────────────────────────────────────────────────────────────────
# Conditional transcript sampling + TTL retention (#1701)
#
# The full CLI JSON envelopes (${LOGDIR}/agent-*.json, critic-*.json, …) and scout's archived raw
# prompts (${LOGDIR}/prompt-*.txt) are the bulky, privacy-sensitive artifacts — unlike the small
# JSONL spans (which we keep indefinitely). We govern them with two rules:
#
#   • agent_trace_sweep <dir…>  — run at END OF TICK. Every transcript is classified and the ones
#     not worth keeping are deleted NOW. A transcript is RETAINED when it is an error, when it is
#     "expensive" (cost/duration over threshold), or when the whole tick ended stuck/needs-human
#     (AGENT_TRACE_RETAIN_ALL=1); otherwise it is kept only as a small random SAMPLE (~PCT %) and
#     the rest are dropped. A scout prompt-<k>.txt shares the fate of its sibling agent-<k>.json.
#   • agent_trace_prune <dir…>  — TTL cleanup, safe to run any time (e.g. tick start). Retained
#     transcripts age out: error/expensive after AGENT_TRACE_TTL_ERROR_DAYS, everything else after
#     AGENT_TRACE_TTL_SAMPLE_DAYS. Spans are NEVER touched by either function.
#
# All knobs are overridable so tests can pin them and an operator can tune retention.
: "${AGENT_TRACE_SAMPLE_PCT:=8}"              # keep ~8% of ordinary successful transcripts
: "${AGENT_TRACE_COST_KEEP_USD:=0.50}"        # …but ALWAYS keep a transcript at/above this cost
: "${AGENT_TRACE_DURATION_KEEP_MS:=300000}"   # …or at/above this wall-time (5 min)
: "${AGENT_TRACE_TTL_ERROR_DAYS:=14}"         # error/expensive transcripts live this long
: "${AGENT_TRACE_TTL_SAMPLE_DAYS:=3}"         # sampled successes live this long

# Portable sha256 of stdin → bare hex (empty string if no hasher is available).
_agent_trace_sha256() {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v openssl   >/dev/null 2>&1; then openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  else cat >/dev/null 2>&1; printf ''; fi
}

# prompt-<key>.txt → the sibling agent-<key>.json in the same dir (empty if not that shape).
_agent_trace_sibling_envelope() {
  local f="$1" dir base key
  dir="$(dirname "$f")"; base="$(basename "$f")"
  case "$base" in
    prompt-*.txt) key="${base#prompt-}"; key="${key%.txt}"; printf '%s/agent-%s.json' "$dir" "$key" ;;
    *) printf '' ;;
  esac
}
# agent-<key>.json → the sibling prompt-<key>.txt in the same dir (empty if not that shape).
_agent_trace_sibling_prompt() {
  local f="$1" dir base key
  dir="$(dirname "$f")"; base="$(basename "$f")"
  case "$base" in
    agent-*.json) key="${base#agent-}"; key="${key%.json}"; printf '%s/prompt-%s.txt' "$dir" "$key" ;;
    *) printf '' ;;
  esac
}

# Is <file> at least <days> old (by mtime)? Best-effort; unstattable file → "no".
_agent_trace_older_than_days() {
  local f="$1" days="$2" mtime now
  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" || return 1
  [ -n "$mtime" ] || return 1
  now="$(date -u +%s)"
  [ $(( now - mtime )) -ge $(( days * 86400 )) ]
}

# Classify a transcript → error | expensive | sample | drop.
#   • AGENT_TRACE_RETAIN_ALL=1 (tick ended stuck/needs-human) → error (longest retention).
#   • a prompt-<k>.txt inherits its sibling envelope's class when that envelope still exists.
#   • a JSON envelope: is_error → error; cost/duration over threshold → expensive.
#   • otherwise a deterministic content-hash sample decides sample (keep) vs drop.
agent_trace_classify() {
  local f="$1"
  [ "${AGENT_TRACE_RETAIN_ALL:-0}" = 1 ] && { printf 'error'; return 0; }
  case "$(basename "$f")" in
    prompt-*.txt)
      local sib; sib="$(_agent_trace_sibling_envelope "$f")"
      if [ -n "$sib" ] && [ -e "$sib" ]; then agent_trace_classify "$sib"; return 0; fi
      ;;
  esac
  if command -v jq >/dev/null 2>&1 && [ -s "$f" ] && jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
    if jq -e '.is_error==true' "$f" >/dev/null 2>&1; then printf 'error'; return 0; fi
    local cost dur
    cost="$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null || echo 0)"
    dur="$(jq -r '.duration_ms // 0' "$f" 2>/dev/null || echo 0)"
    if awk -v c="$cost" -v t="$AGENT_TRACE_COST_KEEP_USD"     'BEGIN{exit !((c+0)>=(t+0))}' \
    || awk -v d="$dur"  -v t="$AGENT_TRACE_DURATION_KEEP_MS"  'BEGIN{exit !((d+0)>=(t+0))}'; then
      printf 'expensive'; return 0
    fi
  fi
  # Deterministic ~PCT% sample keyed on the file's content hash (falls back to its name). Every
  # degraded path fails SAFE — i.e. KEEP (sample), never silently delete: a malformed sample pct,
  # a missing hasher, or a non-hex digest all short-circuit to 'sample' before the arithmetic.
  local h pct="${AGENT_TRACE_SAMPLE_PCT:-8}"
  case "$pct" in ''|*[!0-9]*) printf 'sample'; return 0;; esac
  h="$(_agent_trace_sha256 < "$f" 2>/dev/null)"
  [ -n "$h" ] || h="$(printf '%s' "$(basename "$f")" | _agent_trace_sha256 2>/dev/null)"
  case "$h" in ''|*[!0-9a-fA-F]*) printf 'sample'; return 0;; esac
  if [ $(( 16#${h:0:4} % 100 )) -lt "$pct" ]; then printf 'sample'; else printf 'drop'; fi
}

# END-OF-TICK sweep: delete every drop-class transcript now; keep error/expensive/sample. A
# dropped envelope takes its scout prompt sibling with it. Never touches non-transcript files.
agent_trace_sweep() {
  local d f cls sib
  for d in "$@"; do
    [ -d "$d" ] || continue
    # Only the CLI-envelope transcripts — agent-*.json (inbox / scout producer+pass2 / reviewer /
    # fixer / merger) and critic-*.json (scout critic). NOT scout's scratch cand-*/verdict-*/
    # matrix-*.json, and NOT *.jsonl ledgers — a plain *.json glob would sweep those too.
    for f in "$d"/agent-*.json "$d"/critic-*.json; do
      [ -e "$f" ] || continue
      cls="$(agent_trace_classify "$f")"
      if [ "$cls" = drop ]; then
        sib="$(_agent_trace_sibling_prompt "$f")"
        rm -f "$f" 2>/dev/null || true
        [ -n "$sib" ] && rm -f "$sib" 2>/dev/null || true
      fi
    done
    # Orphan prompts (no surviving sibling envelope) get sampled on their own content.
    for f in "$d"/prompt-*.txt; do
      [ -e "$f" ] || continue
      sib="$(_agent_trace_sibling_envelope "$f")"
      [ -n "$sib" ] && [ -e "$sib" ] && continue      # fate already decided with the envelope
      [ "$(agent_trace_classify "$f")" = drop ] && rm -f "$f" 2>/dev/null || true
    done
  done
  return 0
}

# TTL prune: age out retained transcripts. error/expensive → TTL_ERROR_DAYS, else TTL_SAMPLE_DAYS.
# Re-derives the class from the file itself (a stray RETAIN_ALL only makes pruning MORE conservative,
# never less — it can't delete something early). Safe no-op on missing dirs; spans dir is never passed.
agent_trace_prune() {
  local d f cls days
  for d in "$@"; do
    [ -d "$d" ] || continue
    # Same transcript scope as the sweep (agent-*.json / critic-*.json) plus scout's raw prompts.
    for f in "$d"/agent-*.json "$d"/critic-*.json "$d"/prompt-*.txt; do
      [ -e "$f" ] || continue
      cls="$(agent_trace_classify "$f")"
      case "$cls" in
        error|expensive) days="$AGENT_TRACE_TTL_ERROR_DAYS" ;;
        *)               days="$AGENT_TRACE_TTL_SAMPLE_DAYS" ;;
      esac
      _agent_trace_older_than_days "$f" "$days" && rm -f "$f" 2>/dev/null || true
    done
  done
  return 0
}
