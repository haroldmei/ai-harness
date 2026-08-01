#!/usr/bin/env bash
# verify-loop.sh — the self-contained test → route → fix → re-test driver.
#
# This is the codified version of the loop that build-product-v2 SKILL.md
# describes in prose (Phase 8/9 + the failure-routing matrix). It turns the
# "re-spawn the owner, re-run gates, cap at 3 attempts, surface to user" control
# flow into a deterministic, resumable script that persists its state.
#
# What it does each round:
#   1. Run scripts/quality-gates.sh --keep-going --json (all gates, machine output)
#   2. For every FAILED gate: route it via route-failure.sh → owner skill,
#      bump .testing.gate_attempts[gate] in state.json.
#   3. If --agent: spawn `claude -p` to run the owner skill against the failing
#      log and fix the root cause, then loop. Otherwise (default) report the
#      routing and stop — the orchestrator drives the fix via its Task tool.
#   4. Stop when all gates pass AND open adversarial issues are drained, or when
#      every still-failing gate has hit --max-attempts.
#   5. Write a machine-readable verdict to state/verdict.json and update
#      .testing in state.json.
#
# Usage:
#   scripts/verify-loop.sh                      # report-only: gates + routing + verdict
#   scripts/verify-loop.sh --agent              # autonomous: spawn claude -p to fix
#   scripts/verify-loop.sh --agent --with-adversarial   # also run the loop-until-dry adversary
#   scripts/verify-loop.sh --max-attempts 5 --tier launch
#
# Exit code: 0 = PASS, 1 = gates still failing, 2 = bad usage.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }

# Per-call token/cost/duration telemetry (issue #1693) — best-effort, never fails the loop.
# shellcheck source=scripts/lib/agent-trace.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/agent-trace.sh"
# shellcheck source=scripts/lib/gate-reason.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/gate-reason.sh"
# Sharded blackboard routing (issue #1699): verify-loop reads/writes ONLY the testing
# + findings shards, never the product namespace.
# shellcheck source=scripts/lib/state-shard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/state-shard.sh"

STATE="state/state.json"           # thin index — only .scale_tier is read from here
TESTING_SHARD="$(state_shard_file '.testing')"
FINDINGS_SHARD="$(state_shard_file '.open_issues')"
VERDICT="state/verdict.json"
# PID-namespaced: three pipeline lanes share /tmp, and a fixed path meant one lane's verdict
# JSON and fixer logs were overwritten by another lane's mid-run (issue #2387, M3; #2211).
GATES_JSON="${VERIFY_GATES_JSON:-/tmp/verify-gates-$$.json}"

# Pin the gate-log dir to a STABLE, known path and export it so the quality-gates child writes
# its per-gate logs where spawn_fix can find them. Without this, quality-gates.sh defaults to a
# PID-namespaced /tmp/qg-$$ that this script can't predict, so spawn_fix tailed a non-existent
# /tmp/qg-<gate>.log and fed the fixer model an EMPTY failure — crippling the auto-heal.
export QG_LOGDIR="${QG_LOGDIR:-/tmp/verify-qg-$$}"
VERIFY_FIX_LOGDIR="${VERIFY_FIX_LOGDIR:-/tmp/verify-fix-$$}"
mkdir -p "$VERIFY_FIX_LOGDIR" 2>/dev/null || true
mkdir -p "$QG_LOGDIR"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
AGENT=0
WITH_ADV=0
TIER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)            AGENT=1; shift;;
    --with-adversarial) WITH_ADV=1; shift;;
    --max-attempts)     MAX_ATTEMPTS="$2"; shift 2;;
    --tier)             TIER="$2"; shift 2;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -f "$STATE" ]] || { echo "ERROR: $STATE missing — run scripts/state-init.sh first" >&2; exit 2; }
state_migrate   # ensure the testing/findings shards exist + are authoritative (idempotent)
TIER="${TIER:-$(jq -r '.scale_tier // "preview"' "$STATE")}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

sset() { scripts/state-set.sh "$1" "$2" >/dev/null 2>&1 || true; }

open_issue_count() {
  # Only structured (object) issues gate; legacy free-form string notes don't.
  jq '[.open_issues[]? | select(type == "object") | select((.status // "open") | . == "open" or . == "routed")] | length' "$FINDINGS_SHARD"
}

# Lines that carry an actual DIAGNOSIS (mirrors release-train.sh's FAILURE_LINE_RE).
# pytest's `E  ` prefix is the exception/assert body, `FAILED`/`ERROR` are the summary
# rows, and the rest cover mypy/ruff/vitest/tsc and infra failures.
# A blind `tail` is the wrong excerpt for every test runner we own — pytest prints the
# failure body FIRST and a warnings summary LAST, so the last N lines of a long log are
# deprecation notices (observed: a 1499-line integration log whose root cause sat at line
# 308 while tail-80 sent lines 1420-1499, none of which named the failure). Pull the
# lines that actually diagnose, and fall back to the tail only when nothing matches.
# Shared with quality-gates.sh and release-train.sh via scripts/lib/gate-reason.sh so the
# three cannot drift (issue #2387, H4). Alias kept for the existing call sites below.
SPAWN_DIAG_RE="$GATE_FAILURE_LINE_RE"

# Spawn the owner skill headlessly to fix one failing gate. Best-effort.
spawn_fix() {
  local gate="$1" owner="$2" logf="$QG_LOGDIR/${gate}.log"
  command -v claude >/dev/null || { echo "    (claude CLI not found — cannot auto-fix)"; return 1; }
  local tail
  tail="$(grep -E "$SPAWN_DIAG_RE" "$logf" 2>/dev/null | awk '!seen[$0]++' | head -n 40)"
  if [[ -z "${tail// }" ]]; then
    tail="$(tail -n 40 "$logf" 2>/dev/null)"
  fi
  if [[ -z "${tail// }" ]]; then
    echo "    ⚠ no failing-gate log at $logf — fixer would run blind; skipping this spawn"
    return 1
  fi
  local prompt
  prompt=$(cat <<EOF
You are fixing a failing quality gate in this repository. Do not weaken or delete
tests to make the gate pass — fix the root cause.

Gate that failed: ${gate}
Owner skill to use: ${owner}

Invoke the ${owner} skill (via the Skill tool) scoped to this failure. Failing output:

${tail}

When done, run \`scripts/quality-gates.sh --only ${gate} --tier ${TIER}\` and confirm it passes.
If the fix required a new regression test, leave it committed in the permanent suite.
EOF
)
  echo "    → spawning claude -p for ${owner} (gate ${gate})"
  # Don't blanket-swallow the spawn: a refusal / crash / rate-limit means NO fix was applied, and
  # silently treating that as "fixed" lets the loop burn the gate's whole attempt budget on no-ops.
  # The gate re-run next round is still the source of truth, but surface the spawn failure so it's
  # visible in the log rather than indistinguishable from a successful fix.
  # --output-format json so the CLI emits a cost/token envelope we can trace (#1693). It changes
  # only stdout formatting, not exit code or the acceptEdits behaviour the loop relies on.
  local rc=0
  claude -p "$prompt" --permission-mode acceptEdits --output-format json >"${VERIFY_FIX_LOGDIR}/verify-fix-${gate}.log" 2>&1 || rc=$?
  # Outcome inferred from the envelope (ok/transient/hard); on a pre-JSON crash it stays null.
  agent_trace_span "${VERIFY_FIX_LOGDIR}/verify-fix-${gate}.log" verify-fix template="verify-fix-v1" prompt="$prompt"
  if [ "$rc" -ne 0 ]; then
    echo "    ⚠ fixer spawn for ${gate} exited non-zero (refusal/limit/crash) — no fix applied this round; see ${VERIFY_FIX_LOGDIR}/verify-fix-${gate}.log"
    return 1
  fi
}

echo "═══ verify-loop ═══  tier=$TIER  max_attempts=$MAX_ATTEMPTS  agent=$AGENT  adversarial=$WITH_ADV"

# Optional: drain new bugs first via the loop-until-dry adversary.
if [[ "$WITH_ADV" -eq 1 ]]; then
  ADV_FLAGS=()
  [[ "$AGENT" -eq 1 ]] && ADV_FLAGS+=(--agent)
  scripts/adversarial-loop.sh "${ADV_FLAGS[@]}" || true
fi

verdict="PASS"
round=0
declare -a final_routes=()

while :; do
  round=$((round + 1))
  echo
  echo "── round $round ──"
  scripts/quality-gates.sh --keep-going --tier "$TIER" --json "$GATES_JSON" || true

  mapfile -t failed < <(jq -r '.[] | select(.status == "fail") | .gate' "$GATES_JSON" 2>/dev/null)
  drained=$(open_issue_count)

  if [[ "${#failed[@]}" -eq 0 && "$drained" -eq 0 ]]; then
    verdict="PASS"; break
  fi

  if [[ "${#failed[@]}" -eq 0 && "$drained" -gt 0 ]]; then
    echo "All gates pass but $drained open issue(s) still need a fix+repro."
    verdict="ISSUES_OPEN"
    # repro-tests gate should have caught this if tier-required; surface it.
    [[ "$AGENT" -eq 0 ]] && break
  fi

  # Route each failing gate and account the attempt.
  all_capped=1
  final_routes=()
  for g in "${failed[@]}"; do
    owner="$(scripts/route-failure.sh --gate "$g" 2>/dev/null || echo unknown)"
    attempts=$(jq --arg g "$g" '.testing.gate_attempts[$g] // 0' "$TESTING_SHARD")
    attempts=$((attempts + 1))
    sset ".testing.gate_attempts.\"$g\"" "$attempts"
    final_routes+=("$g → $owner (attempt $attempts/$MAX_ATTEMPTS)")
    echo "  ✗ $g → $owner  (attempt $attempts/$MAX_ATTEMPTS)"
    if [[ "$attempts" -le "$MAX_ATTEMPTS" ]]; then
      all_capped=0
      [[ "$AGENT" -eq 1 ]] && spawn_fix "$g" "$owner"
    else
      echo "    ⚠ cap reached — surfacing to human"
    fi
  done

  if [[ "$AGENT" -eq 0 ]]; then
    verdict="ROUTED"; break          # report-only: orchestrator applies the fixes
  fi
  if [[ "$all_capped" -eq 1 ]]; then
    verdict="SURFACED"; break        # every failing gate exhausted its attempts
  fi
done

# ---- persist verdict ----
final_failed=$(jq -c '[.[] | select(.status == "fail") | .gate]' "$GATES_JSON" 2>/dev/null || echo '[]')
mutation=$(jq '.testing.last_mutation_score' "$TESTING_SHARD")
routes_json=$(printf '%s\n' "${final_routes[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')

jq -n \
  --arg verdict "$verdict" \
  --arg tier "$TIER" \
  --arg now "$NOW" \
  --argjson rounds "$round" \
  --argjson failed "$final_failed" \
  --argjson open_issues "$(open_issue_count)" \
  --argjson mutation "${mutation:-null}" \
  --argjson routes "$routes_json" \
  '{
    verdict: $verdict, tier: $tier, generated_at: $now, rounds: $rounds,
    failed_gates: $failed, open_issues_blocking: $open_issues,
    mutation_score: $mutation, routes: $routes,
    generated_by: "scripts/verify-loop.sh"
  }' > "$VERDICT"

sset '.testing.last_verdict' "\"$verdict\""
sset '.testing.last_run_at'  "\"$NOW\""
sset '.testing.open_issues_drained' "$([[ "$(open_issue_count)" -eq 0 ]] && echo true || echo false)"

echo
echo "═══ verdict: $verdict  (rounds=$round) ═══"
echo "  written to $VERDICT"
[[ "$verdict" == "PASS" ]] && exit 0 || exit 1
