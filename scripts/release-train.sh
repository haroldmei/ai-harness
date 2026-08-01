#!/usr/bin/env bash
# release-train.sh — the weekly unattended staging cut: web first, then iOS, with a
# bounded fix-and-retry loop around each.
#
# This is the codified version of the manual prompt recorded in
# docs/agent-effectiveness-report-2026-07-02.md:150 —
#   "run cut-release.sh staging, if any error, fix it and rerun, until successfully
#    pushing the tag"
# …plus the mobile half, plus the guardrails that make it safe to run with nobody
# watching (issue #2205).
#
#   scripts/release-train.sh                 # web cut, then the iOS store cut
#   scripts/release-train.sh --web-only
#   scripts/release-train.sh --mobile-only
#   scripts/release-train.sh --dry-run       # print the plan; spawn no model, push nothing
#   scripts/release-train.sh --max-attempts 5
#   scripts/release-train.sh --check-env     # mobile preflight ONLY — no cut, no model, no push.
#                                            # This is what skillforge-release-train-checkenv.service
#                                            # runs, so a `systemctl --user start` can prove the unit's
#                                            # EnvironmentFile actually resolves without cutting a release.
#
# ── What it orchestrates (it REUSES, it does not reimplement) ─────────────────
#   scripts/cut-release.sh staging          gates → staging-vX.Y.Z tag → push → deploy-staging.yml
#   scripts/cut-mobile-release.sh staging   gates (mobile-e2e HARD) → eas build → eas submit → TestFlight
#   scripts/route-failure.sh                gate → owner skill
#   scripts/lib/agent-model-call.sh         classify_model_result (transient ≠ a burned attempt)
#   scripts/lib/agent-trace.sh              one telemetry span per `claude` invocation (CLAUDE.md)
#   scripts/lib/state-shard.sh              sget/sset — never touch state JSON directly
#
# ── Three quirks of the underlying cuts this wrapper exists to absorb ─────────
#   1. `cut-release.sh staging` EXITS 1 ON SUCCESS. Its last statement is a
#      prod-only `[[ … ]] && echo …`, which is false for staging, and under
#      `set -e` that is the script's exit status. So web success is asserted from
#      the TAG being on origin and on HEAD — never from `$?`.
#   2. `--skip` on a tier-required gate FAILS CLOSED (quality-gates.sh run_gate).
#      So a fast staging cut must narrow REQUIRED_GATES *first* and only then skip
#      the remainder. This script derives the skip list as "every gate minus the
#      required set", which makes the two impossible to contradict.
#   3. A gate run leaves a corepack `"packageManager": "yarn…"` key in the root
#      package.json. It is reverted before every dirty-tree check and before every
#      fix commit, so no auto-commit ever carries it.
#
# ── Blast radius (the reason this is safe to leave unattended) ────────────────
#   • EVERY gate is auto-fixable (issue #2209). The loop used to escalate any gate
#     outside a five-name allowlist, which meant the single most common staging
#     failure — `unit` — was never self-healing and always woke a human. The bound
#     is now on WHAT a fix may do, not on WHICH gate produced it:
#       - No fix may touch a risk zone — see FORBIDDEN_FIX_PATHS.
#       - No fix may delete a test file, delete an individual test case out of one,
#         disable a test with a skip/only marker, or edit gate configuration —
#         including ANY script under scripts/, since that is the harness judging the
#         fix. See test_integrity_violations(). That is the "turn it green by
#         removing the evidence" move, and it is the ONLY thing the old gate
#         allowlist was really protecting against.
#     A fix that trips either check has the WHOLE fix discarded and escalates.
#   • No-progress guard: the same gate failing with the same signature 3 times in
#     a row, or a fix that produces an empty diff, escalates immediately rather
#     than burning the remaining attempts on an unchanged failure.
#   • Exhaustion files (or updates) a GitHub issue and exits non-zero. It never
#     fails silently.
#
# Exit: 0 = every requested phase succeeded (or was already cut)
#       1 = a phase failed / escalated
#       2 = usage or preflight error
#
# See docs/AGENT-HARNESS.md §"Release train" for the timer and the unstick runbook.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

# shellcheck source=scripts/lib/agent-trace.sh
source "$ROOT/scripts/lib/agent-trace.sh"
# shellcheck source=scripts/lib/agent-model-call.sh
source "$ROOT/scripts/lib/agent-model-call.sh"
# shellcheck source=scripts/lib/state-shard.sh
source "$ROOT/scripts/lib/state-shard.sh"
# shellcheck source=scripts/lib/gate-reason.sh
source "$ROOT/scripts/lib/gate-reason.sh"

GH="${GH:-gh}"

# ═══════════════════════════════════════════════════════════════════════════════
# Blast-radius configuration — ONE place, deliberately at the top of the file.
# ═══════════════════════════════════════════════════════════════════════════════

# Gate classes whose failure is RECURRING DEBT with a mechanical, low-risk fix:
#   typecheck / lint      mypy + ruff baseline drift
#   docs-refs             a doc naming a scripts/… path that moved
#   iteration-immutable   iteration-log drift
#   contract              a stale openapi.yaml dump (regenerated, not hand-edited)
#
# This is a CLASSIFICATION, not a bound (issue #2209). Every other gate — unit,
# integration, e2e, coverage, migration-drift, … — is a real PRODUCT failure and is
# auto-fixed too; it just gets the stricter prompt below. Escalation is now driven
# by what a fix DOES (risk zones, test integrity, no progress), never by which gate
# asked for it. A gate name is not evidence about a diff's blast radius.
MECHANICAL_FIX_GATES=(typecheck lint docs-refs iteration-immutable contract)

# A fix that produces a diff under any of these aborts the run and escalates.
# These are CLAUDE.md's risk zones: auth, billing, the minors AI guard, and
# migrations. An unattended weekly job must never rewrite them.
FORBIDDEN_FIX_PATHS=(
  backend/app/api/v1/endpoints/auth.py
  backend/app/api/v1/endpoints/saml.py
  backend/app/core/security.py
  backend/app/services/billing_service.py
  backend/app/services/ai_guard.py
  backend/alembic/versions/
)

# Added lines matching this in a test file mean the "fix" silenced a test instead of
# repairing it. Editing a test's ASSERTIONS is still allowed — a genuinely stale test
# is a legitimate fix — but a *disabled* test never is.
#
# `pytest\.mark\.(skip|…)` is deliberately NOT anchored to a leading `@`. A decorator is
# only the most visible way to disable a pytest test; the module-level `pytestmark =
# pytest.mark.skip(...)` silences an ENTIRE FILE in one added line without deleting or
# decorating anything, and `pytest.param(…, marks=pytest.mark.skip)` silences one case of
# a parametrize. Requiring the `@` caught the loud form and missed both quiet ones. Any
# occurrence of `pytest.mark.skip`/`skipif`/`xfail` on an ADDED line is a test that no
# longer runs, whatever the syntax around it — so match the mark itself.
#
# `collect_ignore` is conftest.py's version of the same move: the file that lists it is a
# test path (so it is scanned), but the tests it removes live in other files entirely.
SKIP_MARKER_RE='\bpytest\.mark\.(skip|skipif|xfail)|pytest\.skip\(|@unittest\.(skip|expectedFailure)|\bcollect_ignore(_glob)?\b|\b(it|test|describe|context|suite)\.(skip|only|todo|failing|fixme|skipIf|runIf)\b|\b(xit|xtest|xdescribe)[[:space:]]*\(|\.skip\.each\b|# *type: *ignore'

# A test-case DECLARATION. Anchored separately for the '-' and '+' sides of a diff so the
# same body applies to both — see the net-count check in check_test_integrity.
#
# This used to exist only in its '-' form, and any matching removed line was treated as a
# deleted test case. Nothing paired it with the '+' side, so a RENAMED test — one `it(…)`
# title edited — was indistinguishable from a deleted one. On 2026-07-31 that discarded a
# correct fix which had self-reported a test-count INCREASE (2726 → 2727). The fixer brief
# explicitly permits correcting stale assertions and titles, so the guard was rejecting an
# edit class the brief invites (issue #2387, H2).
#
# Now: count declarations on both sides PER FILE and flag only a NET decrease.
#
# Accepted cost, deliberately: net counting cannot catch a 1:1 swap — delete three real
# assertions, add three trivial ones, net zero, guard silent. That hole is real and it is
# the price of unblocking legitimate renames. It is bounded by what still surrounds it: the
# deleted-FILE check, the skip/only-marker check, the gate-config check, the risk-zone
# check, and the gates themselves (a trivial replacement test that asserts nothing still has
# to leave the suite green for real). H1's bounded re-brief covers the residual by letting a
# rejected fixer explain itself instead of being killed outright.
TEST_DECL_BODY_RE='[[:space:]]*((async[[:space:]]+)?def[[:space:]]+test|class[[:space:]]+Test|(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+test|(it|test|describe|bench)[[:space:]]*(\.(each|concurrent|extend|sequential))?[[:space:]]*\(|assert_run[[:space:]])'
# Kept under its original name: other call sites and scripts/release-train.test.sh reference it.
TEST_DECL_RE="^-${TEST_DECL_BODY_RE}"
TEST_DECL_ADD_RE="^\\+${TEST_DECL_BODY_RE}"

# Mirrors GATES in scripts/quality-gates.sh. Kept literal (not grepped) so this
# script works against a stubbed gate runner; release-train.test.sh asserts the
# two lists are identical, so drift fails a gate rather than going unnoticed.
ALL_GATES=(typecheck lint docs-refs iteration-immutable seed-integrity migration-drift unit coverage i18n repro-tests mutation integration contract e2e mobile-e2e mobile-perf wedge-coverage journey-coverage a11y lighthouse visual quarantine)

# The gate set the weekly staging cut REQUIRES. This is quality-gates.sh's own
# REQUIRED_BY_TIER[launch] (see quality-gates.sh:106) MINUS the two gates that are
# deliberately verified elsewhere rather than skipped for cost reasons:
#   - mobile-e2e is the mobile phase's OWN hard gate (cut-mobile-release.sh), run
#     against a real device/emulator once this phase's tag exists — running it here
#     too would just duplicate that pass.
#   - visual needs a pinned-playwright Docker container and a full screenshot-diff
#     pass — the same cost class as the browser `e2e` gate, which was never
#     launch-required to begin with. Pass --with-e2e for the full spine (including
#     visual, via cut-release.sh's own --no-e2e toggle).
# migration-drift (a CLAUDE.md risk zone: backend/alembic/versions/), coverage, and
# integration (the only gate exercising the DB path) stay REQUIRED here even though
# they cost real Docker minutes — a manual cut always verified them, and an
# unattended one must not verify less.
WEB_REQUIRED_GATES="${RT_WEB_REQUIRED_GATES:-typecheck lint docs-refs iteration-immutable migration-drift unit coverage integration contract}"

# iOS store submit needs all four of these EXPORTED (systemd does not read
# ~/.bashrc — that is what the unit's EnvironmentFile= is for). The team-id variable is
# EXPO_APPLE_TEAM_ID: that is the name eas-cli reads natively, the name ~/.bashrc exports,
# and the name cut-mobile-release.sh's own error message cites. A bare APPLE_TEAM_ID is
# accepted as an alias below, since that is what the runbook prose calls it.
IOS_ENV_VARS=(EXPO_ASC_API_KEY_PATH EXPO_ASC_KEY_ID EXPO_ASC_ISSUER_ID EXPO_APPLE_TEAM_ID)
if [[ -z "${EXPO_APPLE_TEAM_ID:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  export EXPO_APPLE_TEAM_ID="$APPLE_TEAM_ID"
fi

# ── Android SDK on PATH (the mobile-e2e emulator gate) ────────────────────────
# `adb` is usually installed to /usr/bin, but `emulator` only ever lives inside the
# SDK — so an interactive shell that can boot an AVD and a systemd unit that cannot
# differ ONLY by PATH. Derive both from the SDK root rather than trusting the
# inherited PATH, so the preflight below can boot the emulator itself instead of
# reporting "no booted device" on a host that is perfectly capable of booting one.
ANDROID_SDK_HOME_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [[ -d "$ANDROID_SDK_HOME_DIR" ]]; then
  export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_HOME_DIR}"
  export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_SDK_HOME_DIR}"
  for _d in "$ANDROID_SDK_HOME_DIR/emulator" "$ANDROID_SDK_HOME_DIR/platform-tools"; do
    [[ -d "$_d" && ":$PATH:" != *":$_d:"* ]] && PATH="$PATH:$_d"
  done
  unset _d
  export PATH
fi
# Which AVD to boot when none is running. Empty ⇒ the first one `emulator -list-avds`
# reports. RT_EMULATOR_BOOT=0 disables the auto-boot entirely (a host that must only
# ever drive a physically attached device).
RT_EMULATOR_AVD="${RT_EMULATOR_AVD:-}"
RT_EMULATOR_BOOT="${RT_EMULATOR_BOOT:-1}"
RT_EMULATOR_BOOT_TIMEOUT="${RT_EMULATOR_BOOT_TIMEOUT:-300}"

# ═══════════════════════════════════════════════════════════════════════════════

MAX_ATTEMPTS=20
DO_WEB=1
DO_MOBILE=1
DRY_RUN=0
WITH_E2E=0
CHECK_ENV=0
TRANSIENT_RETRIES="${RT_TRANSIENT_RETRIES:-5}"
TRANSIENT_BACKOFF="${RT_TRANSIENT_BACKOFF:-60}"

# How many times a DISCARDED fix may be re-briefed with the violation text before the run
# escalates (issue #2387, H1).
#
# run_fixer collapsed every failure into `return 1`, and the loop's only answer to `return 1`
# was `escalate; return 1`. The loop already knows how to say "don't burn this, retry" four
# other ways — HEAD moved, infra backoff, transient model result, empty diff + green recheck —
# but the ONE failure a re-brief could actually repair had none. A fix discarded for touching a
# risk zone or for tripping the test-integrity guard is a fixer that misunderstood its bounds;
# it has not proven the gate unfixable. Observed 2026-07-31: a cut escalated at attempt 1 of 20
# with 19 attempts unused (#2386).
#
# Bounded SEPARATELY from MAX_ATTEMPTS and reset per attempt, so a fixer that keeps reaching
# for the same forbidden edit still terminates quickly instead of spending the whole budget.
REBRIEF_MAX="${RT_REBRIEF_MAX:-2}"
NO_PROGRESS_LIMIT="${RT_NO_PROGRESS_LIMIT:-3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-only)     DO_MOBILE=0; shift;;
    --mobile-only)  DO_WEB=0; shift;;
    --max-attempts) MAX_ATTEMPTS="${2:-}"; shift 2;;
    --dry-run)      DRY_RUN=1; shift;;
    --with-e2e)     WITH_E2E=1; shift;;
    --check-env)    CHECK_ENV=1; shift;;
    -h|--help)      sed -n '2,58p' "$0"; exit 0;;
    *) printf 'release-train: unknown argument: %s\n' "$1" >&2
       printf 'usage: release-train.sh [--web-only|--mobile-only] [--max-attempts N] [--with-e2e] [--dry-run] [--check-env]\n' >&2
       exit 2;;
  esac
done

[[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ && "$MAX_ATTEMPTS" -ge 1 ]] \
  || { echo "release-train: --max-attempts must be a positive integer (got '${MAX_ATTEMPTS}')" >&2; exit 2; }
[[ "$DO_WEB" -eq 1 || "$DO_MOBILE" -eq 1 ]] \
  || { echo "release-train: --web-only and --mobile-only are mutually exclusive" >&2; exit 2; }

# ── Logging ───────────────────────────────────────────────────────────────────
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RT_LOGDIR="${RT_LOGDIR:-/tmp/release-train-${RUN_ID}}"
mkdir -p "$RT_LOGDIR"
# Pin the gate log dir so the fixer can read the ACTUAL failing gate's output
# instead of guessing at quality-gates.sh's default PID-namespaced /tmp/qg-$$
# (the exact bug that once fed verify-loop's fixer an empty failure).
export QG_LOGDIR="${QG_LOGDIR:-$RT_LOGDIR/qg}"
mkdir -p "$QG_LOGDIR"

# A preflight abort (dirty tree, HEAD off main, diverged origin, a failed fetch) is
# the LAST silent-failure path left in the train. Interactively it is fine — the
# operator is reading the message. Under the timer nobody is, so it repeats every
# Friday forever while `systemctl status` reports nothing worth looking at; a dirty
# tree in particular is the likely residue of a previous crashed run, i.e. exactly
# the state that blocks every future cut until a human happens to notice.
#
# `[[ ! -t 1 ]]` is the test for "nobody is watching" — systemd has no tty — which is
# precisely the condition that makes silence harmful. So an unattended abort files an
# issue and an interactive one stays quiet, with no flag to remember either way.
# RT_ESCALATE_PREFLIGHT=1/0 forces it on/off for tests and one-off runs.
die()  {
  printf '\033[31mrelease-train: %s\033[0m\n' "$*" >&2
  local unattended="${RT_ESCALATE_PREFLIGHT:-}"
  [[ -n "$unattended" ]] || { [[ ! -t 1 ]] && unattended=1 || unattended=0; }
  [[ "$unattended" == "1" ]] && escalate preflight "" "" "release-train aborted before any cut: $*" 2>/dev/null || true
  record_run 2 "aborted-preflight" "$*" 2>/dev/null || true
  exit 2
}
info() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WEB_OUTCOME="skipped" MOBILE_OUTCOME="skipped"
WEB_ATTEMPTS=0 MOBILE_ATTEMPTS=0
CUT_TAG="" ESCALATION_ISSUE=""
# Set only when THIS run cold-booted the emulator, so the trap below never kills an
# emulator a developer already had running for their own work.
EMULATOR_PID="" MOBILE_PREFLIGHT_MISSING=""
# Host-capacity backoff state. ITEST_XDIST_MAX mirrors scripts/integration.sh's own
# default so halving it here means the same thing it means there.
INFRA_BACKOFF_USED=0
RT_INFRA_RETRIES="${RT_INFRA_RETRIES:-2}"
ITEST_XDIST_MAX="${ITEST_XDIST_MAX:-16}"
GATE_ENV_EXTRA=()
trap '[[ -n "$EMULATOR_PID" ]] && kill "$EMULATOR_PID" 2>/dev/null' EXIT

# ── Small helpers ─────────────────────────────────────────────────────────────

in_list() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

# The corepack artifact a gate/eas run leaves behind. Reverted ONLY when the
# packageManager key is the sole change, so a genuine package.json edit is still
# caught by the dirty-tree check (same rule as cut-mobile-release.sh §4.2).
revert_package_manager_artifact() {
  git diff --quiet -- package.json 2>/dev/null && return 0
  local real
  real="$(git diff -- package.json | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
          | grep -vE '"packageManager"|^[+-][[:space:]]*[}{,]?$')"
  if [[ -z "$real" ]]; then
    info "reverting corepack packageManager artifact in root package.json"
    git checkout -- package.json
  fi
}

# Every gate name that FAILED in a captured cut log, in order, deduplicated.
# quality-gates.sh's record() prints "  ✗ <name>  <reason>".
parse_failing_gates() { # <logfile>
  local f="$1" g
  [[ -s "$f" ]] || return 0
  grep -oE '✗ [a-z0-9-]+' "$f" 2>/dev/null | sed 's/^✗ //' | awk '!seen[$0]++' | while read -r g; do
    in_list "$g" "${ALL_GATES[@]}" && printf '%s\n' "$g"
  done
}

# A stable fingerprint of "this exact failure". Digits are stripped so timings,
# durations, and counters don't make an identical failure look new — that is what
# makes the no-progress guard (AC-21) able to notice a loop that isn't moving.
failure_signature() { # <gate> <cut-logfile>
  local gate="$1" cutlog="$2" src="$QG_LOGDIR/${gate}.log"
  [[ -s "$src" ]] || src="$cutlog"
  { printf '%s\n' "$gate"
    tail -n 40 "$src" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g; s/[0-9]+/N/g'
  } | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || cksum; } | awk '{print $1}'
}

# The failing gate's own log (or the cut log) — what the fixer and the escalation
# issue are actually given to work from.
# Lines that carry an actual DIAGNOSIS. pytest's `E  ` prefix is the exception/assert
# body, `FAILED`/`ERROR` are the summary rows, and the rest cover mypy/ruff/vitest/tsc
# plus infrastructure failure signals (Docker starvation, disk space, memory, etc.).
# Infra patterns ARE included because `gate_log_tail` is also called from `escalate()`
# for exhausted infra backoffs — if the only content in the log is Docker starvation
# messages, FAILURE_LINE_RE must match them or the excerpt falls back to a blind tail.
# The diagnosing-line regex now lives in scripts/lib/gate-reason.sh so quality-gates.sh,
# verify-loop.sh and this file cannot drift apart (issue #2387, H4). Kept as an alias:
# other call sites and scripts/release-train.test.sh reference FAILURE_LINE_RE by name.
FAILURE_LINE_RE="$GATE_FAILURE_LINE_RE"

gate_log_tail() { # <gate> <cut-logfile> [lines]
  local gate="$1" cutlog="$2" n="${3:-60}" src="$QG_LOGDIR/${gate}.log"
  [[ -s "$src" ]] || src="$cutlog"

  # A blind `tail` is the wrong excerpt for every test runner we own. pytest prints
  # the failure body FIRST and a warnings summary LAST, so the last N lines of a long
  # integration log are deprecation notices — the fixer gets briefed with pure noise
  # and the escalation issue quotes it. Observed: a 1499-line integration log whose
  # root cause ("Postgres testcontainer never became usable … genuine Docker
  # starvation … lower QG_SLOTS or ITEST_XDIST_MAX") sat at line 308, while `tail -80`
  # sent lines 1420-1499 — not one of which mentioned the failure.
  #
  # So: pull the lines that actually diagnose, and fall back to the tail only when
  # nothing matches (an unrecognised runner, or a gate that died before reporting).
  local diag
  diag="$(grep -E "$FAILURE_LINE_RE" "$src" 2>/dev/null | awk '!seen[$0]++' | head -n "$n")"
  if [[ -n "$diag" ]]; then
    { printf '%s\n' "$diag"; printf -- '--- (last %s lines of %s) ---\n' 10 "${src##*/}"; tail -n 10 "$src" 2>/dev/null; } \
      | sed -E 's/\x1b\[[0-9;]*m//g'
    return 0
  fi
  tail -n "$n" "$src" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g'
}

# Failures that NO diff can fix: the host ran out of Docker/CPU headroom, not the code.
# The gate says so itself and names the remedy — which is gate configuration under
# scripts/, the one thing the fix guard forbids the model from touching. Routing these
# to a code fixer is therefore guaranteed waste: three attempts, three empty or bogus
# diffs, then a no-progress escalation. Back the concurrency off and re-run instead.
INFRA_FAILURE_RE='genuine Docker starvation|never became usable after|Cannot connect to the Docker daemon|no space left on device|Connection refused.*5432|ReaperException|Resource temporarily unavailable|Cannot allocate memory'

gate_failure_is_infra() { # <gate> <cut-logfile>
  local src="$QG_LOGDIR/${1}.log"
  [[ -s "$src" ]] || src="$2"
  grep -qE "$INFRA_FAILURE_RE" "$src" 2>/dev/null
}

# Halve the integration suite's parallelism and report whether a retry is worth it.
# Returns 0 when the caller should re-run the cut WITHOUT consuming a fix attempt
# (same rule a transient model result already gets), 1 when the backoff is exhausted
# and the failure should be escalated as infra rather than handed to a model.
# The train runs its gates in the LIVE checkout, which other automation moves. Observed:
# `git reflog` recorded `pull: Fast-forward` in the middle of a mobile cut's unit gate,
# because a PR had just merged. Two things break when that happens:
#
#   1. The gate results stop describing the commit the tag points at — the whole
#      premise of "this tag was verified" is gone.
#   2. bash reads scripts INCREMENTALLY. Replacing a test file mid-execution means the
#      already-copied script runs against newly-arrived tests. That is exactly what was
#      seen: six tests from a commit the script under test did not yet contain.
#
# cut-release.sh only ever creates and pushes a TAG — it never commits — so HEAD moving
# across a cut attempt is ALWAYS external. Treat it like the capacity backoff: discard
# the attempt (its verdict is not about any single tree) and re-run, without consuming a
# fix attempt and without spawning a model. There is nothing for a model to fix here.
head_moved_under_us() { # <head-before> <phase>
  local before="$1" phase="$2" now
  now="$(git rev-parse HEAD 2>/dev/null)"
  [[ -n "$before" && -n "$now" && "$before" != "$now" ]] || return 1
  warn "${phase}: HEAD moved from ${before:0:8} to ${now:0:8} DURING the cut — something else advanced the checkout (a merge landed). The gate results describe a tree that no longer exists; re-running rather than trusting them. No attempt consumed, no model spawned."
  return 0
}

infra_backoff() { # <phase> <gate>
  local phase="$1" gate="$2"
  if [[ "$INFRA_BACKOFF_USED" -ge "$RT_INFRA_RETRIES" ]]; then
    warn "${phase}: '${gate}' still failing on host capacity after ${INFRA_BACKOFF_USED} backoff(s)"
    return 1
  fi
  INFRA_BACKOFF_USED=$((INFRA_BACKOFF_USED + 1))
  ITEST_XDIST_MAX=$(( ITEST_XDIST_MAX / 2 )); [[ "$ITEST_XDIST_MAX" -lt 2 ]] && ITEST_XDIST_MAX=2
  GATE_ENV_EXTRA=("ITEST_XDIST_MAX=${ITEST_XDIST_MAX}" "QG_SLOTS=1")
  warn "${phase}: '${gate}' failed on HOST CAPACITY, not on the code — retrying with ITEST_XDIST_MAX=${ITEST_XDIST_MAX} (backoff ${INFRA_BACKOFF_USED}/${RT_INFRA_RETRIES}); no model spawned, no attempt consumed"
  return 0
}

# Porcelain lines present now but NOT in a given pre-snapshot (git-ignored files are
# excluded by porcelain either way). Isolates a step's OWN tree changes from any
# pre-existing churn — a gate run's state-shard writes, a stray build artifact — so
# an unattended fixer never stages/commits/pushes something it didn't produce.
# PR #2206 round 0: `git add -A` used to sweep up whatever was already dirty.
new_status_lines() { # <pre-snapshot>
  comm -13 <(sort <<<"$1") <(git status --porcelain 2>/dev/null | sort)
}

# Paths new/changed since <pre-snapshot>.
changed_paths() { # <pre-snapshot>
  new_status_lines "$1" | sed -E 's/^.{3}//' | sed 's/^.* -> //'
}

# `git add` targets for the changes since <pre-snapshot>. A rename yields BOTH
# sides — the vacated old path (so its removal is staged) and the new path (so its
# content is staged) — `git add <new-path>` alone would leave a stale duplicate of
# the old blob sitting in the index.
add_targets_since() { # <pre-snapshot>
  local line rest a b
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="${line:3}"
    if [[ "$rest" == *" -> "* ]]; then
      a="${rest%% -> *}"; b="${rest##* -> }"
      a="${a%\"}"; a="${a#\"}"; b="${b%\"}"; b="${b#\"}"
      printf '%s\n%s\n' "$a" "$b"
    else
      rest="${rest%\"}"; rest="${rest#\"}"
      printf '%s\n' "$rest"
    fi
  done < <(new_status_lines "$1")
}

# Changes since <pre-snapshot> that land under a risk zone, as
# "<porcelain-status>\t<path>". The status is carried along because the two cases
# need OPPOSITE remedies: a tracked edit is undone by `git checkout`, while an
# untracked file the fixer ADDED is only removed by deleting it — and running them
# in the wrong order deletes a tracked file outright.
forbidden_changes() { # <pre-snapshot>
  local pre="$1" line st p f
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    st="${line:0:2}"; p="${line:3}"; p="${p##* -> }"; p="${p%\"}"; p="${p#\"}"
    for f in "${FORBIDDEN_FIX_PATHS[@]}"; do
      [[ "$p" == "$f"* ]] && { printf '%s\t%s\n' "$st" "$p"; break; }
    done
  done < <(new_status_lines "$pre")
}
forbidden_diff() { forbidden_changes "$1" | cut -f2; }

# ── Test-integrity guard (issue #2209) ────────────────────────────────────────
# With the gate allowlist gone, this is what keeps an unbounded fixer honest. The
# failure mode the allowlist was really guarding against was never "the fixer
# touched `unit`" — it was "the fixer turned a gate green by removing the evidence."
# So bound THAT directly, for every gate class alike.

is_test_path() { # <path>
  local p="$1"
  case "$p" in
    tests/*|*/tests/*|test/*|*/test/*|__tests__/*|*/__tests__/*|e2e/*|*/e2e/*) return 0;;
  esac
  case "${p##*/}" in
    *.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.test.mjs) return 0;;
    *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx|*.spec.mjs) return 0;;
    *.test.sh|test_*.py|*_test.py|conftest.py) return 0;;
  esac
  return 1
}

# Files that CONFIGURE a gate. Editing one moves the goalposts rather than clearing
# them, which is the same class of cheat as deleting a test.
#
# The harness is matched by GLOB, not by a hand-kept list of names. quality-gates.sh
# dispatches nearly every gate to a sibling runner (scripts/unit.sh, lint.sh,
# typecheck.sh, integration.sh, coverage.sh, …), so naming four scripts left the most
# obvious cheat wide open for the most common failing gate: `unit` fails, the fixer
# edits scripts/unit.sh to stop running the failing suite, gate green, pushed to main.
# A name list would also have to be re-checked every time a gate is added. The fixer
# never needs to edit the harness that judges it — if a genuine harness bug is the root
# cause (a docs-refs fix that must CREATE a missing script, say), escalating to a human
# is the correct and rare outcome.
is_gate_config_path() { # <path>
  local p="$1"
  case "$p" in
    # NB in a `case` pattern `*` matches `/` too, so these two cover scripts/lib/… and
    # mobile/scripts/… as well — no per-directory arm needed (and shellcheck SC2222
    # flags one as dead if you add it).
    scripts/*.sh|*/scripts/*.sh) return 0;;
    .github/workflows/*) return 0;;
  esac
  case "${p##*/}" in
    # package.json is gate config in this repo, not just a manifest: scripts/unit.sh
    # guards EVERY JS suite behind `jq -e '.scripts.test' <workspace>/package.json` and
    # skips the workspace when that key is absent — without even incrementing its
    # `checked` counter. So deleting one key from frontend/package.json drops the entire
    # frontend suite out of the `unit` gate and the gate goes green reporting nothing
    # amiss. That is the quietest cheat available and it needs no test-file diff at all.
    # The lockfile is deliberately NOT here — it carries no gate selection, and CLAUDE.md
    # requires it to move WITH package.json, so protecting only the manifest is what makes
    # the pair escalate together rather than being half-fixed unattended.
    package.json) return 0;;
    pyproject.toml|pytest.ini|setup.cfg|tox.ini|mypy.ini|.mypy.ini|ruff.toml|.ruff.toml) return 0;;
    # `vite.config.*` is not a near-miss of `vitest.config.*` — frontend/vite.config.ts is
    # where the frontend suite's `test:` block actually lives (there is no
    # frontend/vitest.config.ts), so a `test.exclude` added there drops the largest web
    # suite while every test file and every runner script stays untouched.
    vitest.config.*|vite.config.*|vitest.workspace.*|jest.config.*|playwright.config.*) return 0;;
    .eslintrc|.eslintrc.*|eslint.config.*|tsconfig.json|tsconfig.*.json) return 0;;
  esac
  return 1
}

# Changes since <pre-snapshot> that would make a gate green by REMOVING the
# evidence: a deleted test file, a test silenced with a skip/only marker, or an
# edit to gate configuration. Emits "<why>\t<path>" lines; empty output means clean.
# NB a test-file RENAME reads as a delete + an add and therefore trips this. That is
# deliberate: escalating on the rare unattended test rename is the safe direction.
test_integrity_violations() { # <pre-snapshot>
  local pre="$1" line st p added removed diff_txt
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    st="${line:0:2}"; p="${line:3}"; p="${p##* -> }"; p="${p%\"}"; p="${p#\"}"
    if is_gate_config_path "$p"; then
      printf 'gate configuration edited\t%s\n' "$p"
      continue
    fi
    is_test_path "$p" || continue
    if [[ "$st" == *D* ]]; then
      printf 'test file deleted\t%s\n' "$p"
      continue
    fi
    # Nothing is staged at either call site, so the fixer's additions are exactly
    # the '+' lines of the unstaged diff (or the whole file, when it is brand new).
    if [[ "$st" == "??" ]]; then
      added="$(cat -- "$p" 2>/dev/null)"
      removed=""
    else
      diff_txt="$(git diff -- "$p" 2>/dev/null)"
      added="$(grep -E '^\+' <<<"$diff_txt" | grep -vE '^\+\+\+')"
      removed="$(grep -E '^-' <<<"$diff_txt" | grep -vE '^---')"
    fi
    grep -qE "$SKIP_MARKER_RE" <<<"$added" 2>/dev/null \
      && printf 'test disabled (skip/only marker added)\t%s\n' "$p"
    # Deleting test CASES out of a surviving file is the same cheat as deleting the
    # file — it just doesn't show up in the porcelain status.
    #
    # Compare NET counts, per file. Matching only the '-' side made a rename ("edit the
    # it(…) title") identical to a deletion, and killed correct fixes (issue #2387, H2).
    #
    # Per FILE, not repo-wide: a repo-wide net would let three cases deleted from a.test.ts
    # be paid for by three added to b.test.ts and come out clean.
    #
    # `grep -c` rather than `grep -q`: under this script's `set -o pipefail` a `-q` exits on
    # first match and SIGPIPEs its producer, so the pipeline status is 141 and the test reads
    # backwards. -c drains the input.
    local n_removed n_added
    n_removed="$(grep -cE "$TEST_DECL_RE" <<<"$removed" 2>/dev/null || true)"
    n_added="$(grep -cE "$TEST_DECL_ADD_RE" <<<"$added" 2>/dev/null || true)"
    n_removed="${n_removed:-0}"; n_added="${n_added:-0}"
    if [[ "$n_removed" -gt "$n_added" ]]; then
      printf 'test cases removed (%s declaration(s) deleted, %s added)\t%s\n' \
        "$((n_removed - n_added))" "$n_added" "$p"
    fi
  done < <(new_status_lines "$pre")
}

# Undo EVERYTHING the fixer produced since <pre-snapshot>. A fix that reached into a
# risk zone (or silenced a test) is not trustworthy piecemeal, so it is discarded
# whole. Order matters: delete the untracked files it ADDED first, then `git checkout`
# to undo tracked edits — the other way round restores a tracked file and then rm's
# it, which is a deletion, not a revert.
discard_fix_since() { # <pre-snapshot>
  local line st p
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    st="${line:0:2}"; p="${line:3}"; p="${p##* -> }"; p="${p%\"}"; p="${p#\"}"
    [[ "$st" == "??" && -n "$p" ]] && rm -f -- "$p"
  done < <(new_status_lines "$1")
  git checkout -- . 2>/dev/null || true
}

# ── Escalation (AC-13) ────────────────────────────────────────────────────────
# One open issue per (phase) — a re-run after an unresolved escalation COMMENTS on
# the existing issue instead of filing a duplicate. The marker is the join key.
escalate() { # <phase> <gate> <cut-logfile> <reason>
  local phase="$1" gate="$2" cutlog="$3" reason="$4"
  # Print the reason FIRST: this is the one line an operator (or `journalctl`) needs
  # to understand why an unattended run stopped, and it must survive `gh` being
  # unavailable or the issue-filing call failing.
  warn "ESCALATING ${phase}/${gate:-preflight}: ${reason}"
  local marker="<!-- release-train:staging:${phase} -->"
  local excerpt; excerpt="$(gate_log_tail "$gate" "$cutlog" 80)"
  local title="release-train: ${phase} staging cut is stuck (${gate:-preflight})"
  local body
  body="$(cat <<EOF
**Auto-filed by \`scripts/release-train.sh\`** (run \`${RUN_ID}\`).

| | |
|---|---|
| Phase | \`${phase}\` |
| Failing gate | \`${gate:-—}\` |
| Reason | ${reason} |
| Attempts used | ${WEB_ATTEMPTS} web / ${MOBILE_ATTEMPTS} mobile (cap ${MAX_ATTEMPTS}) |
| Commit | \`$(git rev-parse --short HEAD 2>/dev/null || echo unknown)\` |

The unattended fix loop stopped rather than keep pushing to \`main\`. Nothing was
tagged or shipped for this phase.

**Tail of the failing gate log:**

\`\`\`
${excerpt}
\`\`\`

Unstick: see docs/AGENT-HARNESS.md §Release train. Full logs for this run are in
\`${RT_LOGDIR}\` on the host that ran the timer.

${marker}
EOF
)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "--dry-run: WOULD escalate ${phase}/${gate:-preflight}: ${reason}"
    return 0
  fi
  command -v "$GH" >/dev/null 2>&1 || { warn "gh not available — cannot escalate; reason: ${reason}"; return 1; }

  # GitHub's --search is TERM-based, not substring — "release train staging web" all
  # appear in unrelated issues (e.g. the tracking issue for this very feature), so a
  # term hit is not proof of a dedupe match. Scope by label like the other two
  # callers of this pattern (agent-pr-merger.sh, agent-triage-failure.sh), then
  # require the literal HTML-comment marker inside the body before treating a hit as
  # "the" existing escalation for this phase.
  local existing raw
  raw="$("$GH" issue list --state open --label release-train \
         --search "${marker} in:body" --json number,body 2>/dev/null || echo '[]')"
  existing="$(jq -r --arg m "$marker" \
              '[.[] | select(.body // "" | contains($m))][0].number // empty' \
              <<<"$raw" 2>/dev/null)"
  if [[ "$existing" =~ ^[0-9]+$ ]]; then
    "$GH" issue comment "$existing" --body "$body" >/dev/null 2>&1 \
      && { ESCALATION_ISSUE="$existing"; warn "escalated — updated existing issue #${existing}"; return 0; }
    warn "could not comment on the existing escalation issue #${existing}"
    ESCALATION_ISSUE="$existing"; return 1
  fi

  "$GH" label create release-train --color B60205 --description "Auto-filed by the weekly release train" >/dev/null 2>&1 || true
  "$GH" label create needs-human   --color D93F0B --description "Needs a human" >/dev/null 2>&1 || true
  local url num
  url="$("$GH" issue create --title "$title" --body "$body" \
         --label release-train --label needs-human 2>/dev/null || echo '')"
  num="${url##*/}"
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    ESCALATION_ISSUE="$num"; warn "escalated — filed issue #${num}"
    return 0
  fi
  warn "gh issue create FAILED — escalation not recorded on GitHub; reason: ${reason}"
  return 1
}

# recheck_gate — re-run a SINGLE gate to confirm it's still failing before escalating.
# Returns 0 if the gate passes (was transient), 1 if it still fails (escalate).
#
# TWO properties this has to hold, both learned the hard way on the 2026-08-01 mobile cut:
#
# 1. RE-RUN IT THE WAY THE PHASE RAN IT. The cuts run the gates through a wrapper that adds
#    environment (`env "${GATE_ENV_EXTRA[@]}" scripts/cut-mobile-release.sh …`); this function
#    used to invoke quality-gates.sh bare. A failure caused by anything the wrapper contributes
#    is therefore UNREACHABLE from here — the recheck is the control condition, so it comes back
#    green by construction and every attempt gets stamped "transient". That is exactly what
#    happened: an exported REQUIRED_GATES poisoned quality-gates.test.sh inside the cut and
#    nowhere else, and the train looped its full 20 attempts, burning a `claude -p` fixer on each
#    one. Replicating GATE_ENV_EXTRA does not make the recheck a perfect replica (a wrapper can
#    still add state we do not model), which is why property 2 exists and is the load-bearing one.
#
# 2. NEVER LET "transient" BE UNBOUNDED. Callers reset their no-progress counters on a green
#    recheck, so an always-green recheck is an infinite loop with no escalation path — the one
#    shape that cannot self-terminate. Forgiveness is now capped per (phase,gate): after
#    RT_MAX_TRANSIENT verdicts the gate is treated as REAL and the caller escalates to a human,
#    however green the re-run looks. A genuine flake clears well inside the cap.
RT_MAX_TRANSIENT="${RT_MAX_TRANSIENT:-2}"
declare -A RT_TRANSIENT_SEEN=()

recheck_gate() { # <phase> <gate>
  local phase="$1" gate="$2"
  local logf="$RT_LOGDIR/recheck-${phase}-${gate}.log"
  local key="${phase}/${gate}"
  local seen="${RT_TRANSIENT_SEEN[$key]:-0}"
  if [[ "$seen" -ge "$RT_MAX_TRANSIENT" ]]; then
    warn "  '${gate}' has already been forgiven as transient ${seen}× — treating it as REAL and escalating"
    return 1
  fi
  info "  rechecking ${gate} gate (single-gate re-run to rule out transience)"
  if ! command -v python >/dev/null 2>&1 && [[ "$gate" == "contract" ]]; then
    # contract gate needs python for dump_openapi; fall through to escalate
    return 1
  fi
  env "${GATE_ENV_EXTRA[@]+"${GATE_ENV_EXTRA[@]}"}" \
    "$ROOT/scripts/quality-gates.sh" --only "$gate" --tier launch >"$logf" 2>&1 || true
  if grep -qE 'RESULT:.*all gates pass|RESULT: 0 gate' "$logf" 2>/dev/null; then
    RT_TRANSIENT_SEEN[$key]=$((seen + 1))
    info "  '${gate}' passed on re-run (transient ${RT_TRANSIENT_SEEN[$key]}/${RT_MAX_TRANSIENT})"
    return 0
  fi
  return 1
}

# ── The fixer (AC-3, AC-11, AC-12) ────────────────────────────────────────────
# Returns 0 when a bounded, allowed, committed+pushed fix landed; 1 otherwise.
# Sets FIX_FAILURE to a human-readable reason when it returns 1.
FIX_FAILURE=""
# rebrief_note <what-went-wrong> <violation-detail> — the block appended to a re-issued
# fixer prompt after its previous attempt was discarded (issue #2387, H1).
#
# The point is to hand back the SPECIFIC violation. The original prompt already lists the
# bounds in the abstract and the model still crossed one; repeating the same abstract list
# would just buy the same answer. Naming the file it touched is what makes the second turn
# different from the first. It also states plainly that making no change is an acceptable
# outcome, so a fixer that genuinely cannot fix this inside the bounds stops rather than
# hunting for a way around them.
rebrief_note() { # <headline> <detail>
  cat <<EOF

⚠️  RETRY — READ THIS FIRST.
This is a re-brief: ${1}. The whole diff was reverted, so the repository is back
to the state you first saw and none of your previous edits survive.

Specifically:
$(printf '      - %s\n' "${2}" | sed 's/^      - $//')

Try again WITHOUT that edit. If the only fix you can see requires it, make NO change at
all and say so — escalating to a human is a correct, expected outcome here, and is much
better than a variation that trips the same guard.
EOF
}

run_fixer() { # <phase> <gate> <cut-logfile> <attempt>
  local phase="$1" gate="$2" cutlog="$3" attempt="$4"
  FIX_FAILURE=""

  # issue #2209: every gate is fixable. The class only selects how the fixer is
  # briefed — it is no longer an escalation boundary.
  local gate_class="product"
  in_list "$gate" "${MECHANICAL_FIX_GATES[@]}" && gate_class="mechanical"

  # Snapshot BEFORE any fix step runs, not just before the model call — the cut that
  # just failed may itself have left tracked churn (e.g. quality-gates.sh's
  # state-set.sh writes) that must never be mistaken for this fixer's own diff.
  local pre_status; pre_status="$(git status --porcelain 2>/dev/null)"

  local owner; owner="$(scripts/route-failure.sh --gate "$gate" 2>/dev/null || echo unknown)"
  info "  routing ${gate} → ${owner}"

  # The contract gate's fix is mechanical and deterministic — regenerate the dump
  # rather than spend a model turn hand-editing 650 KB of generated YAML.
  if [[ "$gate" == "contract" ]] && regenerate_openapi; then
    if [[ -n "$(changed_paths "$pre_status")" ]]; then
      commit_and_push_fix "$gate" "$attempt" "regenerated openapi.yaml" "$pre_status" && return 0
      return 1
    fi
  fi

  command -v claude >/dev/null 2>&1 || { FIX_FAILURE="claude CLI not on PATH — cannot auto-fix"; return 1; }

  local tail_txt; tail_txt="$(gate_log_tail "$gate" "$cutlog" 60)"
  if [[ -z "${tail_txt// }" ]]; then
    FIX_FAILURE="no failing-gate log for '${gate}' — the fixer would run blind"
    return 1
  fi

  local scope_line
  if [[ "$gate_class" == "mechanical" ]]; then
    scope_line="  • Change ONLY what is needed to fix the \`${gate}\` gate. This is expected to be
    recurring debt (mypy/ruff baseline drift, docs/iteration-log drift, a stale
    OpenAPI dump), not a product change."
  else
    scope_line="  • \`${gate}\` is a REAL PRODUCT FAILURE, not drift. Diagnose it before you edit:
    find the assertion or behaviour that actually broke and fix the CODE that broke
    it. Change only what that root cause requires — do not refactor around it.
  • If the test itself encodes stale behaviour, you may correct its assertions, but
    you may NEVER delete a test file, add a skip/only/xfail marker (including a
    module-level \`pytestmark\`, a \`marks=\` on a parametrize case, or a conftest
    \`collect_ignore\`), delete an individual test case out of a file that survives, or
    loosen gate configuration (pytest/vitest/playwright/eslint/mypy/ruff/tsconfig, any
    package.json — \`scripts.test\` is what selects a suite to run — a CI workflow, or
    ANY script under scripts/, that being the harness judging you). The wrapper checks
    the diff for exactly this and discards the whole fix if it finds it.
  • If you cannot find a root-cause fix inside these bounds, make NO change at all
    and say so — an escalation to a human is the correct outcome, a green-washed
    gate is not."
  fi

  # ── Re-brief loop (issue #2387, H1) ──────────────────────────────────────────
  # A fix DISCARDED for a risk-zone touch or a test-integrity violation is recoverable:
  # the model overstepped a bound it was told about but evidently did not apply. Hand the
  # violation back verbatim and let it try again, bounded by REBRIEF_MAX. Everything else
  # (spawn failure, blind fixer, exhausted transients, reproducible empty diff) stays
  # terminal exactly as before.
  local rebrief=0 violation_note=""
  local prompt try rc cls envelope bad weak
  while :; do
  prompt=$(cat <<EOF
You are unblocking the weekly unattended STAGING release cut for this repository.
The \`${gate}\` gate failed during the ${phase} cut. Fix the ROOT CAUSE so the gate
goes green. Do not weaken, skip, or delete tests, and do not edit gate configuration
to make the failure disappear.

Owner skill to use: ${owner} (invoke it via the Skill tool, scoped to this failure).

HARD BOUNDS — this is an unattended job that pushes to main:
${scope_line}
  • You MUST NOT modify any of these risk zones. If the real fix requires one, make
    NO change at all and say so — the run will escalate to a human instead:
$(printf '      - %s\n' "${FORBIDDEN_FIX_PATHS[@]}")
  • Do not commit, tag, or push. The wrapper commits and pushes what you leave in
    the working tree.
${violation_note}
Failing gate output:

${tail_txt}

When done, verify with: scripts/quality-gates.sh --only ${gate} --tier launch
EOF
)

  try=0
  while :; do
    try=$((try + 1))
    envelope="$RT_LOGDIR/fix-${phase}-${gate}-${attempt}-${try}.json"
    info "  spawning claude -p for ${owner} (gate ${gate}, attempt ${attempt}/${MAX_ATTEMPTS}, try ${try})"
    rc=0
    claude -p "$prompt" --permission-mode bypassPermissions --output-format json >"$envelope" 2>"${envelope}.err" || rc=$?
    cls="$(classify_model_result "$envelope")"
    # CLAUDE.md: every `claude` invocation emits a span.
    agent_trace_span "$envelope" release-train-fix \
      round="$attempt" outcome="$cls" result="$cls" \
      template="release-train-fix-v1" prompt="$prompt"

    if [[ "$cls" == "transient" ]]; then
      # A rate/usage limit is not the fix loop's fault — it must NOT consume one of
      # the --max-attempts. Back off and re-issue the same turn.
      if [[ "$try" -ge "$TRANSIENT_RETRIES" ]]; then
        FIX_FAILURE="model call kept returning a transient (rate/usage) limit after ${try} tries"
        return 1
      fi
      warn "  transient model result (rate/usage limit) — retrying in ${TRANSIENT_BACKOFF}s (attempt NOT consumed)"
      sleep "$TRANSIENT_BACKOFF"
      continue
    fi
    if [[ "$cls" != "ok" || "$rc" -ne 0 ]]; then
      FIX_FAILURE="fixer spawn failed (classification=${cls}, exit=${rc}); see ${envelope}"
      return 1
    fi
    break
  done

  revert_package_manager_artifact

  bad="$(forbidden_changes "$pre_status")"
  if [[ -n "$bad" ]]; then
    warn "  fix touched a risk zone — discarding the WHOLE fix:"
    cut -f2 <<<"$bad" | sed 's/^/      /'
    discard_fix_since "$pre_status"
    FIX_FAILURE="fix produced a diff in a protected risk zone: $(cut -f2 <<<"$bad" | tr '\n' ' ')"
    if [[ "$rebrief" -lt "$REBRIEF_MAX" ]]; then
      rebrief=$((rebrief + 1))
      warn "  re-briefing the fixer with the violation (re-brief ${rebrief}/${REBRIEF_MAX}; attempt NOT consumed)"
      violation_note="$(rebrief_note "your previous attempt was DISCARDED because it modified a protected risk zone" \
        "$(cut -f2 <<<"$bad")")"
      continue
    fi
    warn "  re-brief budget exhausted (${REBRIEF_MAX}) — escalating"
    return 1
  fi

  # issue #2209 — the compensating control for an unbounded fixer. A gate turned
  # green by deleting/skipping a test or loosening gate config is worse than the red
  # gate it replaced, because it ships silently.
  weak="$(test_integrity_violations "$pre_status")"
  if [[ -n "$weak" ]]; then
    warn "  fix would weaken the gate instead of fixing it — discarding the WHOLE fix:"
    sed 's/^/      /; s/\t/: /' <<<"$weak"
    discard_fix_since "$pre_status"
    FIX_FAILURE="fix weakened the test surface instead of fixing '${gate}': $(sed 's/\t/ → /' <<<"$weak" | tr '\n' ';' )"
    if [[ "$rebrief" -lt "$REBRIEF_MAX" ]]; then
      rebrief=$((rebrief + 1))
      warn "  re-briefing the fixer with the violation (re-brief ${rebrief}/${REBRIEF_MAX}; attempt NOT consumed)"
      violation_note="$(rebrief_note "your previous attempt was DISCARDED because it weakened the test surface instead of fixing the code" \
        "$(sed 's/\t/ → /' <<<"$weak")")"
      continue
    fi
    warn "  re-brief budget exhausted (${REBRIEF_MAX}) — escalating"
    return 1
  fi

  if [[ -z "$(changed_paths "$pre_status")" ]]; then
    # The fixer produced no code changes. The failure may have been transient
    # (a flaky test, Docker starvation, a race). Re-run the gate BEFORE
    # escalating — an empty-diff escalation with no follow-up is how a weekly
    # train gets stuck on a gate that actually passes.
    warn "  fixer produced an empty diff — re-running the '${gate}' gate to rule out a transient failure"
    if recheck_gate "$phase" "$gate"; then
      ok "  '${gate}' gate is now green — the failure was transient; continuing the cut"
      return 0
    fi
    FIX_FAILURE="fixer produced an EMPTY diff for gate '${gate}' — the failure is reproducible, not transient"
    return 1
  fi

  commit_and_push_fix "$gate" "$attempt" "auto-fix via ${owner}" "$pre_status"
  return $?
  done
}

commit_and_push_fix() { # <gate> <attempt> <note> <pre-snapshot>
  local gate="$1" attempt="$2" note="$3" pre_status="${4-}"
  revert_package_manager_artifact

  local bad; bad="$(forbidden_diff "$pre_status")"
  if [[ -n "$bad" ]]; then
    FIX_FAILURE="refusing to commit — protected paths changed: $(tr '\n' ' ' <<<"$bad")"
    return 1
  fi
  # Re-checked here rather than trusted from run_fixer: preflight's OpenAPI
  # regeneration and the contract fast path both reach this function directly, and
  # "no commit may weaken a gate" has to hold on every path that pushes to main.
  local weak; weak="$(test_integrity_violations "$pre_status")"
  if [[ -n "$weak" ]]; then
    FIX_FAILURE="refusing to commit — the diff weakens the test surface: $(sed 's/\t/ → /' <<<"$weak" | tr '\n' ';')"
    return 1
  fi
  local -a new_paths=()
  while IFS= read -r p; do [[ -n "$p" ]] && new_paths+=("$p"); done < <(changed_paths "$pre_status")
  if [[ "${#new_paths[@]}" -eq 0 ]]; then
    FIX_FAILURE="nothing to commit for gate '${gate}'"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "--dry-run: WOULD commit + push the ${gate} fix"
    return 0
  fi

  # Stage only what changed since <pre-snapshot> — never `git add -A`, which would
  # also sweep up any pre-existing tracked/untracked churn (a gate run's state-shard
  # writes, a stray build artifact) into an unattended push to main. PR #2206 round 0.
  local -a add_paths=()
  while IFS= read -r p; do [[ -n "$p" ]] && add_paths+=("$p"); done < <(add_targets_since "$pre_status")
  git add -- "${add_paths[@]}" || { FIX_FAILURE="git add failed"; return 1; }
  git commit -q -m "$(printf 'fix(release-train): %s gate on the staging cut (attempt %s)\n\n%s\n\nCo-Authored-By: Claude <noreply@anthropic.com>' "$gate" "$attempt" "$note")" \
    || { FIX_FAILURE="git commit failed"; return 1; }

  # main may have moved under us (the merger runs on its own timer). --autostash
  # because <pre-snapshot> churn we deliberately left uncommitted above is still
  # sitting in the working tree — plain `git rebase` refuses to run at all against
  # ANY uncommitted change, not just ones it would touch.
  git fetch --quiet origin main 2>/dev/null || true
  git rebase --quiet --autostash origin/main 2>/dev/null \
    || { git rebase --abort 2>/dev/null; FIX_FAILURE="rebase onto origin/main failed"; return 1; }
  if ! git push --quiet origin HEAD:main 2>&1; then
    FIX_FAILURE="push to origin/main rejected"
    return 1
  fi
  ok "  committed + pushed the ${gate} fix"
}

# ── OpenAPI dump (AC-2) ───────────────────────────────────────────────────────
# The contract gate goes stale between cuts; regenerate BEFORE any gate runs.
regenerate_openapi() {
  [[ -f backend/scripts/dump_openapi.py ]] || { info "no backend/scripts/dump_openapi.py — skipping OpenAPI regen"; return 1; }
  command -v python >/dev/null 2>&1 || { warn "python not on PATH — skipping OpenAPI regen"; return 1; }
  info "regenerating openapi.yaml…"
  if ( cd backend && python scripts/dump_openapi.py ) >"$RT_LOGDIR/openapi-regen.log" 2>&1; then
    ok "openapi.yaml regenerated"
    return 0
  fi
  warn "OpenAPI regen failed — see $RT_LOGDIR/openapi-regen.log"
  return 1
}

# ── Preflight (AC-2) ──────────────────────────────────────────────────────────
preflight() {
  revert_package_manager_artifact

  local branch; branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  [[ "$branch" == "main" ]] || die "releases are cut from 'main' (HEAD is on '${branch}'). Checkout main first."

  if [[ -n "$(git status --porcelain)" ]]; then
    printf '\033[31mrelease-train: working tree is dirty — commit or stash before the cut:\033[0m\n' >&2
    git status --porcelain | sed 's/^/    /' >&2
    die "working tree is dirty"
  fi

  info "fetching origin…"
  git fetch --quiet origin main --tags || die "git fetch origin failed — is the network up?"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    git merge --quiet --ff-only origin/main 2>/dev/null || true
  fi
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || die "local main is behind/diverged from origin/main after pull — resolve by hand before cutting."
  ok "on main @ $(git rev-parse --short HEAD), clean, in sync with origin"

  # Regenerate the dump BEFORE the first gate run so the contract gate is never
  # measured against a stale spec. If it moved, that is a legitimate auto-commit.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "--dry-run: WOULD regenerate openapi.yaml (backend/scripts/dump_openapi.py)"
    return 0
  fi
  # The tree was just asserted clean above, so "" (nothing pre-existing) is the
  # correct pre-snapshot: any diff regenerate_openapi produces is entirely its own.
  if regenerate_openapi && [[ -n "$(changed_paths "")" ]]; then
    info "openapi.yaml drifted since the last cut — committing the regenerated dump"
    commit_and_push_fix "contract" 0 "pre-cut OpenAPI regeneration" "" \
      || die "could not land the regenerated openapi.yaml: ${FIX_FAILURE}"
  fi
}

# ── Web phase (AC-4, AC-5, AC-6, AC-21) ───────────────────────────────────────

# The staging tag currently on origin AND on HEAD, if any. This — not an exit
# code — is what "the web cut succeeded" means.
# Is there a staging tag on ORIGIN pointing at HEAD? This is how the train decides a cut
# succeeded — deliberately tag-based rather than trusting cut-release.sh's exit code, since
# a cut can exit non-zero after the tag is safely pushed.
#
# It could not, however, tell "origin has no such tag" from "I could not reach origin"
# (issue #2387, M1): the fetch was `|| true` and the ls-remote was `2>/dev/null | grep -q .`,
# so a network blip, an auth expiry or a dead remote all read as "no tag" — i.e. as a FAILED
# cut. The train would then re-attempt, and eventually escalate, a cut that had actually
# succeeded. Distinguish the three outcomes:
#   0 → tag confirmed on origin (name on stdout)
#   1 → definitively no such tag on origin
#   2 → origin unreachable; the caller must NOT read this as failure
web_tag_on_origin_at_head() {
  local t ls_rc ls_out
  git fetch --quiet origin --tags 2>/dev/null || true
  t="$(git tag --points-at HEAD 2>/dev/null | grep -E '^staging-v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [[ -n "$t" ]] || return 1
  # Capture output and status separately: `ls-remote … | grep -q .` throws the exit code away,
  # and under `set -o pipefail` grep -q's early exit SIGPIPEs ls-remote as well.
  ls_out="$(git ls-remote --tags --quiet origin "refs/tags/${t}" 2>/dev/null)"; ls_rc=$?
  if [[ "$ls_rc" -ne 0 ]]; then
    warn "  cannot reach origin to confirm tag ${t} (git ls-remote exit ${ls_rc}) — treating as UNKNOWN, not as a failed cut"
    return 2
  fi
  [[ -n "${ls_out//[[:space:]]/}" ]] || return 1
  printf '%s\n' "$t"
}

web_gate_env() {
  # --skip is derived as "every gate minus the required set", so it can never name
  # a required gate (which quality-gates.sh would fail closed on).
  local g skip=()
  for g in "${ALL_GATES[@]}"; do
    in_list "$g" $WEB_REQUIRED_GATES || skip+=("$g")
  done
  printf '%s' "$(IFS=,; echo "${skip[*]}")"
}

run_web_phase() {
  local existing
  if existing="$(web_tag_on_origin_at_head)"; then
    CUT_TAG="$existing"
    WEB_OUTCOME="already-cut"
    ok "web: HEAD already carries ${existing} on origin — nothing to cut"
    return 0
  fi

  local skip; skip="$(web_gate_env)"
  local -a cut_args=(staging --yes)
  if [[ "$WITH_E2E" -eq 0 ]]; then
    cut_args+=(--no-e2e "--skip=${skip}")
  fi

  info "web: required gates = ${WEB_REQUIRED_GATES}"
  [[ "$WITH_E2E" -eq 0 ]] && warn "web: NOT running (skipping): ${skip}  — pass --with-e2e for the full spine"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    ok "--dry-run: WOULD run  REQUIRED_GATES=\"${WEB_REQUIRED_GATES}\" scripts/cut-release.sh ${cut_args[*]}"
    ok "--dry-run: success would be asserted from a staging-v* tag on origin at HEAD (NOT the exit code)"
    WEB_OUTCOME="dry-run"
    return 0
  fi

  local attempt=0 last_sig="" same_sig=0
  while [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; do
    attempt=$((attempt + 1)); WEB_ATTEMPTS="$attempt"
    local cutlog="$RT_LOGDIR/web-cut-${attempt}.log"
    info "web: cut attempt ${attempt}/${MAX_ATTEMPTS}"
    local head_before; head_before="$(git rev-parse HEAD 2>/dev/null)"
    env REQUIRED_GATES="$WEB_REQUIRED_GATES" "${GATE_ENV_EXTRA[@]}" scripts/cut-release.sh "${cut_args[@]}" \
      >"$cutlog" 2>&1 </dev/null
    # NB: the exit code is deliberately ignored — cut-release.sh exits 1 on a
    # SUCCESSFUL staging cut (its last statement is a prod-only test).
    revert_package_manager_artifact
    if head_moved_under_us "$head_before" web; then attempt=$((attempt - 1)); continue; fi

    local tag tag_rc
    tag="$(web_tag_on_origin_at_head)"; tag_rc=$?
    if [[ "$tag_rc" -eq 0 ]]; then
      CUT_TAG="$tag"; WEB_OUTCOME="cut"
      ok "web: ${tag} is on origin and on HEAD — staging deploy triggered"
      return 0
    fi
    # Exit 2 = origin unreachable, NOT "no tag" (issue #2387, M1). Reading a network blip as a
    # failed cut sends the fixer after a gate that already passed and burns an attempt on it.
    # Back off and re-check instead; the tag either appears or a real failure is diagnosed next
    # attempt. Costs one attempt in the worst case, versus a spurious escalation.
    if [[ "$tag_rc" -eq 2 ]]; then
      warn "web: could not reach origin to confirm the cut — retrying in ${TRANSIENT_BACKOFF}s (attempt NOT consumed)"
      sleep "$TRANSIENT_BACKOFF"
      attempt=$((attempt - 1))
      continue
    fi

    local gate; gate="$(parse_failing_gates "$cutlog" | head -1)"
    if [[ -z "$gate" ]]; then
      warn "web: the cut failed without a recognisable gate name"
      tail -n 15 "$cutlog" | sed 's/^/    /'
      escalate web "" "$cutlog" "the cut failed with no parseable gate failure (see the log tail)"
      WEB_OUTCOME="escalated"; return 1
    fi
    warn "web: gate '${gate}' failed"

    # Host capacity, not code — back off and re-run rather than briefing a model that
    # is forbidden from making the only change that would help.
    if gate_failure_is_infra "$gate" "$cutlog"; then
      if infra_backoff web "$gate"; then attempt=$((attempt - 1)); continue; fi
      escalate web "$gate" "$cutlog" \
        "host capacity: '${gate}' exhausted ${RT_INFRA_RETRIES} concurrency backoff(s). This is a Docker/CPU starvation failure, not a code defect — no diff can fix it, so no model was spawned."
      WEB_OUTCOME="escalated"; return 1
    fi

    local sig; sig="$(failure_signature "$gate" "$cutlog")"
    if [[ "$sig" == "$last_sig" ]]; then
      same_sig=$((same_sig + 1))
    else
      same_sig=1; last_sig="$sig"
    fi
    if [[ "$same_sig" -ge "$NO_PROGRESS_LIMIT" ]]; then
      # Before escalating on no-progress: re-run the gate once. A transient failure
      # (flake, Docker starvation) can produce the same signature 3 times yet the
      # underlying code is correct — escalating here blocks the release for nothing.
      if recheck_gate web "$gate"; then
        ok "  '${gate}' gate is now green — the failure was transient; resetting no-progress counter"
        same_sig=0; continue
      fi
      escalate web "$gate" "$cutlog" "no progress: '${gate}' failed with an identical signature ${same_sig} attempts in a row (re-check confirmed)"
      WEB_OUTCOME="escalated"; return 1
    fi

    if ! run_fixer web "$gate" "$cutlog" "$attempt"; then
      escalate web "$gate" "$cutlog" "$FIX_FAILURE"
      WEB_OUTCOME="escalated"; return 1
    fi
  done

  escalate web "${gate:-}" "$RT_LOGDIR/web-cut-${attempt}.log" \
    "attempt cap reached (${MAX_ATTEMPTS}) without a staging tag on origin"
  WEB_OUTCOME="exhausted"; return 1
}

# ── Mobile phase (AC-7, AC-8, AC-9, AC-10) ────────────────────────────────────

# True when adb reports at least one device in the `device` (not `offline`) state.
android_device_ready() {
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit f?0:1}'
}

# Boot a headless AVD and wait for it, so an unattended run heals the single most
# common mobile preflight failure instead of escalating it.
#
# "No booted emulator" is NOT a missing dependency the way an absent ASC key is — the
# SDK, the AVD, and KVM are all installed; the machine simply has nobody logged in to
# type `emulator -avd … &`. A weekly timer that reports it as a missing item fails
# identically every week and can never make progress. Everything this needs is already
# on the host, so the train boots it itself and only reports a missing item when the
# boot is genuinely impossible (no emulator binary, no AVD, no KVM).
boot_android_emulator() {
  android_device_ready && return 0
  [[ "$RT_EMULATOR_BOOT" == "1" ]] || return 1
  command -v emulator >/dev/null 2>&1 || return 1

  local avd="$RT_EMULATOR_AVD"
  [[ -n "$avd" ]] || avd="$(emulator -list-avds 2>/dev/null | grep -v '^$' | head -1)"
  [[ -n "$avd" ]] || return 1

  info "mobile: no booted device — cold-booting AVD '${avd}' headless…"
  # -no-snapshot-save keeps the AVD reproducible run to run; a half-written snapshot
  # from a SIGKILLed weekly run is its own class of Monday-morning mystery.
  #
  # `9>&-` is load-bearing, not hygiene. Fd 9 is the flock the run holds for its whole
  # lifetime (AC-17), and a forked child inherits it — so an emulator that outlives the
  # run (the kill below racing, a detached qemu, an operator's own emulator) would keep
  # the lock file open and make EVERY subsequent weekly run exit "another run is already
  # in flight — no-op". That is a scheduler that silently stops cutting releases and
  # reports success, which is strictly worse than the failure this function fixes.
  nohup emulator -avd "$avd" -no-window -no-audio -no-boot-anim \
      -no-snapshot-save -gpu swiftshader_indirect \
      >"$RT_LOGDIR/emulator.log" 2>&1 </dev/null 9>&- &
  EMULATOR_PID=$!

  # sys.boot_completed, not `adb devices` — the device shows up in the device list
  # long before Android is up enough for Maestro to drive it.
  local waited=0
  while [[ "$waited" -lt "$RT_EMULATOR_BOOT_TIMEOUT" ]]; do
    kill -0 "$EMULATOR_PID" 2>/dev/null || { warn "mobile: the emulator process died during boot — see $RT_LOGDIR/emulator.log"; return 1; }
    if [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
      ok "mobile: AVD '${avd}' booted in ${waited}s (pid ${EMULATOR_PID})"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  warn "mobile: AVD '${avd}' did not finish booting within ${RT_EMULATOR_BOOT_TIMEOUT}s"
  return 1
}

# AC-9 — every precondition checked BEFORE the loop, each named specifically.
# Sets MOBILE_PREFLIGHT_MISSING so an unattended failure can be escalated with the
# specific items in the issue body, not just printed to a terminal nobody is at.
mobile_preflight() {
  local missing=()
  MOBILE_PREFLIGHT_MISSING=""

  command -v maestro >/dev/null 2>&1 || missing+=("maestro CLI (curl -Ls https://get.maestro.mobile.dev | bash)")
  if command -v adb >/dev/null 2>&1; then
    boot_android_emulator || android_device_ready \
      || missing+=("a booted Android device/emulator (adb devices shows none, and the train could not boot one: no 'emulator' binary on PATH under \$ANDROID_HOME, no AVD from 'emulator -list-avds', or the boot timed out — see $RT_LOGDIR/emulator.log)")
  else
    missing+=("adb (Android platform-tools not on PATH)")
  fi
  if command -v eas >/dev/null 2>&1; then
    # Under the timer there is no interactive session, so `eas` cannot ride on a cached
    # login the way it does in a shell. EXPO_TOKEN is the only credential that survives
    # into a systemd unit — check it BEFORE the loop rather than after a 20-minute build.
    if [[ -z "${EXPO_TOKEN:-}" ]] && ! eas whoami >/dev/null 2>&1; then
      missing+=("Expo authentication: EXPO_TOKEN is unset and 'eas whoami' fails (an unattended run cannot use interactive login state — see docs/05-secrets-setup.md)")
    fi
  else
    missing+=("eas CLI (npm i -g eas-cli)")
  fi

  # eas.json ascAppId + submit credentials, per profile/platform.
  if [[ -f mobile/scripts/check-submit-config.sh ]]; then
    bash mobile/scripts/check-submit-config.sh preview ios >"$RT_LOGDIR/check-submit-config.log" 2>&1 \
      || missing+=("complete iOS submit config (mobile/scripts/check-submit-config.sh preview ios failed — see $RT_LOGDIR/check-submit-config.log)")
  else
    missing+=("mobile/scripts/check-submit-config.sh")
  fi

  # systemd does not source ~/.bashrc, so these are the vars most likely to be
  # missing under the timer — name each one individually.
  local v
  for v in "${IOS_ENV_VARS[@]}"; do
    [[ -n "${!v:-}" ]] || missing+=("environment variable ${v} (see the unit's EnvironmentFile=)")
  done
  if [[ -n "${EXPO_ASC_API_KEY_PATH:-}" && ! -f "${EXPO_ASC_API_KEY_PATH}" ]]; then
    missing+=("the ASC .p8 key file at EXPO_ASC_API_KEY_PATH=${EXPO_ASC_API_KEY_PATH} (file not found)")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf '\033[31mrelease-train: mobile preflight FAILED — %d missing item(s):\033[0m\n' "${#missing[@]}" >&2
    printf '    ✗ %s\n' "${missing[@]}" >&2
    MOBILE_PREFLIGHT_MISSING="$(printf '%s; ' "${missing[@]}")"
    MOBILE_PREFLIGHT_MISSING="${MOBILE_PREFLIGHT_MISSING%; }"
    return 1
  fi
  ok "mobile preflight: maestro, adb + booted device, eas, submit config, and all ${#IOS_ENV_VARS[@]} iOS env vars present"
}

# AC-10 — assert the submit actually landed, not just that the process exited 0.
mobile_submit_succeeded() { # <logfile>
  local f="$1"
  grep -qE 'eas (build|submit) failed' "$f" 2>/dev/null && return 1
  # cut-mobile-release.sh only prints this AFTER `eas submit` returns 0.
  grep -qE 'shipped .* via build to the' "$f" 2>/dev/null || return 1
  # AC-8 — an OTA update is NOT a store binary; treat it as a failed cut.
  if [[ -f mobile/.last-shipped ]]; then
    grep -qE '"mechanism"[[:space:]]*:[[:space:]]*"build"' mobile/.last-shipped || return 1
  fi
  return 0
}

run_mobile_phase() {
  local tag; tag="$(web_tag_on_origin_at_head)"
  if [[ -z "$tag" ]]; then
    if [[ "$DRY_RUN" -eq 1 && "$DO_WEB" -eq 1 ]]; then
      # AC-1: a plain `--dry-run` runs both phases and never actually cuts, so HEAD
      # genuinely carries no tag yet — that is expected here, not a blocking failure.
      # In a real (non-dry) run the web phase above would have cut one first.
      info "mobile: no staging-v* tag on HEAD yet — the web phase above would cut one first in a real run"
    else
      printf '\033[31mrelease-train: mobile phase blocked — HEAD carries no staging-v* tag that exists on origin.\033[0m\n' >&2
      printf '    The mobile cut ships the exact commit the web cut tagged; run the web phase first\n' >&2
      printf '    (scripts/release-train.sh --web-only), or drop --mobile-only.\n' >&2
      MOBILE_OUTCOME="blocked"
      return 1
    fi
  else
    info "mobile: web tag ${tag} is on origin and on HEAD"
  fi

  # A preflight failure used to be the ONE mobile failure path that returned without
  # escalating. Under the weekly timer that is the worst possible shape: the run stops
  # before the fix loop, files nothing, and prints the reason to a journal nobody reads
  # — so the same host gap silently blocks every cut until someone notices by hand.
  # The remaining items (ASC keys, EXPO_TOKEN, submit config) are deliberately NOT
  # auto-fixable — store credentials must never be invented by a model — so escalation
  # to a human IS the correct terminal state. It just has to be a LOUD one.
  if ! mobile_preflight; then
    MOBILE_OUTCOME="preflight-failed"
    escalate mobile "" "$RT_LOGDIR/check-submit-config.log" \
      "mobile preflight failed — the host is missing: ${MOBILE_PREFLIGHT_MISSING:-unknown}"
    return 1
  fi

  local -a cut_args=(staging --store --platform=ios --yes)

  if [[ "$DRY_RUN" -eq 1 ]]; then
    ok "--dry-run: WOULD run  scripts/cut-mobile-release.sh ${cut_args[*]}"
    ok "--dry-run: success would be asserted from the eas submit result (TestFlight), NOT the exit code"
    MOBILE_OUTCOME="dry-run"
    return 0
  fi

  local attempt=0 last_sig="" same_sig=0
  while [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; do
    attempt=$((attempt + 1)); MOBILE_ATTEMPTS="$attempt"
    local cutlog="$RT_LOGDIR/mobile-cut-${attempt}.log"
    info "mobile: cut attempt ${attempt}/${MAX_ATTEMPTS}"
    local head_before; head_before="$(git rev-parse HEAD 2>/dev/null)"
    env "${GATE_ENV_EXTRA[@]}" scripts/cut-mobile-release.sh "${cut_args[@]}" >"$cutlog" 2>&1 </dev/null
    revert_package_manager_artifact
    # Only re-run when nothing shipped. A submit that already reached TestFlight must
    # never be repeated just because a merge landed while it was uploading.
    if ! mobile_submit_succeeded "$cutlog" && head_moved_under_us "$head_before" mobile; then
      attempt=$((attempt - 1)); continue
    fi

    if mobile_submit_succeeded "$cutlog"; then
      MOBILE_OUTCOME="submitted"
      ok "mobile: ${tag} built and submitted — build accepted for TestFlight"
      return 0
    fi

    if grep -qE 'eas update --branch' "$cutlog" 2>/dev/null; then
      escalate mobile "" "$cutlog" "the cut routed to an OTA update instead of a store binary despite --store"
      MOBILE_OUTCOME="escalated"; return 1
    fi

    local gate; gate="$(parse_failing_gates "$cutlog" | head -1)"
    if [[ -z "$gate" ]]; then
      warn "mobile: the cut failed without a recognisable gate name"
      tail -n 15 "$cutlog" | sed 's/^/    /'
      escalate mobile "" "$cutlog" "the mobile cut failed with no parseable gate failure (see the log tail)"
      MOBILE_OUTCOME="escalated"; return 1
    fi
    warn "mobile: gate '${gate}' failed"

    if gate_failure_is_infra "$gate" "$cutlog"; then
      if infra_backoff mobile "$gate"; then attempt=$((attempt - 1)); continue; fi
      escalate mobile "$gate" "$cutlog" \
        "host capacity: '${gate}' exhausted ${RT_INFRA_RETRIES} concurrency backoff(s). This is a Docker/CPU starvation failure, not a code defect — no diff can fix it, so no model was spawned."
      MOBILE_OUTCOME="escalated"; return 1
    fi

    local sig; sig="$(failure_signature "$gate" "$cutlog")"
    if [[ "$sig" == "$last_sig" ]]; then same_sig=$((same_sig + 1)); else same_sig=1; last_sig="$sig"; fi
    if [[ "$same_sig" -ge "$NO_PROGRESS_LIMIT" ]]; then
      if recheck_gate mobile "$gate"; then
        ok "  '${gate}' gate is now green — the failure was transient; resetting no-progress counter"
        same_sig=0; continue
      fi
      escalate mobile "$gate" "$cutlog" "no progress: '${gate}' failed with an identical signature ${same_sig} attempts in a row (re-check confirmed)"
      MOBILE_OUTCOME="escalated"; return 1
    fi

    if ! run_fixer mobile "$gate" "$cutlog" "$attempt"; then
      escalate mobile "$gate" "$cutlog" "$FIX_FAILURE"
      MOBILE_OUTCOME="escalated"; return 1
    fi
    # A fix pushed a new commit to main, so the web tag no longer points at HEAD.
    if ! tag="$(web_tag_on_origin_at_head)"; then
      if [[ "$DO_WEB" -eq 0 ]]; then
        # AC-7: --mobile-only must never cut (and deploy) an unrequested web release to
        # re-pair the tag. Stop and tell the operator instead of cutting behind their back.
        printf '\033[31mrelease-train: mobile auto-fix pushed a commit that moved HEAD off the staging tag, but --mobile-only forbids cutting a new web release to re-pair it.\033[0m\n' >&2
        printf '    Re-run without --mobile-only (or run --web-only, then --mobile-only) to re-cut the shared tag.\n' >&2
        MOBILE_OUTCOME="blocked"
        return 1
      fi
      # The shared-tag invariant is not negotiable when the web phase was requested —
      # re-cut it before submitting the mobile build against a commit it never tagged.
      info "mobile: the fix advanced main past ${CUT_TAG:-the tag} — re-cutting the web tag first"
      if ! run_web_phase; then MOBILE_OUTCOME="blocked"; return 1; fi
      tag="$CUT_TAG"
    fi
  done

  escalate mobile "${gate:-}" "$RT_LOGDIR/mobile-cut-${attempt}.log" \
    "attempt cap reached (${MAX_ATTEMPTS}) without an accepted TestFlight submission"
  MOBILE_OUTCOME="exhausted"; return 1
}

# ── Run summary → state (AC-14) ───────────────────────────────────────────────
# Written exclusively through sget/sset; this script never opens a state JSON file.
# <outcome> covers runs that never reach a phase at all (preflight died, or a
# concurrent run was already in flight) as well as a normal completion, so a week
# where the train never got past preflight still leaves a trace in state.
record_run() { # <exit-code> <outcome:completed|aborted-preflight|lock-busy> [reason]
  local rc="$1" outcome="${2:-completed}" reason="${3:-}"
  local summary
  summary="$(jq -n -c \
    --arg run_id "$RUN_ID" \
    --arg started "$STARTED_AT" \
    --arg ended "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg outcome "$outcome" \
    --arg reason "$reason" \
    --arg web "$WEB_OUTCOME" \
    --arg mobile "$MOBILE_OUTCOME" \
    --arg tag "$CUT_TAG" \
    --arg logdir "$RT_LOGDIR" \
    --argjson web_attempts "$WEB_ATTEMPTS" \
    --argjson mobile_attempts "$MOBILE_ATTEMPTS" \
    --argjson max_attempts "$MAX_ATTEMPTS" \
    --argjson dry_run "$([[ "$DRY_RUN" -eq 1 ]] && echo true || echo false)" \
    --argjson exit_code "$rc" \
    --arg escalation "$ESCALATION_ISSUE" \
    '{run_id:$run_id, started_at:$started, ended_at:$ended, outcome:$outcome,
      reason:(if $reason == "" then null else $reason end),
      web:{outcome:$web, attempts:$web_attempts},
      mobile:{outcome:$mobile, attempts:$mobile_attempts},
      tag:(if $tag == "" then null else $tag end),
      max_attempts:$max_attempts, dry_run:$dry_run, exit_code:$exit_code,
      escalation_issue:(if $escalation == "" then null else ($escalation|tonumber) end),
      log_dir:$logdir, generated_by:"scripts/release-train.sh"}' 2>/dev/null)"
  [[ -n "$summary" ]] || return 0

  sset '.release_train.last_run' "$summary" >/dev/null 2>&1 || warn "could not record the run summary in state"
  # Bounded history — the last 20 runs, appended (never a full-file rewrite).
  local hist
  hist="$(sget '.release_train.runs' 2>/dev/null)"
  [[ "$hist" =~ ^\[ ]] || hist='[]'
  hist="$(jq -c --argjson s "$summary" '(. + [$s]) | .[-20:]' <<<"$hist" 2>/dev/null)"
  [[ -n "$hist" ]] && { sset '.release_train.runs' "$hist" >/dev/null 2>&1 || true; }
}

# ── Main ──────────────────────────────────────────────────────────────────────

# --check-env is read-only: no lock, no git mutation, no model, no cut. It exists so a
# `systemctl --user start` can prove the unit's EnvironmentFile resolves (AC-16) without
# the side effect of actually cutting a staging release.
if [[ "$CHECK_ENV" -eq 1 ]]; then
  echo "═══ release-train --check-env ═══  (mobile preflight only — nothing is cut)"
  printf '  PATH=%s\n' "$PATH"
  for t in git jq gh claude node npm eas maestro adb python; do
    printf '  %-8s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo '— NOT FOUND')"
  done
  mobile_preflight || exit 1
  exit 0
fi

# AC-17 — a second start while a run is in flight is a NO-OP, never a parallel cut.
# The fd is held open for the process lifetime, so a SIGKILLed run cannot wedge it.
LOCK="${RT_LOCK:-/tmp/release-train-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1).lock}"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "release-train: another run is already in flight ($LOCK) — no-op."
  record_run 0 "lock-busy" "another release-train run already held ${LOCK}" 2>/dev/null || true
  exit 0
fi

echo "═══ release-train ═══  run=${RUN_ID}  web=${DO_WEB} mobile=${DO_MOBILE} max_attempts=${MAX_ATTEMPTS} dry_run=${DRY_RUN}"
echo "  logs: $RT_LOGDIR"
echo "  auto-fix: ALL gates (mechanical: ${MECHANICAL_FIX_GATES[*]}; everything else gets the product-failure brief)"
echo "  fix guards: risk zones + test integrity (no deleted/skipped tests, no gate-config edits)"

preflight

EXIT=0
if [[ "$DO_WEB" -eq 1 ]]; then
  run_web_phase || EXIT=1
fi
if [[ "$DO_MOBILE" -eq 1 && "$EXIT" -eq 0 ]]; then
  run_mobile_phase || EXIT=1
elif [[ "$DO_MOBILE" -eq 1 ]]; then
  warn "mobile phase skipped — the web phase did not produce a tag"
  MOBILE_OUTCOME="skipped-web-failed"
fi

record_run "$EXIT" "completed"

echo
echo "═══ release-train summary ═══"
printf '  web:    %s (%s attempt(s))\n' "$WEB_OUTCOME" "$WEB_ATTEMPTS"
printf '  mobile: %s (%s attempt(s))\n' "$MOBILE_OUTCOME" "$MOBILE_ATTEMPTS"
[[ -n "$CUT_TAG" ]] && printf '  tag:    %s\n' "$CUT_TAG"
[[ -n "$ESCALATION_ISSUE" ]] && printf '  escalation: #%s\n' "$ESCALATION_ISSUE"
printf '  logs:   %s\n' "$RT_LOGDIR"
exit "$EXIT"
