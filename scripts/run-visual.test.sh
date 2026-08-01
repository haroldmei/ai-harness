#!/usr/bin/env bash
# run-visual.test.sh — static assertions against scripts/run-visual.sh.
#
# Guards the key contracts of the visual-regression gate:
#   • runs ONLY the `visual` Playwright project (never the functional chromium project)
#   • detects cross-arch node_modules (esbuild probe, not just missing-file check)
#   • passes --update-snapshots when VISUAL_UPDATE=1
#   • uses a port band isolated from dev/e2e/lighthouse/integration stacks
#   • volume cleanup is scoped to the skillforge-visual project prefix
#
# All assertions are STATIC (grep the script source) — no docker daemon, no images,
# no network required.
#
#   Run: bash scripts/run-visual.test.sh     (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCRIPT="scripts/run-visual.sh"
[[ -f "$SCRIPT" ]] || { echo "run-visual.test: $SCRIPT not found"; exit 1; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "run-visual project-scope contract"

# 1) The Playwright invocation inside the container MUST include --project=visual.
#    The visual specs (*.visual.spec.ts) only pass inside the pinned container; omitting
#    the filter would run the functional chromium specs in the jammy image unnecessarily and
#    could also run them against container baselines that don't match.
if grep -E "playwright test" "$SCRIPT" | grep -qE "\-\-project=visual"; then
  ok "container playwright invocation is scoped to --project=visual"
else
  bad "playwright invocation missing --project=visual — may run functional specs in the container"
fi

# 2) The visual gate must NOT invoke the chromium project or run without any project filter
#    (which would pick up both projects). Guard both regressions.
if grep -E "playwright test" "$SCRIPT" | grep -qE "\-\-project=chromium"; then
  bad "found --project=chromium in run-visual.sh — functional specs should not run in the container"
else
  ok "no --project=chromium in the container invocation (functional specs excluded)"
fi

echo
echo "run-visual arch-mismatch guard contract"

# 3) The dependency guard must check MORE than just the playwright binary's presence. On a
#    non-Linux dev box, a host-arch node_modules may be mounted into the Linux container; the
#    playwright JS shim (architecture-agnostic) would exist but the native platform binaries
#    (esbuild, used by Playwright to transpile the TS config+specs) would fail to exec.
#    The guard must probe a known native binary — esbuild — to catch this case.
if grep -qE "esbuild.*--version|esbuild.*>/dev/null" "$SCRIPT"; then
  ok "arch-mismatch guard probes esbuild (catches host-arch node_modules in Linux container)"
else
  bad "arch-mismatch guard only checks playwright binary presence — will silently use wrong-arch node_modules on Mac/Windows"
fi

# 4) npm ci must be run inside the container (not on the host) when the guard fires, so the
#    installed binaries match the container platform.
if grep -qE "npm ci" "$SCRIPT"; then
  ok "npm ci is present (reinstalls deps inside the container when guard triggers)"
else
  bad "no npm ci — cannot recover from missing or wrong-arch node_modules inside the container"
fi

echo
echo "run-visual update-snapshots contract"

# 5) VISUAL_UPDATE=1 must pass --update-snapshots to Playwright so baseline PNGs can be
#    (re-)generated inside the pinned container and committed as the new ground truth.
if grep -qE 'VISUAL_UPDATE.*==.*1.*--update-snapshots|update-snapshots.*VISUAL_UPDATE' "$SCRIPT" || \
   grep -qE 'UPDATE_FLAG.*--update-snapshots' "$SCRIPT"; then
  ok "VISUAL_UPDATE=1 passes --update-snapshots to Playwright (baseline regeneration)"
else
  bad "VISUAL_UPDATE=1 does not trigger --update-snapshots — baseline regeneration broken"
fi

echo
echo "run-visual port-isolation contract"

# 6) The default starting ports must be distinct from the dev (3000/8000/5432/6379),
#    e2e (13000/18000/15432/16379), lighthouse (14000/19000/16432/17379) stacks so
#    they never collide on a box with multiple stacks running.
if grep -qE 'SF_FRONTEND_PORT.*145[0-9]{2}|145[0-9]{2}.*SF_FRONTEND_PORT' "$SCRIPT"; then
  ok "frontend port band starts at ~14500 (isolated from dev/e2e/lighthouse defaults)"
else
  bad "frontend port does not use the expected high band — risk of port collision with other stacks"
fi

echo
echo "run-visual volume-scope contract"

# 7) Any docker volume operations must be scoped to the skillforge-visual project prefix so
#    the dev stack's skillforge_postgres_data (no `-visual` infix) is never touched.
if grep -qE 'skillforge-visual' "$SCRIPT"; then
  ok "volume / project operations reference the skillforge-visual prefix"
else
  bad "no skillforge-visual prefix found — volume operations could overlap with the dev stack"
fi

echo
echo "run-visual contract: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
