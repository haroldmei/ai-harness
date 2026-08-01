#!/usr/bin/env bash
# Hermetic test for scripts/iteration-count.sh — the O(1) iteration counter that
# replaces reading the 712 KB docs/06-iteration-log.md just to learn one integer (#1696).
#
#   Run: bash scripts/iteration-count.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/iteration-count.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

run() { # <state_file> <iterations_dir> [args...]
  local sf="$1" itd="$2"; shift 2
  ITERATION_STATE_FILE="$sf" ITERATIONS_DIR="$itd" bash "$HELPER" "$@"
}

# ── Scenario 1: field present → O(1) read, no log needed ──────────────────────────
echo "Scenario 1 — reads .iteration_count directly (no log dependency)"
T1="$(mktemp -d)"
echo '{"iteration_count": 42}' > "$T1/state.json"
# deliberately point the log at a nonexistent path: a field read must not touch it
eq "current returns the field value" "$(run "$T1/state.json" "$T1/nope.md")" "42"
eq "state file unchanged after read" "$(jq -r .iteration_count "$T1/state.json")" "42"

# ── Scenario 2: --next reserves + persists ───────────────────────────────────────
echo "Scenario 2 — --next increments and persists"
eq "--next returns current+1" "$(run "$T1/state.json" "$T1/nope.md" --next)" "43"
eq "persisted to state" "$(jq -r .iteration_count "$T1/state.json")" "43"
eq "second --next continues" "$(run "$T1/state.json" "$T1/nope.md" --next)" "44"

# ── Scenario 3: --peek-next does NOT persist ─────────────────────────────────────
echo "Scenario 3 — --peek-next is non-mutating"
eq "peek returns current+1" "$(run "$T1/state.json" "$T1/nope.md" --peek-next)" "45"
eq "state left unchanged by peek" "$(jq -r .iteration_count "$T1/state.json")" "44"

# ── Scenario 4: migration — absent field seeds from docs/iterations/ MAX filename ─
echo "Scenario 4 — absent field migrates from iterations dir (max NNN prefix, not count)"
T2="$(mktemp -d)"
echo '{"scale_tier":"launch"}' > "$T2/state.json"
mkdir -p "$T2/iterations"
# Create files: filename format NNN-issue-NNNN-slug.md
touch "$T2/iterations/005-issue-100-older.md"
touch "$T2/iterations/012-issue-200-newest-number.md"
touch "$T2/iterations/008-issue-300-out-of-order.md"
touch "$T2/iterations/008-issue-301-dup.md"
eq "current seeds from max NNN (12), not count (4)" "$(run "$T2/state.json" "$T2/iterations")" "12"
eq "migration persisted the field" "$(jq -r .iteration_count "$T2/state.json")" "12"
# after seeding, the dir is never read again — prove it by removing it
rm -rf "$T2/iterations"
eq "subsequent read is O(1) (dir gone, still works)" "$(run "$T2/state.json" "$T2/iterations")" "12"

# ── Scenario 5: absent field + empty dir → seeds to 0 ────────────────────────────
echo "Scenario 5 — absent field, empty dir → 0"
T3="$(mktemp -d)"
echo '{}' > "$T3/state.json"
mkdir -p "$T3/empty"
eq "no field, empty dir → 0" "$(run "$T3/state.json" "$T3/empty")" "0"
eq "first --next from zero base → 1" "$(run "$T3/state.json" "$T3/empty" --next)" "1"

rm -rf "$T1" "$T2" "$T3" 2>/dev/null || true
echo
echo "iteration-count: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
