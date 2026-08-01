#!/usr/bin/env bash
# agent-triage-failure.sh — turn a RED quality-gate into the right next action so the
# unattended loop SELF-HEALS instead of dead-ending on `needs-human`.
#
# The agent-inbox used to do exactly one thing when the gates failed: comment the log +
# label `needs-human`. That fails OPEN — it can't tell whose fault the failure is, and it
# never turns a blocker into work, so the SAME infra/test breakage recurs on every issue
# (the #89 shared-volume alembic brick; the #90 pre-existing e2e specs the agent never
# touched). This script classifies the failure and routes it:
#
#   transient  — rate-limit / docker daemon down / OOM / network  → RETRY next tick (file
#                nothing, drop `wip`); the limit clears on its own.
#   deps       — an incomplete node_modules in the build worktree: a BARE package specifier is
#                unresolvable, it took out ≥TRIAGE_DEPS_MIN_FILES whole test files at load time,
#                AND the agent neither touched a manifest/lockfile nor authored the importing
#                file (else the undeclared import is its own bug → `self`, which is fixable).
#                → same route as transient (retry on a fresh install), but fingerprinted by the
#                missing PACKAGE so retries are counted per cause (#2124).
#   self       — the failing area INTERSECTS the agent's own changed files            → `needs-human`
#   infra      — alembic "Can't locate revision", "exited (255)", "dependency failed to
#                start", seed/migration/volume → AUTO-FILE a deduped `agent`+`harness`
#                blocker issue, mark the current issue `blocked` → loop continues.
#   unrelated  — a gate failed in files the agent did NOT touch (a pre-existing breakage
#                the now-running gate exposed) → AUTO-FILE a deduped `agent`+`flaky` issue
#                for THAT failure, mark the current issue `blocked` → loop continues.
#   stale-base — same shape as `unrelated`, but the build branch is BEHIND $BASE, so "pre-existing
#                on $BASE" is not a claim this tree can support: the failure is more likely already
#                FIXED on $BASE. → RETRY (file nothing); the inbox rebases before the next build.
#
# GUARDRAILS against an issue storm (the thing you must get right with any self-filing loop):
#   • stable FINGERPRINT per failure (tmp paths / line numbers / hex / timestamps stripped),
#     checked against OPEN issues — a dup just bumps a counter + comments, never re-files.
#   • OUTCOME LEDGER with a per-fingerprint attempt counter; after TRIAGE_MAX_ATTEMPTS
#     auto-file→still-red cycles, STOP self-filing and escalate a real `needs-human`.
#   • GLOBAL CAP (TRIAGE_MAX_OPEN) on open auto-filed blocker issues; beyond it, escalate.
#
# Injectable + hermetically testable (scripts/agent-triage-failure.test.sh): gh + git are
# overridable and every MUTATING gh call goes through `do_gh`, which `--dry-run` turns into a
# printed `WOULD:` line (zero GitHub side-effects) — so it can be dry-run against real issues.
#
#   Usage:
#     scripts/agent-triage-failure.sh --issue N --branch BR --base main \
#        --root /path/to/repo --log gates-N.log [--changed file] [--dry-run]
#
#   Prints a DECISION line and performs (or, with --dry-run, narrates) the routing.
#   Exit 0 always — this is an advisory router, never the thing that fails the run.
set -uo pipefail

# ── Injectable dependencies (defaults = production; tests/dry-run override) ───────
GH="${TRIAGE_GH:-gh}"
LABEL="${TRIAGE_LABEL:-agent}"            # inbox label new blocker issues get
HARNESS_LABEL="${TRIAGE_HARNESS_LABEL:-harness}"
FLAKY_LABEL="${TRIAGE_FLAKY_LABEL:-flaky}"
BLOCKED_LABEL="${TRIAGE_BLOCKED_LABEL:-blocked}"
MAX_ATTEMPTS="${TRIAGE_MAX_ATTEMPTS:-3}"  # per-fingerprint auto-file→still-red cycles before escalate
MAX_OPEN="${TRIAGE_MAX_OPEN:-5}"          # cap on open auto-filed blocker issues at once
MAX_SELF_REPAIR="${TRIAGE_MAX_SELF_REPAIR:-2}"   # `self` re-build attempts (with the gate log fed back) before needs-human
MAX_TRANSIENT="${TRIAGE_MAX_TRANSIENT:-8}"       # transient retries per fingerprint before escalating (a "transient" that never clears isn't transient)
# Marker the triage leaves on a self-repair comment; the inbox reads the latest one and feeds
# its gate log back into the next build. MUST match the string agent-inbox.sh greps for.
SELF_REPAIR_MARKER="${TRIAGE_SELF_REPAIR_MARKER:-<!-- self-repair -->}"

ISSUE="" BRANCH="" BASE="main" ROOT="" WORKTREE="" LOG="" CHANGED_FILE="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)   ISSUE="$2"; shift 2;;
    --branch)  BRANCH="$2"; shift 2;;
    --base)    BASE="$2"; shift 2;;
    --root)    ROOT="$2"; shift 2;;
    --worktree)WORKTREE="$2"; shift 2;;
    --log)     LOG="$2"; shift 2;;
    --changed) CHANGED_FILE="$2"; shift 2;;     # newline-delimited file list (else computed)
    --dry-run) DRY_RUN=1; shift;;
    *) echo "[triage] unknown arg: $1" >&2; exit 2;;
  esac
done
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -n "$ISSUE" ] || { echo "[triage] --issue required" >&2; exit 2; }
[ -n "$LOG" ] && [ -f "$LOG" ] || { echo "[triage] --log <existing file> required" >&2; exit 2; }

log() { printf '[triage] %s\n' "$*"; }

# Per-repo state dir (ledger) — namespaced by repo so unrelated repos never share a counter.
ns() { git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null | { read -r d; cd "$ROOT" 2>/dev/null && cd "$d" 2>/dev/null && pwd; } | sha1sum | cut -c1-12; }
NS="$(ns 2>/dev/null || true)"; [ -n "$NS" ] || NS="nogit"
STATE_DIR="${TRIAGE_STATE_DIR:-/tmp/agent-triage-$NS}"
LEDGER="${TRIAGE_LEDGER:-$STATE_DIR/ledger.jsonl}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Every MUTATING gh call funnels through here so --dry-run is provably side-effect-free.
do_gh() {
  if [ "$DRY_RUN" = 1 ]; then printf 'WOULD: gh %s\n' "$*"; return 0; fi
  "$GH" "$@" >/dev/null 2>&1 || log "WARN: gh $* failed"
}
# Label via REST (gh's --add-label hits the deprecated projectCards GraphQL field and
# flakily drops the label — docs/35). Read-only gh (list/view) runs even under --dry-run.
add_label()    { do_gh api -X POST "repos/{owner}/{repo}/issues/$1/labels" -f "labels[]=$2"; }
remove_label() { do_gh api -X DELETE "repos/{owner}/{repo}/issues/$1/labels/$2"; }
# `gh issue create --label X` VALIDATES X and fails outright if the label doesn't exist yet
# (harness/flaky are new). Pre-create them idempotently so the first auto-file never no-ops.
ensure_label() { do_gh label create "$1" --force; }

# ── Collect the full failure text: the captured gate log PLUS any sub-logs it points
# at (quality-gates prints "see /tmp/qg-XXX/e2e.log" — the real Playwright/compose detail
# lives THERE, not in the summary). Following the reference is what lets us fingerprint the
# specific failing spec or the alembic error rather than the generic "1 gate failed". ─
collect_text() {
  cat "$LOG" 2>/dev/null
  # de-dup referenced paths, read those that still exist on disk
  grep -oE 'see /[A-Za-z0-9._/-]+\.log' "$LOG" 2>/dev/null | awk '{print $2}' | sort -u | while read -r p; do
    [ -f "$p" ] && { echo "── referenced: $p ──"; cat "$p" 2>/dev/null; }
  done
}
TEXT="$(collect_text)"

# ── The failing gate name (from the quality-gates summary: "✗ e2e …" / "e2e   fail …") ─
failing_gate() {
  printf '%s\n' "$TEXT" \
    | grep -E '(^|[[:space:]])(✗|✘)[[:space:]]+[a-z]|[[:space:]]fail[[:space:]]' \
    | grep -oE '\b(typecheck|lint|seed-integrity|unit|repro-tests|mutation|integration|contract|e2e|wedge-coverage|journey-coverage|a11y|lighthouse|visual)\b' \
    | head -1
}
GATE="$(failing_gate)"; [ -n "$GATE" ] || GATE="gate"

# ── Failing AREA: the files that actually FAILED (basenames, so a worktree tmp path matches
# a repo-relative changed path). This drives the self-vs-unrelated split, so it must pick out
# only failures — NOT every test that ran. Playwright's `--reporter=line` prints a line per
# test, so a naive scan grabs all specs; we key on failure-only markers instead:
#   • numbered failure detail headers   "  1) [chromium] › foo.spec.ts:20:7 › …"
#   • stack frames                       "  at …/foo.spec.ts:70:73"
#   • pytest                             "FAILED tests/…py::…"  and  "…py:NN: …Error"
# Only if NONE of those match do we fall back to a broad token scan (best-effort). ─
#
# `no_console` strips test-runner CONSOLE CAPTURE lines. vitest emits them as
# "stdout | src/x.test.tsx > Suite > title" for tests that may well have PASSED, so any
# matcher keyed on the word "fail" hits titles like "query failure attacks" /
# "…when getSlidesSettings fails". Every failure-detecting matcher below reads through this.
no_console() { printf '%s\n' "$TEXT" | grep -vE '^[[:space:]]*(stdout|stderr)[[:space:]]*\|'; }

#
# `no_vendor` drops frames pointing INTO the toolchain rather than into this repo. The loose
# pytest matcher below accepts any `foo.py:NN:` on a line containing "error"/"assert", and a
# pydantic deprecation warning
#   …/site-packages/pydantic/_internal/_config.py:323: PydanticDeprecatedSince20 … see
#   https://errors.pydantic.dev/2.11/migration/
# satisfies both ("errors.pydantic.dev" supplies the "error"). Being a PRIMARY hit it then
# suppressed the fallback entirely, so for #2124 the "failing area" of a 138-file vitest brick
# was one warning from site-packages — the long-standing phantom `_config.py` attribution.
no_vendor() { grep -vE '(^|/)(site-packages|dist-packages|node_modules)/'; }

failing_areas() {
  local hits
  hits="$( {
    printf '%s\n' "$TEXT" | grep -oE '^[[:space:]]*[0-9]+\)[[:space:]].*\.(spec|test)\.tsx?'
    printf '%s\n' "$TEXT" | grep -oE '\bat[[:space:]]+[A-Za-z0-9_./-]+\.(spec|test)\.tsx?:[0-9]+'
    printf '%s\n' "$TEXT" | grep -oE 'FAILED[[:space:]]+[A-Za-z0-9_./-]+\.py'
    printf '%s\n' "$TEXT" | grep -E '[A-Za-z0-9_./-]+\.py:[0-9]+:' | grep -iE 'error|assert' | no_vendor | grep -oE '[A-Za-z0-9_./-]+\.py:[0-9]+'
    # vitest's own suite-level verdict — " FAIL  src/x.test.tsx [ src/x.test.tsx ]" — is as
    # structured as a Playwright failure header and must not be left to the fallback.
    no_console | grep -oE '^[[:space:]]*(FAIL|✗|×)[[:space:]]+[A-Za-z0-9_./-]+\.(spec|test)\.tsx?'
  } | grep -oE '[A-Za-z0-9_./-]+\.(spec\.tsx?|test\.tsx?|py)' | sed -E 's#^.*/##' | sort -u \
      | grep -vE '^(env|conftest|fixtures|setup)\.' )"
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; return; fi
  # fallback: no structured failure markers — scan only lines carrying a failure indicator.
  # `stdout |`/`stderr |` lines are excluded: vitest prefixes CAPTURED CONSOLE OUTPUT with the
  # emitting test's own name, so a test merely TITLED "…query failure attacks" (which passed)
  # otherwise lands in the failing set and can be fingerprinted as the culprit (#2124).
  no_console | grep -E '(Error|FAIL|failed|Timed out|AssertionError|✗|×)' | grep -oE '[A-Za-z0-9_./-]+\.(spec\.ts|test\.tsx?|py)' \
    | sed -E 's#^.*/##' | sort -u | grep -vE '^(env|conftest|fixtures|setup)\.' || true
}

# ── The agent's own changed files (basenames) ─────────────────────────────────────
changed_basenames() {
  if [ -n "$CHANGED_FILE" ] && [ -f "$CHANGED_FILE" ]; then
    sed -E 's#^.*/##' "$CHANGED_FILE" | sort -u
  elif [ -n "$BRANCH" ]; then
    git -C "$ROOT" diff --name-only "${BASE}...${BRANCH}" 2>/dev/null | sed -E 's#^.*/##' | sort -u
  fi
}

# ── Base freshness: is the build's tree even current? ─────────────────────────────
# `unrelated` means "this failure is pre-existing on $BASE" — a claim about $BASE, inferred
# purely from the fact that the diff does not touch the failing files. That inference is only
# sound if the build actually ran against $BASE. When the branch is BEHIND $BASE, a failure in
# untouched files is far more likely to be something already FIXED on $BASE that this tree
# simply predates, and filing a blocker for it is unfalsifiable busywork: closing the blocker
# re-queues the parent onto the same stale tree, the same cluster re-fails, and a different
# test name in it fingerprints as a brand-new bug (#2212 → #2217 → …). Fixing $BASE cannot
# break that loop, because the build never sees $BASE.
#
# Fails CLOSED (returns "current") when the answer is unknowable — no branch, no git, a base
# ref that will not resolve. An unverifiable freshness check must not suppress real filings.
branch_behind_base() { # → prints the commit count when the branch is behind $BASE, else empty
  [ -n "$BRANCH" ] || return 0
  local base_ref
  for base_ref in "origin/${BASE}" "$BASE"; do
    git -C "$ROOT" rev-parse --verify -q "$base_ref" >/dev/null 2>&1 || continue
    git -C "$ROOT" rev-parse --verify -q "$BRANCH" >/dev/null 2>&1 || return 0
    git -C "$ROOT" merge-base --is-ancestor "$base_ref" "$BRANCH" >/dev/null 2>&1 && return 0
    git -C "$ROOT" rev-list --count "${BRANCH}..${base_ref}" 2>/dev/null | grep -E '^[1-9][0-9]*$'
    return 0
  done
}

# ── Classification ───────────────────────────────────────────────────────────────
is_transient() {
  printf '%s\n' "$TEXT" | grep -qiE \
    'session limit|usage limit|rate.?limit|overloaded|too many requests|quota|api_error_status.*(429|503|529)|cannot connect to the docker daemon|is the docker daemon running|docker daemon unreachable|no space left on device|temporary failure in name resolution|could not resolve|network is unreachable|i/o timeout|tls handshake timeout|connection reset by peer|oomkilled|error pulling image|manifest unknown|toomanyrequests'
}
is_infra() {
  # STRONG failure phrases only — never bare "alembic"/"migration"/"seed", since a SUCCESSFUL
  # stack boot logs "alembic.runtime.migration … Running upgrade" and would false-positive
  # every e2e run. We only want signals that the stack/DB itself failed to come up.
  printf '%s\n' "$TEXT" | grep -qiE \
    "can't locate revision|cant locate revision|multiple head revisions|ERROR \[alembic|FAILED: Can't locate|dependency failed to start|exited \((1|255)\)|api/frontend failed to start|failed to start the e2e stack|could not translate host name|password authentication failed|relation \"[^\"]*\" does not exist|sqlalchemy\.exc\.|connection refused"
}

# ── Dependency-provisioning brick (#2124) ─────────────────────────────────────────
# An incomplete node_modules in the build worktree fails EVERY test file of the affected
# workspace at load time ("Cannot find module 'expo/tsconfig.base'" × 138). That is nobody's
# defect and it clears on a reinstall, but unclassified it looked `unrelated`: a blocker issue
# was filed, three auto-fix rounds were spent, and the parent deadlocked behind it.
# Three conditions, ALL required. The specifier must be a BARE package name (never './x'), it
# must have taken out at least DEPS_MIN_FILES whole test FILES (one bad import cannot), and the
# missing package must not be plausibly the AGENT'S OWN omission — importing a dependency without
# declaring it looks identical in the log but is self-repairable, and routing it here would burn
# MAX_TRANSIENT ticks re-running an install that can never help before reaching a human.
DEPS_MIN_FILES="${TRIAGE_DEPS_MIN_FILES:-5}"
unresolved_package() { # the missing package name (scope-aware), else empty
  no_console \
    | grep -oE "(Cannot find (module|package)|Failed to resolve (import|entry for package))[[:space:]]+['\"][^'\"]+['\"]" \
    | grep -oE "['\"][^'\"]+['\"]" | tr -d "\"'" \
    | grep -vE '^[./]' \
    | sed -E 's#^(@[^/]+/[^/]+|[^/]+).*#\1#' \
    | sort -u | head -1
}
suite_level_failures() { # count of test FILES that failed before running a single test
  local c; c="$(no_console | grep -cE '^[[:space:]]*(FAIL|✗|×)[[:space:]]+[A-Za-z0-9_./-]+\.(test|spec)\.tsx?' 2>/dev/null || true)"
  echo "${c:-0}"
}
# A manifest/lockfile in the diff means the agent was editing dependencies — a missing package
# is then its own to fix, not the harness's.
manifest_in_diff() {
  local paths; paths="$(changed_paths)"
  [ -n "$paths" ] || return 1
  grep -qE '(^|/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml)$' <<<"$paths"
}
# vite names the importer: `Failed to resolve import "lodash-es" from "src/lib/formatters.ts"`.
# If that importer is one of the agent's own changed files, the undeclared import is its bug.
deps_import_sources() { # basenames of the files whose imports failed to resolve
  no_console \
    | grep -oE 'Failed to resolve import[[:space:]]+"[^"]+"[[:space:]]+from[[:space:]]+"[^"]+"' \
    | grep -oE 'from[[:space:]]+"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/' \
    | sed -E 's#^.*/##' | sort -u
}
importer_in_diff() {
  local cb src; cb="$(changed_basenames)"
  [ -n "$cb" ] || return 1
  while read -r src; do
    [ -n "$src" ] || continue
    grep -qxF -- "$src" <<<"$cb" && return 0
  done <<<"$(deps_import_sources)"
  return 1
}
is_deps_failure() {
  local pkg n
  pkg="$(unresolved_package)"; [ -n "$pkg" ] || return 1
  n="$(suite_level_failures)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
  [ "$n" -ge "$DEPS_MIN_FILES" ] || return 1
  manifest_in_diff && return 1
  importer_in_diff && return 1
  return 0
}
# The other side of that split, and it needs its OWN branch rather than falling through to the
# generic overlap test: that test compares failing TEST files against the diff, and an undeclared
# import fails test files the agent never touched — so it would land on `unrelated`, filing a
# blocker for "lodash-es is missing" that belongs to nobody and blocking the parent behind it.
# When the diff owns the manifest or the importing file, the fix is in-branch: declare the dep.
is_dep_self_fault() {
  [ -n "$(unresolved_package)" ] || return 1
  manifest_in_diff && return 0
  importer_in_diff && return 0
  return 1
}

# ── Branch-introduced migration / boot failure (#172) ─────────────────────────────
# An `alembic upgrade head` that dies on the agent's OWN migration (a redundant
# create_unique_constraint → DuplicateTable, UndefinedColumn, multiple heads, a bad
# down_revision) crashes the api container — so compose prints the SAME
# "dependency failed to start" tail as a genuinely-infra poisoned-Postgres volume.
# Identical fingerprint, opposite owner. Splitting them is the whole point of this ticket:
# a migrate marker re-fingerprints the failure as `e2e:migrate-failure`; if the failing
# migration/model is in the agent's diff it's a `self` fault (feed the alembic error back into
# the next build), else it stays infra. (#152: migration 042 re-created a constraint 001
# already made; the volume was a red herring.)
#
# Markers are STRONG, migration-specific error signatures only — NOT bare "alembic" (a healthy
# boot logs "Running upgrade …") and NOT "can't locate revision" (kept on the infra path above,
# so a clean-checkout shared-state brick like #89 still routes to infra, not self).
is_migrate_failure() {
  printf '%s\n' "$TEXT" | grep -qiE \
    'migrate: non-transient failure|DuplicateTable|DuplicateObject|DuplicateColumn|UndefinedColumn|UndefinedTable|Multiple head revisions'
}
# Full repo-relative changed paths (NOT basenames — we must see the alembic/versions/ dir
# to tell an agent-authored migration from an unrelated model edit).
changed_paths() {
  if [ -n "$CHANGED_FILE" ] && [ -f "$CHANGED_FILE" ]; then
    sort -u "$CHANGED_FILE"
  elif [ -n "$BRANCH" ]; then
    git -C "$ROOT" diff --name-only "${BASE}...${BRANCH}" 2>/dev/null | sort -u
  fi
}
# The migration/model files in the agent's diff that could have broken the boot — the cheap
# self-intersection test the ticket asks for. Non-empty ⇒ this migrate crash is the agent's.
migrate_overlap() {
  changed_paths | grep -E 'alembic/versions/.*\.py$|(^|/)models/.*\.py$|(^|/)models\.py$' || true
}
# The real cause, pulled from the captured log so the comment shows the alembic/SQL error
# (which migration, what it collides with) instead of the generic compose container-exit tail.
migrate_excerpt() {
  printf '%s\n' "$TEXT" \
    | grep -iE 'Running upgrade|migrate: non-transient failure|DuplicateTable|DuplicateObject|DuplicateColumn|UndefinedColumn|UndefinedTable|Multiple head revisions|already exists|does not exist|asyncpg\.|sqlalchemy\.exc' \
    | tail -12
}
# ── The excerpt a human or the next agent actually reads ──────────────────────────
# A blind `tail -N` of a multi-workspace gate log shows whichever package finished LAST. For
# #2124 that was two GREEN workspaces, so the needs-human comment looked like a passing run
# while `RESULT: 1 gate(s) FAILED` and 138 failures sat 5,000 lines earlier — the reader's
# reasonable conclusion was "the gate passed, why is it stuck?". Anchor on the first real
# failure marker instead and always append the gate summary, which names the failing gate.
failure_excerpt() { # <max-lines>
  local max="${1:-40}" first
  first="$(no_console | grep -nE '^[[:space:]]*(FAIL|FAILED|ERROR|✗|✘|×)[[:space:]]|^[[:space:]]*[0-9]+\)[[:space:]]|Cannot find (module|package)|AssertionError|Traceback \(most recent call last\)' \
            | head -1 | cut -d: -f1)"
  if [ -z "$first" ]; then printf '%s\n' "$TEXT" | tail -"$max"; return; fi
  no_console | sed -n "${first},$((first + max - 1))p"
  printf '\n--- gate summary ---\n%s\n' \
    "$(printf '%s\n' "$TEXT" | grep -E '^[[:space:]]*[a-z-]+[[:space:]]+(pass|fail|skip)([[:space:]]|$)|^RESULT:|^[[:space:]]*(✗|✘)[[:space:]]+[a-z-]+' | tail -12)"
}

# Code-fenced excerpt for comments/blocker bodies. When we have a migrate error, lead with it
# (the actual cause) and keep only a short compose tail; otherwise use the caller's tail as-is.
fenced_excerpt() { # <fallback-text>
  if [ -n "${MIGRATE_EXCERPT:-}" ]; then
    printf 'migrate failure — the real cause (NOT the compose teardown tail below):\n%s\n\n--- compose tail ---\n%s' \
      "$MIGRATE_EXCERPT" "$(printf '%s\n' "$TEXT" | tail -12)"
  else
    printf '%s' "$1"
  fi
}

# ── Stable fingerprint: a kebab signature that the SAME failure always hashes to, so we
# never re-file a dup. We ANCHOR it on the failing TEST IDENTITY (pytest nodeid / Playwright
# spec+title / vitest spec+title) so two genuinely different failing tests can NEVER collapse
# into one bucket (#937). The old fingerprint slugified an arbitrary "salient" line, so any
# failure whose first salient line happened to mention `config.py` — a traceback frame, a
# pydantic error — all became `unit:config-py`: that corrupted the per-fingerprint attempt
# counter (unrelated failures burned each other's retries → premature `needs-human`) and
# pointed the escalation at the wrong file. Only when NO test id is extractable do we fall back
# to the lossy slug(salient_line), tagged `…-unclassified` so it's obviously low-confidence.
# (Infra/migrate keep their dedicated signatures — see below.) ─
salient_line() {
  if is_infra; then
    printf '%s\n' "$TEXT" | grep -ioE "can't locate revision identified by '[^']*'|multiple head revisions|dependency failed to start|exited \(255\)|password authentication failed|relation \"[^\"]*\" does not exist" | head -1
  else
    # the first failing spec/test name, else the first "Error:"/"FAILED" line
    local a; a="$(failing_areas | head -1)"
    if [ -n "$a" ]; then echo "$a"; else
      printf '%s\n' "$TEXT" | grep -iE 'error:|assert|FAILED|Timed out' | head -1
    fi
  fi
}
slug() { sed -E "s#/[A-Za-z0-9._/-]+##g; s/[0-9a-f]{7,}//g; s/[0-9]+//g; s/[^A-Za-z]+/-/g; s/^-+|-+\$//g" | tr '[:upper:]' '[:lower:]' | cut -c1-60; }

# Gentle normalizer for a test id: keep [a-z0-9_], collapse other runs to a single '_', trim,
# cap length. Unlike slug() it does NOT strip digits (so test_foo_v2 ≠ test_foo) and it preserves
# the existing `__` separator between the file basename and the test name.
norm_testid() { sed -E 's/[^A-Za-z0-9_]+/_/g; s/^_+|_+$//g' | tr '[:upper:]' '[:lower:]' | cut -c1-80; }

# pytest: "FAILED path/test_x.py::TestC::test_y[p] - AssertionError" / "ERROR path/test_x.py".
# Anchor on the nodeid: basename(-.py) + the ::-joined test path → test_x__TestC__test_y_p.
pytest_sig() {
  printf '%s\n' "$TEXT" \
    | grep -oE '^[[:space:]]*(FAILED|ERROR)[[:space:]]+[A-Za-z0-9_./-]+\.py(::[^[:space:]]+)?' \
    | head -1 \
    | sed -E 's/^[[:space:]]*(FAILED|ERROR)[[:space:]]+//; s#^.*/##; s/\.py::/__/; s/\.py$//; s/::/__/g' \
    | norm_testid
}
# Playwright: "  1) [chromium] › foo.spec.ts:16:7 › Suite › Test title" → spec basename + title.
playwright_sig() {
  local line spec title
  line="$(printf '%s\n' "$TEXT" | grep -oiE '^[[:space:]]*[0-9]+\)[[:space:]].*\.(spec|test)\.tsx?:[0-9]+:[0-9]+.*' | head -1)"
  [ -n "$line" ] || return 0
  spec="$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_./-]+\.(spec|test)\.tsx?' | head -1 | sed -E 's#^.*/##; s/\.(spec|test)\.tsx?$//')"
  title="$(printf '%s' "$line" | sed -E 's/.*\.(spec|test)\.tsx?:[0-9]+:[0-9]+[^A-Za-z0-9]*//')"
  printf '%s__%s' "$spec" "$title" | norm_testid
}
# vitest, two result shapes:
#   test-level   " FAIL  src/x.test.tsx > Suite > Test title"   → spec + title
#   suite-level  " FAIL  src/x.test.tsx [ src/x.test.tsx ]"     → spec only (file never loaded)
# The marker is anchored at the START of the line, where vitest prints its verdict, and console
# capture is stripped first. Previously this matched `fail` ANYWHERE on ANY line mentioning a
# spec, so `stderr | …OrgPedagogyPage.adversarial.test.tsx > SlidesGenerationToggle — query
# failure attacks > AT-016: …when getSlidesSettings fails` — console output from a test that
# PASSED — became the fingerprint for a 138-file dependency brick (#2124). The whole auto-fix
# budget then went to a test that passes 15/15 on main.
vitest_sig() {
  local line spec rest
  # test-level first: it carries a title, so it is the most specific signature available
  line="$(no_console | grep -E '^[[:space:]]*(FAIL|×|✗|✘|❯)[[:space:]]+.*\.(test|spec)\.tsx?[[:space:]]+>[[:space:]]+' | head -1)"
  if [ -n "$line" ]; then
    spec="$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_./-]+\.(test|spec)\.tsx?' | head -1 | sed -E 's#^.*/##; s/\.(test|spec)\.tsx?$//')"
    rest="$(printf '%s' "$line" | sed -E 's/^.*\.(test|spec)\.tsx?[[:space:]]+>[[:space:]]+//')"
    printf '%s__%s' "$spec" "$rest" | norm_testid
    return 0
  fi
  # suite-level: the file failed to load at all (transform / import error) — no title exists
  line="$(no_console | grep -E '^[[:space:]]*(FAIL|×|✗|✘|❯)[[:space:]]+[A-Za-z0-9_./-]+\.(test|spec)\.tsx?([[:space:]]|$)' | head -1)"
  [ -n "$line" ] || return 0
  printf '%s' "$line" | grep -oE '[A-Za-z0-9_./-]+\.(test|spec)\.tsx?' | head -1 \
    | sed -E 's#^.*/##; s/\.(test|spec)\.tsx?$//' | norm_testid
}
# ── Sanity guard on a test-anchored signature ─────────────────────────────────────
# The signature drives the per-fingerprint attempt counter AND the file the escalation blames,
# so one extracted from a stray log line is worse than none: #2124 anchored on a test that
# never appeared in the failing set, spent every retry on it, and reported it to a human as
# the cause. Cheap invariant — the file the signature names must be in failing_areas().
# Failing it is not fatal; it demotes the signature to the honest `-unclassified` bucket.
sig_names_a_failing_file() { # <signature>
  local head_tok hay
  head_tok="${1%%__*}"
  [ -n "$head_tok" ] || return 1
  # Materialise first, then match from a herestring: under `set -o pipefail` a `grep -q` that
  # exits on its first match SIGPIPEs the upstream stage, so the pipeline's status is 141 and
  # every lookup would report "absent" — the guard would demote every signature it ever saw.
  hay="$(failing_areas | sed -E 's/\.(spec|test)\.tsx?$//; s/\.py$//' | norm_testid)"
  [ -n "$hay" ] || return 1
  grep -qxF -- "$head_tok" <<<"$hay"
}

# First test-anchored signature we can extract (pytest → Playwright → vitest), else empty.
test_signature() {
  local s
  s="$(pytest_sig)";     [ -n "$s" ] && { printf '%s' "$s"; return 0; }
  s="$(playwright_sig)"; [ -n "$s" ] && { printf '%s' "$s"; return 0; }
  s="$(vitest_sig)";     [ -n "$s" ] && { printf '%s' "$s"; return 0; }
  return 0
}

# ── Cluster signature: one breakage, many files ───────────────────────────────────
# A test-anchored signature names whichever failure the log listed FIRST. With a single
# failure that is the culprit; across a CLUSTER it is a coin toss — pytest-xdist shards by
# worker, so the same breakage lists a different test first on every run. The fingerprint then
# changes per run, the dedup search at file time finds nothing, and one breakage is filed as an
# endless stream of "new" issues: the #2208 landing redesign broke 25 tests across 3 files and
# was filed as #2212, then #2217, and would have kept going once per round.
#
# So when the failing set spans multiple FILES, anchor on the file set instead. It is sorted,
# making it independent of run order, and it carries a hash of the whole set so two different
# clusters that happen to share an alphabetically-first file stay distinct. Deps and migrate
# bricks override this further down — they have a better identity (the package / the phase).
#
# Counted over TEST files only. failing_areas() deliberately over-reports — it picks up
# traceback frames through ordinary source too, so a single failing test whose stack passes
# through `config.py` yields two "areas" (#937). Two areas is not two failures; two failing
# test files is. Filtering on test-file naming keeps the single-failure case test-anchored.
CLUSTER_MIN_FILES="${TRIAGE_CLUSTER_MIN_FILES:-2}"
cluster_signature() {
  local files n first hash
  files="$(failing_areas | grep -E '(^test_|_test\.py$|\.(test|spec)\.tsx?$)' \
             | sed -E 's/\.(spec|test)\.tsx?$//; s/\.py$//' | sort -u | grep -v '^$')"
  n="$(printf '%s\n' "$files" | grep -c . || true)"
  [ "${n:-0}" -ge "$CLUSTER_MIN_FILES" ] || return 0
  first="$(printf '%s\n' "$files" | head -1 | norm_testid)"
  hash="$(printf '%s' "$files" | sha1sum | cut -c1-8)"
  printf 'cluster-%sfiles-%s-%s' "$n" "$first" "$hash"
}

if is_infra; then
  SIG="$(salient_line | slug)"; [ -n "$SIG" ] || SIG="unclassified"
else
  SIG="$(test_signature)"
  # Demote a signature that names a file which is not actually in the failing set — a
  # low-confidence slug is honest, a confident pointer at an innocent test is not (#2124).
  if [ -n "$SIG" ] && ! sig_names_a_failing_file "$SIG"; then
    log "WARN: discarding signature '${SIG}' — it names no file in the failing set"
    SIG=""
  fi
  CLUSTER_SIG="$(cluster_signature)"
  if [ -n "$CLUSTER_SIG" ]; then
    [ -n "$SIG" ] && log "cluster: failure spans multiple files — anchoring on the file set, not '${SIG}'"
    SIG="$CLUSTER_SIG"
  elif [ -z "$SIG" ]; then
    # No failing test id — keep the legacy lossy slug but TAG it so the low-confidence bucket is
    # unmistakable (humans/agents know not to trust this fingerprint as "the failing test").
    SIG="$(salient_line | slug)"
    if [ -n "$SIG" ]; then SIG="${SIG}-unclassified"; else SIG="unclassified"; fi
  fi
fi
# A migrate/boot failure gets a dedicated sub-fingerprint so it never collides with the
# genuinely-infra `dependency-failed-to-start` signature (#172). alembic only runs inside the
# e2e stack boot, so pin the gate to `e2e` → fingerprint `e2e:migrate-failure`.
MIGRATE_EXCERPT=""
if is_migrate_failure; then GATE="e2e"; SIG="migrate-failure"; MIGRATE_EXCERPT="$(migrate_excerpt)"; fi
# A deps brick is named after the PACKAGE that is missing, never after whichever test file
# happened to be listed first — that is the only stable identity it has, and it keeps the
# transient retry counter per-cause (#2124).
DEPS_PKG=""
if is_deps_failure; then
  DEPS_PKG="$(unresolved_package)"
  SIG="deps-unresolved-$(printf '%s' "$DEPS_PKG" | slug)"
elif is_dep_self_fault; then
  # Same naming logic for the self-owned side, so the escalation names the PACKAGE rather than
  # whichever of the many load-failed test files happened to be listed first.
  SIG="deps-undeclared-$(printf '%s' "$(unresolved_package)" | slug)"
fi
FP="${GATE}:${SIG}"
FP_MARKER="<!-- triage-fp:${FP} -->"

# ── Ledger helpers (attempt counter per fingerprint, persisted across ticks) ──────
ledger_attempts() { # grep -c prints "0" AND exits 1 on zero matches, so a naive `|| echo 0`
                    # yields "0\n0" → integer-comparison error. Capture + swallow exit instead.
  local c; c="$(grep -cF "\"fp\":\"${FP}\"" "$LEDGER" 2>/dev/null || true)"; echo "${c:-0}"; }
ledger_transient_attempts() { # prior transient retries recorded for THIS fingerprint
  local c; c="$(grep -F "\"fp\":\"${FP}\"" "$LEDGER" 2>/dev/null | grep -cF '"action":"transient"' || true)"; echo "${c:-0}"; }
ledger_record() { # <action> <blocker#>
  [ "$DRY_RUN" = 1 ] && { printf 'WOULD: ledger += {fp:%s action:%s blocker:%s}\n' "$FP" "$1" "${2:-}"; return; }
  printf '{"fp":"%s","issue":"%s","action":"%s","blocker":"%s"}\n' "$FP" "$ISSUE" "$1" "${2:-}" >> "$LEDGER" 2>/dev/null || true
}

# ── Dedup: an OPEN issue already carrying this fingerprint marker (open blockers only) ─
existing_blocker() {
  # NEVER return the issue being triaged — an issue cannot block itself (the marker lives in
  # the blocker's OWN body, so a same-fingerprint search would otherwise match it).
  "$GH" issue list --label "$LABEL" --state open --search "$FP_MARKER in:body" \
    --json number,body --limit 20 2>/dev/null \
    | jq -r --arg m "$FP_MARKER" --argjson self "${ISSUE:-0}" \
        '[.[] | select((.number != $self) and (.body | contains($m)))][0].number // empty' 2>/dev/null
}
open_autofiled_count() { # harness + flaky blockers currently open (single clean integer)
  local c
  c="$( { "$GH" issue list --label "$HARNESS_LABEL" --state open --json number --limit 100 2>/dev/null || echo '[]'
          "$GH" issue list --label "$FLAKY_LABEL"   --state open --json number --limit 100 2>/dev/null || echo '[]'
        } | jq -s 'add | length' 2>/dev/null )"
  echo "${c:-0}"
}

comment() { do_gh issue comment "$1" -b "$2"; }

escalate_needs_human() { # <reason>
  log "DECISION: needs-human — $1"
  printf 'DECISION: class=%s action=needs-human fp=%s reason=%s\n' "${CLASS:-self}" "$FP" "$1"
  comment "$ISSUE" "$(printf '❌ agent-inbox: gates failed (%s) — needs a human.\n\n%s\n\n```\n%s\n```' "$1" "$FP_MARKER" "$(fenced_excerpt "$(failure_excerpt 25)")")"
  add_label "$ISSUE" "needs-human"
  remove_label "$ISSUE" "wip"
}

# How many self-repair attempts this issue has already had (= count of marker comments).
self_repair_attempts() {
  local n
  n="$("$GH" issue view "$ISSUE" --json comments \
        --jq "[.comments[] | select(.body | contains(\"$SELF_REPAIR_MARKER\"))] | length" 2>/dev/null)"
  echo "${n:-0}"
}

# The agent's OWN build failed (not infra, not someone else's code). Instead of dead-ending at
# needs-human, RE-QUEUE the issue with the gate-failure log attached so the next build can fix
# the ROOT CAUSE (often a pre-existing bug a correct new test exposed). Bounded: after
# MAX_SELF_REPAIR attempts, give up loudly to a human.
self_repair_or_escalate() { # <reason>
  local n; n="$(self_repair_attempts)"
  if [ "${n:-0}" -ge "$MAX_SELF_REPAIR" ]; then
    escalate_needs_human "$1 — self-repair exhausted after ${n} attempt(s)"; return
  fi
  local next=$((n + 1))
  log "DECISION: self action=self-repair attempt ${next}/${MAX_SELF_REPAIR} — $1"
  printf 'DECISION: class=self action=self-repair attempt=%s/%s fp=%s\n' "$next" "$MAX_SELF_REPAIR" "$FP"
  comment "$ISSUE" "$(printf '🔧 agent-inbox: the gate failed on this build (%s). Re-queuing for an automatic fix attempt (%s/%s) — the next build receives this failure log and must fix the ROOT CAUSE. The failing test may be CORRECT and exposing a pre-existing bug in code you did not write; fix that, not just your diff.\n\n```\n%s\n```\n%s' \
    "$1" "$next" "$MAX_SELF_REPAIR" "$(fenced_excerpt "$(failure_excerpt 60)")" "$SELF_REPAIR_MARKER")"
  # Re-queue: keep `agent`, drop `wip`, do NOT add needs-human/blocked → eligible again next tick.
  remove_label "$ISSUE" "wip"
}

file_and_requeue() { # <kind: harness|flaky>  <extra-label>
  local kind="$1" extra="$2" attempts
  # Guardrail 0 (terminal): if THIS issue is itself the auto-filed fix for this exact
  # fingerprint — its own body carries the marker — and it's failing AGAIN on that
  # fingerprint, the designated fix didn't take. A human must step in. This is what stops
  # a blocker issue from blocking ITSELF (deadlock) or spawning a chain of blockers.
  if "$GH" issue view "$ISSUE" --json body --jq '.body' 2>/dev/null | grep -qF "$FP_MARKER"; then
    escalate_needs_human "this issue is the designated fix for ${FP} and it still fails"; return
  fi
  attempts="$(ledger_attempts)"
  # Guardrail 1: per-fingerprint attempt cap → stop self-filing, escalate for real.
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    escalate_needs_human "auto-fix attempted ${attempts}× without clearing (fp ${FP})"; return
  fi
  # Guardrail 2: global cap on open auto-filed blockers.
  local openc; openc="$(open_autofiled_count)"
  if [ "${openc:-0}" -ge "$MAX_OPEN" ]; then
    escalate_needs_human "auto-filed blocker cap reached (${openc} open ≥ ${MAX_OPEN})"; return
  fi
  # Dedup: a blocker for this fingerprint already exists → just attach to it.
  local blocker; blocker="$(existing_blocker 2>/dev/null || true)"
  if [ -n "$blocker" ]; then
    log "DECISION: ${CLASS} action=attach-to-existing blocker=#${blocker} fp=${FP}"
    printf 'DECISION: class=%s action=attach blocker=#%s fp=%s\n' "$CLASS" "$blocker" "$FP"
    comment "$blocker" "🔁 agent-inbox: still failing — also blocks #${ISSUE} (attempt $((attempts+1)))."
    comment "$ISSUE" "⛔ agent-inbox: blocked by #${blocker} (${CLASS} gate failure — not caused by this change). Re-queues automatically when #${blocker} closes. ${FP_MARKER}"
    add_label "$ISSUE" "$BLOCKED_LABEL"
    remove_label "$ISSUE" "wip"
    ledger_record "attach" "$blocker"
    return
  fi
  # File a fresh blocker issue into the inbox (label `agent` so the next tick builds it).
  local title body excerpt
  excerpt="$(fenced_excerpt "$(failure_excerpt 40)")"
  if [ "$kind" = harness ]; then
    title="agent-inbox: ${GATE} gate blocked by harness/infra failure — ${SIG}"
    body="$(cat <<EOF
**Auto-filed by agent-triage-failure** while building #${ISSUE} (\`${BRANCH}\`).

The \`${GATE}\` quality gate failed for an **infrastructure / harness** reason — NOT a defect in
#${ISSUE}'s change. The agent's diff does not touch the failing area, so the right fix is to the
harness/shared state, after which #${ISSUE} (and every other branch) unblocks.

**Signature:** \`${FP}\`

**Acceptance:** the \`${GATE}\` gate runs to completion and passes on a clean checkout of \`${BASE}\`.

\`\`\`
${excerpt}
\`\`\`

Blocks: #${ISSUE}
${FP_MARKER}
EOF
)"
  else
    title="Failing ${GATE} exposed by the gate: ${SIG} (auto-filed)"
    body="$(cat <<EOF
**Auto-filed by agent-triage-failure** while building #${ISSUE} (\`${BRANCH}\`).

The \`${GATE}\` gate failed in **files this change never touched** — a pre-existing breakage the
now-running gate surfaced. It must be fixed on its own; #${ISSUE} is merely blocked behind it.

**Signature:** \`${FP}\`
**Failing area:** $(failing_areas | paste -sd', ' -)

**Acceptance:** the listed test(s) pass against \`${BASE}\`; the \`${GATE}\` gate goes green.

\`\`\`
${excerpt}
\`\`\`

Blocks: #${ISSUE}
${FP_MARKER}
EOF
)"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf 'DECISION: class=%s action=file-and-requeue kind=%s fp=%s\n' "$CLASS" "$kind" "$FP"
    printf 'WOULD: gh issue create --label %s --label %s --title %q\n' "$LABEL" "$extra" "$title"
    printf '       body: %s … (%d chars) + marker %s\n' "$(printf '%s' "$body" | head -1)" "${#body}" "$FP_MARKER"
    printf 'WOULD: gh api issues/%s/labels labels[]=%s   (block current, drop wip)\n' "$ISSUE" "$BLOCKED_LABEL"
    ledger_record "file-dry" ""
    return
  fi
  ensure_label "$extra"; ensure_label "$BLOCKED_LABEL"   # so `issue create --label` can't no-op
  local url newnum
  url="$("$GH" issue create --label "$LABEL" --label "$extra" --title "$title" --body "$body" 2>/dev/null || echo '')"
  newnum="${url##*/}"
  # Never mark the issue `blocked` against a phantom blocker — if create failed, escalate.
  if ! printf '%s' "$newnum" | grep -qE '^[0-9]+$'; then
    escalate_needs_human "could not file the auto-blocker issue (gh issue create failed)"; return
  fi
  log "DECISION: ${CLASS} action=file-and-requeue blocker=#${newnum} fp=${FP}"
  printf 'DECISION: class=%s action=file-and-requeue blocker=#%s fp=%s\n' "$CLASS" "$newnum" "$FP"
  comment "$ISSUE" "⛔ agent-inbox: blocked by #${newnum} (${CLASS} ${GATE} failure — not caused by this change). Re-queues automatically when it closes. ${FP_MARKER}"
  add_label "$ISSUE" "$BLOCKED_LABEL"
  remove_label "$ISSUE" "wip"
  ledger_record "file" "$newnum"
}

# ── Decide ───────────────────────────────────────────────────────────────────────
log "fingerprint=${FP}  gate=${GATE}  dry-run=${DRY_RUN}"
# A deps brick shares the transient ROUTE (retry, file nothing) — a reinstall clears it — but
# keeps its own fingerprint, so its retries are counted per missing package and MAX_TRANSIENT
# still escalates it to a human if reinstalling never helps.
if is_transient || is_deps_failure; then
  CLASS=transient
  if [ -n "$DEPS_PKG" ]; then
    log "deps brick: '${DEPS_PKG}' unresolved across $(suite_level_failures) test file(s) — not a code failure"
  fi
  tcount="$(ledger_transient_attempts)"; [[ "$tcount" =~ ^[0-9]+$ ]] || tcount=0
  if [ "$tcount" -ge "$MAX_TRANSIENT" ]; then
    # A "transient" failure that recurs every tick without ever clearing is NOT actually transient
    # (a chronic OOM, a permanently-down docker daemon, or asserted test output that merely contains
    # a transient-looking phrase). The old branch retried FOREVER with no cap — unbounded spend and
    # a stuck issue. After MAX_TRANSIENT retries, escalate to a human.
    escalate_needs_human "gate kept hitting a transient/availability error ${tcount}× without clearing (fp ${FP}) — not self-healing"
  else
    log "DECISION: transient — retry next tick (no file, drop wip) [retry $((tcount+1))/${MAX_TRANSIENT}]"
    printf 'DECISION: class=transient action=retry attempt=%s/%s fp=%s\n' "$((tcount+1))" "$MAX_TRANSIENT" "$FP"
    if [ -n "$DEPS_PKG" ]; then
      comment "$ISSUE" "⏳ agent-inbox: the build worktree could not resolve \`${DEPS_PKG}\`, which failed $(suite_level_failures) test file(s) at load time — a dependency-provisioning brick, not a defect in this change. Will retry with a fresh install on the next tick. (retry $((tcount+1))/${MAX_TRANSIENT})"
    else
      comment "$ISSUE" "⏳ agent-inbox: gates hit a transient/infra-availability error (\`${SIG}\`); will retry on the next tick. (transient retry $((tcount+1))/${MAX_TRANSIENT})"
    fi
    remove_label "$ISSUE" "wip"
    ledger_record "transient" ""
  fi
elif is_dep_self_fault; then
  # A package cannot be resolved AND the diff owns it — the agent imported a dependency it did
  # not declare, or edited the manifest/lockfile. That is fixable in-branch, so feed it back
  # rather than letting the overlap test call it `unrelated` and file a blocker nobody owns.
  CLASS=self
  self_repair_or_escalate "the imported package '$(unresolved_package)' cannot be resolved and this diff owns it (manifest or importing file changed) — declare and install the dependency, do not expect the harness to provide it"
elif is_migrate_failure; then
  # The stack boot died on an alembic/migration error. Discriminate the agent's own broken
  # migration (→ self, fix it) from a genuinely-infra brick that merely surfaced during migrate
  # (→ infra, block+retry). The migrate error is fed back via the self-repair / blocker comment.
  mo="$(migrate_overlap)"
  if [ -n "$mo" ]; then
    CLASS=self
    self_repair_or_escalate "alembic upgrade head failed on a migration in this diff ($(printf '%s' "$mo" | paste -sd', ')) — it likely duplicates/conflicts with an existing migration; fix the migration, not the harness"
  else
    CLASS=infra
    file_and_requeue harness "$HARNESS_LABEL"
  fi
elif is_infra; then
  CLASS=infra
  file_and_requeue harness "$HARNESS_LABEL"
else
  fa="$(failing_areas)"; cb="$(changed_basenames)"
  overlap=""
  if [ -n "$fa" ] && [ -n "$cb" ]; then
    overlap="$(comm -12 <(printf '%s\n' "$fa") <(printf '%s\n' "$cb") 2>/dev/null)"
  fi
  if [ -n "$overlap" ]; then
    CLASS=self
    self_repair_or_escalate "failure is in the agent's own changed files ($(printf '%s' "$overlap" | paste -sd', '))"
  elif [ -n "$fa" ]; then
    # Before blaming $BASE for a failure in untouched files, check the build was ever looking at
    # $BASE. A behind-base tree cannot support an `unrelated` verdict — see branch_behind_base().
    behind="$(branch_behind_base)"
    if [ -n "$behind" ]; then
      CLASS=stale-base
      log "DECISION: stale-base — branch is ${behind} commit(s) behind ${BASE}; not filing (retry on a rebased tree)"
      printf 'DECISION: class=stale-base action=retry behind=%s fp=%s\n' "$behind" "$FP"
      comment "$ISSUE" "⏳ agent-inbox: the \`${GATE}\` gate failed in files this change never touched, but the build branch is **${behind} commit(s) behind \`${BASE}\`** — so those failures are most likely already fixed on \`${BASE}\` and this tree simply predates the fix. Not filing a blocker for them. The next build rebases onto \`${BASE}\` before gating and re-runs. (\`${SIG}\`)"
      remove_label "$ISSUE" "wip"
      ledger_record "stale-base" ""
    else
      CLASS=unrelated
      file_and_requeue flaky "$FLAKY_LABEL"
    fi
  else
    CLASS=self
    self_repair_or_escalate "could not localize the failure to specific files (conservative)"
  fi
fi
exit 0
