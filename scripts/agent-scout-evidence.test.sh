#!/usr/bin/env bash
# Regression test for verify_evidence (agent-scout.sh #7). The bug it guards: basename-shorthand
# `file:line` refs (e.g. "orgs.ts:302" after the full path is cited once) wrongly caused an
# `evidence-not-found` DROP, silently discarding real findings. These cases pin the contract:
#   keep if ≥1 cited location resolves to a real, in-range line; drop only pure fabrications.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# Define verify_evidence exactly as it appears in the script under test (no fork to drift).
eval "$(sed -n '/^verify_evidence() {/,/^}/p' "$ROOT/scripts/agent-scout.sh")"

# A worktree git repo with a nested file (the shape real evidence cites).
wt="$(mktemp -d)"
( cd "$wt"; git init -q; git config user.email t@t; git config user.name t
  mkdir -p services/api-gateway/src/routes
  seq 400 > services/api-gateway/src/routes/orgs.ts            # a 400-line real file
  git add -A; git commit -qm init ) >/dev/null 2>&1

# 1) THE BUG: full path once + basename shorthands → must be KEPT (return 0).
if verify_evidence "orgs guard: services/api-gateway/src/routes/orgs.ts:179 ownerCount; DELETE orgs.ts:302 then orgs.ts:309 in a separate tx"; then
  ok "real file via full-path + basename shorthand is KEPT (the regression)"
else
  bad "basename-shorthand evidence was wrongly dropped (the bug is back)"
fi

# 2) Pure fabrication (no cited path resolves) → DROP (return 1).
if verify_evidence "see totally-made-up-fabricated-file.ts:42 which does not exist"; then
  bad "fabricated-only evidence should be dropped"
else
  ok "pure-fabrication evidence is dropped"
fi

# 3) No path:line refs at all → don't block (critic judged plausibility).
if verify_evidence "this prose cites no code locations whatsoever"; then
  ok "evidence with no refs is not blocked"
else
  bad "no-ref evidence was wrongly dropped"
fi

# 4) One out-of-range ref + one in-range ref → KEEP (at least one resolves in range).
if verify_evidence "orgs.ts:99999 (past EOF) but also orgs.ts:50 (valid)"; then
  ok "kept when at least one cited line resolves in range"
else
  bad "should keep when a valid in-range ref exists"
fi

rm -rf "$wt"
echo; echo "verify_evidence regression: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
