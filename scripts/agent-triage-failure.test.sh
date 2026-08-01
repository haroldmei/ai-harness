#!/usr/bin/env bash
# Hermetic test for scripts/agent-triage-failure.sh — the self-heal failure router.
#
# Drives the REAL script with `gh` STUBBED (zero GitHub side-effects). Each scenario feeds a
# representative gate log + the agent's changed-file list and asserts the routing DECISION
# and the gh calls it makes (file / comment / label).
#
#   Run: bash scripts/agent-triage-failure.test.sh     (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/agent-triage-failure.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
agrep()   { if grep -qF -e "$2" -- "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
angrep()  { if grep -qF -e "$2" -- "$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

# gh stub: records every call; serves canned reads. SEARCH_HIT=<n> makes the dedup search
# return an existing open blocker carrying the marker; otherwise reads return empty sets.
make_gh() { # <dir>
  cat > "$1/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS"
# dedup search → existing blocker?
if [ "$1" = issue ] && [ "$2" = list ] && printf '%s ' "$@" | grep -q -- '--search'; then
  if [ -n "${SEARCH_HIT:-}" ]; then
    echo "[{\"number\":${SEARCH_HIT},\"body\":\"x ${FP_MARKER:-} x\"}]"; else echo '[]'; fi
  exit 0
fi
# open auto-filed count (label harness/flaky) → empty unless OPEN_COUNT set
if [ "$1" = issue ] && [ "$2" = list ]; then
  if [ -n "${OPEN_COUNT:-}" ]; then
    seq 1 "$OPEN_COUNT" | awk '{print "{\"number\":"$1"}"}' | paste -sd, - | sed 's/^/[/; s/$/]/'
  else echo '[]'; fi
  exit 0
fi
if [ "$1" = issue ] && [ "$2" = view ] && printf '%s ' "$@" | grep -q -- '--json comments'; then
  echo "${SELF_REPAIR_COUNT:-0}"; exit 0   # self_repair_attempts() jq → count of marker comments
fi
if [ "$1" = issue ] && [ "$2" = view ] && printf '%s ' "$@" | grep -q -- '--json body'; then
  echo "${SELF_BODY:-}"; exit 0     # the triaged issue's own body (carries the marker iff self-blocker)
fi
if [ "$1" = issue ] && [ "$2" = create ]; then
  [ -n "${CREATE_FAIL:-}" ] && exit 1
  echo "https://github.com/t/r/issues/777"; exit 0
fi
exit 0
GH
  chmod +x "$1/gh"
}

run() { # <tmp> <logfile> <changedfile> [extra env...]
  local tmp="$1" lg="$2" ch="$3"; shift 3
  GH_CALLS="$tmp/gh.log" FP_MARKER="${FP_MARKER:-}" \
  TRIAGE_GH="$tmp/gh" TRIAGE_STATE_DIR="$tmp/state" "$@" \
    bash "$RUNNER" --issue 42 --branch agent/issue-42 --base main \
      --root "$tmp" --log "$lg" --changed "$ch" > "$tmp/out.txt" 2>&1
}

# The computed fingerprint, via a side-effect-free --dry-run (reads the `[triage] fingerprint=`
# log line). Used by the #937 regression to assert distinct, test-anchored signatures.
fp_of() { # <tmp> <logfile> <changedfile>
  TRIAGE_GH="$1/gh" TRIAGE_STATE_DIR="$1/fpstate" \
    bash "$RUNNER" --dry-run --issue 42 --branch agent/issue-42 --base main \
      --root "$1" --log "$2" --changed "$3" 2>&1 \
    | grep -oE 'fingerprint=[^ ]+' | head -1 | cut -d= -f2-
}

# ── Scenario 1: transient → retry, no file ───────────────────────────────────────
echo "Scenario 1 — transient (session limit) → retry, no issue filed"
T="$(mktemp -d)"; make_gh "$T"
printf "You've hit your session limit · resets at 5pm\n" > "$T/log"
printf "scripts/agent-inbox.sh\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep  "$T/out.txt" "action=retry" "classified transient → retry"
angrep "$T/gh.log"  "issue create" "no blocker issue filed for a transient error"
agrep  "$T/gh.log"  "labels/wip"   "wip label dropped (will retry next tick)"

# ── Scenario 2: infra → file harness blocker + block current ─────────────────────
echo "Scenario 2 — infra (alembic can't-locate-revision) → file harness blocker"
T="$(mktemp -d)"; make_gh "$T"
printf "ERROR [alembic.util.messaging] Can't locate revision identified by '038'\nFAILED: Can't locate revision identified by '038'\n" > "$T/log"
printf "scripts/agent-inbox.sh\nbackend/app/models/learning_path.py\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep "$T/out.txt" "class=infra"     "classified infra"
agrep "$T/gh.log"  "issue create"    "harness blocker issue filed"
agrep "$T/gh.log"  "--label harness" "blocker labelled harness"
agrep "$T/gh.log"  "labels[]=blocked" "current issue marked blocked"
agrep "$T/gh.log"  "labels/wip"      "wip dropped on the blocked issue"

# ── Scenario 3: unrelated → file flaky blocker (failure NOT in changed files) ─────
echo "Scenario 3 — unrelated e2e spec (not in changed files) → file flaky blocker"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
  2 failed
  1) [chromium] › seat-role-lockout.spec.ts:16:7 › Seat management — last-admin lockout
    TimeoutError: locator.click: Timeout 15000ms exceeded.
    at /tmp/wt/frontend/tests/e2e/seat-role-lockout.spec.ts:70:73
L
printf "scripts/run-e2e.sh\nbackend/tests/unit/test_alembic_migrations.py\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep "$T/out.txt" "class=unrelated" "classified unrelated (no overlap with changed files)"
agrep "$T/gh.log"  "--label flaky"   "blocker labelled flaky"
agrep "$T/gh.log"  "labels[]=blocked" "current issue marked blocked"

# ── Scenario 4: self → self-repair (re-queue with the gate log, NOT needs-human) ──
echo "Scenario 4 — failure in the agent's OWN file, first time → self-repair (re-queue)"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
  1 failed
  1) [chromium] › seat-role-lockout.spec.ts:16:7 › Seat management
    at /tmp/wt/frontend/tests/e2e/seat-role-lockout.spec.ts:70:73
L
printf "frontend/tests/e2e/seat-role-lockout.spec.ts\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep  "$T/out.txt" "action=self-repair"   "self-fault, first time → self-repair (not a dead-end)"
angrep "$T/gh.log"  "labels[]=needs-human" "NOT escalated to needs-human on the first self failure"
angrep "$T/gh.log"  "issue create"         "no blocker filed for a self failure"
agrep  "$T/gh.log"  "issue comment 42"     "left a self-repair comment (with the failure log)"
agrep  "$T/gh.log"  "labels/wip"           "wip dropped → re-queued (eligible again next tick)"

# ── Scenario 9: self-repair EXHAUSTED → needs-human ──────────────────────────────
echo "Scenario 9 — self failure after MAX_SELF_REPAIR prior attempts → needs-human"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
  1 failed
  1) [chromium] › seat-role-lockout.spec.ts:16:7 › Seat management
    at /tmp/wt/frontend/tests/e2e/seat-role-lockout.spec.ts:70:73
L
printf "frontend/tests/e2e/seat-role-lockout.spec.ts\n" > "$T/changed"
run "$T" "$T/log" "$T/changed" env SELF_REPAIR_COUNT=2 TRIAGE_MAX_SELF_REPAIR=2
agrep  "$T/out.txt" "action=needs-human"   "self-repair exhausted → needs-human"
agrep  "$T/gh.log"  "labels[]=needs-human" "issue escalated after the retry budget"

# ── Scenario 5: dedup → attach to existing blocker, do not re-file ───────────────
echo "Scenario 5 — an open blocker already exists for this fingerprint → attach, no new issue"
T="$(mktemp -d)"; make_gh "$T"
printf "FAILED: Can't locate revision identified by '038'\n" > "$T/log"
printf "scripts/agent-inbox.sh\n" > "$T/changed"
# the search must return the SAME marker the script computes → provide it via FP_MARKER
FP_MARKER="<!-- triage-fp:gate:cant-locate-revision-identified-by -->" \
SEARCH_HIT=500 run "$T" "$T/log" "$T/changed" env SEARCH_HIT=500 FP_MARKER="<!-- triage-fp:gate:cant-locate-revision-identified-by -->"
angrep "$T/gh.log" "issue create"        "no duplicate issue filed (deduped)"
agrep  "$T/gh.log" "issue comment 500"   "attached to the existing blocker #500"
agrep  "$T/gh.log" "labels[]=blocked"    "current issue still marked blocked"

# ── Scenario 6: per-fingerprint attempt cap → escalate after MAX_ATTEMPTS ─────────
echo "Scenario 6 — attempt cap (MAX_ATTEMPTS=1): 2nd auto-file attempt escalates to needs-human"
T="$(mktemp -d)"; make_gh "$T"
printf "FAILED: Can't locate revision identified by '038'\n" > "$T/log"
printf "scripts/agent-inbox.sh\n" > "$T/changed"
run "$T" "$T/log" "$T/changed" env TRIAGE_MAX_ATTEMPTS=1   # attempt #1 → files
agrep "$T/gh.log" "issue create" "1st attempt files the blocker"
: > "$T/gh.log"                                            # clear, run again on same ledger
run "$T" "$T/log" "$T/changed" env TRIAGE_MAX_ATTEMPTS=1   # attempt #2 → cap hit
angrep "$T/gh.log" "issue create"        "2nd attempt does NOT file again (cap hit)"
agrep  "$T/gh.log" "labels[]=needs-human" "2nd attempt escalates to needs-human"

# ── Scenario 7: issue-create fails → escalate, never mark blocked against a phantom ──
echo "Scenario 7 — gh issue create fails → needs-human (no phantom 'blocked')"
T="$(mktemp -d)"; make_gh "$T"
printf "FAILED: Can't locate revision identified by '038'\n" > "$T/log"
printf "scripts/agent-inbox.sh\n" > "$T/changed"
run "$T" "$T/log" "$T/changed" env CREATE_FAIL=1
agrep  "$T/out.txt" "action=needs-human" "create failure escalates to needs-human"
angrep "$T/gh.log"  "labels[]=blocked"   "issue NOT marked blocked when no blocker was filed"

# ── Scenario 8: an auto-filed blocker that fails AGAIN on its own fingerprint → needs-human ─
echo "Scenario 8 — issue is the designated fix for its own fingerprint → needs-human (no self-block / chain)"
T="$(mktemp -d)"; make_gh "$T"
printf "FAILED: Can't locate revision identified by '038'\n" > "$T/log"
printf "scripts/agent-inbox.sh\n" > "$T/changed"
# discover the fingerprint via a side-effect-free dry-run, then feed it back as THIS issue's body
fp="$(TRIAGE_GH="$T/gh" TRIAGE_STATE_DIR="$T/s" bash "$RUNNER" --dry-run --issue 42 \
      --branch agent/issue-42 --base main --root "$T" --log "$T/log" --changed "$T/changed" 2>&1 \
      | grep -oE 'fingerprint=[^ ]+' | head -1 | cut -d= -f2)"
GH_CALLS="$T/gh.log" SELF_BODY="<!-- triage-fp:${fp} -->" TRIAGE_GH="$T/gh" TRIAGE_STATE_DIR="$T/s" \
  bash "$RUNNER" --issue 42 --branch agent/issue-42 --base main \
    --root "$T" --log "$T/log" --changed "$T/changed" > "$T/out.txt" 2>&1
agrep  "$T/out.txt" "action=needs-human" "self-blocker fails again → needs-human"
angrep "$T/gh.log"  "issue create"       "no new blocker filed (no chain)"
angrep "$T/gh.log"  "labels[]=blocked"   "issue NOT marked blocked against itself"

# ── Scenario 10: branch-introduced migrate crash IN the diff → self, NOT infra (#172) ──
echo "Scenario 10 — alembic upgrade head dies on a migration in the agent's diff → self/migrate-failure"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
✗ e2e   fail
  INFO  [alembic.runtime.migration] Running upgrade 041 -> 042, add enrollment unique
migrate: non-transient failure — asyncpg DuplicateTableError:
relation "uq_enrollment_user_course" already exists
api exited (1)
dependency failed to start: container skillforge-api exited (1)
e2e stack teardown: Removing skillforge-api ... done
L
printf "backend/alembic/versions/042_add_enrollment_unique.py\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep  "$T/out.txt" "class=self"          "migrate crash in own diff → self (not infra)"
agrep  "$T/out.txt" "action=self-repair"  "routed to self-repair (re-queued with the error)"
agrep  "$T/out.txt" "fp=e2e:migrate-failure" "sub-fingerprinted e2e:migrate-failure (not dependency-failed-to-start)"
angrep "$T/gh.log"  "issue create"        "NOT filed as an infra/harness blocker"
angrep "$T/gh.log"  "--label harness"     "no harness blocker labelled"
agrep  "$T/gh.log"  "issue comment 42"    "left a self-repair comment for the build agent"
agrep  "$T/gh.log"  "DuplicateTableError" "the migrate error (not just the compose tail) is in the comment"
agrep  "$T/gh.log"  "labels/wip"          "wip dropped → re-queued next tick"

# ── Scenario 11: migrate crash NOT in the diff → infra (block + retry), no regression ──
echo "Scenario 11 — migrate marker but no migration/model in the diff → infra (still blocks)"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
✗ e2e   fail
migrate: non-transient failure — asyncpg DuplicateObject: type "x" already exists
dependency failed to start: container skillforge-api exited (1)
L
printf "frontend/src/App.tsx\nscripts/run-e2e.sh\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep  "$T/out.txt" "class=infra"      "migrate crash outside the diff → infra"
agrep  "$T/gh.log"  "issue create"     "harness blocker filed"
agrep  "$T/gh.log"  "--label harness"  "blocker labelled harness"
agrep  "$T/gh.log"  "labels[]=blocked" "current issue marked blocked"

# ── Scenario 12: genuine poisoned-volume infra (no migrate marker) → infra even with a
#    migration in the diff. Guards the migrate branch from over-claiming `self`. ──
echo "Scenario 12 — poisoned Postgres volume (password auth) with a migration in the diff → infra, NOT self"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
✗ e2e   fail
db   | FATAL:  password authentication failed for user "skillforge"
dependency failed to start: container skillforge-api exited (1)
L
printf "backend/alembic/versions/099_add_widget.py\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep  "$T/out.txt" "class=infra"      "real infra brick stays infra even with a migration in the diff"
angrep "$T/out.txt" "action=self-repair" "NOT routed to self (no migrate-error marker present)"
agrep  "$T/gh.log"  "--label harness"  "filed as harness/infra blocker"

# ── Scenario 13: #937 — fingerprint anchors on the failing TEST id, not a lossy slug ──
# The lossy slug let unrelated failures collapse into `unit:config-py`, corrupting the
# per-fingerprint attempt counter and mislabeling the escalation. Anchor on the test identity.
echo "Scenario 13 — distinct failing tests get distinct, test-anchored fingerprints (#937)"
T="$(mktemp -d)"; make_gh "$T"
printf "x\n" > "$T/changed"   # changed file is irrelevant to the fingerprint

# (a) The real incident: a doc-sync unit test whose traceback frame mentions config.py. The OLD
#     fingerprinter picked `config.py` (alphabetically first failing-area) → `unit:config-py`.
cat > "$T/log.a" <<'L'
✗ unit   fail   1 failed, 842 passed
=================================== FAILURES ===================================
_____________ test_wif_provider_documented_under_workflow_names ________________
backend/app/config.py:42: PydanticUserError: settings misconfigured
E   AssertionError: WIF provider not documented under workflow_names
FAILED backend/tests/unit/test_deploy_vars_doc_sync.py::test_wif_provider_documented_under_workflow_names - AssertionError: WIF provider not documented
L
fpa="$(fp_of "$T" "$T/log.a" "$T/changed")"
case "$fpa" in
  *test_deploy_vars_doc_sync__test_wif_provider*) ok "pytest fp anchors on the real failing test ($fpa)";;
  *) bad "pytest fp anchors on the real failing test (got: $fpa)";;
esac
case "$fpa" in
  *config_py*|*config-py*) bad "pytest fp must NOT collapse into config-py (got: $fpa)";;
  *) ok "pytest fp does NOT collapse into config-py";;
esac

# (b) A genuinely different unit test failure → must NOT share the same fingerprint.
cat > "$T/log.b" <<'L'
✗ unit   fail   1 failed, 842 passed
FAILED backend/tests/unit/test_logging_config.py::test_json_formatter_includes_request_id - AssertionError
L
fpb="$(fp_of "$T" "$T/log.b" "$T/changed")"
case "$fpb" in
  *test_logging_config__test_json_formatter_includes_request_id*) ok "second pytest fp names its own test ($fpb)";;
  *) bad "second pytest fp names its own test (got: $fpb)";;
esac
if [ -n "$fpa" ] && [ "$fpa" != "$fpb" ]; then ok "two different failing tests → different fingerprints"
else bad "distinct tests must not collapse to one fp (a=$fpa b=$fpb)"; fi

# (c) vitest spec+title (the earlier MobileDrawer ADMIN_ITEMS regression) → test-anchored, distinct.
cat > "$T/log.c" <<'L'
✗ unit   fail
 FAIL  src/components/MobileDrawer.adversarial.test.tsx > MobileDrawer > shows the correct ADMIN_ITEMS count
AssertionError: expected 5 to be 4
L
fpc="$(fp_of "$T" "$T/log.c" "$T/changed")"
case "$fpc" in
  *mobiledrawer_adversarial__*admin_items*|*mobiledrawer*shows*) ok "vitest fp anchors on spec+title ($fpc)";;
  *) bad "vitest fp anchors on spec+title (got: $fpc)";;
esac
if [ "$fpc" != "$fpa" ] && [ "$fpc" != "$fpb" ]; then ok "vitest fp distinct from the pytest fps"
else bad "vitest fp collided with a pytest fp ($fpc)"; fi

# (d) Playwright spec+title → spec basename + test title.
cat > "$T/log.d" <<'L'
✗ e2e   fail
  1) [chromium] › seat-role-lockout.spec.ts:16:7 › Seat management — last-admin lockout
    TimeoutError: locator.click: Timeout 15000ms exceeded.
L
fpd="$(fp_of "$T" "$T/log.d" "$T/changed")"
case "$fpd" in
  *seat_role_lockout__seat_management*) ok "playwright fp anchors on spec+title ($fpd)";;
  *) bad "playwright fp anchors on spec+title (got: $fpd)";;
esac

# (e) No extractable test id → tagged `unclassified` so it's an obvious low-confidence bucket.
cat > "$T/log.e" <<'L'
✗ lint   fail
Error: something went wrong in a place with no test identifier
make: *** [build] Error 1
L
fpe="$(fp_of "$T" "$T/log.e" "$T/changed")"
case "$fpe" in
  *unclassified*) ok "untestable failure is tagged unclassified ($fpe)";;
  *) bad "untestable failure must be tagged unclassified (got: $fpe)";;
esac

# ── Scenario 14: vitest CONSOLE CAPTURE from a PASSING test is never the fingerprint (#2124) ──
# `stderr | ….test.tsx > Suite — query failure attacks > AT-016: …when getSlidesSettings fails`
# is output emitted BY a test that passed. It used to win the fingerprint (matching bare "fail"
# on any line naming a spec), pointing every retry and the human escalation at an innocent test.
echo "Scenario 14 — vitest console-capture line from a passing test is not fingerprinted"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
✗ unit   fail
stderr | src/tests/adversarial/OrgPedagogyPage.adversarial.test.tsx > SlidesGenerationToggle — query failure attacks > AT-016: shows an error+retry card when getSlidesSettings fails
Warning: Received the string `false` for the boolean attribute `checked`.
 ✓ src/tests/adversarial/OrgPedagogyPage.adversarial.test.tsx (15 tests) 786ms
 FAIL  src/__tests__/offline-store.test.ts [ src/__tests__/offline-store.test.ts ]
Error: Failed to resolve import "../services/offlineStore" from "src/__tests__/offline-store.test.ts"
L
printf "mobile/src/services/offlineStore.ts\n" > "$T/changed"
fp14="$(fp_of "$T" "$T/log" "$T/changed")"
case "$fp14" in
  *orgpedagogy*) bad "console capture from a PASSING test became the fingerprint ($fp14)";;
  *offline_store*) ok "fingerprint anchors on the actually-failing file ($fp14)";;
  *) bad "expected the failing file in the fingerprint (got: $fp14)";;
esac

# ── Scenario 15: dependency brick → transient retry, no blocker, package-anchored fp (#2124) ──
echo "Scenario 15 — unresolvable BARE package across many test files → transient (deps), no issue filed"
T="$(mktemp -d)"; make_gh "$T"
{ echo "✗ unit   fail"
  for f in a b c d e f; do
    echo " FAIL  src/__tests__/${f}.test.tsx [ src/__tests__/${f}.test.tsx ]"
  done
  echo "Caused by: Error: Cannot find module 'expo/tsconfig.base/tsconfig.json'"
  echo "Require stack:"
  echo "- /tmp/wt/mobile/tsconfig.json"
  echo "RESULT: 1 gate(s) FAILED"
} > "$T/log"
printf "mobile/src/screens/CoursesScreen.tsx\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep  "$T/out.txt" "class=transient"          "deps brick classified transient (not a code failure)"
agrep  "$T/out.txt" "fp=unit:deps-unresolved-expo" "fingerprint anchors on the MISSING PACKAGE, not a random test file"
angrep "$T/gh.log"  "issue create"             "no blocker issue filed for a deps brick"
angrep "$T/gh.log"  "labels[]=needs-human"     "no needs-human for a deps brick"
angrep "$T/gh.log"  "labels[]=blocked"         "parent issue is not blocked by a deps brick"
agrep  "$T/gh.log"  "labels/wip"               "wip dropped → rebuilt with a fresh install next tick"

# ── Scenario 16: ONE broken relative import is the agent's own bug, NOT a deps brick ─────
echo "Scenario 16 — single unresolved RELATIVE import in the agent's own file → self, not deps"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
✗ unit   fail
 FAIL  src/__tests__/offline-store.test.ts [ src/__tests__/offline-store.test.ts ]
Error: Failed to resolve import "./helpers/missingThing" from "src/services/offlineStore.ts"
RESULT: 1 gate(s) FAILED
L
printf "mobile/src/services/offlineStore.ts\nmobile/src/__tests__/offline-store.test.ts\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep  "$T/out.txt" "class=self"     "a relative-import break in the agent's own file stays self"
angrep "$T/out.txt" "deps-unresolved" "not misread as a dependency brick (relative specifier, 1 file)"

# ── Scenario 15b/15c: a missing package the AGENT introduced is its OWN bug, not a brick ──
# Importing a dependency without declaring it produces the same log as a provisioning brick, but
# it is auto-fixable via self-repair. Routing it to the deps class would burn MAX_TRANSIENT ticks
# re-running an install that can never help, then dead-end on needs-human.
echo "Scenario 15b — missing package + a manifest in the diff → self, not a deps brick"
T="$(mktemp -d)"; make_gh "$T"
{ echo "✗ unit   fail"
  for f in a b c d e f; do echo " FAIL  src/__tests__/${f}.test.tsx [ src/__tests__/${f}.test.tsx ]"; done
  echo 'Error: Failed to resolve import "lodash-es" from "src/lib/formatters.ts"'
  echo "RESULT: 1 gate(s) FAILED"
} > "$T/log"
printf "frontend/src/lib/formatters.ts\nfrontend/package.json\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
angrep "$T/out.txt" "deps-unresolved"  "a manifest in the diff disqualifies the deps class"
angrep "$T/out.txt" "class=transient"  "not retried x8 for a dependency the agent forgot to declare"
agrep  "$T/out.txt" "class=self"       "routed to self (auto-fixable via self-repair)"

echo "Scenario 15c — missing package imported BY one of the agent's own changed files → self"
T="$(mktemp -d)"; make_gh "$T"
{ echo "✗ unit   fail"
  for f in a b c d e f; do echo " FAIL  src/__tests__/${f}.test.tsx [ src/__tests__/${f}.test.tsx ]"; done
  echo 'Error: Failed to resolve import "lodash-es" from "src/lib/formatters.ts"'
  echo "RESULT: 1 gate(s) FAILED"
} > "$T/log"
printf "frontend/src/lib/formatters.ts\n" > "$T/changed"   # no manifest — the importer alone
run "$T" "$T/log" "$T/changed"
angrep "$T/out.txt" "deps-unresolved" "the importing file being the agent's own disqualifies deps"
agrep  "$T/out.txt" "class=self"      "routed to self"

echo "Scenario 15d — same log, importer NOT in the diff → still a deps brick"
T="$(mktemp -d)"; make_gh "$T"
{ echo "✗ unit   fail"
  for f in a b c d e f; do echo " FAIL  src/__tests__/${f}.test.tsx [ src/__tests__/${f}.test.tsx ]"; done
  echo 'Error: Failed to resolve import "lodash-es" from "src/lib/formatters.ts"'
  echo "RESULT: 1 gate(s) FAILED"
} > "$T/log"
printf "backend/app/services/billing_service.py\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep "$T/out.txt" "fp=unit:deps-unresolved-lodash-es" "an untouched importer still fingerprints as a deps brick"
agrep "$T/out.txt" "class=transient"                   "and still routes to retry, not needs-human"

# ── Scenario 17: a site-packages warning is never the failing area (phantom _config.py) ──
# A pydantic deprecation notice satisfies the loose pytest matcher — `_config.py:323:` on a line
# containing "errors.pydantic.dev" — and, being a PRIMARY hit, used to suppress every real
# failure marker in the log. `_config.py` exists nowhere in this repo.
echo "Scenario 17 — pydantic site-packages deprecation warning is not the failing area"
T="$(mktemp -d)"; make_gh "$T"
cat > "$T/log" <<'L'
✗ unit   fail
/home/u/miniconda3/lib/python3.12/site-packages/pydantic/_internal/_config.py:323: PydanticDeprecatedSince20: Support for class-based `config` is deprecated. See https://errors.pydantic.dev/2.11/migration/
 FAIL  src/__tests__/notification-badge.test.ts [ src/__tests__/notification-badge.test.ts ]
Error: Failed to resolve import "../lib/badge" from "src/__tests__/notification-badge.test.ts"
RESULT: 1 gate(s) FAILED
L
printf "frontend/src/lib/badge.ts\n" > "$T/changed"
fp17="$(fp_of "$T" "$T/log" "$T/changed")"
case "$fp17" in
  *config*) bad "site-packages warning became the fingerprint ($fp17)";;
  *notification_badge*) ok "fingerprint anchors on the real failing test file ($fp17)";;
  *) bad "expected the failing test file in the fingerprint (got: $fp17)";;
esac

# ── Scenario 18: the escalation excerpt shows the FAILURE, not the log's green tail (#2124) ──
# quality-gates runs several workspaces; the last one to finish is often green, so a blind
# `tail -N` produced a needs-human comment that looked like a passing run.
echo "Scenario 18 — needs-human excerpt is anchored on the failure, not the trailing green output"
T="$(mktemp -d)"; make_gh "$T"
{ echo "✗ unit   fail"
  echo " FAIL  src/__tests__/quiz-grade.test.ts > grading > locks the first attempt"
  echo "AssertionError: expected 1 to be 2"
  for i in $(seq 1 40); do echo " ✓ src/__tests__/green-${i}.test.ts (3 tests) 4ms"; done
  echo " Test Files  9 passed (9)"
  echo "  ✓ vscode extension"
} > "$T/log"
printf "frontend/src/__tests__/quiz-grade.test.ts\n" > "$T/changed"
run "$T" "$T/log" "$T/changed" env SELF_REPAIR_COUNT=2 TRIAGE_MAX_SELF_REPAIR=2
agrep  "$T/out.txt" "action=needs-human"     "self-repair budget exhausted → needs-human"
agrep  "$T/gh.log"  "AssertionError"         "the excerpt carries the real failure"
angrep "$T/gh.log"  "✓ vscode extension"     "the excerpt is NOT just the trailing green tail"

# ── Scenario 19: #2218 — one cluster keeps ONE fingerprint across runs ───────────
# The #2208 landing redesign broke 25 tests across 3 files. pytest-xdist shards by worker, so
# each round listed a DIFFERENT one first; the test-anchored fingerprint changed with it, the
# dedup search missed, and one breakage was filed twice (#2212, then #2217) and would have kept
# going once per round. A multi-file cluster must fingerprint on the (sorted) file SET.
echo "Scenario 19 — a multi-file cluster keeps one fingerprint whichever test lists first (#2218)"
T="$(mktemp -d)"; make_gh "$T"
printf "backend/app/services/support_tools.py\n" > "$T/changed"
cat > "$T/log.a" <<'L'
✗ unit   fail   25 failed, 3100 passed
FAILED backend/tests/unit/test_landing_claims_2151.py::test_page_links_its_sibling_pages - AssertionError
FAILED backend/tests/unit/test_landing_browse_catalog_link.py::test_desktop_nav_links_to_browse_catalog - AssertionError
FAILED backend/tests/unit/test_landing_hero_badge_stacking.py::test_hero_card_still_forms_stacking_context - AssertionError
L
cat > "$T/log.b" <<'L'
✗ unit   fail   25 failed, 3100 passed
FAILED backend/tests/unit/test_landing_browse_catalog_link.py::test_desktop_nav_links_to_browse_catalog - AssertionError
FAILED backend/tests/unit/test_landing_hero_badge_stacking.py::test_hero_card_still_forms_stacking_context - AssertionError
FAILED backend/tests/unit/test_landing_claims_2151.py::test_page_links_its_sibling_pages - AssertionError
L
fp19a="$(fp_of "$T" "$T/log.a" "$T/changed")"
fp19b="$(fp_of "$T" "$T/log.b" "$T/changed")"
if [ -n "$fp19a" ] && [ "$fp19a" = "$fp19b" ]; then
  ok "re-ordered cluster keeps one fingerprint ($fp19a)"
else bad "cluster fanout: shard order changed the fingerprint (a=$fp19a b=$fp19b)"; fi
case "$fp19a" in
  *cluster-3files-*) ok "fingerprint names the cluster and its size";;
  *) bad "cluster fingerprint should be file-set anchored (got: $fp19a)";;
esac
# A DIFFERENT 3-file cluster must not collide with it just by sharing a first filename.
cat > "$T/log.c" <<'L'
✗ unit   fail   9 failed, 3100 passed
FAILED backend/tests/unit/test_landing_claims_2151.py::test_page_links_its_sibling_pages - AssertionError
FAILED backend/tests/unit/test_billing_seats.py::test_seat_added_fires - AssertionError
FAILED backend/tests/unit/test_webhook_dedup.py::test_course_completed_dedup - AssertionError
L
fp19c="$(fp_of "$T" "$T/log.c" "$T/changed")"
if [ "$fp19c" != "$fp19a" ]; then ok "a different cluster gets a different fingerprint"
else bad "distinct clusters collapsed to one fp ($fp19a)"; fi

# ── Scenario 20: #2218 — a behind-base tree cannot support an `unrelated` verdict ─
# `unrelated` asserts "this is pre-existing on main". A branch cut before the fix landed fails
# on code that is ALREADY GREEN on main; filing a blocker for it starts a loop that fixing main
# cannot break, because the next build resumes the same stale tree (#2138 → #2212 → #2217).
echo "Scenario 20 — failure in untouched files on a BEHIND-base branch → retry, not a blocker (#2218)"
T="$(mktemp -d)"; make_gh "$T"
(
  cd "$T" || exit 1
  git init -q -b main . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
  echo base > f.txt && git add f.txt && git commit -qm base
  git branch -q agent/issue-42                      # branch cut here …
  echo moved > f.txt && git commit -qam "fix landed on main"   # … main then moved on
) >/dev/null 2>&1
cat > "$T/log" <<'L'
✗ unit   fail   25 failed, 3100 passed
FAILED backend/tests/unit/test_landing_claims_2151.py::test_page_links_its_sibling_pages - AssertionError
FAILED backend/tests/unit/test_landing_browse_catalog_link.py::test_desktop_nav_links_to_browse_catalog - AssertionError
L
printf "backend/app/services/support_tools.py\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep  "$T/out.txt" "class=stale-base"  "behind-base build routed to stale-base, not unrelated"
agrep  "$T/out.txt" "action=retry"      "retries on a rebased tree instead of filing"
angrep "$T/gh.log"  "issue create"      "no blocker filed from a stale tree"
angrep "$T/gh.log"  "labels[]=blocked"  "parent not blocked behind a phantom blocker"
agrep  "$T/gh.log"  "labels/wip"        "wip dropped so the next tick rebuilds"

# ── Scenario 21: the same failure on an UP-TO-DATE branch still files ─────────────
# The freshness guard must not become a blanket excuse to file nothing — a genuinely
# pre-existing breakage on a current tree is exactly what `unrelated` is for.
echo "Scenario 21 — same failure on an up-to-date branch still files a blocker (#2218)"
T="$(mktemp -d)"; make_gh "$T"
(
  cd "$T" || exit 1
  git init -q -b main . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
  echo base > f.txt && git add f.txt && git commit -qm base
  git branch -q agent/issue-42            # branch contains main — nothing stale about it
) >/dev/null 2>&1
cat > "$T/log" <<'L'
✗ unit   fail   25 failed, 3100 passed
FAILED backend/tests/unit/test_landing_claims_2151.py::test_page_links_its_sibling_pages - AssertionError
FAILED backend/tests/unit/test_landing_browse_catalog_link.py::test_desktop_nav_links_to_browse_catalog - AssertionError
L
printf "backend/app/services/support_tools.py\n" > "$T/changed"
run "$T" "$T/log" "$T/changed"
agrep "$T/out.txt" "class=unrelated"      "a current tree still yields an unrelated verdict"
agrep "$T/gh.log"  "issue create"         "blocker filed for a genuinely pre-existing failure"
agrep "$T/gh.log"  "labels[]=blocked"     "parent blocked behind the real blocker"

echo
echo "agent-triage-failure: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
