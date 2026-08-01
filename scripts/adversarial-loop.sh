#!/usr/bin/env bash
# adversarial-loop.sh — loop-until-dry wrapper around the adversarial-tester.
#
# A single adversarial pass (build-product-v2 Phase 9) finds the shallow bugs and
# stops. Comprehensive coverage needs repeated rounds until the attacker comes up
# empty: keep running adversarial-tester until DRY_STOP consecutive rounds add
# zero NEW findings (deduped by issue id across the whole run), or MAX_ROUNDS.
#
# This is the test-side analogue of adversarial-strategy-loop (which loops the
# strategy adversary). Findings accumulate in state.open_issues; this script only
# drives rounds, dedupes, and accounts — the skill does the finding.
#
# Each round:
#   1. Snapshot the set of known issue ids.
#   2. If --agent: spawn `claude -p` to run the adversarial-tester skill, which
#      files new bugs into state.open_issues (tagged [adversarial]) with a
#      repro_test path. Otherwise report current counts and stop (the
#      orchestrator drives the skill via its Task tool).
#   3. Diff issue ids: anything new resets the dry counter; zero new increments it.
#   4. Bump .testing.adversarial_rounds.
#
# Usage:
#   scripts/adversarial-loop.sh                 # report-only (counts + plan)
#   scripts/adversarial-loop.sh --agent         # autonomous loop-until-dry
#   scripts/adversarial-loop.sh --agent --max-rounds 6 --dry-stop 2
#
# Exit code: 0 always (advisory); the verify-loop / gates decide pass/fail.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

# Per-call token/cost/duration telemetry (issue #1693) — best-effort, never fails the loop.
# shellcheck source=scripts/lib/agent-trace.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/agent-trace.sh"
# Sharded blackboard routing (issue #1699): the adversary owns the findings shard.
# shellcheck source=scripts/lib/state-shard.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/state-shard.sh"
command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }

STATE="state/state.json"
FINDINGS_SHARD="$(state_shard_file '.open_issues')"
MAX_ROUNDS="${MAX_ROUNDS:-5}"
DRY_STOP="${DRY_STOP:-2}"
AGENT=0
FOCUS=""
# PID-namespaced (issue #2387, M3): concurrent lanes clobbered one another's round log.
ADV_LOG="${ADV_LOG:-/tmp/adv-round-$$.log}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)      AGENT=1; shift;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2;;
    --dry-stop)   DRY_STOP="$2"; shift 2;;
    --focus)      FOCUS="$2"; shift 2;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -f "$STATE" ]] || { echo "ERROR: $STATE missing" >&2; exit 2; }
state_migrate   # ensure the findings shard exists + is authoritative (idempotent)

issue_ids() { jq -r '[.open_issues[]? | select(type == "object") | .id] | .[]?' "$FINDINGS_SHARD" 2>/dev/null | sort -u; }

spawn_adversary() {
  command -v claude >/dev/null || { echo "  (claude CLI not found — cannot run adversary)"; return 1; }
  local prompt
  prompt=$(cat <<EOF
Use the adversarial-tester skill (via the Skill tool) on this repository.

Your job is to BREAK the implementation, not confirm it: boundary values, fuzz,
property-based, concurrency, and authz/IDOR tests. Run the implementer suite green
first, then attack.${FOCUS:+ Focus this round on: ${FOCUS}.}

For every REAL bug you find:
  - Write a committed reproducing test (red-before-green) under tests/adversarial/.
  - File a structured entry into state.open_issues with fields:
      { "id": "AT-<n>", "severity": ..., "surface": ..., "repro_test": "<path>",
        "owner": "<skill>", "status": "open", "tags": ["adversarial"] }
  - Do NOT fix the bug yourself (tester ≠ fixer).

Pin randomness via the FAST_CHECK_SEED / TEST_SEED env vars so failures reproduce.
Place any known-flaky tests under tests/adversarial/quarantine/ instead of deleting them.
EOF
)
  echo "  → spawning claude -p for adversarial-tester"
  # --output-format json so the CLI emits a token/cost envelope we can trace (#1693); it changes
  # only stdout formatting, not the exit code adversary_ran keys off of.
  local rc=0
  claude -p "$prompt" --permission-mode acceptEdits --output-format json >"$ADV_LOG" 2>&1 || rc=$?
  agent_trace_span "$ADV_LOG" adversarial template="adversarial-v1" prompt="$prompt"
  return "$rc"   # exit code propagates to the caller
}

# Proof-of-work: did the adversary ACTUALLY run this round? "Zero new findings" is ambiguous — it
# means either "ran and the surface is clean" (a real dry round) or "never ran / refused / hit a
# limit" (a no-op). Only the former may count toward DRY_STOP; otherwise a weak or unavailable
# model that simply files nothing would be declared "dry" and green-light the verify-loop's PASS.
# Returns 0 iff the spawn produced a non-empty log with no refusal/limit/crash signature.
adversary_ran() { # <spawn-rc>
  [ "${1:-1}" -eq 0 ] || return 1
  [ -s "$ADV_LOG" ] || return 1
  # With --output-format json (#1693) the log is a single envelope: a clean is_error=false run
  # PROVES the adversary ran, regardless of what its summary text happens to mention (so a summary
  # like "added authentication tests" no longer trips the failure-signature grep below). Fall back
  # to signature-grep only for an error envelope or a CLI that broke before emitting JSON.
  if jq -e 'type=="object"' "$ADV_LOG" >/dev/null 2>&1; then
    jq -e '.is_error != true' "$ADV_LOG" >/dev/null 2>&1
    return
  fi
  ! grep -qiE 'session limit|usage limit|rate.?limit|overloaded|too many requests|quota|command not found|permission denied|execution error|invalid api key|authentication' "$ADV_LOG"
}

echo "═══ adversarial-loop ═══  max_rounds=$MAX_ROUNDS  dry_stop=$DRY_STOP  agent=$AGENT"

if [[ "$AGENT" -eq 0 ]]; then
  echo "  report-only mode: $(issue_ids | wc -l | tr -d ' ') known issue(s) in state.open_issues."
  echo "  Run with --agent to drive the loop-until-dry adversary, or let the"
  echo "  orchestrator spawn adversarial-tester via its Task tool."
  exit 0
fi

dry=0
round=0
productive=0       # rounds where the adversary provably ran
noop=0             # rounds where it didn't (failed/empty/limited) — NEVER counted as dry
while [[ "$round" -lt "$MAX_ROUNDS" && "$dry" -lt "$DRY_STOP" ]]; do
  round=$((round + 1))
  before="$(issue_ids)"
  before_n=$(printf '%s\n' "$before" | grep -c . || true)
  echo
  echo "── adversarial round $round (known issues: $before_n) ──"

  spawn_adversary; rc=$?

  after="$(issue_ids)"
  new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -c . || true)
  scripts/state-set.sh '.testing.adversarial_rounds' "$round" >/dev/null 2>&1 || true

  if ! adversary_ran "$rc"; then
    # The adversary did not actually run — do NOT let a no-op masquerade as a clean (dry) round.
    noop=$((noop + 1))
    echo "  ⚠ adversary did NOT run this round (spawn rc=$rc / empty or limited output — see $ADV_LOG) — not counting toward dry"
    continue
  fi

  productive=$((productive + 1))
  if [[ "$new" -eq 0 ]]; then
    dry=$((dry + 1))
    echo "  ran, no new findings ($dry/$DRY_STOP dry rounds)"
  else
    dry=0
    echo "  +$new new finding(s) — resetting dry counter"
  fi
done

echo
if [[ "$productive" -eq 0 ]]; then
  # Critical: never report "dry" when the adversary never ran. Coverage is UNPROVEN.
  echo "═══ adversary NEVER ran a productive round ($noop no-op round(s)) — coverage is UNPROVEN, NOT dry. Check the claude CLI / session limits ($ADV_LOG). ═══"
elif [[ "$dry" -ge "$DRY_STOP" ]]; then
  echo "═══ adversary is dry ($DRY_STOP consecutive empty rounds; $productive productive round(s)) after $round round(s) ═══"
else
  echo "═══ stopped at max_rounds=$MAX_ROUNDS ($productive productive, $noop no-op round(s); still finding bugs or could not run — consider more rounds) ═══"
fi
exit 0
