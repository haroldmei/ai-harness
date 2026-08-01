#!/usr/bin/env bash
# Hermetic repro for AT-086 + AT-087 — the two harness defects that make the
# whole adversarial loop decorative: filed findings never gate, and committed
# reproducing tests never run.
#
#   Run: bash scripts/adversarial-enforcement.test.sh    (exit 0 = all pass)
#
# AT-086 — gate_repro_tests reads the WRONG FILE.
#   scripts/quality-gates.sh::gate_repro_tests hardcodes `sf="state/state.json"`
#   and queries `.open_issues[]?`. Since the #1699 sharding, `.open_issues`
#   routes to state/findings.json (scripts/lib/state-shard.sh::state_shard_file)
#   and state.json is a thin index that does not carry the key at all. jq
#   therefore matches nothing, the gate reports "no open issues requiring a repro
#   test" and returns 0 — while findings.json holds many open findings. The
#   red-before-green guarantee the gate exists to provide is unenforced, and a
#   finding filed with a missing/bogus repro_test can never fail it.
#
# AT-087 — no gate ever RUNS backend/tests/adversarial/.
#   gate_unit → scripts/unit.sh → `pytest tests/unit/`.
#   gate_integration → scripts/integration.sh → `pytest tests/integration`.
#   gate_quarantine → `pytest tests/adversarial/quarantine` (and NON-BLOCKING
#   by design). Nothing covers backend/tests/adversarial/*.py, so every
#   reproducing test the adversarial loop commits there is dead weight: it can
#   go red forever without any gate noticing, which is the exact regression
#   escape the repro_test contract is supposed to close. (The FRONTEND
#   adversarial tests do run, because they live under frontend/src/ where vitest
#   already looks — which is why this has stayed invisible.)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATES="$ROOT/scripts/quality-gates.sh"
LIB="$ROOT/scripts/lib/state-shard.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null || { echo "jq required"; exit 2; }

# ── AT-086: the repro-tests gate must read the shard that owns open_issues ──────
echo "AT-086 — gate_repro_tests must consult the findings shard"

# 1. The router says findings.json owns .open_issues …
STATE_DIR="$(mktemp -d)"; export STATE_DIR
# shellcheck source=scripts/lib/state-shard.sh
source "$LIB"
owner="$(basename "$(state_shard_file '.open_issues[0].id')")"
if [ "$owner" = "findings.json" ]; then
  ok "state_shard_file routes .open_issues → findings.json"
else
  bad "routing changed: .open_issues → $owner (this test needs updating)"
fi

# 2. … but the gate hardcodes state.json.
if grep -qE 'sf="state/state\.json"' "$GATES" \
   && grep -q 'open_issues\[\]?' "$GATES"; then
  bad "gate_repro_tests reads state/state.json for .open_issues (owned by $owner)"
else
  ok "gate_repro_tests no longer hardcodes state/state.json for .open_issues"
fi

# 3. The live consequence, observed through the REAL gate.
#
#    This assertion used to re-implement the gate's jq against state/state.json and
#    compare it to findings.json. That made it a test of the OLD bug rather than of the
#    invariant: once the gate was fixed, state.json — a thin index whose .open_issues is
#    empty BY DESIGN — still reported 0, so the assertion could never go green no matter
#    how correct the gate became (issue #2387). Ask the gate what it counted instead;
#    that is the property worth holding, and it stays true through any future re-shard.
unset STATE_DIR
live_findings="$ROOT/state/findings.json"
if [ -f "$live_findings" ]; then
  actually_open="$(jq '[.open_issues[]? | select(type=="object")
                        | select((.status // "open") | . == "open" or . == "routed")]
                       | length' "$live_findings")"
  gate_out="$(cd "$ROOT" && bash "$GATES" --only repro-tests --tier launch 2>&1)"
  # The gate reports either "all N open issue(s) carry a repro test" or
  # "no open issues requiring a repro test" (N = 0).
  seen_by_gate="$(grep -oE 'all [0-9]+ open issue' <<<"$gate_out" | grep -oE '[0-9]+' | head -1)"
  grep -q 'no open issues requiring a repro test' <<<"$gate_out" && seen_by_gate=0
  if [ "${seen_by_gate:-unknown}" = "$actually_open" ]; then
    ok "the gate counts the same open issues as the findings shard ($actually_open)"
  elif [ "${seen_by_gate:-0}" = "0" ] && [ "$actually_open" -gt 0 ]; then
    bad "gate counted 0 open issues; findings.json holds $actually_open — the gate passes vacuously"
  else
    bad "gate counted ${seen_by_gate:-<unparseable>}; findings.json holds $actually_open"$'\n'"$gate_out"
  fi
else
  bad "state/findings.json missing — cannot verify"
fi

# ── AT-087: the committed reproducing tests must actually execute ───────────────
echo "AT-087 — some gate must run backend/tests/adversarial/"

adv_dir="$ROOT/backend/tests/adversarial"
n_adv="$(find "$adv_dir" -maxdepth 1 -name 'test_*.py' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$n_adv" -gt 0 ]; then
  ok "backend/tests/adversarial holds $n_adv top-level reproducing test files"
else
  bad "no backend adversarial tests found — this test needs updating"
fi

# Any runner that names the directory (excluding the quarantine sub-lane, which
# is non-blocking by design and therefore cannot enforce anything).
runners="$(grep -rlE 'pytest[^|]*tests/adversarial' "$ROOT/scripts" 2>/dev/null \
           | grep -v 'adversarial-enforcement.test.sh' || true)"
blocking=""
for f in $runners; do
  # A line that runs the dir but NOT only the quarantine sub-dir.
  if grep -E 'pytest[^|]*tests/adversarial' "$f" | grep -qv 'adversarial/quarantine'; then
    blocking="$blocking $f"
  fi
done
if [ -n "$blocking" ]; then
  ok "a blocking lane runs the adversarial suite:$blocking"
else
  bad "no gate runs backend/tests/adversarial/ — $n_adv reproducing tests never execute"
fi

echo
printf 'adversarial-enforcement: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
