#!/usr/bin/env bash
# Tests for openapi-check.sh — regression coverage for issue #2387: a second
# `trap … EXIT` (added for the PID-namespaced drift-diff file) REPLACED the first
# one instead of adding to it, so the `mktemp -t openapi-XXXXXX.yaml` scratch file
# leaked on every run — a leak introduced by the very sweep meant to remove leaks.
#
#   Run: bash scripts/openapi-check.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/test-env.sh
source "$ROOT/scripts/lib/test-env.sh"
test_env_scrub
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# This test runs the REAL script against the real repo's openapi.yaml/dump_openapi.py
# rather than a fake sandbox — the script resolves its own root from
# `dirname "${BASH_SOURCE[0]}"`, so it is not hermetic to a fake ROOT the way
# state-shard.sh (STATE_DIR) is. What we sandbox instead is where its two temp
# artifacts land: TMPDIR (honored by `mktemp -t`) and OPENAPI_DRIFT_DIFF, both
# pointed at a scratch dir this test owns and empties before asserting.
echo "Scenario 1 — openapi-check.sh leaves no temp artifacts behind on EXIT"
SCRATCH="$(mktemp -d)"
DRIFT="$SCRATCH/drift.diff"
out="$(cd "$ROOT" && TMPDIR="$SCRATCH" OPENAPI_DRIFT_DIFF="$DRIFT" bash scripts/openapi-check.sh 2>&1)"
rc=$?
leftover="$(find "$SCRATCH" -mindepth 1 2>/dev/null)"

if [[ "$rc" -eq 77 ]]; then
  echo "  (skip: openapi-check.sh reports 77 — python/app unavailable in this environment)"
  echo "  out: $out"
else
  if [[ -z "$leftover" ]]; then
    ok "no files remain under TMPDIR/OPENAPI_DRIFT_DIFF after exit $rc"
  else
    bad "leaked temp file(s) after exit $rc: $(printf '%s ' "$leftover")"
  fi
fi

rm -rf "$SCRATCH" 2>/dev/null || true

echo
echo "openapi-check: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
