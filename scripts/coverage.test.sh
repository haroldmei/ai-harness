#!/usr/bin/env bash
# Hermetic regression suite for scripts/coverage.sh — the backend coverage gate (#2017).
#
# The gate's whole purpose is to FAIL when coverage drops below the floor, so the assertions
# that matter are the failing ones. Every case here uses the `--from-json` seam (a synthetic
# coverage.py JSON report in a temp dir) so the suite runs in ~1s and never boots pytest —
# the same shape as mobile/tests/perf-validate-unit.test.sh.
#
#   Run: bash scripts/coverage.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COV="$ROOT/scripts/coverage.sh"

# The gate runs this suite inside whatever environment the caller had, and several cases assert
# DEFAULT floor resolution. An inherited COVERAGE_FLOOR silently rewrites those expectations
# (observed: `COVERAGE_FLOOR=95 quality-gates.sh --only coverage` failed 3 cases for that reason
# alone, masking the real gate verdict). Each case sets the floor it means explicitly.
unset COVERAGE_FLOOR
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d -t skillforge-covtest-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Synthetic coverage.py report at <pct>%, with two files so the "least-covered modules"
# listing has something to rank.
mkreport() { # <file> <pct>
  jq -n --argjson pct "$2" '{
    totals: {percent_covered: $pct, num_statements: 1000, missing_lines: 400},
    files: {
      "app/services/thin.py":  {summary: {missing_lines: 300, percent_covered: 10.0}},
      "app/services/thick.py": {summary: {missing_lines: 100, percent_covered: 90.0}}
    }
  }' > "$1"
}

LOW="$TMP/low.json";  mkreport "$LOW" 55.5
HIGH="$TMP/high.json"; mkreport "$HIGH" 85.0
EDGE="$TMP/edge.json"; mkreport "$EDGE" 70.0

run() { OUT="$(bash "$COV" "$@" 2>&1)"; RC=$?; }

echo "coverage.sh — floor enforcement"

# 1) THE acceptance criterion: coverage below the floor fails the gate.
run --from-json "$LOW" --floor 80
if [[ $RC -eq 1 ]]; then ok "below floor → exit 1"
else bad "below floor → expected exit 1, got $RC"$'\n'"$OUT"; fi
if grep -q "BELOW FLOOR" <<<"$OUT"; then ok "below floor → reports BELOW FLOOR"
else bad "below floor → missing BELOW FLOOR"$'\n'"$OUT"; fi
if grep -q "app/services/thin.py" <<<"$OUT"; then ok "below floor → lists least-covered modules"
else bad "below floor → no least-covered listing"$'\n'"$OUT"; fi
# The worst offender must be listed FIRST — the listing is actionable only if it is ranked.
if [[ "$(grep -o 'app/services/[a-z]*\.py' <<<"$OUT" | head -1)" == "app/services/thin.py" ]]; then
  ok "below floor → listing ranked by missing statements"
else bad "below floor → listing not ranked worst-first"$'\n'"$OUT"; fi

# 2) At/above the floor passes.
run --from-json "$HIGH" --floor 80
if [[ $RC -eq 0 ]]; then ok "above floor → exit 0"
else bad "above floor → expected exit 0, got $RC"$'\n'"$OUT"; fi
run --from-json "$EDGE" --floor 70
if [[ $RC -eq 0 ]]; then ok "exactly at floor → exit 0 (floor is inclusive)"
else bad "exactly at floor → expected exit 0, got $RC"$'\n'"$OUT"; fi

# 3) Floor resolution: env var, and --floor beating the env var.
OUT="$(COVERAGE_FLOOR=80 bash "$COV" --from-json "$LOW" 2>&1)"; RC=$?
if [[ $RC -eq 1 ]]; then ok "COVERAGE_FLOOR env is honoured"
else bad "COVERAGE_FLOOR env ignored (rc=$RC)"$'\n'"$OUT"; fi
OUT="$(COVERAGE_FLOOR=80 bash "$COV" --from-json "$LOW" --floor 50 2>&1)"; RC=$?
if [[ $RC -eq 0 ]]; then ok "--floor overrides COVERAGE_FLOOR"
else bad "--floor did not override COVERAGE_FLOOR (rc=$RC)"$'\n'"$OUT"; fi

# 4) The committed floor file is the default source of truth, and it is enforceable —
#    i.e. a report just under the SHIPPED floor really does fail with no args but --from-json.
FLOORFILE="$ROOT/state/artifacts/coverage-floor.json"
if [[ -f "$FLOORFILE" ]]; then
  ok "committed floor file exists ($(basename "$FLOORFILE"))"
  SHIPPED="$(jq -r '.floor' "$FLOORFILE")"
  UNDER="$TMP/under.json"; mkreport "$UNDER" "$(awk -v f="$SHIPPED" 'BEGIN{printf "%.2f", f-0.5}')"
  run --from-json "$UNDER"
  if [[ $RC -eq 1 ]]; then ok "report under the COMMITTED floor (${SHIPPED}%) → exit 1"
  else bad "committed floor not enforced by default (rc=$RC)"$'\n'"$OUT"; fi
  OVER="$TMP/over.json"; mkreport "$OVER" "$(awk -v f="$SHIPPED" 'BEGIN{printf "%.2f", f+0.5}')"
  run --from-json "$OVER"
  if [[ $RC -eq 0 ]]; then ok "report over the COMMITTED floor → exit 0"
  else bad "committed floor rejects a passing report (rc=$RC)"$'\n'"$OUT"; fi
  # The floor must stay below the NFR target, else the ratchet has nowhere to climb.
  if jq -e '.floor <= .target' "$FLOORFILE" >/dev/null; then ok "committed floor ≤ target"
  else bad "committed floor exceeds target"; fi
else
  bad "no committed floor file at $FLOORFILE"
fi

# 5) Unmeasurable input is a SKIP (77), never a silent pass — the gate registry promotes 77
#    to FAIL on tiers where coverage is required, so 77 must not be spelled 0.
run --from-json "$TMP/does-not-exist.json"
if [[ $RC -eq 77 ]]; then ok "missing report → exit 77 (skip, promoted to FAIL where required)"
else bad "missing report → expected 77, got $RC"$'\n'"$OUT"; fi
echo '{"totals":{}}' > "$TMP/empty.json"
run --from-json "$TMP/empty.json"
if [[ $RC -eq 77 ]]; then ok "report without totals → exit 77"
else bad "report without totals → expected 77, got $RC"$'\n'"$OUT"; fi

# 6) The measured number is recorded on a PASS too — drift is only visible if it is written down.
run --from-json "$HIGH" --floor 80
if jq -e '.measured == 85 and .floor == 80' "$ROOT/state/artifacts/coverage.json" >/dev/null 2>&1; then
  ok "pass writes state/artifacts/coverage.json with the measured value"
else bad "state/artifacts/coverage.json not written/incorrect"; fi

# 7) --ratchet raises the floor (in a COPY of the floor file — never mutate the committed one).
RTMP="$TMP/repo"; mkdir -p "$RTMP/state/artifacts" "$RTMP/scripts"
cp "$COV" "$RTMP/scripts/coverage.sh"
jq -n '{floor: 60.0, target: 90.0}' > "$RTMP/state/artifacts/coverage-floor.json"
OUT="$(bash "$RTMP/scripts/coverage.sh" --from-json "$HIGH" --ratchet 2>&1)"; RC=$?
NEWFLOOR="$(jq -r '.floor' "$RTMP/state/artifacts/coverage-floor.json")"
if [[ $RC -eq 0 && "$NEWFLOOR" == "84" ]]; then ok "--ratchet raises floor 60 → 84 (measured 85 − 1pt slack)"
else bad "--ratchet: rc=$RC floor=$NEWFLOOR (expected 0 / 84)"$'\n'"$OUT"; fi
# Ratchet is one-way, even when the RUN was given a lower effective floor. This is the shape
# that regressed during development: comparing against the effective floor instead of the
# committed one silently wrote 69 over a committed 84.
OUT="$(bash "$RTMP/scripts/coverage.sh" --from-json "$EDGE" --floor 60 --ratchet 2>&1)"; RC=$?
NEWFLOOR2="$(jq -r '.floor' "$RTMP/state/artifacts/coverage-floor.json")"
if [[ "$NEWFLOOR2" == "84" ]]; then ok "--ratchet never lowers the committed floor (--floor 60 ignored for writing)"
else bad "--ratchet lowered the floor to $NEWFLOOR2"$'\n'"$OUT"; fi
# The ratchet stops at the NFR target — it must not overshoot into an arbitrary number.
CTMP="$TMP/caprepo"; mkdir -p "$CTMP/state/artifacts" "$CTMP/scripts"
cp "$COV" "$CTMP/scripts/coverage.sh"
jq -n '{floor: 70.0, target: 80.0}' > "$CTMP/state/artifacts/coverage-floor.json"
CAP="$TMP/cap.json"; mkreport "$CAP" 99.0
bash "$CTMP/scripts/coverage.sh" --from-json "$CAP" --ratchet >/dev/null 2>&1
CAPPED="$(jq -r '.floor' "$CTMP/state/artifacts/coverage-floor.json")"
if [[ "$CAPPED" == "80" ]]; then ok "--ratchet caps the floor at the NFR-MAINT-001 target (80)"
else bad "--ratchet overshot the target: floor=$CAPPED"; fi

# 8) A non-numeric floor is rejected rather than silently treated as 0 (which would pass anything).
run --from-json "$LOW" --floor abc
if [[ $RC -ne 0 ]]; then ok "non-numeric floor → nonzero exit"
else bad "non-numeric floor silently accepted"$'\n'"$OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
