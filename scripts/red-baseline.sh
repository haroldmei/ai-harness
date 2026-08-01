#!/usr/bin/env bash
# red-baseline.sh — "which tests are ALREADY red on the base branch?"
#
# THE PROBLEM THIS SOLVES
# A branch's gate runs the WHOLE suite, so it fails on breakage the branch never
# caused. On 2026-07-31 two source-only commits landed straight on main with no test
# updates; every lane afterwards cut from that red main, failed in files it never
# touched, and agent-triage-failure.sh (correctly, by its own rules) called each one
# "a pre-existing breakage — file a blocker". One breakage became #2381 → #2383 →
# #2384 → #2385, each blocked behind the next, none mergeable, ~25 min of build per
# rung. Every guardrail in the triage keys on a fingerprint that CHANGES as each lane
# fixes a different subset, so none of them fired.
#
# The fix is upstream of triage: judge a gate by the failures it ADDS, not the ones it
# inherits — exactly what mypy-baseline already does for the typecheck gate
# (scripts/typecheck.sh, backend/mypy-baseline.txt, `filter --allow-unsynced`).
# A branch that adds nothing red goes green and MERGES; nothing is filed and no rung
# is built. The inherited breakage is then one problem to fix once, on main, instead
# of one auto-filed issue per observed subset.
#
# FAIL-CLOSED BY CONSTRUCTION
# The baseline is only ever consulted when it was recorded for the EXACT base commit
# the branch is being judged against. No baseline for that sha ⇒ `diff` reports every
# failure as new and the gate behaves exactly as it does today. A baseline can
# therefore only ever forgive failures that were demonstrably red on that same base;
# it can never hide a regression a branch introduced, and it goes stale safely (a new
# main commit simply has no baseline until one is recorded).
#
#   Usage:
#     red-baseline.sh ids    --log FILE                 # normalized failing test ids
#     red-baseline.sh record --gate G --log FILE [--sha S]
#     red-baseline.sh diff   --gate G --log FILE [--sha S]   # ids NOT in the baseline
#     red-baseline.sh path   --gate G [--sha S]
#     red-baseline.sh status --gate G [--sha S]
#
#   `diff` exits 0 when nothing new is failing (the gate may be forgiven), 1 when it
#   is (the gate must stay red), and 2 when no baseline exists for the sha (unknown →
#   caller must fail closed).
set -uo pipefail

ROOT="${RED_BASELINE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASE_BRANCH="${RED_BASELINE_BASE:-main}"

# Per-repo namespace so unrelated checkouts never share a baseline.
ns() { git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null \
        | { read -r d; cd "$ROOT" 2>/dev/null && cd "$d" 2>/dev/null && pwd; } \
        | sha1sum | cut -c1-12; }
NS="$(ns 2>/dev/null || true)"; [ -n "$NS" ] || NS="nogit"
DIR="${RED_BASELINE_DIR:-/tmp/skillforge-red-baseline-$NS}"

CMD="${1:-}"; shift 2>/dev/null || true
GATE="" LOG="" SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gate) GATE="$2"; shift 2;;
    --log)  LOG="$2";  shift 2;;
    --sha)  SHA="$2";  shift 2;;
    *) echo "[red-baseline] unknown arg: $1" >&2; exit 2;;
  esac
done

# The commit a branch is judged against. Prefer the remote base (what the branch will
# actually merge into); fall back to the local ref.
resolve_sha() {
  [ -n "$SHA" ] && { printf '%s' "$SHA"; return; }
  local r
  for r in "origin/${BASE_BRANCH}" "$BASE_BRANCH"; do
    if git -C "$ROOT" rev-parse --verify -q "$r" >/dev/null 2>&1; then
      git -C "$ROOT" rev-parse "$r"; return
    fi
  done
  printf 'nosha'
}

baseline_path() { printf '%s/%s-%s.txt' "$DIR" "$(resolve_sha)" "${GATE:-gate}"; }

# ── Failing-test extraction ───────────────────────────────────────────────────────
# One normalized id per failing test, stable across runs of the same breakage.
#
# Deliberately id-level, not file-level: the cluster fingerprint in
# agent-triage-failure.sh hashes the whole failing FILE SET, so it changes the moment
# any lane fixes part of it (that instability is what filed #2383 and #2385 as two
# issues for one breakage). Set membership per test id has no such coupling — a
# branch that fixes 4 of 10 baseline failures simply matches 6.
#
# Line:col is stripped because it moves whenever anything above it in the file moves;
# the suite + title are what identify the test.
#
# Console capture is dropped first: vitest prefixes captured output with the EMITTING
# test's name ("stdout | Foo.test.tsx > … fails when …"), so any matcher keyed on the
# word "fail" otherwise ingests tests that PASSED (#2124).
ids_from_log() {
  local f="$1"
  [ -f "$f" ] || return 0
  # strip ANSI, then drop runner console-capture lines
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$f" 2>/dev/null \
    | grep -vE '^[[:space:]]*(stdout|stderr)[[:space:]]*\|' \
    | {
        # pytest — "FAILED tests/unit/test_x.py::TestC::test_y[p] - AssertionError"
        grep -oE '^[[:space:]]*(FAILED|ERROR)[[:space:]]+[A-Za-z0-9_./-]+\.py(::[^[:space:]]+)?' \
          | sed -E 's/^[[:space:]]*(FAILED|ERROR)[[:space:]]+//' | sed -E 's#^\./##'
        # playwright — "  1) [chromium] › a/b.spec.ts:16:7 › Suite › Title"
        sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$f" \
          | grep -oE '^[[:space:]]*[0-9]+\)[[:space:]]+(\[[^]]+\][[:space:]]+)?›?[[:space:]]*[A-Za-z0-9_./-]+\.(spec|test)\.tsx?:[0-9]+:[0-9]+[[:space:]]*›.*' \
          | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+//; s/^\[[^]]+\][[:space:]]*//; s/^›[[:space:]]*//' \
          | sed -E 's/\.(spec|test)\.(tsx?):[0-9]+:[0-9]+/.\1.\2/' \
          | sed -E 's/[[:space:]]+$//'
        # vitest test-level — " FAIL  src/x.test.tsx > Suite > Title"
        sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$f" \
          | grep -vE '^[[:space:]]*(stdout|stderr)[[:space:]]*\|' \
          | grep -oE '^[[:space:]]*(FAIL|×|✗|✘)[[:space:]]+[A-Za-z0-9_./-]+\.(test|spec)\.tsx?[[:space:]]+>[[:space:]]+.*' \
          | sed -E 's/^[[:space:]]*(FAIL|×|✗|✘)[[:space:]]+//; s/[[:space:]]+$//'
        # vitest suite-level — " FAIL  src/x.test.tsx [ src/x.test.tsx ]" (never loaded).
        # The `> ` exclusion is load-bearing: without it this pattern also matches the
        # PREFIX of a test-level line, so every test-level failure would additionally
        # emit a bare filename and the same failure would be counted twice.
        sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$f" \
          | grep -vE '^[[:space:]]*(stdout|stderr)[[:space:]]*\|' \
          | grep -E '^[[:space:]]*(FAIL|×|✗|✘)[[:space:]]+[A-Za-z0-9_./-]+\.(test|spec)\.tsx?([[:space:]]|$)' \
          | grep -vE '\.(test|spec)\.tsx?[[:space:]]+>' \
          | sed -E 's/^[[:space:]]*(FAIL|×|✗|✘)[[:space:]]+//' \
          | sed -E 's/^([A-Za-z0-9_./-]+\.(test|spec)\.tsx?).*/\1/'
        # harness shell suites — unit.sh prints "  ✗ quality-gates.test.sh — failed (exit 1):"
        # (or "— TIMED OUT after 300s") per failing suite. Without this the whole fourth runner
        # in the `unit` gate is INVISIBLE to the baseline: a unit gate that failed only on
        # scripts/*.test.sh yielded no ids at all, so `record` wrote an empty baseline and
        # announced "recorded 0 failing test(s)" for a gate that was red — an operator reading
        # that concludes the gate is green. `diff` fails closed on an empty extraction (see the
        # note at the diff branch), so nothing was ever wrongly forgiven; the cost was the
        # opposite one — an inherited-red shell suite could never be forgiven either, so every
        # branch off that base stayed red with no way out. The suite basename is the id: it is
        # stable across edits, whereas the individual `✗ <assertion>` lines are not (and are
        # indented, so they do not match this anchor).
        sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$f" \
          | grep -oE '^[[:space:]]*✗[[:space:]]+[A-Za-z0-9_.-]+\.test\.sh[[:space:]]+—' \
          | sed -E 's/^[[:space:]]*✗[[:space:]]+//; s/[[:space:]]+—$//' \
          | sed -E 's#^#scripts/#'
      } \
    | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ +| +$//g' \
    | grep -v '^$' | sort -u
}

case "$CMD" in
  ids)
    [ -n "$LOG" ] || { echo "[red-baseline] ids needs --log" >&2; exit 2; }
    ids_from_log "$LOG"
    ;;

  path) baseline_path ;;

  status)
    p="$(baseline_path)"
    if [ -f "$p" ]; then
      printf 'baseline present sha=%s gate=%s tests=%s path=%s\n' \
        "$(resolve_sha)" "$GATE" "$(grep -c . "$p" 2>/dev/null || echo 0)" "$p"
    else
      printf 'baseline ABSENT sha=%s gate=%s path=%s\n' "$(resolve_sha)" "$GATE" "$p"
      exit 2
    fi
    ;;

  record)
    [ -n "$GATE" ] && [ -n "$LOG" ] || { echo "[red-baseline] record needs --gate and --log" >&2; exit 2; }
    # Never record a baseline from a tree that could not load its own modules (#2438). An
    # incomplete npm-workspaces install fails ~154 mobile suites at TRANSFORM time; recording that
    # as "what is already red on the base" hands every branch off this commit a blanket pardon for
    # the entire mobile suite — the same end state as editing tests to assert broken behaviour,
    # reached by a different route. Observed for real: the merger's deps-broken run at c4b2609a
    # wrote a 154-entry `unit` baseline for a commit whose unit gate is green.
    # Refusing to record leaves the baseline ABSENT, which fails CLOSED (every failure counts as
    # new) — the correct conservative state. RED_BASELINE_SKIP_DEPS_CHECK=1 bypasses it.
    # The LIB is resolved from BASH_SOURCE, never from $ROOT: $ROOT is overridable
    # (RED_BASELINE_ROOT) and a $ROOT-relative source silently no-ops against a sandbox tree,
    # leaving the guard permanently off with no signal (#2390). $ROOT is only the tree to MEASURE.
    #
    # Scoped to the gates that actually LOAD JS modules. `integration` is backend pytest + Docker
    # and can be recorded on a base tree that never had a JS install at all — running the guard
    # there just refuses every integration baseline with no JS ever at fault, silently turning off
    # the inherited-red forgiveness #2381→#2385 exists to provide. RED_BASELINE_DEPS_GATES
    # overrides the list.
    _rb_deps_gates=" ${RED_BASELINE_DEPS_GATES:-unit e2e} "
    _rb_gate_loads_js() { case "$_rb_deps_gates" in *" $1 "*) return 0;; *) return 1;; esac; }
    _rb_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deps-verify.sh"
    if [ "${RED_BASELINE_SKIP_DEPS_CHECK:-0}" != 1 ] && [ -f "$_rb_lib" ] && _rb_gate_loads_js "$GATE"; then
      # shellcheck source=scripts/lib/deps-verify.sh
      . "$_rb_lib"
      _rb_missing="$(deps_unresolved_summary "$ROOT" 2>/dev/null || true)"
      if [ -n "$_rb_missing" ]; then
        printf '[red-baseline] REFUSING to record a %s baseline: the tree cannot resolve %s, so this run measured the install, not the code. Fix the install (root `npm ci`) and re-record.\n' \
          "$GATE" "$_rb_missing" >&2
        exit 2
      fi
    fi
    mkdir -p "$DIR" 2>/dev/null || true
    p="$(baseline_path)"
    ids_from_log "$LOG" > "$p" || true
    printf '[red-baseline] recorded %s failing test(s) for %s @ %s\n' \
      "$(grep -c . "$p" 2>/dev/null || echo 0)" "$GATE" "$(resolve_sha | cut -c1-12)"
    printf '[red-baseline] %s\n' "$p"
    ;;

  diff)
    [ -n "$GATE" ] && [ -n "$LOG" ] || { echo "[red-baseline] diff needs --gate and --log" >&2; exit 2; }
    p="$(baseline_path)"
    # No baseline for THIS base commit ⇒ unknown ⇒ caller fails closed. This is the
    # normal state right after a new commit lands on the base branch.
    [ -f "$p" ] || exit 2
    cur="$(ids_from_log "$LOG")"
    # A gate that failed with no extractable test id (a compile error, a stack that
    # never reached a test, an OOM) is NOT forgivable: there is nothing to compare, so
    # "no new ids" would silently read as "all inherited". Fail closed.
    [ -n "$cur" ] || exit 2
    new="$(comm -23 <(printf '%s\n' "$cur") <(sort -u "$p") 2>/dev/null)"
    [ -n "$new" ] || exit 0
    printf '%s\n' "$new"
    exit 1
    ;;

  *)
    sed -n '/^#   Usage:/,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
    exit 2
    ;;
esac
