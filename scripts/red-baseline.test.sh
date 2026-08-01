#!/usr/bin/env bash
# Hermetic test for scripts/red-baseline.sh — the "judge a gate by what it ADDS"
# baseline that stops a red base branch from being re-filed as one auto-blocker per
# lane (the #2381 → #2383 → #2384 → #2385 cascade).
#
#   Run: bash scripts/red-baseline.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/red-baseline.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"$'\n'"      expected: $3"$'\n'"      got:      $2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export RED_BASELINE_DIR="$TMP/baselines"
# Every scenario below is about the ids/diff/status contract, not the #2438 deps guard — record
# against $ROOT (this checkout) unguarded, so a worktree without node_modules (no JS install at
# all) still runs this suite hermetically. Scenario 9 explicitly re-enables the guard against its
# own throwaway fixture tree, which is the one place this suite means to exercise it.
export RED_BASELINE_SKIP_DEPS_CHECK=1

run() { bash "$HELPER" "$@"; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# ── Fixtures: real runner output shapes ──────────────────────────────────────────
cat > "$TMP/pytest.log" <<'EOF'
bringing up nodes...
........................................                                 [ 40%]
FAILED tests/unit/test_billing.py::TestSeats::test_seat_added_fires - AssertionError
FAILED tests/unit/test_auth.py::test_refresh_rotation
ERROR tests/unit/test_boot.py
=========================== 2 failed, 900 passed ===========================
EOF

cat > "$TMP/vitest.log" <<'EOF'
stdout | src/tests/Passing.test.tsx > SlidesToggle — query failure attacks > AT-016: when getSlidesSettings fails
some captured console output
 FAIL  src/tests/LoginPage.oauthProviders.test.tsx > LoginPage OAuth provider gating > renders only the Google button
 FAIL  src/tests/Sidebar.test.tsx > Sidebar > exposes a Pedagogy Policy link to a manager
 FAIL  src/tests/Broken.test.tsx [ src/tests/Broken.test.tsx ]
 Test Files  3 failed | 326 passed (329)
EOF

cat > "$TMP/playwright.log" <<'EOF'
Running 182 tests using 2 workers
  1) [chromium] › saml-sso-config.spec.ts:37:7 › SAML SSO configuration UI › enterprise admin configures SAML SSO
  2) [chromium] › webhook-config.spec.ts:16:7 › Webhook configuration UI › admin configures webhook URL
  2 failed
EOF

# ── Scenario 1: id extraction per runner ─────────────────────────────────────────
echo "Scenario 1 — extracts one stable id per failing test"
eq "pytest nodeids (incl. ERROR-at-collection)" \
   "$(run ids --log "$TMP/pytest.log" | paste -sd'|' -)" \
   "tests/unit/test_auth.py::test_refresh_rotation|tests/unit/test_billing.py::TestSeats::test_seat_added_fires|tests/unit/test_boot.py"

eq "vitest test-level + suite-level" \
   "$(run ids --log "$TMP/vitest.log" | paste -sd'|' -)" \
   "src/tests/Broken.test.tsx|src/tests/LoginPage.oauthProviders.test.tsx > LoginPage OAuth provider gating > renders only the Google button|src/tests/Sidebar.test.tsx > Sidebar > exposes a Pedagogy Policy link to a manager"

eq "playwright spec+title, line:col stripped" \
   "$(run ids --log "$TMP/playwright.log" | paste -sd'|' -)" \
   "saml-sso-config.spec.ts › SAML SSO configuration UI › enterprise admin configures SAML SSO|webhook-config.spec.ts › Webhook configuration UI › admin configures webhook URL"

# The #2124 trap: a PASSING test whose title contains "fails" is console-captured.
eq "console capture never becomes a failing id" \
   "$(run ids --log "$TMP/vitest.log" | grep -c 'Passing.test.tsx')" "0"

# ── Scenario 2: no baseline ⇒ unknown ⇒ caller fails closed ──────────────────────
echo "Scenario 2 — absent baseline is UNKNOWN (exit 2), never a free pass"
eq "diff exits 2 with no baseline" "$(rc_of run diff --gate unit --log "$TMP/vitest.log" --sha deadbeef)" "2"
eq "status exits 2 with no baseline" "$(rc_of run status --gate unit --sha deadbeef)" "2"

# ── Scenario 3: identical failures ⇒ forgiven ────────────────────────────────────
echo "Scenario 3 — a branch that adds nothing red is forgiven"
run record --gate unit --log "$TMP/vitest.log" --sha aaa111 >/dev/null
eq "diff exits 0 when the failure set is unchanged" \
   "$(rc_of run diff --gate unit --log "$TMP/vitest.log" --sha aaa111)" "0"
eq "status reports the recorded count" \
   "$(run status --gate unit --sha aaa111 | grep -oE 'tests=[0-9]+')" "tests=3"

# ── Scenario 4: a NEW failure is never forgiven ──────────────────────────────────
echo "Scenario 4 — one added failure keeps the gate red"
cat > "$TMP/vitest-plus.log" <<'EOF'
 FAIL  src/tests/LoginPage.oauthProviders.test.tsx > LoginPage OAuth provider gating > renders only the Google button
 FAIL  src/tests/Sidebar.test.tsx > Sidebar > exposes a Pedagogy Policy link to a manager
 FAIL  src/tests/Broken.test.tsx [ src/tests/Broken.test.tsx ]
 FAIL  src/tests/Regression.test.tsx > Billing > charges the right seat count
EOF
eq "diff exits 1 when a failure is new" \
   "$(rc_of run diff --gate unit --log "$TMP/vitest-plus.log" --sha aaa111)" "1"
eq "diff names ONLY the new failure" \
   "$(run diff --gate unit --log "$TMP/vitest-plus.log" --sha aaa111 2>/dev/null)" \
   "src/tests/Regression.test.tsx > Billing > charges the right seat count"

# ── Scenario 5: a PARTIAL fix stays forgiven ─────────────────────────────────────
# This is the property the triage's cluster fingerprint lacks: it hashes the whole
# failing FILE SET, so fixing part of a breakage produced a different hash, missed
# dedup, and filed a second issue for the same cause (#2383 and #2385).
echo "Scenario 5 — fixing PART of the inherited breakage is still forgiven"
cat > "$TMP/vitest-partial.log" <<'EOF'
 FAIL  src/tests/Sidebar.test.tsx > Sidebar > exposes a Pedagogy Policy link to a manager
EOF
eq "a subset of the baseline exits 0" \
   "$(rc_of run diff --gate unit --log "$TMP/vitest-partial.log" --sha aaa111)" "0"

# ── Scenario 6: baselines are per-sha and per-gate ───────────────────────────────
echo "Scenario 6 — a baseline is scoped to its exact base commit and gate"
eq "another sha does not inherit the baseline" \
   "$(rc_of run diff --gate unit --log "$TMP/vitest.log" --sha bbb222)" "2"
eq "another gate does not inherit the baseline" \
   "$(rc_of run diff --gate e2e --log "$TMP/vitest.log" --sha aaa111)" "2"

# ── Scenario 7: an unparseable failure is never forgiven ─────────────────────────
# A compile error / OOM / stack that never reached a test yields no ids. "No new ids"
# must NOT read as "all inherited", or a branch that fails to build goes green.
echo "Scenario 7 — a failure with no extractable test id fails closed"
printf 'error TS2304: Cannot find name %s\nBuild failed\n' "'foo'" > "$TMP/compile.log"
eq "diff exits 2 when no ids can be parsed" \
   "$(rc_of run diff --gate unit --log "$TMP/compile.log" --sha aaa111)" "2"

# ── Scenario 8: mixed-runner log (the real `unit` gate runs pytest AND vitest) ────
echo "Scenario 8 — one log carrying both runners"
cat "$TMP/pytest.log" "$TMP/vitest.log" > "$TMP/both.log"
run record --gate unit --log "$TMP/both.log" --sha ccc333 >/dev/null
eq "records ids from both runners" \
   "$(run status --gate unit --sha ccc333 | grep -oE 'tests=[0-9]+')" "tests=6"
eq "the combined log is forgiven against itself" \
   "$(rc_of run diff --gate unit --log "$TMP/both.log" --sha ccc333)" "0"

# ── Scenario 8b: the harness shell suites are the FOURTH runner in the `unit` gate ───
# unit.sh runs scripts/*.test.sh alongside pytest/vitest/playwright, but ids_from_log knew
# nothing about them, so a unit gate that failed ONLY on a shell suite extracted zero ids.
# `record` then wrote an empty baseline and announced "recorded 0 failing test(s)" for a gate
# that was red — read literally, that says the gate is green (observed on the 2026-08-01 mobile
# cut). `diff` fails closed on an empty extraction, so nothing was wrongly forgiven; the cost was
# the mirror image — an inherited-red shell suite could never be forgiven, so every branch off
# that base stayed red with no way out.
echo "Scenario 8b — harness shell-suite failures are extractable ids"
cat > "$TMP/shell.log" <<'EOF'
unit: harness shell suites (scripts/*.test.sh)
  running 38 suite(s) at concurrency 8
  ✓ agent-inbox.test.sh — passed: 87  failed: 0
  ✗ quality-gates.test.sh — failed (exit 1):
      ✗ --skip contract at launch → expected nonzero exit, got 0 (contract not required?)
      ✗ --skip: contract not recorded as a required-gate FAIL
  ✗ slow-suite.test.sh — TIMED OUT after 300s
  harness shell suites: 36 passed, 2 failed
EOF
eq "one id per FAILING suite (the passing suite is not collected)" \
   "$(run ids --log "$TMP/shell.log" | tr '\n' ' ' | sed 's/ *$//')" \
   "scripts/quality-gates.test.sh scripts/slow-suite.test.sh"
eq "the indented per-assertion ✗ lines are not mistaken for suites" \
   "$(run ids --log "$TMP/shell.log" | grep -c 'skip contract')" "0"
eq "a timed-out suite counts as a failing suite" \
   "$(run ids --log "$TMP/shell.log" | grep -c 'slow-suite')" "1"
run record --gate unit --log "$TMP/shell.log" --sha 8b8b8b >/dev/null
eq "record no longer reports a red gate as '0 failing test(s)'" \
   "$(run status --gate unit --sha 8b8b8b | grep -oE 'tests=[0-9]+')" "tests=2"
eq "an inherited-red shell suite is now forgivable against its own baseline" \
   "$(rc_of run diff --gate unit --log "$TMP/shell.log" --sha 8b8b8b)" "0"
# …and a NEWLY red shell suite must still fail the gate — the forgiveness must not widen
# to "any shell suite failure is inherited".
cat "$TMP/shell.log" > "$TMP/shell-plus.log"
printf '  ✗ brand-new.test.sh — failed (exit 1):\n' >> "$TMP/shell-plus.log"
eq "a suite that goes red on the branch is NOT forgiven" \
   "$(rc_of run diff --gate unit --log "$TMP/shell-plus.log" --sha 8b8b8b)" "1"

# ── Scenario 9: a deps-broken tree can never RECORD a baseline (#2438) ───────────
# An incomplete npm-workspaces install fails ~154 mobile suites at TRANSFORM time. Recording that
# as "already red on the base" pardons the entire mobile suite for every branch off that commit —
# the same end state as editing tests to assert broken behaviour, reached from the other side.
# Not hypothetical: the merger's deps-broken run wrote a 154-entry `unit` baseline for c4b2609a,
# a commit whose unit gate passes in any healthy worktree.
echo "Scenario 9 — a tree that cannot resolve its workspaces must not record a baseline"
BROKEN="$TMP/broken-tree"
mkdir -p "$BROKEN/mobile"
printf '{"name":"t","workspaces":["mobile"]}\n' > "$BROKEN/package.json"
printf '{ "extends": "expo/tsconfig.base" }\n' > "$BROKEN/mobile/tsconfig.json"
printf '{"name":"mobile"}\n' > "$BROKEN/mobile/package.json"
# The workspace's own npm-workspaces self-link (deps_workspace_unlinked) — present, so the only
# unresolved thing in this fixture is the THIRD-PARTY dependency (expo) the scenario is about.
mkdir -p "$BROKEN/node_modules/mobile"
out="$(RED_BASELINE_SKIP_DEPS_CHECK=0 RED_BASELINE_ROOT="$BROKEN" run record --gate unit --log "$TMP/vitest.log" --sha ddd444 2>&1)"
eq "record exits 2 on an unresolvable tree" \
   "$(rc_of env RED_BASELINE_SKIP_DEPS_CHECK=0 RED_BASELINE_ROOT="$BROKEN" bash "$HELPER" record --gate unit --log "$TMP/vitest.log" --sha ddd444)" "2"
case "$out" in *"REFUSING to record"*) ok "and says why, naming the unresolved package" ;;
  *) bad "no refusal message: $out" ;; esac
case "$out" in *"expo"*) ok "the message names the package that cannot resolve" ;;
  *) bad "the refusal did not name the package: $out" ;; esac
# Absent, not empty: `diff` must still fail CLOSED afterwards rather than forgive everything.
eq "no baseline file was written (absent ⇒ fails closed)" \
   "$(rc_of run status --gate unit --sha ddd444)" "2"

# Counter-check: the SAME tree with the package installed records normally, so the guard keys off
# resolvability and not on the workspace merely existing.
mkdir -p "$BROKEN/mobile/node_modules/expo"; printf '{"name":"expo"}\n' > "$BROKEN/mobile/node_modules/expo/package.json"
eq "a resolvable tree records as before" \
   "$(rc_of env RED_BASELINE_SKIP_DEPS_CHECK=0 RED_BASELINE_ROOT="$BROKEN" bash "$HELPER" record --gate unit --log "$TMP/vitest.log" --sha ddd444)" "0"
eq "and the baseline is present with the right count" \
   "$(run status --gate unit --sha ddd444 | grep -oE 'tests=[0-9]+')" "tests=3"

# ── Scenario 10: the deps guard is scoped to gates that actually LOAD JS modules ──
# `integration` is backend pytest + Docker; it can be legitimately run and recorded on a base tree
# that never had a JS install at all. The guard must not refuse that baseline — refusing silently
# turns off the inherited-red forgiveness (#2381→#2385) for a gate the deps check has nothing to
# say about.
echo "Scenario 10 — the deps guard does not block a gate that never loads JS (e.g. integration)"
BROKEN2="$TMP/broken-tree-2"
mkdir -p "$BROKEN2/mobile"
printf '{"name":"t","workspaces":["mobile"]}\n' > "$BROKEN2/package.json"
printf '{ "extends": "expo/tsconfig.base" }\n' > "$BROKEN2/mobile/tsconfig.json"
printf '{"name":"mobile"}\n' > "$BROKEN2/mobile/package.json"
mkdir -p "$BROKEN2/node_modules/mobile"
eq "an integration baseline records fine on the SAME unresolvable tree that blocked unit" \
   "$(rc_of env RED_BASELINE_SKIP_DEPS_CHECK=0 RED_BASELINE_ROOT="$BROKEN2" bash "$HELPER" record --gate integration --log "$TMP/pytest.log" --sha eee555)" "0"
eq "and the integration baseline is present" \
   "$(run status --gate integration --sha eee555 | grep -oE 'tests=[0-9]+')" "tests=3"
eq "a unit baseline on the SAME broken tree is still refused (the scoping is per-gate, not global)" \
   "$(rc_of env RED_BASELINE_SKIP_DEPS_CHECK=0 RED_BASELINE_ROOT="$BROKEN2" bash "$HELPER" record --gate unit --log "$TMP/pytest.log" --sha eee555)" "2"
eq "RED_BASELINE_DEPS_GATES widens the scope to a gate not in the default list" \
   "$(rc_of env RED_BASELINE_SKIP_DEPS_CHECK=0 RED_BASELINE_DEPS_GATES="integration" RED_BASELINE_ROOT="$BROKEN2" bash "$HELPER" record --gate integration --log "$TMP/pytest.log" --sha fff666)" "2"

echo
printf 'red-baseline.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
