#!/usr/bin/env bash
# unit.sh — run skillforge's unit suites (no external services required).
#   backend    → pytest tests/unit
#   frontend   → vitest run
#   mobile     → vitest run
#   api-client → vitest run  (packages/api-client; #1906)
# gate_unit (scripts/quality-gates.sh) calls this.
#
# Exit: 0 all pass | 1 a suite failed | 77 no unit suites found.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

fail=0
checked=0

if [[ -d backend/tests/unit ]]; then
  checked=$((checked + 1))
  echo "unit: backend (pytest tests/unit)"

  # xdist keeps the unit gate near the coverage gate's wall clock (the same
  # 3410 tests take 38s with -n auto vs 173s serial). Fall back when absent.
  XDIST=()
  ( cd backend && python -c "import xdist" ) 2>/dev/null && XDIST=(-n auto)

  # UNIT_EMIT_COVERAGE=<path>: measure coverage during THIS run and write the coverage.py
  # JSON there, so the `coverage` gate can consume it via `coverage.sh --from-json` instead
  # of replaying the identical 3489-test suite a second time (issue #2412). quality-gates.sh
  # sets it only when BOTH `unit` and `coverage` are scheduled, so a standalone `--only unit`
  # keeps the historical `--no-cov` fast path exactly as it was.
  #
  # The pair is deliberately coupled through a file rather than by merging the two gates:
  # they report different things (suite green vs. ratchet floor), route to different owners
  # on failure, and `coverage` must stay independently runnable on a host where `unit` was
  # filtered out.
  COV=(--no-cov)
  if [[ -n "${UNIT_EMIT_COVERAGE:-}" ]] && ( cd backend && python -c "import pytest_cov" ) 2>/dev/null; then
    mkdir -p "$(dirname "$UNIT_EMIT_COVERAGE")" 2>/dev/null || true
    # --cov-report= silences the terminal table; only the JSON is wanted here.
    COV=(--cov=app --cov-report= "--cov-report=json:${UNIT_EMIT_COVERAGE}")
    echo "  (measuring coverage → ${UNIT_EMIT_COVERAGE})"
  fi

  if ( cd backend && python -m pytest tests/unit/ -q "${COV[@]}" -p no:cacheprovider "${XDIST[@]}" ); then
    echo "  ✓ backend"
  else
    echo "  ✗ backend — pytest failed"; fail=1
    # A red suite makes the coverage number meaningless AND would let the coverage gate
    # report a ratchet result derived from a partial run. Remove the artifact so the
    # coverage gate falls back to measuring for itself (and fails on the same red suite)
    # rather than silently trusting a truncated report.
    [[ -n "${UNIT_EMIT_COVERAGE:-}" ]] && rm -f "$UNIT_EMIT_COVERAGE"
  fi
fi

if [[ -f frontend/package.json ]] && jq -e '.scripts.test // empty' frontend/package.json >/dev/null 2>&1; then
  checked=$((checked + 1))
  echo "unit: frontend (vitest)"
  if ( cd frontend && npx --no-install vitest run --coverage=false ); then
    echo "  ✓ frontend"
  else
    echo "  ✗ frontend — vitest failed"; fail=1
  fi
fi

if [[ -f mobile/package.json ]] && jq -e '.scripts.test // empty' mobile/package.json >/dev/null 2>&1; then
  checked=$((checked + 1))
  echo "unit: mobile (vitest)"
  if ( cd mobile && npx --no-install vitest run --coverage=false ); then
    echo "  ✓ mobile"
  else
    echo "  ✗ mobile — vitest failed"; fail=1
  fi
fi

# packages/api-client is the shared client imported by BOTH frontend and mobile
# (#1906). It has its own vitest.config.ts and is a project in the root
# vitest.workspace.ts; gate it here alongside the other JS suites.
if [[ -f packages/api-client/package.json ]] && jq -e '.scripts.test // empty' packages/api-client/package.json >/dev/null 2>&1; then
  checked=$((checked + 1))
  echo "unit: api-client (vitest)"
  if ( cd packages/api-client && npx --no-install vitest run --coverage=false ); then
    echo "  ✓ api-client"
  else
    echo "  ✗ api-client — vitest failed"; fail=1
  fi
fi

# extensions/vscode is a shipped surface (FR-VSCODE-001/002/003) that consumes
# GET /ai/micro-lessons + POST /ai/tutor/chat. Its vitest suite existed but was
# run by nothing, so a backend contract change broke it silently (#2023).
if [[ -f extensions/vscode/package.json ]] && jq -e '.scripts.test // empty' extensions/vscode/package.json >/dev/null 2>&1; then
  checked=$((checked + 1))
  echo "unit: vscode extension (vitest)"
  if ( cd extensions/vscode && npx --no-install vitest run --coverage=false ); then
    echo "  ✓ vscode extension"
  else
    echo "  ✗ vscode extension — vitest failed"; fail=1
  fi
fi

# ── The harness's own suites ─────────────────────────────────────────────────────
# `scripts/` is ~20k lines that gate every other change and push to `main` unattended.
# It ships 31 `scripts/*.test.sh` suites; until #2387 this block ran exactly ONE of them
# (release-train) and docs-script-refs.sh ran three more. The other 27 were executed by
# nothing — wedge-coverage only *greps* for their existence. Two had rotted into the red
# without anyone noticing, and C1/C4/H3-class bugs sat in scripts whose suites existed
# and never ran.
#
# The lesson from the single-file version of this block (and from #2023 before it) is
# that an OPT-IN list rots: it records the one suite whoever wrote it cared about, and
# every suite added later is silently ungated. So this is an OPT-OUT list — a new
# `scripts/*.test.sh` is gated the day it lands, and excluding one is a deliberate,
# commented act.
#
# Cost: ~100s wall clock for all 31, no network, no model, no DB, no emulator.
#
# Excluded suites (each needs a REASON, not just a name):
#   (none today — every suite is hermetic and runs here.)
# Set UNIT_SKIP_SHELL_SUITES to a space-separated list of basenames for a local override.
SHELL_SUITE_OPT_OUT=(
  # e.g. "foo.test.sh  # needs a live Docker daemon (issue #NNNN)"
)
if compgen -G 'scripts/*.test.sh' >/dev/null; then
  echo "unit: harness shell suites (scripts/*.test.sh)"
  # Ambient lane configuration (AGENT_SLOT, AGENT_LOGDIR, PR_MERGER_LOCK, …) changes what
  # these suites observe: agent-inbox.test.sh was green on lane 0 and red on lanes 1-2
  # purely because the lane exports AGENT_SLOT (issue #2387). A gate whose result depends
  # on which lane ran it is not a gate. Scrub before running any of them; each suite sets
  # the variables it actually wants explicitly.
  # shellcheck source=scripts/lib/test-env.sh
  source scripts/lib/test-env.sh
  test_env_scrub

  # ── Run them CONCURRENTLY (issue #2412) ───────────────────────────────────────
  # Serially these cost ~155s and dominate the unit gate. They are hermetic by
  # construction — every suite builds its sandbox with `mktemp -d` and points the script
  # under test at it (`PR_LOGDIR="$tmp/logs"`, `PR_MERGER_LOCK="$tmp/mg.lock"`, …) — so
  # nothing they touch is shared between suites and they parallelise cleanly.
  #
  # Two properties are preserved deliberately:
  #   • Output stays in ALPHABETICAL order, not completion order. Buffering each suite to
  #     its own file and reporting after the pool drains keeps the gate log diffable run to
  #     run; interleaved live output would make a two-run comparison useless.
  #   • The per-suite timeout still bounds each suite individually, so one hung suite costs
  #     its own slot rather than the whole gate.
  #
  # UNIT_SHELL_JOBS=1 restores the exact serial behaviour (the escape hatch for bisecting a
  # suite that turns out to be order- or concurrency-sensitive). SHELL_SUITE_SERIAL is the
  # narrower escape hatch: named suites run alone, after the pool, instead of being dropped.
  _nproc="$( (nproc 2>/dev/null || echo 4) )"
  UNIT_SHELL_JOBS="${UNIT_SHELL_JOBS:-8}"
  [[ "$UNIT_SHELL_JOBS" =~ ^[0-9]+$ && "$UNIT_SHELL_JOBS" -ge 1 ]] || UNIT_SHELL_JOBS=8
  (( UNIT_SHELL_JOBS > _nproc )) && UNIT_SHELL_JOBS="$_nproc"

  # Suites that must NOT share the box with another suite. Each needs a REASON.
  #   (none today — all are mktemp-sandboxed.)
  SHELL_SUITE_SERIAL=(
    # e.g. "foo.test.sh  # binds a fixed port (issue #NNNN)"
  )

  _shell_outdir="$(mktemp -d -t skillforge-shellsuites-XXXXXX)"
  # shellcheck disable=SC2064  # expand $_shell_outdir now, not at trap time
  trap "rm -rf '$_shell_outdir'" EXIT

  _run_suite() { # <suite-path> <outfile>  — child; writes output + rc, never touches parent state
    local s="$1" o="$2" r=0
    timeout "${UNIT_SHELL_SUITE_TIMEOUT:-300}" bash "$s" >"$o" 2>&1 || r=$?
    printf '%s' "$r" >"${o}.rc"
  }

  _parallel=() _serial=()
  for suite in scripts/*.test.sh; do
    base="$(basename "$suite")"
    skip_reason=""
    for entry in "${SHELL_SUITE_OPT_OUT[@]:-}"; do
      # entries look like: "name.test.sh  # why it is excluded"
      [[ "${entry%%[[:space:]]*}" == "$base" ]] && skip_reason="${entry#*#}"
    done
    for entry in ${UNIT_SKIP_SHELL_SUITES:-}; do
      [[ "$entry" == "$base" ]] && skip_reason=" local override via UNIT_SKIP_SHELL_SUITES"
    done
    if [[ -n "$skip_reason" ]]; then
      echo "  ⏭ $base — skipped:${skip_reason}"
      continue
    fi
    _is_serial=0
    for entry in "${SHELL_SUITE_SERIAL[@]:-}"; do
      [[ "${entry%%[[:space:]]*}" == "$base" ]] && _is_serial=1
    done
    if (( _is_serial )); then _serial+=("$suite"); else _parallel+=("$suite"); fi
    checked=$((checked + 1))
  done

  echo "  running ${#_parallel[@]} suite(s) at concurrency ${UNIT_SHELL_JOBS}${_serial:+, ${#_serial[@]} serial}"
  _live=0
  for suite in "${_parallel[@]}"; do
    # `wait -n` (bash 4.3+, this repo runs 5.x) returns as soon as ANY child finishes, which
    # keeps every slot busy — unlike `wait` on a batch, which idles until the slowest in the
    # batch completes and wastes most of the parallelism on a long-tailed suite set.
    while (( _live >= UNIT_SHELL_JOBS )); do wait -n 2>/dev/null || true; _live=$((_live - 1)); done
    _run_suite "$suite" "$_shell_outdir/$(basename "$suite")" &
    _live=$((_live + 1))
  done
  wait
  for suite in "${_serial[@]:-}"; do
    [[ -n "$suite" ]] || continue
    _run_suite "$suite" "$_shell_outdir/$(basename "$suite")"
  done

  shell_pass=0; shell_fail=0
  for suite in "${_parallel[@]}" ${_serial[@]+"${_serial[@]}"}; do
    base="$(basename "$suite")"
    out="$(cat "$_shell_outdir/$base" 2>/dev/null)"
    rc="$(cat "$_shell_outdir/${base}.rc" 2>/dev/null || echo 1)"
    if [[ "$rc" == "0" ]]; then
      echo "  ✓ $base — $(printf '%s' "$out" | tail -n1)"
      shell_pass=$((shell_pass + 1))
    else
      shell_fail=$((shell_fail + 1)); fail=1
      if [[ "$rc" == "124" ]]; then
        echo "  ✗ $base — TIMED OUT after ${UNIT_SHELL_SUITE_TIMEOUT:-300}s"
      else
        echo "  ✗ $base — failed (exit $rc):"
        printf '%s\n' "$out" | grep -E '✗|FAIL|Error|error:' | head -15 | sed 's/^/      /'
      fi
    fi
  done
  echo "  harness shell suites: ${shell_pass} passed, ${shell_fail} failed"
fi

if [[ "$checked" -eq 0 ]]; then echo "no unit suites found"; exit 77; fi
exit "$fail"
