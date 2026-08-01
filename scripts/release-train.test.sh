#!/usr/bin/env bash
# Tests for release-train.sh — the weekly unattended staging cut (issue #2205).
#
# Mirrors cut-mobile-release.test.sh: a real sandbox git repo with a bare origin,
# the REAL cut scripts replaced by controllable stubs, and `claude` / `gh` / `eas`
# / `maestro` / `adb` stubbed on PATH. No emulator, Expo account, model call, or
# network is touched.
#
# What it pins down (the behaviours that are easy to regress and expensive to
# discover in production at 20:00 on a Friday):
#   • cut-release.sh exits 1 on a SUCCESSFUL staging cut → success must come from
#     the tag on origin, never from $?                                     (AC-4)
#   • the converse: exit 0 with no tag pushed is NOT success               (AC-4)
#   • attempt exhaustion escalates instead of failing silently             (AC-13)
#   • a second escalation UPDATES the open issue instead of duplicating it (AC-13)
#   • the mobile phase refuses to run without the web tag on HEAD          (AC-7)
#   • EVERY gate is auto-fixed — no gate-class allowlist strands `unit`    (AC-11, #2209)
#   • a fix that deletes/skips a test or loosens gate config is discarded  (#2209)
#   • …but repairing a stale test's ASSERTIONS still lands                 (#2209)
#   • a fix that touches a risk zone is reverted and escalated             (AC-12)
#   • an empty-diff or same-signature loop escalates early                 (AC-21)
#   • a transient (rate-limit) model result does NOT consume an attempt    (AC-3)
#   • the mobile preflight names the specific missing item                 (AC-9)
#   • a second concurrent start is a no-op, not a parallel cut             (AC-17)
#   • ALL_GATES has not drifted from quality-gates.sh's GATES
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT_SCRIPT="$SCRIPT_DIR/release-train.sh"
# shellcheck source=scripts/lib/test-env.sh
source "$SCRIPT_DIR/lib/test-env.sh"
test_env_scrub
# The REAL repo, not the sandbox: the coverage guards below check the guard predicates
# against this repo's actual gate runners and test-runner configs.
RT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0 FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; echo "      $2"; FAIL=$((FAIL+1)); }

LAST_OUT=""
# run <args…> — run the sandboxed release train; captures output in $LAST_OUT, exit in $LAST_RC
#
# QG_LOGDIR must be pinned per-sandbox, not just RT_LOGDIR. release-train.sh derives it
# as `${QG_LOGDIR:-$RT_LOGDIR/qg}` — deliberately honouring an inherited value so the
# fixer reads the ACTUAL failing gate's output. But this suite is itself run BY the
# `unit` gate, so when the real release train runs it, the outer run has already
# exported its own QG_LOGDIR. The sandbox then inherited it and `gate_log_tail` read
# the OUTER run's unit.log instead of the stub cut's — the suite passed standalone and
# failed inside the gate, which is the one place it has to be trustworthy.
# The stub dir SUBSTITUTES for PATH rather than being prepended (issue #2387, M7). This is
# the suite that mattered most: it was the ONE scripts/*.test.sh the unit gate ran, so its
# guarantees were host-dependent while looking authoritative. Prepending left the host's real
# gh / claude / eas / adb / maestro reachable on the tail, so an assertion about a tool being
# ABSENT could silently be answered by the developer's machine.
STUB_KEEP_TOOLS=(bash sh env git jq node npx python3 sed awk grep cat mktemp date dirname basename tr head tail sort uniq wc find xargs rm mkdir cp mv chmod ln printf ls touch tee diff realpath readlink sha1sum flock timeout sleep cut paste comm)
run() {
  LAST_OUT="$( cd "$REPO" && PATH="$(test_env_stub_path "$STUB" "${STUB_KEEP_TOOLS[@]}")" \
      RT_LOGDIR="$ROOTDIR/logs-$((++LOGN))" RT_LOCK="$ROOTDIR/rt.lock" \
      QG_LOGDIR="$ROOTDIR/qg-$LOGN" \
      RT_TRANSIENT_BACKOFF=0 GH=gh EXPO_TOKEN='' \
      bash scripts/release-train.sh "$@" </dev/null 2>&1 )"
  LAST_RC=$?
}

assert_run() { # <label> <want_rc> <want_regex> <args…>
  local label="$1" want_rc="$2" want_re="$3"; shift 3
  run "$@"
  if [[ "$LAST_RC" -ne "$want_rc" ]]; then
    fail "$label" "exit $LAST_RC≠$want_rc; out: $(tail -3 <<<"$LAST_OUT" | tr '\n' '|')"; return
  fi
  if [[ -n "$want_re" ]] && ! grep -qE "$want_re" <<<"$LAST_OUT"; then
    fail "$label" "missing /$want_re/; out: $(tail -4 <<<"$LAST_OUT" | tr '\n' '|')"; return
  fi
  pass "$label"
}

# ── Sandbox ───────────────────────────────────────────────────────────────────
# A real repo on main, clean, in sync with a bare origin, with NO staging tag.
LOGN=0
make_sandbox() {
  ROOTDIR="$(mktemp -d)"
  REPO="$ROOTDIR/repo"; ORIGIN="$ROOTDIR/origin.git"; STUB="$ROOTDIR/stub"
  mkdir -p "$STUB"
  git init --bare --quiet "$ORIGIN"
  git init -b main --quiet "$REPO"
  ( cd "$REPO" || exit 1
    git config user.email t@t.co; git config user.name t
    mkdir -p scripts/lib state mobile/scripts backend/app/core backend/tests
    cp "$RT_SCRIPT" scripts/release-train.sh
    cp "$SCRIPT_DIR/route-failure.sh" "$SCRIPT_DIR/state-set.sh" scripts/
    cp "$SCRIPT_DIR/lib/agent-trace.sh" "$SCRIPT_DIR/lib/agent-model-call.sh" \
       "$SCRIPT_DIR/lib/state-shard.sh" "$SCRIPT_DIR/lib/gate-reason.sh" scripts/lib/
    echo '{"scale_tier":"launch"}' > state/state.json
    echo '{"name":"root"}' > package.json
    # scripts/unit.sh runs a JS workspace only when its package.json has a `scripts.test`
    # key, so this file IS gate config: dropping the key silently removes the suite.
    mkdir -p frontend
    echo '{"name":"frontend","scripts":{"test":"vitest run"}}' > frontend/package.json
    echo 'x = 1' > backend/app/core/security.py
    # A real test file + gate-config files, so the test-integrity guard (issue #2209)
    # has something to catch a fixer deleting/silencing/loosening. TWO test cases in
    # the file: one is edited (the legitimate repair), the other is what a fixer
    # thinning the suite would quietly drop.
    printf 'def test_thing():\n    assert 1 == 1\n\n\ndef test_other():\n    assert True\n' > backend/tests/test_thing.py
    printf '#!/usr/bin/env bash\n# stub gate runner\nexit 0\n' > scripts/quality-gates.sh
    # The per-gate runner quality-gates.sh dispatches `unit` to — the file a fixer
    # would edit to stop running the suite that is failing it.
    printf '#!/usr/bin/env bash\n# stub unit gate\nexit 0\n' > scripts/unit.sh
    chmod +x scripts/quality-gates.sh scripts/unit.sh

    # Stub web cut. Env-driven:
    #   CUT_EXIT      exit code to return
    #   CUT_PUSH_TAG  1 → create + push staging-v9.9.<CUT_SEQ> at HEAD
    #   CUT_GATE      gate name to report as failed (blank → no gate line)
    #   CUT_VARY      1 → vary the failure text (non-numerically) each call, so the
    #                     no-progress signature differs between attempts
    #   GATE_STATE_CHURN  1 → leave a TRACKED, uncommitted edit behind (mimics a real
    #                     gate run's own state-shard write) so tests can assert the
    #                     auto-fixer never sweeps it into its push (PR #2206 round 0)
    cat > scripts/cut-release.sh <<'STUBEOF'
#!/usr/bin/env bash
seq="${RT_SEQ_FILE:?RT_SEQ_FILE unset}"
n=0; [ -f "$seq" ] && n=$(cat "$seq"); n=$((n+1)); echo "$n" > "$seq"
echo "▶ running gates…"
if [ "${GATE_STATE_CHURN:-0}" = 1 ]; then echo "churn-$n" >> state/state.json; fi
# CUT_ADVANCE_HEAD=1: on the FIRST call only, land a commit on main mid-cut — standing
# in for a PR merging while the gates run. cut-release.sh itself only ever tags, so any
# HEAD movement across a cut is external by construction.
if [ "${CUT_ADVANCE_HEAD:-0}" = 1 ] && [ "$n" = 1 ]; then
  echo "someone-elses-merge" >> merged-elsewhere.txt
  git add merged-elsewhere.txt >/dev/null 2>&1
  git -c user.email=o@o.co -c user.name=other commit --quiet -m "a PR merged while the gates ran" >/dev/null 2>&1
fi
# CUT_INFRA=<n>: the first <n> calls fail on HOST CAPACITY (no diff can fix it), in
# the exact words scripts/integration.sh uses. Call <n>+1 behaves normally.
if [ -n "${CUT_INFRA:-}" ] && [ "$n" -le "${CUT_INFRA}" ]; then
  echo "  ✗ integration    testcontainer did not start"
  echo "E       ContainerNotServingError: Postgres testcontainer never became usable after 3/3 attempts within a 50s budget — this is genuine Docker starvation rather than the #2180 ryuk cascade — lower QG_SLOTS or ITEST_XDIST_MAX."
  echo "RESULT: 1 gate(s) FAILED"
  exit 1
fi
# CUT_NOISE=1: a real pytest log shape — the diagnosis FIRST, then a long warnings
# summary. A blind `tail` of this sends the fixer nothing but deprecation notices.
if [ "${CUT_NOISE:-0}" = 1 ]; then
  echo "  ✗ ${CUT_GATE:-unit}    failed"
  echo "E       AssertionError: THE-REAL-DIAGNOSIS-LINE"
  i=0; while [ "$i" -lt 120 ]; do echo "  DeprecationWarning: utcnow() is deprecated - filler $i"; i=$((i+1)); done
  echo "RESULT: 1 gate(s) FAILED"
  exit 1
fi
if [ "${CUT_PUSH_TAG:-0}" = 1 ]; then
  tag="staging-v9.9.$n"
  git tag -a "$tag" -m "release: $tag" >/dev/null 2>&1
  git push --quiet origin "$tag" >/dev/null 2>&1
  echo "✓ pushed $tag — deploy triggered."
fi
if [ -n "${CUT_GATE:-}" ]; then
  echo "  ✗ ${CUT_GATE}    something is broken"
  if [ "${CUT_VARY:-0}" = 1 ]; then
    printf '  detail '; for i in $(seq 1 "$n"); do printf 'x'; done; echo
  fi
  echo "RESULT: 1 gate(s) FAILED"
fi
exit "${CUT_EXIT:-0}"
STUBEOF

    # Stub mobile cut: MOBILE_MODE=build|ota|gatefail
    cat > scripts/cut-mobile-release.sh <<'STUBEOF'
#!/usr/bin/env bash
case "${MOBILE_MODE:-build}" in
  build) echo "▶ eas submit --profile preview --platform ios (latest build)…"
         echo "✓ shipped staging-v9.9.1 via build to the preview channel"
         printf '{\n  "mechanism": "build"\n}\n' > mobile/.last-shipped ;;
  ota)   echo "▶ eas update --branch preview…"
         echo "✓ shipped staging-v9.9.1 via update to the preview channel" ;;
  gatefail) echo "  ✗ ${CUT_GATE:-unit}    mobile gate broke"; exit 1 ;;
esac
exit 0
STUBEOF
    printf '#!/usr/bin/env bash\nexit ${SUBMIT_RC:-0}\n' > mobile/scripts/check-submit-config.sh
    chmod +x scripts/cut-release.sh scripts/cut-mobile-release.sh mobile/scripts/check-submit-config.sh
    # Mirror the real repo's ignores for host-local runtime state — otherwise the
    # telemetry spans and the run log would look like a "fix diff" to the wrapper.
    printf 'mobile/.last-shipped\nstate/traces/\nstate/*.lock\nstate/release-train.json\n' > .gitignore
    git add -A; git commit --quiet -m init
    git remote add origin "$ORIGIN"
    git push --quiet origin main )

  # ── PATH stubs ──────────────────────────────────────────────────────────────
  # claude: CLAUDE_MODE=fix|noop|risk|transient|crash|edittest
  #                    |deltest|skiptest|pytestmark|collectignore|dropcase   (test removal)
  #                    |gateconfig|gaterunner|pkgjson                        (gate loosening)
  # RT_PROMPT_DUMP=<path> also captures the prompt the wrapper briefed the fixer with,
  # so tests can assert the mechanical-vs-product brief (issue #2209).
  cat > "$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
[ -n "${RT_PROMPT_DUMP:-}" ] && printf '%s' "${2:-}" > "$RT_PROMPT_DUMP"
# Per-invocation counter + a per-call prompt archive, so a mode can behave differently on
# the re-brief than on the first turn and a test can assert what the re-brief actually said
# (issue #2387, H1).
CLAUDE_CALLS_FILE="${RT_CALL_COUNT_FILE:-/dev/null}"
_calls=0
if [ "$CLAUDE_CALLS_FILE" != /dev/null ]; then
  _calls="$(cat "$CLAUDE_CALLS_FILE" 2>/dev/null || echo 0)"
  _calls=$((_calls + 1)); echo "$_calls" > "$CLAUDE_CALLS_FILE"
  [ -n "${RT_PROMPT_ARCHIVE:-}" ] && printf '%s' "${2:-}" > "${RT_PROMPT_ARCHIVE}.${_calls}"
fi
case "${CLAUDE_MODE:-fix}" in
  # Oversteps on the FIRST turn (deletes a test case), then complies on the re-brief.
  # Proves the re-brief loop both fires and can recover a fix the old code threw away.
  relent)    if [ "${_calls:-1}" -le 1 ]; then
               printf 'def test_thing():\n    assert 2 == 2\n' > backend/tests/test_thing.py
               echo '{"is_error":false,"result":"dropped the failing test case"}'
             else
               printf 'def test_thing():\n    assert 2 == 2\n\n\ndef test_other():\n    assert True\n' > backend/tests/test_thing.py
               echo '{"is_error":false,"result":"repaired the assertion properly"}'
             fi ;;
  # Never relents: keeps reaching for the same forbidden risk-zone edit on every turn.
  # Must still terminate — via the re-brief budget, not by burning all 20 attempts.
  stubborn)  echo "y = 2" >> backend/app/core/security.py
             echo '{"is_error":false,"result":"edited auth again"}' ;;
  fix)       echo "// fixed $(date +%s%N)" >> fixed.txt
             echo '{"is_error":false,"result":"fixed","total_cost_usd":0.01}' ;;
  noop)      echo '{"is_error":false,"result":"nothing to do"}' ;;
  risk)      echo "y = 2" >> backend/app/core/security.py
             echo '{"is_error":false,"result":"edited auth"}' ;;
  # The three ways an unbounded fixer could turn a gate green by removing the evidence.
  deltest)   rm -f backend/tests/test_thing.py
             echo '{"is_error":false,"result":"deleted the failing test"}' ;;
  skiptest)  printf '\n@pytest.mark.skip(reason="flaky")\ndef test_extra():\n    assert True\n' >> backend/tests/test_thing.py
             echo '{"is_error":false,"result":"skipped the failing test"}' ;;
  gateconfig) echo '# exit 0 always' >> scripts/quality-gates.sh
             echo '{"is_error":false,"result":"loosened the gate runner"}' ;;
  # Module-level skip: no decorator, no deletion, one added line, whole file silenced.
  pytestmark) printf '\npytestmark = pytest.mark.skip(reason="flaky in CI")\n' >> backend/tests/test_thing.py
             echo '{"is_error":false,"result":"skipped the module"}' ;;
  # conftest.py drops OTHER files from collection — the file it edits is itself a test path.
  collectignore) printf 'collect_ignore = ["test_thing.py"]\n' > backend/tests/conftest.py
             echo '{"is_error":false,"result":"stopped collecting the failing module"}' ;;
  # No test diff at all: delete the key scripts/unit.sh dispatches the JS suites on.
  pkgjson)   printf '{"name":"root"}\n' > frontend/package.json
             echo '{"is_error":false,"result":"dropped the frontend test script"}' ;;
  # The per-gate runner, not the dispatcher: the `unit` gate's own script.
  gaterunner) echo 'exit 0 # never mind the suite' >> scripts/unit.sh
             echo '{"is_error":false,"result":"stopped running the failing suite"}' ;;
  # Thinning the suite without deleting the file — the porcelain status stays " M".
  dropcase) printf 'def test_thing():\n    assert 2 == 2\n' > backend/tests/test_thing.py
             echo '{"is_error":false,"result":"dropped the failing test case"}' ;;
  # …and the legitimate one it must still be allowed to do: repair a stale assertion
  # while every test case in the file survives.
  edittest)  printf 'def test_thing():\n    assert 2 == 2\n\n\ndef test_other():\n    assert True\n' > backend/tests/test_thing.py
             echo '{"is_error":false,"result":"repaired a stale assertion"}' ;;
  # RENAMING a test case: the declaration line changes, so the '-' side of the diff shows a
  # deleted `def test_other` and the '+' side shows an added `def test_other_renamed`. The
  # case count is unchanged — 2 before, 2 after. The old '-'-side-only guard could not tell
  # this from a deletion and discarded the whole fix (issue #2387, H2).
  renamecase) printf 'def test_thing():\n    assert 2 == 2\n\n\ndef test_other_renamed():\n    assert True\n' > backend/tests/test_thing.py
             echo '{"is_error":false,"result":"renamed a test for clarity"}' ;;
  # Net counting must still catch a real thinning that hides behind an addition: the two
  # existing cases are replaced by ONE. Net -1, so the guard fires.
  netshrink) printf 'def test_only():\n    assert True\n' > backend/tests/test_thing.py
             echo '{"is_error":false,"result":"consolidated tests"}' ;;
  transient) echo '{"is_error":true,"api_error_status":"429","result":"rate limit exceeded"}' ;;
  crash)     echo '{"is_error":true,"result":"model produced garbage"}' ;;
esac
exit 0
STUBEOF
  # gh: GH_EXISTING=<n> makes `issue list` report an already-open escalation, whose
  # body is GH_EXISTING_BODY (default: the real web-phase marker, so the existing
  # "updated existing issue" test keeps matching). Emits real `--json number,body`
  # JSON so release-train.sh's `jq --arg m "$marker" contains($m)` check is exercised
  # — a stub that just echoed the number would mask the exact bug PR #2206 round 0
  # found (a term-search hit whose body does NOT actually contain the marker).
  cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      list)
        if [ -n "${GH_EXISTING:-}" ]; then
          body="${GH_EXISTING_BODY:-<!-- release-train:staging:web -->}"
          printf '[{"number": %s, "body": %s}]\n' "$GH_EXISTING" "$(printf '%s' "$body" | jq -Rs .)"
        else
          echo '[]'
        fi
        exit 0 ;;
      create)  echo "https://github.com/o/r/issues/${GH_NEW:-4242}"; exit 0 ;;
      comment) exit 0 ;;
    esac ;;
  label) exit 0 ;;
esac
exit 0
STUBEOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/maestro"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/eas"
  printf '#!/usr/bin/env bash\nif [ "$1" = devices ]; then printf "List\\nemulator-5554\\tdevice\\n"; fi\nexit 0\n' > "$STUB/adb"
  chmod +x "$STUB"/*
  # Per-sandbox, NOT a fixed /tmp path: this suite now runs inside the `unit` gate
  # (scripts/unit.sh), where a shared counter file would make two concurrent runs
  # collide on the stub cut's tag sequence.
  export RT_SEQ_FILE="$ROOTDIR/cut-seq"
  rm -f "$RT_SEQ_FILE"
  export CUT_EXIT=0 CUT_PUSH_TAG=0 CUT_GATE="" CUT_VARY=0
  export CLAUDE_MODE=fix MOBILE_MODE=build SUBMIT_RC=0
  export EXPO_ASC_API_KEY_PATH="$ROOTDIR/asc.p8" EXPO_ASC_KEY_ID=K EXPO_ASC_ISSUER_ID=I EXPO_APPLE_TEAM_ID=T
  : > "$ROOTDIR/asc.p8"
  unset GH_EXISTING
}
reset_repo() {
  ( cd "$REPO"
    git tag -l 'staging-v*' | while read -r t; do
      git tag -d "$t" >/dev/null 2>&1; git push --quiet origin ":refs/tags/$t" >/dev/null 2>&1
    done
    git checkout --quiet -- . 2>/dev/null
    git clean -qfd -e node_modules 2>/dev/null
    git reset --quiet --hard origin/main 2>/dev/null )
  rm -f "$RT_SEQ_FILE"
}
cleanup() { [[ -n "${ROOTDIR:-}" ]] && rm -rf "$ROOTDIR"; }
trap cleanup EXIT

echo "release-train.sh tests"
make_sandbox

# ── Argument validation ───────────────────────────────────────────────────────
assert_run "unknown arg → usage error"      2 "unknown argument"        --bogus
assert_run "--max-attempts must be numeric" 2 "positive integer"        --max-attempts x
assert_run "--help prints the header"       0 "release-train.sh"        --help

# ── AC-4: staging exit 1 IS success when the tag landed ───────────────────────
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=1 \
  assert_run "web: cut-release exit 1 + tag on origin → SUCCESS" 0 "is on origin and on HEAD" --web-only
grep -qE 'web: +cut' <<<"$LAST_OUT" || fail "web outcome recorded as 'cut'" "out: $(tail -5 <<<"$LAST_OUT")"

# ── AC-4 converse: exit 0 with NO tag is NOT success ──────────────────────────
reset_repo
CUT_EXIT=0 CUT_PUSH_TAG=0 CUT_GATE=unit \
  assert_run "web: cut-release exit 0 but no tag → NOT success" 1 "escalated|escalation" --web-only --max-attempts 1

# ── AC-11 (issue #2209): the auto-fixer is UNBOUNDED by gate class ────────────
# It used to escalate any gate outside a five-name allowlist, which meant `unit` —
# the most common staging failure — always woke a human instead of self-healing.
# Every gate is now fixed; the bound moved onto what a fix may DO (below).
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=unit CUT_VARY=1 CLAUDE_MODE=fix \
  assert_run "web: a product-failure gate (unit) is auto-fixed, not escalated on class" \
  1 "attempt cap reached" --web-only --max-attempts 2
grep -q "outside the auto-fix bound" <<<"$LAST_OUT" \
  && fail "no gate escalates merely for its class" "'unit' still hit a gate allowlist" \
  || pass "no gate escalates merely for its class"
grep -q "spawning claude" <<<"$LAST_OUT" && pass "a model IS spawned for a product-failure gate" \
  || fail "a model IS spawned for a product-failure gate" "out: $(tail -5 <<<"$LAST_OUT")"
unit_fix_pushed="$( cd "$REPO" && git log --name-only origin/main 2>/dev/null | grep -c '^fixed\.txt$' )"
[[ "$unit_fix_pushed" -ge 1 ]] && pass "the unit-gate fix actually landed on main" \
  || fail "the unit-gate fix actually landed on main" "fixed.txt-touching commits=$unit_fix_pushed"

# The same unbounded treatment for a gate that was never in the old allowlist at all.
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=integration CUT_VARY=1 CLAUDE_MODE=fix \
  assert_run "web: integration is auto-fixed too" 1 "attempt cap reached" --web-only --max-attempts 2
grep -q "outside the auto-fix bound" <<<"$LAST_OUT" \
  && fail "integration is not class-escalated" "hit a gate allowlist" \
  || pass "integration is not class-escalated"

# ── issue #2209: the fixer is briefed differently per class, but fixed either way ──
reset_repo
PROMPT_DUMP="$ROOTDIR/prompt.txt"
export RT_PROMPT_DUMP="$PROMPT_DUMP"
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=unit CUT_VARY=1 CLAUDE_MODE=fix \
  run --web-only --max-attempts 1
grep -q "REAL PRODUCT FAILURE" "$PROMPT_DUMP" 2>/dev/null \
  && pass "a product-failure gate gets the root-cause brief" \
  || fail "a product-failure gate gets the root-cause brief" "prompt: $(head -20 "$PROMPT_DUMP" 2>/dev/null | tr '\n' '|')"
grep -qE "NEVER delete a test file, add a skip" "$PROMPT_DUMP" 2>/dev/null \
  && pass "the product-failure brief spells out the test-integrity bound" \
  || fail "the product-failure brief spells out the test-integrity bound" "prompt lacks the no-weakening clause"
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=typecheck CUT_VARY=1 CLAUDE_MODE=fix \
  run --web-only --max-attempts 1
grep -q "recurring debt" "$PROMPT_DUMP" 2>/dev/null \
  && pass "a mechanical gate keeps the recurring-debt brief" \
  || fail "a mechanical gate keeps the recurring-debt brief" "prompt: $(head -20 "$PROMPT_DUMP" 2>/dev/null | tr '\n' '|')"
unset RT_PROMPT_DUMP

# ── issue #2209: the test-integrity guard is the compensating control ─────────
# With no gate allowlist, THIS is what stops an unattended fixer from turning a red
# gate green by removing the evidence. Each case must discard the WHOLE fix, escalate,
# and leave nothing of it on origin/main.
assert_weakening_rejected() { # <label> <claude-mode> <want_regex> <sentinel-check…>
  local label="$1" mode="$2" want_re="$3"
  reset_repo
  CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=unit CUT_VARY=1 CLAUDE_MODE="$mode" \
    assert_run "$label" 1 "$want_re" --web-only --max-attempts 20
  if [[ -z "$( cd "$REPO" && git status --porcelain )" ]] \
     && [[ -z "$( cd "$REPO" && git log --oneline origin/main..HEAD )" ]]; then
    pass "${label} — fix discarded, nothing pushed"
  else
    fail "${label} — fix discarded, nothing pushed" \
      "status=[$( cd "$REPO" && git status --porcelain | tr '\n' ' ' )] ahead=[$( cd "$REPO" && git log --oneline origin/main..HEAD | tr '\n' ' ' )]"
  fi
}
assert_weakening_rejected "web: a fix that DELETES a test → escalate"        deltest    "weaken|test file deleted"
[[ -f "$REPO/backend/tests/test_thing.py" ]] && pass "the deleted test file was restored" \
  || fail "the deleted test file was restored" "backend/tests/test_thing.py is still gone"
assert_weakening_rejected "web: a fix that SKIPS a test → escalate"          skiptest   "weaken|test disabled"
grep -q 'pytest.mark.skip' "$REPO/backend/tests/test_thing.py" \
  && fail "the skip marker was reverted" "pytest.mark.skip survived in the test file" \
  || pass "the skip marker was reverted"
assert_weakening_rejected "web: a fix that edits GATE CONFIG → escalate"     gateconfig "weaken|gate configuration"
grep -q 'exit 0 always' "$REPO/scripts/quality-gates.sh" \
  && fail "the gate-config edit was reverted" "the loosening line survived" \
  || pass "the gate-config edit was reverted"

# The PER-GATE runner, not just the dispatcher. quality-gates.sh sends `unit` to
# scripts/unit.sh, so that is the file a fixer edits to stop running the suite that is
# failing it — the most reachable version of this cheat, via the most common gate.
assert_weakening_rejected "web: a fix that edits the GATE RUNNER (scripts/unit.sh) → escalate" \
  gaterunner "weaken|gate configuration"
grep -q 'never mind the suite' "$REPO/scripts/unit.sh" \
  && fail "the gate-runner edit was reverted" "the suite-skipping line survived in scripts/unit.sh" \
  || pass "the gate-runner edit was reverted"

# A module-level `pytestmark = pytest.mark.skip(...)`. No decorator, no deletion, no
# `def` removed — one appended line that silences every test in the file. The guard's
# marker pattern was anchored to a leading `@`, so it caught the loud decorator form and
# walked straight past this one.
assert_weakening_rejected "web: a fix that adds a module-level pytestmark skip → escalate" \
  pytestmark "weaken|test disabled"
grep -q 'pytestmark' "$REPO/backend/tests/test_thing.py" \
  && fail "the module-level skip was reverted" "pytestmark survived in the test file" \
  || pass "the module-level skip was reverted"

# conftest.py's `collect_ignore` — the tests it removes live in OTHER files, so nothing
# about the failing test file changes at all.
assert_weakening_rejected "web: a fix that adds conftest collect_ignore → escalate" \
  collectignore "weaken|test disabled"
[[ -f "$REPO/backend/tests/conftest.py" ]] \
  && fail "the collect_ignore conftest was reverted" "backend/tests/conftest.py survived" \
  || pass "the collect_ignore conftest was reverted"

# The cheat with NO test diff whatsoever: scripts/unit.sh runs each JS workspace only if
# its package.json has a `scripts.test` key, and skips it silently otherwise — without
# even incrementing `checked`. Dropping that one key deletes a whole suite from the gate.
assert_weakening_rejected "web: a fix that drops scripts.test from a package.json → escalate" \
  pkgjson "weaken|gate configuration"
jq -e '.scripts.test // empty' "$REPO/frontend/package.json" >/dev/null 2>&1 \
  && pass "the dropped test script was restored" \
  || fail "the dropped test script was restored" "frontend/package.json still has no scripts.test"

# Deleting test CASES out of a file that survives: porcelain says " M", the file is
# still there, and the suite is quietly smaller. Same cheat, no status-code tell.
assert_weakening_rejected "web: a fix that DELETES a test case from a surviving file → escalate" \
  dropcase "weaken|test case removed"
grep -q 'def test_other' "$REPO/backend/tests/test_thing.py" \
  && pass "the dropped test case was restored" \
  || fail "the dropped test case was restored" "def test_other is still gone"

# The converse — the guard must not block a LEGITIMATE test repair. An unattended fixer
# may correct a stale assertion; it may only never silence the test.
# --max-attempts 1 because this repair is idempotent: it lands on attempt 1, and a
# second attempt would re-apply the same content and trip the empty-diff guard rather
# than the cap. One attempt is enough — what is under test is that the fix LANDS.
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=unit CUT_VARY=1 CLAUDE_MODE=edittest \
  assert_run "web: repairing a stale test ASSERTION is still allowed to land" \
  1 "attempt cap reached" --web-only --max-attempts 1
# NB assert on the BLOB at origin/main, not on `git log -p | grep -q`: under
# `set -o pipefail` an early-exiting `grep -q` SIGPIPEs git and the pipeline reports
# 141, so a long history silently turns a real match into a failure (and, for a
# negated check, a real hit into a spurious pass).
main_test_body="$( cd "$REPO" && git show origin/main:backend/tests/test_thing.py 2>/dev/null )"
if grep -q 'assert 2 == 2' <<<"$main_test_body"; then
  pass "a legitimate test-assertion repair reaches origin/main"
else
  fail "a legitimate test-assertion repair reaches origin/main" \
    "origin/main blob=[$(tr '\n' ' ' <<<"$main_test_body")] out: $(tail -6 <<<"$LAST_OUT" | tr '\n' '|')"
fi

# ── RENAMING a test case must be allowed (issue #2387, H2) ────────────────────
# The declaration line changes on BOTH sides of the diff, so a '-'-side-only guard read
# `def test_other` as deleted and discarded the fix. The case count is unchanged (2 → 2).
# This is not hypothetical: on 2026-07-31 it killed a correct fix that had self-reported a
# test-count INCREASE, and the fixer brief explicitly permits correcting stale titles.
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=unit CUT_VARY=1 CLAUDE_MODE=renamecase \
  assert_run "web: RENAMING a test case is allowed to land (net count unchanged)" \
  1 "attempt cap reached" --web-only --max-attempts 1
main_test_body="$( cd "$REPO" && git show origin/main:backend/tests/test_thing.py 2>/dev/null )"
if grep -q 'def test_other_renamed' <<<"$main_test_body"; then
  pass "a test rename reaches origin/main (not read as a deletion)"
else
  fail "a test rename reaches origin/main (not read as a deletion)" \
    "origin/main blob=[$(tr '\n' ' ' <<<"$main_test_body")] out: $(tail -6 <<<"$LAST_OUT" | tr '\n' '|')"
fi
# …and the count really is preserved, so this passes for the right reason rather than
# because the guard stopped working altogether.
decls="$(grep -c '^def test' <<<"$main_test_body" || true)"
[[ "${decls:-0}" -eq 2 ]] && pass "the renamed file still declares 2 test cases" \
  || fail "the renamed file still declares 2 test cases" "counted ${decls}"

# ── …but a NET decrease hiding behind an addition is still caught ─────────────
# Net counting is the deliberate trade H2 made; it must not degenerate into "any file that
# adds a declaration is exempt". Two cases replaced by one is net -1 and must still escalate.
assert_weakening_rejected "web: replacing two test cases with one → escalate (net -1)" \
  netshrink "weaken|test cases removed"
grep -q 'def test_other' "$REPO/backend/tests/test_thing.py" \
  && pass "the net-shrinking edit was reverted" \
  || fail "the net-shrinking edit was reverted" "def test_other is still gone"

# ── H1: a DISCARDED fix is re-briefed, not treated as terminal (issue #2387) ──
# run_fixer collapsed every failure into `return 1`, and the caller answered every
# `return 1` with `escalate; return 1`. So the one failure a second turn could actually
# repair — a fixer that overstepped a bound — ended the run. Observed 2026-07-31: escalated
# at attempt 1 of 20 with 19 unused (#2386).
reset_repo
RT_CALL_COUNT_FILE="$ROOTDIR/relent.count" RT_PROMPT_ARCHIVE="$ROOTDIR/relent.prompt" \
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=unit CUT_VARY=1 CLAUDE_MODE=relent \
  assert_run "web: a fix discarded for weakening is RE-BRIEFED and can then succeed" \
  1 "re-briefing the fixer" --web-only --max-attempts 1
calls="$(cat "$ROOTDIR/relent.count" 2>/dev/null || echo 0)"
[[ "${calls:-0}" -ge 2 ]] && pass "the fixer was re-spawned after the discard (${calls} model calls)" \
  || fail "the fixer was re-spawned after the discard" "only ${calls} model call(s) — the discard was terminal"
# The re-brief must carry the SPECIFIC violation; repeating the generic bounds would buy
# the same answer the model already gave.
if [[ -f "$ROOTDIR/relent.prompt.2" ]]; then
  grep -q 'RETRY' "$ROOTDIR/relent.prompt.2" \
    && pass "the second prompt is marked as a retry" \
    || fail "the second prompt is marked as a retry" "$(head -c 200 "$ROOTDIR/relent.prompt.2")"
  grep -qE 'test case|weakened the test surface' "$ROOTDIR/relent.prompt.2" \
    && pass "the re-brief names the actual violation" \
    || fail "the re-brief names the actual violation" "$(head -c 400 "$ROOTDIR/relent.prompt.2")"
else
  fail "a second prompt was issued" "no $ROOTDIR/relent.prompt.2 — the fixer was never re-briefed"
fi
# …and the recovered fix is the one that reaches main.
main_test_body="$( cd "$REPO" && git show origin/main:backend/tests/test_thing.py 2>/dev/null )"
grep -q 'def test_other' <<<"$main_test_body" \
  && pass "the re-briefed fix landed with the test case intact" \
  || fail "the re-briefed fix landed with the test case intact" \
       "origin/main blob=[$(tr '\n' ' ' <<<"$main_test_body")]"

# The counter-property: the re-brief must be BOUNDED. A fixer that keeps making the same
# forbidden edit has to stop at REBRIEF_MAX, not consume the whole attempt budget.
reset_repo
RT_CALL_COUNT_FILE="$ROOTDIR/stubborn.count" RT_REBRIEF_MAX=2 \
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=unit CUT_VARY=1 CLAUDE_MODE=stubborn \
  assert_run "web: a fixer that never relents still escalates (re-brief is bounded)" \
  1 "risk zone|re-brief budget exhausted" --web-only --max-attempts 1
calls="$(cat "$ROOTDIR/stubborn.count" 2>/dev/null || echo 0)"
# 1 initial + REBRIEF_MAX re-briefs = 3. Anything more means the bound is not enforced.
[[ "${calls:-0}" -eq 3 ]] \
  && pass "an unrelenting fixer stopped after 1 + REBRIEF_MAX(2) = 3 calls" \
  || fail "an unrelenting fixer stopped after 1 + REBRIEF_MAX(2) = 3 calls" "made ${calls} calls"
[[ -z "$( cd "$REPO" && git status --porcelain )" ]] \
  && pass "the unrelenting fixer's risk-zone edit was discarded" \
  || fail "the unrelenting fixer's risk-zone edit was discarded" \
       "status=[$( cd "$REPO" && git status --porcelain | tr '\n' ' ')]"

# ── A merge landing mid-cut invalidates the attempt ───────────────────────────
# The train gates the LIVE checkout, which other automation moves. Observed on a real
# run: `git reflog` recorded `pull: Fast-forward` during a cut's unit gate because a PR
# had just merged. bash reads scripts incrementally, so the already-copied script ran
# against newly-arrived tests — six failures from a commit it did not contain. The gate
# verdict also stops describing the commit being tagged. CUT_ADVANCE_HEAD=1 makes the
# stub cut commit to main mid-run, standing in for the external merge.
reset_repo
CUT_ADVANCE_HEAD=1 CUT_PUSH_TAG=1 CUT_EXIT=1 \
  assert_run "web: a merge landing mid-cut re-runs instead of trusting the gates" 0 "HEAD moved from" --web-only
grep -q "spawning claude" <<<"$LAST_OUT" \
  && fail "web: a mid-cut merge spawns NO model" "a model was briefed on a stale-tree failure" \
  || pass "web: a mid-cut merge spawns NO model"
grep -q "cut attempt 2/" <<<"$LAST_OUT" \
  && fail "web: a mid-cut merge consumes no fix attempt" "attempt counter advanced" \
  || pass "web: a mid-cut merge consumes no fix attempt"
unset CUT_ADVANCE_HEAD

# ── Host capacity is NOT a code failure ───────────────────────────────────────
# Observed on a real run: `integration` failed with "genuine Docker starvation …
# lower QG_SLOTS or ITEST_XDIST_MAX" while an agent-inbox lane held the other half of
# the host. The train routed it to a code fixer — which is guaranteed waste, since the
# remedy the gate itself names is gate configuration under scripts/, the one thing the
# fix guard forbids the model from touching. Back the concurrency off instead.
reset_repo
CUT_INFRA=1 CUT_PUSH_TAG=1 CUT_EXIT=1 \
  assert_run "web: a capacity failure backs the concurrency off and retries" 0 "retrying with ITEST_XDIST_MAX=8" --web-only
grep -q "spawning claude" <<<"$LAST_OUT" \
  && fail "web: a capacity backoff spawns NO model" "a model was briefed on a failure no diff can fix" \
  || pass "web: a capacity backoff spawns NO model"
grep -q "cut attempt 2/" <<<"$LAST_OUT" \
  && fail "web: a capacity backoff consumes no fix attempt" "attempt counter advanced" \
  || pass "web: a capacity backoff consumes no fix attempt"

reset_repo
CUT_INFRA=99 CUT_PUSH_TAG=1 CUT_EXIT=1 RT_INFRA_RETRIES=1 \
  assert_run "web: persistent starvation escalates as capacity, not as a code defect" 1 "host capacity" --web-only
grep -q "spawning claude" <<<"$LAST_OUT" \
  && fail "web: persistent starvation still spawns no model" "a model was briefed" \
  || pass "web: persistent starvation still spawns no model"
unset CUT_INFRA

# ── The fixer is briefed with the DIAGNOSIS, not the last 80 lines ────────────
# pytest prints the failure first and a warnings summary last, so a blind tail of a
# long integration log is pure noise. Observed: a 1499-line log whose root cause sat
# at line 308 while `tail -80` sent lines 1420-1499, none of which named the failure.
reset_repo
export RT_PROMPT_DUMP="$ROOTDIR/fixer-prompt.txt"; rm -f "$RT_PROMPT_DUMP"
CUT_NOISE=1 CUT_EXIT=1 CUT_GATE=unit CLAUDE_MODE=noop run --web-only --max-attempts 1
if grep -q "THE-REAL-DIAGNOSIS-LINE" "$RT_PROMPT_DUMP" 2>/dev/null; then
  pass "the fixer brief carries the diagnosis, not just the log tail"
else
  fail "the fixer brief carries the diagnosis, not just the log tail" \
    "prompt tail: $(tail -c 300 "$RT_PROMPT_DUMP" 2>/dev/null | tr '\n' '|')"
fi
unset RT_PROMPT_DUMP CUT_NOISE

# ── AC-13: attempt exhaustion → escalation issue, non-zero exit ───────────────
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=typecheck CUT_VARY=1 CLAUDE_MODE=fix \
  assert_run "web: attempts exhausted → escalate + exit 1" 1 "attempt cap reached" --web-only --max-attempts 2
grep -q "filed issue #4242" <<<"$LAST_OUT" && pass "escalation files a GitHub issue" \
  || fail "escalation files a GitHub issue" "out: $(tail -5 <<<"$LAST_OUT")"

# ── AC-13: a re-run with an unresolved escalation UPDATES, never duplicates ───
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=typecheck CUT_VARY=1 CLAUDE_MODE=fix GH_EXISTING=777 \
  assert_run "web: existing escalation is updated, not duplicated" 1 "updated existing issue #777" --web-only --max-attempts 2
unset GH_EXISTING

# ── AC-13 regression (PR #2206 round 0): a --search TERM hit whose body does NOT
# actually contain the marker (e.g. it matched on "release"/"train"/"staging"/"web"
# from an unrelated issue like this feature's own tracking issue) must NOT be
# mistaken for the existing escalation — a fresh issue must be filed instead.
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=typecheck CUT_VARY=1 CLAUDE_MODE=fix GH_EXISTING=2205 \
GH_EXISTING_BODY="weekly unattended staging release train (web then iOS) — tracking issue" GH_NEW=9001 \
  assert_run "web: a term-search hit without the literal marker is NOT treated as the escalation" \
  1 "filed issue #9001" --web-only --max-attempts 2
grep -q "updated existing issue #2205" <<<"$LAST_OUT" \
  && fail "the spec/tracking issue is never comment-hijacked" "commented on #2205 instead of filing a new issue" \
  || pass "the spec/tracking issue is never comment-hijacked"
unset GH_EXISTING GH_EXISTING_BODY GH_NEW

# ── AC-21: identical failure signature 3× in a row → escalate early ───────────
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=typecheck CUT_VARY=0 CLAUDE_MODE=fix \
  assert_run "web: same signature 3× → no-progress escalation" 1 "no progress: 'typecheck'" --web-only --max-attempts 20

# ── AC-21: an empty-diff fix escalates rather than burning the cap ────────────
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=lint CUT_VARY=1 CLAUDE_MODE=noop \
  assert_run "web: empty-diff fix → escalate" 1 "EMPTY diff" --web-only --max-attempts 20

# ── PR #2206 round 0: a gate run's own pre-existing tracked churn (e.g. a
# state-shard write) must never be swept into the auto-fixer's push — only the
# fixer's own diff may land on main via `git add`.
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=typecheck CUT_VARY=1 CLAUDE_MODE=fix GATE_STATE_CHURN=1 \
  assert_run "web: pre-existing gate-run churn still lets the fixer push" 1 "attempt cap reached" --web-only --max-attempts 2
churn_pushed="$( cd "$REPO" && git log -p origin/main -- state/state.json 2>/dev/null | grep -c '^+churn-' )"
fixed_pushed="$( cd "$REPO" && git log --name-only origin/main 2>/dev/null | grep -c '^fixed\.txt$' )"
if [[ "$churn_pushed" -eq 0 && "$fixed_pushed" -ge 1 ]]; then
  pass "the fixer's push carries its own diff only, never a gate run's leftover churn"
else
  fail "the fixer's push carries its own diff only, never a gate run's leftover churn" \
    "state.json churn lines pushed=$churn_pushed fixed.txt-touching commits=$fixed_pushed"
fi

# ── AC-12: a fix that touches a risk zone is reverted + escalated ─────────────
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=lint CUT_VARY=1 CLAUDE_MODE=risk \
  assert_run "web: risk-zone diff → revert + escalate" 1 "protected risk zone" --web-only --max-attempts 20
# Same pipefail/SIGPIPE trap as above: capture the diff first, then grep the string.
# `! (git log -p …) | grep -q` reports 141 the moment grep matches early, which the
# `!` would flip into a PASS — i.e. the louder the violation, the greener the test.
risk_range_diff="$( cd "$REPO" && git log -p origin/main..HEAD -- backend/app/core/security.py 2>/dev/null )"
if [[ -z "$( cd "$REPO" && git status --porcelain )" ]] \
   && ! grep -q 'y = 2' "$REPO/backend/app/core/security.py" \
   && ! grep -q 'y = 2' <<<"$risk_range_diff"; then
  pass "risk-zone edit reverted and never committed"
else
  fail "risk-zone edit reverted and never committed" \
    "status=[$( cd "$REPO" && git status --porcelain | tr '\n' ' ' )] file=[$(tr '\n' ' ' < "$REPO/backend/app/core/security.py")] range=[$( cd "$REPO" && git log --oneline origin/main..HEAD | tr '\n' ' ' )]"
fi

# ── AC-3: a transient model result does NOT consume an attempt ────────────────
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=0 CUT_GATE=lint CUT_VARY=1 CLAUDE_MODE=transient RT_TRANSIENT_RETRIES=2 \
  assert_run "web: transient model result retries without burning an attempt" 1 "transient model result" --web-only --max-attempts 20
grep -qE 'web: +escalated \(1 attempt' <<<"$LAST_OUT" && pass "transient retries stayed on attempt 1" \
  || fail "transient retries stayed on attempt 1" "out: $(grep -E '^  web:' <<<"$LAST_OUT")"

# ── AC-7: the mobile phase is blocked without the web tag on HEAD ─────────────
reset_repo
assert_run "mobile: --mobile-only with no web tag → blocked, non-zero" 1 "carries no staging-v\* tag" --mobile-only --dry-run

# ── AC-9: the mobile preflight names the specific missing item ────────────────
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=1 run --web-only >/dev/null 2>&1   # land a tag on HEAD
# NB: NOT in a subshell — assert_run's PASS/FAIL increments would be lost (the same
# trap cut-mobile-release.test.sh documents).
saved_key_id="$EXPO_ASC_KEY_ID"; unset EXPO_ASC_KEY_ID
assert_run "mobile: preflight names the missing env var" 1 "environment variable EXPO_ASC_KEY_ID" --mobile-only
export EXPO_ASC_KEY_ID="$saved_key_id"
SUBMIT_RC=1 assert_run "mobile: preflight names a failed submit-config check" 1 "check-submit-config.sh preview ios failed" --mobile-only
SUBMIT_RC=0
# Under the timer there is no interactive `eas login` state to fall back on.
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/eas"; chmod +x "$STUB/eas"
assert_run "mobile: preflight names missing Expo auth (no EXPO_TOKEN, eas whoami fails)" 1 "EXPO_TOKEN is unset" --mobile-only
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/eas"; chmod +x "$STUB/eas"

# ── Self-heal: "no booted emulator" must be BOOTED, not reported ──────────────
# The single most common weekly failure. The SDK, the AVD and KVM are all installed;
# the host merely has nobody logged in to type `emulator -avd … &`. Reporting it as a
# missing item makes every scheduled run fail identically forever, so the train boots
# one itself. These stubs model a host with no device until `emulator` is launched.
cat > "$STUB/adb" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = devices ]; then
  printf 'List of devices attached\n'
  [ -f "$EMU_STATE" ] && printf 'emulator-5554\tdevice\n'
elif [ "$1" = shell ] && [ "$2" = getprop ]; then
  [ -f "$EMU_STATE" ] && echo 1
fi
exit 0
STUBEOF
cat > "$STUB/emulator" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "-list-avds" ]; then echo skillforge_test; exit 0; fi
touch "$EMU_STATE"
sleep 120     # the real emulator stays in the foreground; release-train nohups it
STUBEOF
chmod +x "$STUB/adb" "$STUB/emulator"
export EMU_STATE="$ROOTDIR/emu-booted"; rm -f "$EMU_STATE"

assert_run "mobile: preflight COLD-BOOTS an AVD instead of reporting no device" \
  0 "cold-booting AVD 'skillforge_test'" --mobile-only
grep -q "booted in" <<<"$LAST_OUT" && pass "mobile: the boot is awaited via sys.boot_completed" \
  || fail "mobile: the boot is awaited via sys.boot_completed" "out: $(tail -5 <<<"$LAST_OUT")"

# …and a host where the boot is genuinely impossible still escalates LOUDLY, because
# a preflight failure used to be the one mobile path that filed nothing at all.
rm -f "$EMU_STATE"
RT_EMULATOR_BOOT=0 assert_run "mobile: an unbootable emulator is still named specifically" \
  1 "could not boot one" --mobile-only
grep -qE "filed issue #4242|ESCALATING mobile/preflight" <<<"$LAST_OUT" \
  && pass "mobile: a preflight failure ESCALATES (a weekly timer must never fail silently)" \
  || fail "mobile: a preflight failure ESCALATES (a weekly timer must never fail silently)" \
          "out: $(tail -6 <<<"$LAST_OUT")"

# Restore the always-booted stub for the remaining mobile tests.
printf '#!/usr/bin/env bash\nif [ "$1" = devices ]; then printf "List\\nemulator-5554\\tdevice\\n"; fi\nexit 0\n' > "$STUB/adb"
rm -f "$STUB/emulator"; chmod +x "$STUB/adb"

# ── AC-8/AC-10: an OTA update is NOT a store binary → failure ─────────────────
MOBILE_MODE=ota assert_run "mobile: OTA instead of a store binary → escalate" 1 "OTA update instead of a store binary" --mobile-only
MOBILE_MODE=build assert_run "mobile: eas submit accepted → success" 0 "accepted for TestFlight" --mobile-only

# ── AC-7 (PR #2206 round 1): a mobile-phase auto-fix that pushes to main moves HEAD
# past the web tag; --mobile-only must NOT silently re-cut (and redeploy) the WEB
# phase to re-pair it — that would ship an unrequested web release. It must stop and
# say so, non-zero, instead of cutting behind the operator's back.
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=1 run --web-only >/dev/null 2>&1   # land the initial web tag
before_web_tags="$( cd "$REPO" && git tag -l 'staging-v*' | wc -l | tr -d ' ' )"
CUT_GATE=typecheck MOBILE_MODE=gatefail CLAUDE_MODE=fix CUT_PUSH_TAG=1 \
  assert_run "mobile: an auto-fix push during --mobile-only does NOT re-cut web" \
  1 "mobile-only forbids cutting a new web release to re-pair it" --mobile-only
web_cuts="$(grep -cE 'web: +cut' <<<"$LAST_OUT")"
after_web_tags="$( cd "$REPO" && git tag -l 'staging-v*' | wc -l | tr -d ' ' )"
if [[ "$web_cuts" -eq 0 && "$after_web_tags" -eq "$before_web_tags" ]]; then
  pass "--mobile-only never cuts (or deploys) a new web staging tag, even after its own auto-fix"
else
  fail "--mobile-only never cuts (or deploys) a new web staging tag, even after its own auto-fix" \
    "web_cuts=$web_cuts tags_before=$before_web_tags tags_after=$after_web_tags out: $(tail -12 <<<"$LAST_OUT")"
fi

# ── AC-1/AC-2: --dry-run prints the plan, spawns nothing, pushes nothing ──────
reset_repo
before="$( cd "$REPO" && git rev-parse HEAD )"
CLAUDE_MODE=crash assert_run "--dry-run prints the plan" 0 "WOULD run .*cut-release.sh staging" --web-only --dry-run
grep -q "spawning claude" <<<"$LAST_OUT" && fail "--dry-run spawns no model" "claude was spawned" || pass "--dry-run spawns no model"
[[ "$( cd "$REPO" && git rev-parse HEAD )" == "$before" ]] \
  && [[ -z "$( cd "$REPO" && git tag -l 'staging-v*' )" ]] \
  && pass "--dry-run pushes nothing" || fail "--dry-run pushes nothing" "HEAD or tags moved"

# ── AC-1 regression (PR #2206 round 1): the plain, no-flag `--dry-run` documented in
# docs/AGENT-HARNESS.md and release-train-setup.sh runs BOTH phases. Since the web
# dry-run never actually tags HEAD, the mobile phase used to treat the absent tag as
# a hard block (rc=1, "mobile phase blocked") instead of printing its own plan.
reset_repo
CLAUDE_MODE=crash assert_run "default --dry-run prints BOTH the web and the mobile plan" \
  0 "WOULD run .*cut-mobile-release.sh" --dry-run
grep -q "mobile phase blocked" <<<"$LAST_OUT" \
  && fail "default --dry-run does not block the mobile phase on the not-yet-cut tag" "printed 'mobile phase blocked'" \
  || pass "default --dry-run does not block the mobile phase on the not-yet-cut tag"
grep -qE "no staging-v\* tag on HEAD yet" <<<"$LAST_OUT" \
  && pass "default --dry-run notes the tag precondition instead of silently assuming it" \
  || fail "default --dry-run notes the tag precondition instead of silently assuming it" "out: $(tail -8 <<<"$LAST_OUT")"

# ── AC-2: preflight aborts on a dirty tree / a non-main HEAD ──────────────────
( cd "$REPO" && echo dirt > dirty.txt )
assert_run "preflight: dirty tree → exit 2" 2 "working tree is dirty" --web-only
# AC-14 (PR #2206 round 1): a preflight abort must still leave a trace in state,
# not just on stderr — a week where the train never got past preflight is otherwise
# invisible to anything reading `.release_train`.
summary="$( cd "$REPO" && bash -c 'source scripts/lib/state-shard.sh; sget ".release_train.last_run"' 2>/dev/null )"
if jq -e '.outcome == "aborted-preflight" and (.reason | test("dirty"))' <<<"$summary" >/dev/null 2>&1; then
  pass "a preflight abort (dirty tree) still records a run summary in state"
else
  fail "a preflight abort (dirty tree) still records a run summary in state" "got: ${summary:0:200}"
fi
( cd "$REPO" && rm -f dirty.txt )
( cd "$REPO" && git checkout --quiet -b sidebranch )
assert_run "preflight: HEAD not on main → exit 2" 2 "releases are cut from 'main'" --web-only

# …and an UNATTENDED abort must file an issue, not just print to a journal nobody
# reads. A dirty tree is the likely residue of a previous crashed run, so it blocks
# every future weekly cut until a human happens to look.
reset_repo
( cd "$REPO" && echo dirt >> package.json )
RT_ESCALATE_PREFLIGHT=1 assert_run "preflight: an unattended abort escalates" 2 "filed issue #4242" --web-only
# Interactively it stays quiet — the operator is reading the message right now.
RT_ESCALATE_PREFLIGHT=0 run --web-only
grep -q "filed issue" <<<"$LAST_OUT" \
  && fail "preflight: an INTERACTIVE abort files nothing" "filed an issue with an operator watching" \
  || pass "preflight: an INTERACTIVE abort files nothing"
reset_repo
( cd "$REPO" && git checkout --quiet main )

# ── AC-17: a second concurrent start is a no-op ───────────────────────────────
reset_repo
( exec 9>"$ROOTDIR/rt.lock"; flock -n 9 && sleep 6 ) &
HOLDER=$!
sleep 1
assert_run "concurrency: second start is a no-op" 0 "another run is already in flight" --web-only --dry-run
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
# flock lives on the INODE, and killing the holder's shell does not always close its fd
# promptly. Unlink the path so the next run's `exec 9>` creates a fresh inode — otherwise
# every subsequent case in this file silently no-ops on a lock nobody owns any more.
rm -f "$ROOTDIR/rt.lock"
# AC-14 (PR #2206 round 1): the no-op path must also record a summary in state.
summary="$( cd "$REPO" && bash -c 'source scripts/lib/state-shard.sh; sget ".release_train.last_run"' 2>/dev/null )"
if jq -e '.outcome == "lock-busy"' <<<"$summary" >/dev/null 2>&1; then
  pass "a concurrent-start no-op still records a run summary in state"
else
  fail "a concurrent-start no-op still records a run summary in state" "got: ${summary:0:200}"
fi

# ── AC-14: the run summary lands in state via sset ────────────────────────────
reset_repo
CUT_EXIT=1 CUT_PUSH_TAG=1 run --web-only
STATE_RUN_OUT="$LAST_OUT"
summary="$( cd "$REPO" && bash -c 'source scripts/lib/state-shard.sh; sget ".release_train.last_run"' 2>/dev/null )"
if jq -e '.web.outcome == "cut" and (.tag|startswith("staging-v"))' <<<"$summary" >/dev/null 2>&1; then
  pass "run summary written to state via sget/sset"
else
  fail "run summary written to state via sget/sset" "got: ${summary:0:200} ||| run: $(tail -6 <<<"$STATE_RUN_OUT" | tr '\n' '|')"
fi

# ── Drift guard: ALL_GATES must match quality-gates.sh's GATES ────────────────
rt_gates="$(grep -oE '^ALL_GATES=\(.*\)' "$RT_SCRIPT" | sed -E 's/^ALL_GATES=\(|\)$//g')"
qg_gates="$(grep -oE '^GATES=\(.*\)' "$SCRIPT_DIR/quality-gates.sh" | sed -E 's/^GATES=\(|\)$//g')"
if [[ -n "$rt_gates" && "$rt_gates" == "$qg_gates" ]]; then
  pass "ALL_GATES matches quality-gates.sh GATES"
else
  fail "ALL_GATES matches quality-gates.sh GATES" "rt=[$rt_gates] qg=[$qg_gates]"
fi

# ── Coverage guard: EVERY gate the train can auto-fix has an owner skill ──────
# Since issue #2209 every gate is auto-fixable, so every gate name can reach
# route-failure.sh. A gate with no case there resolves to the literal "unknown", and
# the fixer is briefed to "invoke the `unknown` skill" — the routing the harness is
# built around is silently lost. Observed live: `routing mobile-e2e → unknown` during
# a real mobile cut. This guard makes adding a gate without an owner a test failure.
unrouted=()
for g in $rt_gates; do
  owner="$(bash "$SCRIPT_DIR/route-failure.sh" --gate "$g" 2>/dev/null | tr -d '[:space:]')"
  [[ -z "$owner" || "$owner" == "unknown" ]] && unrouted+=("$g")
done
[[ "${#unrouted[@]}" -eq 0 ]] \
  && pass "every gate in ALL_GATES routes to a real owner skill" \
  || fail "every gate in ALL_GATES routes to a real owner skill" "unrouted: ${unrouted[*]}"

# ── PR #2206 round 1: the weekly cut must not verify LESS than the manual cut it
# replaces. WEB_REQUIRED_GATES must cover every one of quality-gates.sh's own
# REQUIRED_BY_TIER[launch] gates except mobile-e2e (the mobile phase's own hard
# gate) and visual (Docker-heavy, same cost class as the never-required `e2e`).
qg_launch_required="$(grep -oE '\[launch\]="[^"]*"' "$SCRIPT_DIR/quality-gates.sh" | sed -E 's/^\[launch\]="|"$//g')"
rt_web_required="$(grep -oE '^WEB_REQUIRED_GATES="\$\{RT_WEB_REQUIRED_GATES:-[^}]*\}"' "$RT_SCRIPT" \
  | sed -E 's/^WEB_REQUIRED_GATES="\$\{RT_WEB_REQUIRED_GATES:-|\}"$//g')"
missing=()
for g in $qg_launch_required; do
  case "$g" in mobile-e2e|visual) continue;; esac
  [[ " $rt_web_required " == *" $g "* ]] || missing+=("$g")
done
if [[ -n "$qg_launch_required" && -n "$rt_web_required" && "${#missing[@]}" -eq 0 ]]; then
  pass "WEB_REQUIRED_GATES covers every launch-tier gate except mobile-e2e/visual"
else
  fail "WEB_REQUIRED_GATES covers every launch-tier gate except mobile-e2e/visual" \
    "launch=[$qg_launch_required] web=[$rt_web_required] missing=[${missing[*]:-}]"
fi

# ── The systemd units (AC-15/16/17) ───────────────────────────────────────────
UNITS_DIR="$(cd "$SCRIPT_DIR/../deploy/systemd" && pwd)"
SVC="$UNITS_DIR/skillforge-release-train.service"
TMR="$UNITS_DIR/skillforge-release-train.timer"
CHK="$UNITS_DIR/skillforge-release-train-checkenv.service"

for f in "$SVC" "$TMR" "$CHK"; do
  [[ -f "$f" ]] && pass "unit exists: $(basename "$f")" || fail "unit exists: $(basename "$f")" "missing"
done
grep -qE '^OnCalendar=Fri \*-\*-\* 20:00$' "$TMR" && pass "timer: OnCalendar=Fri *-*-* 20:00" \
  || fail "timer: OnCalendar=Fri *-*-* 20:00" "got: $(grep -E '^OnCalendar=' "$TMR")"
grep -qE '^Persistent=true$' "$TMR" && pass "timer: Persistent=true (a missed Friday fires on resume)" \
  || fail "timer: Persistent=true" "got: $(grep -E '^Persistent=' "$TMR")"
grep -qE '^EnvironmentFile=-.*release-train\.env$' "$SVC" && pass "service: pins credentials via EnvironmentFile=" \
  || fail "service: pins credentials via EnvironmentFile=" "no release-train.env EnvironmentFile line"
# The PATH must carry everything ~/.bashrc adds and systemd would not: nvm node, conda,
# ~/.local/bin, the Android platform-tools (adb) and ~/.maestro/bin (the mobile-e2e runner).
svc_path="$(grep -E '^Environment=PATH=' "$SVC")"
missing_path=()
for seg in nvm miniconda '\.local/bin' 'platform-tools' '\.maestro/bin'; do
  grep -qE "$seg" <<<"$svc_path" || missing_path+=("$seg")
done
[[ "${#missing_path[@]}" -eq 0 ]] && pass "service: PATH carries nvm/conda/local/adb/maestro" \
  || fail "service: PATH carries nvm/conda/local/adb/maestro" "missing: ${missing_path[*]}"
# check-env must share the real unit's environment or it proves nothing about it.
svc_env="$(grep -E '^(Environment|EnvironmentFile)=' "$SVC" | grep -v 'RELEASE_TRAIN_ARGS')"
chk_env="$(grep -E '^(Environment|EnvironmentFile)=' "$CHK")"
[[ "$svc_env" == "$chk_env" ]] && pass "checkenv unit shares the release-train unit's environment" \
  || fail "checkenv unit shares the release-train unit's environment" "env blocks differ"
grep -q -- '--check-env' "$CHK" && pass "checkenv unit runs --check-env (cuts nothing)" \
  || fail "checkenv unit runs --check-env" "ExecStart does not pass --check-env"
if command -v systemd-analyze >/dev/null 2>&1; then
  vfail=()
  for f in "$SVC" "$TMR" "$CHK"; do systemd-analyze --user verify "$f" >/dev/null 2>&1 || vfail+=("$(basename "$f")"); done
  [[ "${#vfail[@]}" -eq 0 ]] && pass "systemd-analyze verify: all three units clean" \
    || fail "systemd-analyze verify" "failed: ${vfail[*]}"
else
  pass "systemd-analyze verify (skipped — not installed)"
fi
# ExecStart must name a script that actually exists (same rule the docs-refs gate enforces).
es="$(grep -hoE '/[^ ]*/scripts/release-train\.sh' "$SVC" "$CHK" | sed 's|.*/scripts/|scripts/|' | sort -u)"
[[ "$es" == "scripts/release-train.sh" && -f "$SCRIPT_DIR/release-train.sh" ]] \
  && pass "unit ExecStart points at a real script" || fail "unit ExecStart points at a real script" "got: $es"

# ── The fix classes and the risk zones are declared in exactly one place ──────
for k in MECHANICAL_FIX_GATES FORBIDDEN_FIX_PATHS; do
  n="$(grep -cE "^${k}=\(" "$RT_SCRIPT")"
  [[ "$n" -eq 1 ]] && pass "${k} is declared exactly once" || fail "${k} is declared exactly once" "found $n declarations"
done
# issue #2209: the allowlist is gone for good. A future edit that reintroduces a
# gate-class escalation boundary must fail here rather than silently re-strand `unit`.
grep -q 'ALLOWED_FIX_GATES' "$RT_SCRIPT" \
  && fail "no gate-class allowlist remains" "ALLOWED_FIX_GATES is back in release-train.sh" \
  || pass "no gate-class allowlist remains"
grep -qE 'MECHANICAL_FIX_GATES.*escalation boundary|is a CLASSIFICATION, not a bound' "$RT_SCRIPT" \
  && pass "MECHANICAL_FIX_GATES documents itself as a classification, not a bound" \
  || fail "MECHANICAL_FIX_GATES documents itself as a classification, not a bound" "the comment drifted"

  # ── Every FORBIDDEN_FIX_PATHS entry must resolve on disk ─────────────────────
  # issue #2241: the phantom backend/app/api/auth/ path was in this list for months
  # without any gate noticing — so the guard was inert for auth edits. This test
  # extracts the paths the same way the fixer reads them and asserts each exists.
  miss=""
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -e "$p" ]] || miss="${miss} ${p}"
  done < <(sed -n '/^FORBIDDEN_FIX_PATHS=(/,/^)/p' "$RT_SCRIPT" \
           | grep -oE 'backend/[A-Za-z0-9_./-]+')
  [[ -z "$miss" ]] \
    && pass "every FORBIDDEN_FIX_PATHS entry resolves on disk" \
    || fail "every FORBIDDEN_FIX_PATHS entry resolves on disk" "MISSING:${miss}"

# ── Coverage guard: EVERY runner quality-gates.sh dispatches to is gate config ────
# The predicate named four scripts by hand while the gate runner dispatches to ~20, so
# the `unit` gate's own scripts/unit.sh was unprotected. Extract the REAL predicate and
# run it against every runner quality-gates.sh actually calls, so adding a gate (or
# re-narrowing the glob to a name list) fails here instead of silently reopening the hole.
sed -n '/^is_gate_config_path() {/,/^}/p' "$RT_SCRIPT" > "$ROOTDIR/gcp.sh"
covers_gate_config() { ( set +u; source "$ROOTDIR/gcp.sh"; is_gate_config_path "$1" ); }
uncovered=""
for s in $(grep -oE 'scripts/[a-z0-9-]+\.sh' "$SCRIPT_DIR/quality-gates.sh" | sort -u); do
  covers_gate_config "$s" || uncovered="${uncovered} ${s}"
done
[[ -z "$uncovered" ]] \
  && pass "every gate runner quality-gates.sh dispatches to counts as gate config" \
  || fail "every gate runner quality-gates.sh dispatches to counts as gate config" "uncovered:${uncovered}"
# …and the converse, so "cover everything" can never be satisfied by returning 0 always:
# ordinary product source and docs must stay freely fixable, or nothing is auto-fixable.
still_fixable=""
for s in backend/app/services/course_service.py frontend/src/lib/api.ts docs/AGENT-HARNESS.md backend/openapi.yaml; do
  covers_gate_config "$s" && still_fixable="${still_fixable} ${s}"
done
[[ -z "$still_fixable" ]] \
  && pass "ordinary product source is NOT classed as gate config" \
  || fail "ordinary product source is NOT classed as gate config" "wrongly protected:${still_fixable}"

# The same coverage argument for the CONFIG side, derived from disk rather than from a
# name list — a name list is what let `frontend/vite.config.ts` slip through, since it is
# `vite.config.ts` (not `vitest.config.ts`) that carries the frontend suite's `test:`
# block. For every JS workspace the `unit` gate actually runs, resolve the config file
# vitest/jest would load and assert the guard protects it; same for the file pytest reads.
# Adding a workspace — or re-narrowing the glob — fails here instead of quietly handing a
# fixer a `test.exclude` it can drop the largest suite with.
uncovered_cfg=""
while IFS= read -r pkg; do
  jq -e '.scripts.test // empty' "$RT_REPO_ROOT/$pkg" >/dev/null 2>&1 || continue
  d="$(dirname "$pkg")"
  for cfg in vitest.config vite.config jest.config; do
    for f in "$RT_REPO_ROOT/$d/$cfg".*; do
      [[ -f "$f" ]] || continue
      rel="${f#"$RT_REPO_ROOT"/}"
      covers_gate_config "$rel" || uncovered_cfg="${uncovered_cfg} ${rel}"
    done
  done
done < <(git -C "$RT_REPO_ROOT" ls-files '*package.json' ':!:**/node_modules/**')
for f in "$RT_REPO_ROOT"/vitest.workspace.* "$RT_REPO_ROOT"/backend/pyproject.toml \
         "$RT_REPO_ROOT"/frontend/playwright.config.*; do
  [[ -f "$f" ]] || continue
  rel="${f#"$RT_REPO_ROOT"/}"
  covers_gate_config "$rel" || uncovered_cfg="${uncovered_cfg} ${rel}"
done
[[ -z "$uncovered_cfg" ]] \
  && pass "every test-runner config the gates actually load counts as gate config" \
  || fail "every test-runner config the gates actually load counts as gate config" \
          "uncovered:${uncovered_cfg}"

# ── Coverage guard: the skip-marker pattern vs. every way to silence a test ───────
# Same reasoning as the gate-config guard above, one level down. The end-to-end cases
# each drive ONE idiom through a real cut, which is slow and therefore samples thinly —
# and a thin sample is how `@pytest.mark.skip` got covered while the module-level
# `pytestmark = pytest.mark.skip` (an entire file, one line, no decorator) did not.
# Extract the REAL pattern and run the table against it, so narrowing it fails here.
rt_skip_re="$(sed -n "s/^SKIP_MARKER_RE='\(.*\)'$/\1/p" "$RT_SCRIPT")"
[[ -n "$rt_skip_re" ]] && pass "SKIP_MARKER_RE is extractable for coverage checking" \
  || fail "SKIP_MARKER_RE is extractable for coverage checking" "the declaration's shape changed"
uncaught=""
while IFS= read -r probe; do
  [[ -z "$probe" ]] && continue
  grep -qE "$rt_skip_re" <<<"$probe" || uncaught="${uncaught}
    ${probe}"
done <<'PROBES'
@pytest.mark.skip(reason="flaky")
    @pytest.mark.skipif(True, reason="x")
pytestmark = pytest.mark.skip(reason="flaky in CI")
pytestmark = pytest.mark.skipif(sys.platform == "linux", reason="x")
pytestmark = [pytest.mark.skip]
    pytest.param(1, marks=pytest.mark.skip),
        pytest.skip("cannot run here", allow_module_level=True)
@unittest.skip("no")
collect_ignore = ["test_thing.py"]
collect_ignore_glob = ["test_*.py"]
  it.skip('does the thing', () => {})
  describe.only('just this one', () => {})
  test.todo('later')
  test.skipIf(process.env.CI)('x', () => {})
  test.runIf(false)('x', () => {})
  xit('x', () => {})
PROBES
[[ -z "$uncaught" ]] && pass "SKIP_MARKER_RE catches every known test-silencing idiom" \
  || fail "SKIP_MARKER_RE catches every known test-silencing idiom" "uncaught:${uncaught}"
# The converse: repairing a stale assertion is the one edit a fixer MUST still be able to
# make, so the pattern must not swallow ordinary test code.
wrongly=""
while IFS= read -r probe; do
  [[ -z "$probe" ]] && continue
  grep -qE "$rt_skip_re" <<<"$probe" && wrongly="${wrongly}
    ${probe}"
done <<'PROBES'
    assert response.status_code == 200
def test_thing():
  expect(screen.getByRole('button')).toBeVisible()
  it('renders the skip link', () => {})
    assert user.is_active is True
PROBES
[[ -z "$wrongly" ]] && pass "SKIP_MARKER_RE does not block a legitimate assertion repair" \
  || fail "SKIP_MARKER_RE does not block a legitimate assertion repair" "wrongly caught:${wrongly}"

# ── recheck_gate: transience must be BOUNDED and measured under the phase's env ───────
# The 2026-08-01 mobile cut ran its full 20 attempts without ever escalating. Every attempt
# failed the `unit` gate, and every recheck came back green, so every attempt was stamped
# "the failure was transient; continuing the cut". The recheck could not see the failure by
# construction: the cut runs the gates through a wrapper that exports REQUIRED_GATES, and
# recheck_gate invoked quality-gates.sh bare — it WAS the control condition. An always-green
# recheck resets the callers' no-progress counters, so there is no escalation path at all.
#
# Extracted rather than driven through the sandbox: this is a decision function, and the
# properties worth pinning are "does it stop" and "does it carry the env", both of which a
# stub gate runner answers deterministically in milliseconds. (Same technique as the
# is_gate_config_path extraction above.)
echo
echo "recheck_gate — bounded transience"
RG_DIR="$(mktemp -d)"; trap 'rm -rf "$RG_DIR"' EXIT
mkdir -p "$RG_DIR/scripts"
{
  echo 'info() { :; }'
  echo 'warn() { :; }'
  sed -n '/^RT_MAX_TRANSIENT=/p;/^declare -A RT_TRANSIENT_SEEN=/p' "$RT_SCRIPT"
  sed -n '/^recheck_gate() {/,/^}/p' "$RT_SCRIPT"
} > "$RG_DIR/rg.sh"

# A stub gate runner that always passes, and records the env it was given.
cat > "$RG_DIR/scripts/quality-gates.sh" <<'STUB'
#!/usr/bin/env bash
printf 'SAW_MARKER=%s\n' "${RT_TEST_MARKER:-<unset>}" >> "$RG_DIR_ENVLOG"
echo "RESULT: all gates pass"
STUB
chmod +x "$RG_DIR/scripts/quality-gates.sh"

# GATE_ENV_EXTRA is a bash ARRAY, so it cannot be handed to a child through the environment —
# it has to be declared inside the subshell that sources the extracted function.
_rg_probe() { # <max> → prints the rc of each successive call
  RT_MAX_TRANSIENT="$1" \
  RG_DIR_ENVLOG="$RG_DIR/env.log" \
  ROOT="$RG_DIR" RT_LOGDIR="$RG_DIR" \
  bash -c '
    GATE_ENV_EXTRA=("RT_TEST_MARKER=carried")
    source "$1/rg.sh"
    for _ in 1 2 3 4 5; do recheck_gate mobile unit && printf "0" || printf "1"; done
  ' _ "$RG_DIR"
}

# An always-green recheck must stop forgiving after RT_MAX_TRANSIENT, not forever.
_seq="$(_rg_probe 2)"
[[ "$_seq" == "00111" ]] \
  && pass "an always-green recheck is forgiven exactly RT_MAX_TRANSIENT times, then escalates" \
  || fail "an always-green recheck is forgiven exactly RT_MAX_TRANSIENT times, then escalates" \
          "expected 00111, got ${_seq}"

# The cap is configurable, and 1 means "one free pass".
rm -f "$RG_DIR/env.log"
_seq="$(_rg_probe 1)"
[[ "$_seq" == "01111" ]] \
  && pass "RT_MAX_TRANSIENT=1 gives exactly one free pass" \
  || fail "RT_MAX_TRANSIENT=1 gives exactly one free pass" "expected 01111, got ${_seq}"

# The phase's GATE_ENV_EXTRA must reach the re-run, or the recheck measures a different
# environment than the one that failed — which is how it became a guaranteed false green.
if grep -q 'SAW_MARKER=carried' "$RG_DIR/env.log" 2>/dev/null; then
  pass "recheck_gate re-runs the gate under the phase's GATE_ENV_EXTRA"
else
  fail "recheck_gate re-runs the gate under the phase's GATE_ENV_EXTRA" \
       "stub never saw RT_TEST_MARKER: $(cat "$RG_DIR/env.log" 2>/dev/null)"
fi

# A gate that genuinely stays red is reported red on the FIRST call — the bound must not
# accidentally grant a red gate a free pass.
cat > "$RG_DIR/scripts/quality-gates.sh" <<'STUB'
#!/usr/bin/env bash
echo "RESULT: 1 gate(s) FAILED"
exit 1
STUB
chmod +x "$RG_DIR/scripts/quality-gates.sh"
_seq="$(_rg_probe 2)"
[[ "$_seq" == "11111" ]] \
  && pass "a still-red gate is never reported as transient" \
  || fail "a still-red gate is never reported as transient" "expected 11111, got ${_seq}"

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
