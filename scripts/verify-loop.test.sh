#!/usr/bin/env bash
# Regression test for verify-loop.sh's spawn-failure message (issue #2387).
#
# verify-loop.sh is a full pipeline orchestrator (spawns `claude -p`, drives
# quality-gates.sh, reads/writes the sharded blackboard) with no seam for a
# hermetic end-to-end run, so this is a static assertion rather than a live
# invocation: it checks the exact operator-facing message printed when the
# fixer spawn exits non-zero.
#
# The bug: `VERIFY_FIX_LOGDIR` replaced the hardcoded `/tmp` prefix for where
# per-gate fixer logs are written (PID-namespaced, since three lanes share
# /tmp), but the ONE message telling an operator where to look after a spawn
# failure kept the old literal `/tmp/verify-fix-${gate}.log` — a path that no
# longer exists once VERIFY_FIX_LOGDIR is set to anything else, which is the
# only case where reading this message matters.
#
#   Run: bash scripts/verify-loop.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/verify-loop.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "Scenario 1 — spawn-failure message points at the real (VERIFY_FIX_LOGDIR) log path"
line="$(grep -n 'fixer spawn for' "$SCRIPT" || true)"
if [[ -z "$line" ]]; then
  bad "could not find the spawn-failure message in $SCRIPT"
elif [[ "$line" == *'${VERIFY_FIX_LOGDIR}/verify-fix-${gate}.log'* ]]; then
  ok "message interpolates \${VERIFY_FIX_LOGDIR}"
else
  bad "message does not reference \${VERIFY_FIX_LOGDIR}: $line"
fi

if [[ "$line" == *'see /tmp/verify-fix-${gate}.log'* ]]; then
  bad "message still hardcodes the stale /tmp/verify-fix-\${gate}.log path"
else
  ok "message does not hardcode the stale /tmp path"
fi

echo
echo "verify-loop: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
