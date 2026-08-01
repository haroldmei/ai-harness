#!/usr/bin/env bash
# quality-gates.sh — layered hard quality gate runner for build-product-v2.
#
# Each gate is a separate hard pass. A gate failure exits non-zero with the
# gate name; the orchestrator uses the exit name to route the failure.
#
# Gates whose tooling/inputs are absent return SKIP — UNLESS the gate is
# required for the project's scale tier, in which case SKIP becomes FAIL
# (you can't be "green" on a gate you never actually ran). Tier is read from
# state/state.json .scale_tier; override with --tier or REQUIRED_GATES env.
#
# Override which gates run with --only and --skip:
#
#   scripts/quality-gates.sh --only typecheck,unit
#   scripts/quality-gates.sh --skip mutation,visual
#   scripts/quality-gates.sh --tier launch --json /tmp/gates.json
#
# Stop on first failure by default; --keep-going runs all gates and
# reports at the end. --json writes a machine-readable result array.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root $ROOT" >&2; exit 2; }

# State lives in per-concern shards; `.open_issues` is owned by state/findings.json, not
# state/state.json. gate_repro_tests hard-coded the latter and silently measured 0 issues
# (issue #2387). Resolve every state path through the shard map, per CLAUDE.md.
# shellcheck source=scripts/lib/state-shard.sh
source "$ROOT/scripts/lib/state-shard.sh"
# One shared "why did this gate fail" extractor for quality-gates / verify-loop /
# release-train — this file used to answer it with `tail -n1` (issue #2387, H4).
# shellcheck source=scripts/lib/gate-reason.sh
source "$ROOT/scripts/lib/gate-reason.sh"

# Per-invocation gate-log dir. Was a shared /tmp/qg-<gate>.log, which two concurrent loops
# (e.g. skillforge + ml-builder agent-inbox) clobbered — so a failing gate's REASON line could
# show the other repo's output ("✓ services/data-copilot"). Namespace by PID (override via
# QG_LOGDIR) so each run's logs are its own.
QG_LOGDIR="${QG_LOGDIR:-/tmp/qg-$$}"
mkdir -p "$QG_LOGDIR"

# ---- reproducible test seeds ----
# Pinned so fuzz / property / mutation runs are re-runnable: a failure found in
# CI reproduces locally. Override any via env for a one-off re-roll.
export TEST_SEED="${TEST_SEED:-1337}"
export FAST_CHECK_SEED="${FAST_CHECK_SEED:-$TEST_SEED}"
export STRYKER_SEED="${STRYKER_SEED:-$TEST_SEED}"
export VITEST_SEED="${VITEST_SEED:-$TEST_SEED}"

# ---- argument parsing ----
ONLY=""
SKIP=""
KEEP_GOING=0
JSON_OUT=""
TIER=""
MUTATION_THRESHOLD="${MUTATION_THRESHOLD:-70}"
LIGHTHOUSE_PERF_BUDGET="${LIGHTHOUSE_PERF_BUDGET:-80}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)        ONLY="$2"; shift 2;;
    --skip)        SKIP="$2"; shift 2;;
    --keep-going)  KEEP_GOING=1; shift;;
    --json)        JSON_OUT="$2"; shift 2;;
    --tier)        TIER="$2"; shift 2;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# ---- gate registry (in dependency order) ----
GATES=(typecheck lint docs-refs iteration-immutable seed-integrity migration-drift unit coverage i18n repro-tests mutation integration contract e2e mobile-e2e mobile-perf wedge-coverage journey-coverage a11y lighthouse visual quarantine)

# ---- tier → required gates ----
# A gate in the required set that would otherwise SKIP (tooling/inputs absent)
# is recorded as FAIL instead. This closes the "silently green because nothing
# was wired" hole. Non-required gates keep skip-as-pass.
TIER="${TIER:-$(jq -r '.scale_tier // "preview"' state/state.json 2>/dev/null || echo preview)}"
# skillforge required-gate sets. Every gate is now WIRED with real tooling, so at `launch` the
# full suite is required — a gate that can't run (missing docker/tooling) returns 77 → promoted
# to FAIL, closing the "silently green because nothing was wired" hole. The runnable gates each
# boot their OWN isolated ephemeral stack on a distinct compose project + high port band (never
# the dev DB): integration (scripts/integration.sh, skillforge-itest), e2e (run-e2e.sh,
# skillforge-e2e), lighthouse (run-lighthouse.sh, skillforge-lh), a11y (run-a11y.sh via run-e2e),
# visual (run-visual.sh, skillforge-visual, pinned playwright container), migration-drift
# (migration-check.sh — pg_virtualenv, a reachable Postgres, or an ephemeral docker Postgres on
# skillforge-migdrift), seed-integrity (seed-integrity.sh, opt-in). contract (redocly lint +
# openapi drift diff + schemathesis, all in-process) / coverage / wedge-coverage / journey-coverage /
# mutation run in-process. `quarantine` stays NON-required by design (it only ever reports, never
# gates). `e2e` is launch-runnable but kept required at `scale` only (it overlaps the other
# browser gates).
#
# contract + migration-drift are REQUIRED at launch+ (#1971): both were WIRED but in no required
# set, so on a host missing their tooling they 77-skipped silently and the run stayed green — the
# exact hole this promotion mechanism exists to close (stale openapi.yaml from agent PRs surfaced
# only at release-cut time, e.g. staging-v1.0.31). contract needs npx + the backend venv (launch
# hosts already run npx- and Docker-heavy gates); migration-drift now self-provisions an ephemeral
# docker Postgres when neither pg_virtualenv nor a reachable Postgres exists, so a Docker launch
# host never silently skips it. A genuine drift already hard-fails at ANY tier; the promotion only
# removes the "no Postgres ⇒ silent SKIP" escape.
#
# coverage is REQUIRED at launch+ (#2017): NFR-MAINT-001 asserted an 80% backend coverage floor
# that NOTHING computed (unit.sh runs pytest --no-cov, pyproject declares no --cov-fail-under),
# so coverage could drift down across agent PRs invisibly. The gate is hermetic (backend unit
# suite + --cov=app, no Docker/Postgres, ~40s) and enforces the ratchet floor in
# state/artifacts/coverage-floor.json — see scripts/coverage.sh for why the enforced floor is a
# ratchet seeded at the real measured number rather than the aspirational 80.
#
# i18n is WIRED but deliberately NOT in any required set yet (#2394). It is green today only
# because the 69-key mobile catalog drift is BASELINED in state/artifacts/i18n-baseline.json;
# promoting it to required now would make a launch run's verdict hostage to a known gap this
# gate did not create. Once #2397 clears that drift and the parity exception list ratchets to
# empty, add `i18n` to the launch and scale sets below — that is the whole promotion. Until
# then it still runs on every invocation and still fails on NEW drift, which is the point:
# a non-required gate that FAILS is recorded as a failure and turns the run red like any
# other (see _record_gate_result — only a 77 SKIP is treated differently by requiredness).
#
# Override any of this via the REQUIRED_GATES env. NB: the full launch run boots several Docker
# stacks and is slow (~30-40min) — a no-Docker host fails the required infra gates by design.
declare -A REQUIRED_BY_TIER=(
  [toy]="typecheck lint"
  [preview]="typecheck lint docs-refs iteration-immutable unit"
  [launch]="typecheck lint docs-refs iteration-immutable migration-drift unit coverage integration contract visual mobile-e2e"
  [scale]="typecheck lint docs-refs iteration-immutable migration-drift unit coverage integration contract e2e visual mobile-e2e"
)
# A typo'd --tier used to fall back to the `preview` set, silently running a WEAKER gate
# contract than the one asked for: `--tier lanuch` quietly dropped integration, contract,
# coverage, migration-drift, visual and mobile-e2e and still printed "all gates pass"
# (issue #2387, M8). Fail closed on an unknown tier — the caller mistyped, and guessing
# downward is the one interpretation that can ship red code.
if [[ -z "${REQUIRED_GATES:-}" && -z "${REQUIRED_BY_TIER[$TIER]+set}" ]]; then
  printf 'FATAL: unknown --tier %s (known: %s)\n' "$TIER" "${!REQUIRED_BY_TIER[*]}" >&2
  exit 2
fi
REQUIRED="${REQUIRED_GATES:-${REQUIRED_BY_TIER[$TIER]:-}}"
# Consumed — now drop it, so it cannot be inherited by anything this run spawns.
# The release cuts pass it EXPORTED (`env REQUIRED_GATES=… scripts/quality-gates.sh`), so
# without this it reached every descendant: unit.sh → the shell-suite pool → the CHILD
# quality-gates.sh that quality-gates.test.sh spawns, where it overrode REQUIRED_BY_TIER a
# second time and rewrote the very set that suite asserts. Cases 5/6 (#1971) went red inside
# every mobile cut and nowhere else, and because release-train's transience recheck invokes
# quality-gates.sh WITHOUT the cut wrapper it came back green every time — 20 attempts, each
# one misfiled "transient". A narrowing meant for THIS process must not outlive it.
# test-env.sh scrubs it for the suite pool as well; both layers are deliberate (belt and braces
# for gates that do not route through test_env_scrub).
unset REQUIRED_GATES
is_required() { [[ " $REQUIRED " == *" $1 "* ]]; }

results=()         # "<gate>:<pass|fail|skip>:<reason>"
fail_count=0

# Wall-clock seconds per gate, keyed by gate name. Kept OUT of `results` on purpose: a
# reason string may contain colons (paths, timestamps), and `write_json` already has to
# rejoin `$p[2:]` to survive that — adding a fourth positional field would make the split
# ambiguous. A gate name is unique per run, so an associative array is the unambiguous
# carrier. Empty for a gate that never executed (filtered out).
#
# This exists so gate-runtime work is measurable at all: `_exec_gate` has always tracked
# `start=$SECONDS` for its heartbeat, but nothing ever reported the total, so "did that
# make the suite faster?" could only be answered with a stopwatch (issue #2412).
declare -A GATE_SECONDS=()

# Helper: should we run this gate?
should_run() {
  local name="$1"
  if [[ -n "$ONLY" ]]; then
    [[ ",${ONLY}," == *",${name},"* ]] || return 1
  fi
  if [[ -n "$SKIP" ]]; then
    [[ ",${SKIP}," == *",${name},"* ]] && return 1
  fi
  return 0
}

write_json() {
  [[ -z "$JSON_OUT" ]] && return 0
  # `… > "$JSON_OUT" 2>/dev/null || true` swallowed every jq failure, so a malformed or
  # unwritable scorecard was indistinguishable from an empty one — and the scorecard is what
  # the iteration log and the release train READ to decide whether gates passed (issue #2387,
  # hygiene). Write to a temp file first so a failed jq cannot leave a truncated JSON_OUT that
  # parses as "no gates ran", and say so on stderr when it happens.
  local tmp; tmp="$(mktemp "${JSON_OUT}.XXXXXX" 2>/dev/null)" || {
    echo "WARN: cannot create temp file next to $JSON_OUT — scorecard not written" >&2; return 1; }
  # Durations ride in as a side-channel object rather than a fourth colon-delimited field,
  # for the same reason `reason` is rejoined below: a reason may contain colons. `duration_s`
  # is ADDITIVE — existing consumers (release-train, iteration log) read .gate/.status/.reason
  # and are unaffected. Null for a gate that never executed.
  local durs; durs="$(
    { for _g in "${!GATE_SECONDS[@]}"; do printf '%s\t%s\n' "$_g" "${GATE_SECONDS[$_g]}"; done; } \
      | jq -R -s 'split("\n")|map(select(length>0))|map(./"\t")|map({(.[0]): (.[1]|tonumber)})|add // {}'
  )" || durs='{}'
  if printf '%s\n' "${results[@]}" \
    | jq -R -s --argjson d "${durs:-\{\}}" '
        split("\n") | map(select(length > 0)) | map(
          (. / ":") as $p
          | { gate: $p[0], status: $p[1], reason: ($p[2:] | join(":")), duration_s: $d[$p[0]] }
        )' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$JSON_OUT"
  else
    rm -f "$tmp"
    echo "WARN: failed to write the gate scorecard to $JSON_OUT (jq error) — leaving the previous file untouched" >&2
    return 1
  fi
}

summary() {
  local name status reason r busy=0
  echo
  echo "── Quality gates summary (tier: $TIER) ──"
  for r in "${results[@]}"; do
    IFS=':' read -r name status reason <<< "$r"
    printf '  %-14s %-4s %s  %s\n' "$name" "$status" "$(_dur_col "$name")" "$reason"
    busy=$(( busy + ${GATE_SECONDS[$name]:-0} ))
  done
  echo
  # `busy` is the sum of per-gate wall-clock; `SECONDS` is the run's own wall-clock.
  # Serially they are equal (modulo startup); the gap between them IS the parallel
  # speedup, so printing both makes a scheduling change self-evidencing rather than
  # something you have to stopwatch (issue #2412).
  if (( busy > 0 )); then
    printf '  wall-clock %ss · gate-time %ss' "$SECONDS" "$busy"
    (( SECONDS > 0 )) && printf ' · speedup %s.%sx' $(( busy / SECONDS )) $(( (busy * 10 / SECONDS) % 10 ))
    printf '\n\n'
  fi
  if [[ "$fail_count" -gt 0 ]]; then
    echo "RESULT: $fail_count gate(s) FAILED"
  else
    echo "RESULT: all gates pass"
  fi
  write_json
}

# Render a gate's wall-clock as a fixed-width column so the ✓/✗/· lines stay aligned
# whether or not the gate actually ran (a filtered-out gate has no duration).
_dur_col() { # <gate>
  local s="${GATE_SECONDS[$1]:-}"
  if [[ -z "$s" ]]; then printf '%7s' ''; else printf '%6ss' "$s"; fi
}

record() {
  local name="$1" status="$2" reason="${3:-}"
  results+=("${name}:${status}:${reason}")
  local dur; dur="$(_dur_col "$name")"
  case "$status" in
    pass) printf '  ✓ %-14s %s  %s\n' "$name" "$dur" "$reason";;
    fail) printf '  ✗ %-14s %s  %s\n' "$name" "$dur" "$reason"; ((fail_count++));;
    skip) printf '  · %-14s %s  SKIP — %s\n' "$name" "$dur" "$reason";;
  esac
  if [[ "$status" == "fail" && "$KEEP_GOING" -eq 0 ]]; then
    summary
    exit 1
  fi
}

# Recursively SIGKILL a process and ALL its descendants. A bare `kill <pid>`
# orphans the grandchildren that vitest (worker pool) and e2e (docker compose)
# spawn — exactly the processes that wedge a gate — so a timeout must walk the
# tree.
_kill_tree() {
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do _kill_tree "$c"; done
  kill -9 "$p" 2>/dev/null
}

# Execute a gate fn with its output captured to $logf, emitting a throttled
# heartbeat (elapsed time + latest log line) while it runs, and enforcing a HARD
# timeout. The slow phase (mutation/integration/e2e — boots the Docker stack,
# tens of minutes) otherwise goes dark between "running…" and the final ✓/✗; the
# heartbeat surfaces the milestones the gate already logs (alembic upgrades, seed
# counts, Playwright [N/150]). Fast gates finish before the first tick, so they
# print nothing extra. The timeout turns a HUNG gate (e.g. vitest workers that
# never exit at end-of-run) into a clean FAIL instead of wedging the whole run —
# and the merger — forever.
# Tunables: QG_PROGRESS=0 silences the heartbeat; QG_PROGRESS_INTERVAL sets its
# cadence (s); QG_GATE_TIMEOUT caps per-gate wall-clock (default 3600s, 0=off —
# generous enough for a ~30-40min e2e, tight enough to catch an infinite hang).
_exec_gate() {
  local fn="$1" logf="$2" name="$3"
  local interval="${QG_PROGRESS_INTERVAL:-30}" timeout_s="${QG_GATE_TIMEOUT:-3600}"
  "$fn" >"$logf" 2>&1 &
  local pid=$! start=$SECONDS next="$interval" rc last el
  # Forward Ctrl-C / termination to the backgrounded gate (whole tree).
  trap '_kill_tree "$pid" 2>/dev/null' INT TERM
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    el=$(( SECONDS - start ))
    if (( timeout_s > 0 && el >= timeout_s )); then
      _kill_tree "$pid"
      wait "$pid" 2>/dev/null
      trap - INT TERM
      GATE_SECONDS["$name"]=$el
      printf '    ⏱ %-14s TIMED OUT after %ds — killed (raise QG_GATE_TIMEOUT)\n' "$name" "$timeout_s"
      echo "gate '$name' timed out after ${timeout_s}s — killed (hung?)" >>"$logf"
      return 124
    fi
    if [[ "${QG_PROGRESS:-1}" == "1" ]] && (( el >= next )); then
      next=$(( next + interval ))
      last="$(tail -n1 "$logf" 2>/dev/null | tr -d '\r' | cut -c1-90)"
      printf '    ⏳ %-14s %02d:%02d  %s\n' "$name" $(( el / 60 )) $(( el % 60 )) "${last:-…}"
    fi
  done
  wait "$pid"; rc=$?
  trap - INT TERM
  GATE_SECONDS["$name"]=$(( SECONDS - start ))
  return "$rc"
}

# Gate functions return:  0 pass | 77 skip (no tooling/inputs) | other fail.
# A 77 on a tier-required gate is promoted to FAIL.
# ── Inherited-red baseline (scripts/red-baseline.sh) ─────────────────────────────
# Only the whole-suite gates participate. typecheck already has its own baseline
# (mypy-baseline.txt); the rest are cheap, deterministic, or not test-shaped.
RED_BASELINE_GATES="${RED_BASELINE_GATES:-unit e2e integration}"
_red_baseline_enabled() { # <gate>
  [[ "${RED_BASELINE:-1}" == 1 ]] || return 1
  [[ -x "$ROOT/scripts/red-baseline.sh" ]] || return 1
  [[ " $RED_BASELINE_GATES " == *" $1 "* ]]
}

# True when this tree IS the base commit — i.e. the run is measuring the base itself
# (the pr-merger's post-merge gate on main, a nightly, a human on a clean main). Only
# such a run may define what "already red on the base" means; a run on a feature
# branch is measuring the branch and must never overwrite the baseline with it.
_is_base_tree() {
  local head base
  head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || return 1
  base="$(RED_BASELINE_ROOT="$ROOT" "$ROOT/scripts/red-baseline.sh" path --gate _ 2>/dev/null)" || return 1
  base="$(basename "$base")"; base="${base%%-*}"
  [[ -n "$head" && "$head" == "$base" ]]
}

# Called after a gate FAILS. Exit 0 (forgive) only when a baseline exists for this
# exact base commit AND every failing test id in this log is already in it.
_red_baseline_forgives() { # <gate> <logfile>
  local gate="$1" logf="$2" new
  _red_baseline_enabled "$gate" || return 1
  # A run ON the base defines the baseline; it must never forgive itself, or a red
  # base would record its own failures and immediately report green.
  if _is_base_tree; then
    RED_BASELINE_ROOT="$ROOT" "$ROOT/scripts/red-baseline.sh" \
      record --gate "$gate" --log "$logf" 2>&1 | sed 's/^/  /' || true
    return 1
  fi
  new="$(RED_BASELINE_ROOT="$ROOT" "$ROOT/scripts/red-baseline.sh" \
           diff --gate "$gate" --log "$logf" 2>/dev/null)"
  case $? in
    0) printf '  ⚑ %-14s every failure is already red on the base commit — not charged to this branch\n' "$gate"
       return 0;;
    1) printf '  ⚑ %-14s %s NEW failure(s) above the base baseline:\n' "$gate" "$(printf '%s\n' "$new" | grep -c .)"
       printf '%s\n' "$new" | head -10 | sed 's/^/      • /'
       return 1;;
    *) return 1;;   # 2 = no baseline for this sha ⇒ unknown ⇒ fail closed
  esac
}

run_gate() {
  local name="$1" fn="$2"
  if ! should_run "$name"; then
    # --only and --skip express OPPOSITE intents, so a required gate they exclude is treated
    # differently:
    #   --only X,Y  is an explicit ALLOW-LIST — the caller is deliberately scoping THIS run to a
    #               named subset (the heavy gates run elsewhere: a separate full-tier pass, the
    #               pr-merger, a nightly). A required gate simply not named here is an honest SKIP.
    #   --skip Z    is a DENY-LIST that removes a gate from an otherwise-full run — the classic
    #               "dodge the hard gate" move. Removing a REQUIRED gate this way must never go
    #               green (same "silently green because it never ran" hole the 77→FAIL promotion
    #               closes, reached via a flag). That is recorded as FAIL.
    # NB: the deployed agent units run `--only unit,e2e --tier launch` on purpose; without this
    # split that legitimate scoping fails closed on every build and wedges the whole pipeline.
    if is_required "$name" && [[ -n "$SKIP" && ",${SKIP}," == *",${name},"* ]]; then
      record "$name" fail "REQUIRED for tier '$TIER' but removed via --skip"
    else
      record "$name" skip "filtered out"
    fi
    return 0
  fi
  local logf="$QG_LOGDIR/${name}.log" rc
  printf '  ▶ %-14s running… (log: %s)\n' "$name" "$logf"
  _exec_gate "$fn" "$logf" "$name"; rc=$?
  _record_gate_result "$name" "$rc" "$logf"
}

# Turn a finished gate's exit code into a recorded verdict. Split out of run_gate so the
# serial and concurrent dispatchers share ONE implementation of the 77-promotion, the
# red-baseline forgiveness and the reason extraction — three subtle rules that must not
# drift between two copies.
_record_gate_result() { # <gate> <rc> <logfile>
  local name="$1" rc="$2" logf="$3" reason
  # For pass/skip the gate's own last line IS the summary it chose to print ("no unit
  # suites found", "all 76 open issue(s) carry a repro test") — keep it.
  #
  # For a FAILURE it is the wrong line. A gate script's last output is typically its final
  # per-suite banner, so `tail -n1` reported things like
  #     unit  fail  see …/unit.log —  ✓ release-train guards
  # i.e. a PASSING check named as the reason a gate failed. That string propagates into
  # escalation issues, PR comments and the auto-fixer's brief, so the fixer was briefed to
  # fix something that had passed (issue #2387, H4). Pull the diagnosing line instead, via
  # the same extractor verify-loop.sh and release-train.sh use.
  reason="$(tail -n1 "$logf" 2>/dev/null)"
  # A suite gate that failed ONLY on tests already red on the base commit is judged
  # green: the branch added nothing. Same principle as mypy-baseline on typecheck.
  # See scripts/red-baseline.sh for why (the #2381→#2385 auto-filing cascade) and for
  # the fail-closed rules — no baseline for this exact base sha, or a failure with no
  # extractable test id, both leave the gate red.
  if [[ "$rc" != 0 && "$rc" != 77 ]] && _red_baseline_forgives "$name" "$logf"; then
    record "$name" pass "inherited red base — no NEW failures (see $logf)"
    return 0
  fi
  case "$rc" in
    0)  record "$name" pass "${reason:-ok}";;
    77) if is_required "$name"; then
          record "$name" fail "REQUIRED for tier '$TIER' but unavailable — ${reason:-no inputs}"
        else
          record "$name" skip "${reason:-not configured}"
        fi;;
    *)  record "$name" fail "see $logf — $(gate_reason_summary "$logf")";;
  esac
}

# ── Concurrent gate scheduling (issue #2412) ──────────────────────────────────────
# The dispatch loop ran one gate at a time on a 32-thread host, so the suite cost the SUM
# of every gate (~514s measured) when it only needed the longest chain. Gates are already
# isolated from each other by construction — each stack gate owns a distinct compose
# project, its own named volumes and a lock file keyed on that project, and picks host
# ports by probing from its own base — so the blocker was the loop, not the gates.
#
# Two resource classes, each with its own budget:
#   cpu   — no ports, no docker, no shared DB. Bounded by QG_CPU_JOBS.
#   stack — boots containers. Bounded by QG_STACK_JOBS, which is the one that matters:
#           #2178 measured a Postgres container reaching "listening" in ~1.3s idle but
#           ~8.1s with sixteen alive, and integration ALONE runs up to 16 xdist workers.
#           Two concurrent stacks is the conservative default; raising it re-enters the
#           starvation regime that produced the ConnectionRefusedError cascade.
#
# QG_PARALLEL=0 restores the original serial dispatch byte for byte — kept as the escape
# hatch AND because the serial path is what the existing filtering tests exercise.
QG_PARALLEL="${QG_PARALLEL:-1}"
QG_CPU_JOBS="${QG_CPU_JOBS:-3}"
QG_STACK_JOBS="${QG_STACK_JOBS:-2}"

# Gates that boot containers / bind ports. Mirrors the list _qg_run_needs_stack already
# uses to decide whether the run needs the stack mutex at all, plus the two ephemeral-PG
# gates (migration-drift, seed-integrity) which that list omits because they are cheap —
# cheap or not, they hold a docker project and must be counted here.
_QG_STACK_CLASS="integration e2e mobile-e2e mobile-perf lighthouse visual a11y mutation migration-drift seed-integrity"
_gate_class() { case " $_QG_STACK_CLASS " in *" $1 "*) echo stack;; *) echo cpu;; esac; }

# Gates that must not START until another gate has finished. One real edge today:
# `coverage` consumes the report `unit` writes (see the handoff above). Without the
# ordering the artifact simply is not there yet and coverage silently falls back to
# re-running the suite — correct, but it gives back the whole saving.
_gate_after() { case "$1" in coverage) echo unit;; *) echo "";; esac; }

# A docker-compose project name unique to (this run's slot, this gate). Several gates
# delegate to run-e2e.sh, which derives its container namespace, its volumes AND its lock
# file from $E2E_PROJECT — so gates that share the value share a mutex, which is fatal once
# gates run concurrently. Suffixing the ambient value (already slot-qualified in multi-slot
# mode) keeps per-slot isolation and adds per-gate isolation on top.
_stack_project() { printf '%s-%s' "${E2E_PROJECT:-skillforge-e2e}" "$1"; }

# ---- gate implementations ----
gate_typecheck() {
  # Project hook: scripts/typecheck.sh runs tsc in every service (the repo root has
  # no tsconfig, so the bare `tsc` below would skip and miss per-service TS errors).
  if [[ -x scripts/typecheck.sh ]]; then
    scripts/typecheck.sh
    return $?
  fi
  if [[ -f tsconfig.json ]]; then
    npx --yes tsc --noEmit
  elif command -v mypy >/dev/null && [[ -d src ]]; then
    mypy src
  else
    echo "no typechecker configured"; return 77
  fi
}

gate_lint() {
  # Project hook: scripts/lint.sh lints backend (ruff) + frontend (eslint).
  if [[ -x scripts/lint.sh ]]; then
    scripts/lint.sh
    return $?
  fi
  if [[ -f .eslintrc.js || -f .eslintrc.json || -f eslint.config.js || -f eslint.config.mjs ]]; then
    npx --yes eslint . --max-warnings=0
  elif command -v ruff >/dev/null; then
    ruff check .
  else
    echo "no linter configured"; return 77
  fi
}

gate_seed_integrity() {
  # Verifies db-migrator's manifest against the filesystem and (optionally)
  # against a live database. Catches the "phantom artifact" failure mode
  # where the skill's decision-record claims a seed/migration/compose file
  # that was never actually written.
  #
  # Hard checks (always run):
  #   1. Every required entry in manifest.files exists on disk.
  #   2. Every entry in manifest.package_scripts has a key in package.json#scripts.
  #
  # Runtime checks (opt-in via SEED_INTEGRITY_RUNTIME=1, requires DATABASE_URL):
  #   3. boot_command runs cleanly.
  #   4. Each table in seed_expectations.tables has rows >= min_rows.
  #   5. Re-running seed_command leaves row counts unchanged (idempotency).

  local manifest="state/artifacts/db-migrator.json"
  if [[ ! -f "$manifest" ]]; then
    echo "no manifest at $manifest (db-migrator may not have run yet)"
    return 77   # skip (promoted to fail if seed-integrity is tier-required)
  fi

  # Full runtime check on an ISOLATED ephemeral DB (opt-in via SEED_INTEGRITY_FULL=1): delegate
  # to scripts/seed-integrity.sh, which boots its own throwaway Postgres on a high port band and
  # runs boot_command + row-count + idempotency. Off by default so the launch gate stays green on
  # the static file/script checks below until the runtime path is validated end-to-end. The
  # sentinel stops re-entry; absent docker also falls through to the static checks.
  if [[ "${SEED_INTEGRITY_FULL:-0}" == "1" && -z "${DATABASE_URL:-}" && -z "${_SEED_INTEGRITY_PROVISIONED:-}" \
        && -x scripts/seed-integrity.sh ]] \
     && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    _SEED_INTEGRITY_PROVISIONED=1 scripts/seed-integrity.sh
    return $?
  fi
  if ! command -v jq >/dev/null; then
    echo "jq not installed; cannot parse manifest"
    return 1
  fi

  # 1. File existence
  local missing_files=""
  while IFS=$'\t' read -r path kind min_entries; do
    [[ -z "$path" ]] && continue
    if [[ "$kind" == "dir" ]]; then
      if [[ ! -d "$path" ]]; then
        missing_files+="  - $path (dir)"$'\n'
      elif [[ -n "$min_entries" && "$min_entries" != "null" ]]; then
        local n
        n=$(find "$path" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
        if [[ "$n" -lt "$min_entries" ]]; then
          missing_files+="  - $path: $n entries < min_entries=$min_entries"$'\n'
        fi
      fi
    else
      [[ -e "$path" ]] || missing_files+="  - $path"$'\n'
    fi
  done < <(jq -r '(.files // []) | map(select(.required != false))[] | [.path, (.kind // "file"), (.min_entries // "null")] | @tsv' "$manifest")

  if [[ -n "$missing_files" ]]; then
    echo "manifest claims files that do not exist:"
    echo "$missing_files"
    return 1
  fi

  # 2. package.json scripts
  if [[ -f package.json ]]; then
    local missing_scripts=""
    while read -r script; do
      [[ -z "$script" ]] && continue
      jq -e ".scripts.\"$script\"" package.json >/dev/null 2>&1 \
        || missing_scripts+="  - $script"$'\n'
    done < <(jq -r '(.package_scripts // [])[]' "$manifest")

    if [[ -n "$missing_scripts" ]]; then
      echo "manifest claims package.json scripts that do not exist:"
      echo "$missing_scripts"
      return 1
    fi
  fi

  # 3-5. Runtime checks (opt-in)
  if [[ "${SEED_INTEGRITY_RUNTIME:-0}" != "1" ]]; then
    echo "manifest valid (file/script existence). Set SEED_INTEGRITY_RUNTIME=1 with a live DATABASE_URL for full row-count + idempotency checks."
    return 0
  fi

  if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "SEED_INTEGRITY_RUNTIME=1 requires DATABASE_URL"
    return 1
  fi
  if ! command -v psql >/dev/null; then
    echo "SEED_INTEGRITY_RUNTIME=1 requires psql on PATH"
    return 1
  fi

  # 3. boot_command
  local boot_cmd
  boot_cmd=$(jq -r '.boot_command // empty' "$manifest")
  if [[ -n "$boot_cmd" ]]; then
    echo "running boot_command: $boot_cmd"
    bash -c "$boot_cmd" || { echo "boot_command failed"; return 1; }
  fi

  # 4. Row count assertions
  local row_fail=""
  while IFS=$'\t' read -r name min query; do
    [[ -z "$name" ]] && continue
    [[ "$query" == "null" || -z "$query" ]] && query="SELECT COUNT(*) FROM \"$name\""
    local count
    count=$(psql "$DATABASE_URL" -tAc "$query" 2>/dev/null | tr -d ' ')
    [[ -z "$count" ]] && count=0
    if [[ "$count" -lt "$min" ]]; then
      row_fail+="  - $name: $count rows < manifest min_rows=$min"$'\n'
    fi
  done < <(jq -r '(.seed_expectations.tables // [])[] | [.name, (.min_rows | tostring), (.count_query // "null")] | @tsv' "$manifest")

  if [[ -n "$row_fail" ]]; then
    echo "seed produced fewer rows than manifest promises:"
    echo "$row_fail"
    return 1
  fi

  # 5. Idempotency
  local seed_cmd
  seed_cmd=$(jq -r '.seed_command // empty' "$manifest")
  if [[ -n "$seed_cmd" ]] && jq -e '.seed_expectations.idempotent == true' "$manifest" >/dev/null; then
    # Capture pre-rerun counts
    local pre_counts post_counts
    pre_counts=$(jq -r '(.seed_expectations.tables // [])[] | [.name, (.count_query // "null")] | @tsv' "$manifest" \
      | while IFS=$'\t' read -r name query; do
          [[ "$query" == "null" || -z "$query" ]] && query="SELECT COUNT(*) FROM \"$name\""
          printf '%s:%s\n' "$name" "$(psql "$DATABASE_URL" -tAc "$query" 2>/dev/null | tr -d ' ')"
        done)
    bash -c "$seed_cmd" || { echo "second seed_command run failed"; return 1; }
    post_counts=$(jq -r '(.seed_expectations.tables // [])[] | [.name, (.count_query // "null")] | @tsv' "$manifest" \
      | while IFS=$'\t' read -r name query; do
          [[ "$query" == "null" || -z "$query" ]] && query="SELECT COUNT(*) FROM \"$name\""
          printf '%s:%s\n' "$name" "$(psql "$DATABASE_URL" -tAc "$query" 2>/dev/null | tr -d ' ')"
        done)
    if [[ "$pre_counts" != "$post_counts" ]]; then
      echo "seed is not idempotent — row counts changed on second run"
      diff <(echo "$pre_counts") <(echo "$post_counts") || true
      return 1
    fi
  fi

  return 0
}

# migration-drift — model⇄migration drift gate (issue #194, root cause of #152).
# Applies the full Alembic history to a SCRATCH Postgres, then asserts no model
# table/column exists without a migration (or vice-versa). Self-provisions a
# cluster in preference order: pg_virtualenv → a reachable Postgres → an ephemeral
# docker Postgres (skillforge-migdrift, #1971). A genuine drift returns 1 → hard
# FAIL regardless of tier. REQUIRED at launch+ (#1971): the docker fallback means a
# Docker host always HAS a Postgres, so the old "no Postgres ⇒ silent SKIP" escape
# (which let stale schemas ride to release-cut time) is closed. It SKIPs (77 →
# promoted to FAIL when required) only on a host with none of the three — set
# MIGRATION_DRIFT_NO_DOCKER=1 to force the skip on a Docker host that can't spare it.
# docs-refs (#1984): the harness docs and the scripts tree must agree. CLAUDE.md is binding
# convention every agent follows verbatim, so a rule citing a deleted file makes every agent do
# something broken. 7d418560 deleted scripts/lib/{state-shard,agent-trace}.sh while CLAUDE.md kept
# mandating both and six shipped scripts kept sourcing them — the whole state + telemetry surface
# was dead for days and no gate noticed. Pure bash, no infra, runs in <1s: REQUIRED at every tier
# above toy, since a gate this cheap has no excuse to be optional.
gate_docs_refs() {
  if [[ -x scripts/docs-script-refs.sh ]]; then
    scripts/docs-script-refs.sh
    return $?
  fi
  echo "no docs-script-refs script"; return 77
}

# iteration-immutable (#2167) — reject PRs that modify existing iteration files.
# Each iteration file is a distinct path; when two concurrent branches create
# different files they merge trivially. Modifying an existing file is what
# reintroduces the conflict — block it. Pure git, no infra, <1s.
gate_iteration_immutable() {
  if [[ -x scripts/iteration-immutable-check.sh ]]; then
    scripts/iteration-immutable-check.sh
    return $?
  fi
  echo "no iteration-immutable-check script"; return 77
}

gate_migration_drift() {
  if [[ -x scripts/migration-check.sh ]]; then
    scripts/migration-check.sh
    return $?
  fi
  echo "no migration-check script"; return 77
}

gate_unit() {
  # Project hook: scripts/unit.sh runs `npm test` in every service (the repo root has
  # no package.json, so the bare `npm test` below errored ENOENT and — with --silent —
  # failed with an EMPTY log on every run). Mirrors gate_typecheck.
  if [[ -x scripts/unit.sh ]]; then
    scripts/unit.sh
    return $?
  fi
  if [[ -f vitest.config.ts || -f vitest.config.js ]]; then
    npx --yes vitest run --reporter=verbose
  elif [[ -f jest.config.js || -f jest.config.ts ]]; then
    npx --yes jest --ci
  elif [[ -f pyproject.toml ]] && grep -q pytest pyproject.toml; then
    pytest -q
  else
    npm test --silent || return 1
  fi
}

gate_mutation() {
  # Project hook: scripts/mutation.sh runs BOTH halves (backend mutmut + frontend
  # Stryker), each scored and gated independently against MUTATION_THRESHOLD, and
  # persists the MIN of the two. Mirrors typecheck/lint/unit. The bare stryker-only
  # path below is the fallback for non-skillforge repos (single JS service).
  if [[ -x scripts/mutation.sh ]]; then
    MUTATION_THRESHOLD="$MUTATION_THRESHOLD" scripts/mutation.sh
    return $?
  fi
  if [[ ! -f stryker.conf.js && ! -f stryker.conf.json && ! -f stryker.config.json ]]; then
    echo "stryker not configured"; return 77   # skip (promoted to fail at launch+)
  fi
  npx --yes stryker run --maxConcurrentTestRunners=2 || true
  # Parse score from reports/mutation/mutation.json if present.
  if [[ -f reports/mutation/mutation.json ]]; then
    local score
    score=$(node -e "
      const r = require('./reports/mutation/mutation.json');
      const f = r.metrics?.mutationScore ?? r.systemUnderTestMetrics?.metrics?.mutationScore;
      if (f === undefined) { console.error('no score'); process.exit(1); }
      console.log(Math.round(f));
    ")
    # Persist for the test-loop driver / Governance view.
    "$ROOT/scripts/state-set.sh" '.testing.last_mutation_score' "$score" >/dev/null 2>&1 || true
    echo "mutation score: $score (threshold $MUTATION_THRESHOLD)"
    [[ "$score" -ge "$MUTATION_THRESHOLD" ]]
  else
    echo "stryker ran but produced no score report"; return 1
  fi
}

gate_integration() {
  # Project hook: scripts/integration.sh runs backend pytest tests/integration against an
  # ISOLATED ephemeral Postgres it boots itself (own compose project + high port band — never
  # the dev DB on :5432). Auto-enable that bring-up (ITEST_LOCAL_STACK=1) so the gate actually
  # runs the suite. integration is launch-required, so on a host WITHOUT docker integration.sh
  # returns 77 → promoted to FAIL (you can't be green on a gate you never ran). The per-test
  # timeout is set inside integration.sh (override via ITEST_TIMEOUT).
  if [[ -x scripts/integration.sh ]]; then
    ITEST_LOCAL_STACK="${ITEST_LOCAL_STACK:-1}" scripts/integration.sh
    return $?
  fi
  if [[ -d tests/integration ]]; then
    npx --yes vitest run tests/integration --reporter=verbose
  elif [[ -d e2e ]] && grep -q '"test:integration"' package.json 2>/dev/null; then
    npm run test:integration
  else
    echo "no integration suite"; return 77
  fi
}

gate_contract() {
  [[ -f openapi.yaml ]] || { echo "no openapi.yaml (run: cd backend && python scripts/dump_openapi.py)"; return 77; }
  # 1. Structural validity (redocly.yaml tunes the ruleset for a generated FastAPI spec).
  npx --yes @redocly/cli lint openapi.yaml || return 1
  # 2. Drift guard: the committed spec must match the app's generated schema (no root
  #    package.json here, so contract tests live in the backend, not an npm script).
  if [[ -x scripts/openapi-check.sh ]]; then
    scripts/openapi-check.sh || return 1
  fi
  # 3. Contract test suite (schemathesis-backed completeness + live /health conformance).
  if [[ -d backend/tests/contract ]]; then
    ( cd backend && python -m pytest tests/contract -q --no-cov -p no:cacheprovider ) || return 1
  fi
  echo "contract: spec valid, in sync with app, and contract tests pass"
}

gate_e2e() {
  # Project hook: scripts/run-e2e.sh boots+seeds the real stack and runs the @live
  # Playwright suite. Required when the specs assert against a running backend —
  # `npx playwright test` with no stack runs 0 tests and passes vacuously.
  if [[ -x scripts/run-e2e.sh ]]; then
    scripts/run-e2e.sh
    return $?
  fi
  if [[ -f playwright.config.ts || -f playwright.config.js ]]; then
    npx --yes playwright test
  else
    echo "no playwright config"; return 77
  fi
}

gate_mobile_e2e() {
  # Validates that Maestro e2e flows exist and config.yaml is consistent, then
  # (issue #1970) actually executes them.
  #
  # DESIGN DECISION (2026-07-19): the emulator-based GHA workflow
  # (.github/workflows/mobile-e2e.yml) was deliberately retired in 48992e99
  # (2026-07-16) — emulator runners were slow, flaky, and expensive — and it
  # must NOT be reintroduced. Before phase 2 below existed, the 26 Maestro flows
  # executed nowhere but this static gate; #1970 restored a real execution path
  # inside the repo gate spine instead of resurrecting the GHA workflow.
  #
  # Two-phase mobile e2e gate:
  #   1) STATIC preflight (cheap, ALWAYS runs) — every flow referenced in
  #      config.yaml exists, each flow's YAML parses, `maestro validate` passes,
  #      and the store-submission preflight unit tests pass. Catches broken flow
  #      definitions before an expensive emulator boot.
  #   2) RUNTIME execution (scripts/run-mobile-e2e.sh, mirroring gate_e2e →
  #      scripts/run-e2e.sh) — boots the hermetic mock server (mobile/e2e/
  #      mock-server.ts, :8099) and runs `maestro test .maestro` against a build
  #      installed on a booted emulator/simulator. Disabled by default; opt in with
  #      MOBILE_E2E_LOCAL=1. Returns 77 (SKIP) when maestro / a booted device are
  #      absent so infra-less hosts don't false-fail. mobile-e2e is tier-required
  #      (launch+scale); on a host without MOBILE_E2E_LOCAL=1 (or without an
  #      emulator/maestro) phase 2's SKIP is promoted to FAIL like any other
  #      required gate that never ran — set REQUIRED_GATES to exclude mobile-e2e
  #      (or export MOBILE_E2E_LOCAL=1 with an emulator booted) to avoid that on
  #      hosts that can't run an emulator.
  #
  # See docs/mobile-e2e-ci.md for the real execution path and
  # docs/MOBILE-RELEASE-CHECKLIST.md for the manual fallback when no emulator
  # host is available.
  #
  # Use --skip mobile-e2e to bypass this gate in emergency situations.
  local maestro_dir="mobile/.maestro"
  if [[ ! -d "$maestro_dir" ]]; then
    echo "no mobile Maestro flows at $maestro_dir"; return 77
  fi
  if [[ ! -f "$maestro_dir/config.yaml" ]]; then
    echo "mobile/.maestro/config.yaml not found"; return 1
  fi

  local errors=0

  # Verify every flow referenced in config.yaml exists on disk.
  # Flows are listed as YAML list items under the 'flows:' key.
  while IFS= read -r flow; do
    [[ -z "$flow" ]] && continue
    if [[ ! -f "$maestro_dir/$flow" ]]; then
      echo "config.yaml references '$flow' — file not found"
      errors=$((errors + 1))
    fi
  done < <(sed -n '/^flows:/,/^[a-zA-Z]/p' "$maestro_dir/config.yaml" \
           | grep -E '^\s+-\s+' | sed 's/^\s*-\s*//')

  # Verify YAML syntax of all flow files (best-effort — Maestro uses a lenient
  # YAML parser that supports inline commands inside runFlow blocks, which
  # standard PyYAML rejects. We try to validate, but only report errors from
  # Maestro's own validator (if the CLI is available).
  if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
    local yaml_errors=0
    while IFS= read -r -d '' f; do
      if ! python3 -c "
import yaml, sys
with open(sys.argv[1]) as fh:
    raw = fh.read()
# Maestro uses YAML document separators (---) between frontmatter and
# flow commands. Some files use inline commands inside runFlow blocks
# which standard YAML parsers reject. We skip files for which safe_load
# fails with a known Maestro-specific error (mixed mapping/sequence).
parts = raw.split('---')
for i, part in enumerate(parts):
    part = part.strip()
    if not part:
        continue
    try:
        yaml.safe_load(part)
    except yaml.YAMLError as e:
        # Maestro supports inline commands under runFlow (e.g.
        # - runFlow:\n    when:\n      ...\n    - command)
        # This is not valid standard YAML but Maestro handles it.
        # Only fail on syntax errors unrelated to this pattern.
        msg = str(e)
        if 'expected <block end>' in msg and 'mapping' in msg:
            continue  # likely Maestro inline-commands extension
        sys.exit(1)
" "$f" 2>/dev/null; then
        echo "warning: YAML syntax may not be portable: $(basename "$f")"
        yaml_errors=$((yaml_errors + 1))
      fi
    done < <(find "$maestro_dir" -name '*.yaml' ! -name 'config.yaml' -type f -print0)
    if [[ "$yaml_errors" -gt 0 ]]; then
      echo "YAML warnings: $yaml_errors file(s) use Maestro-specific syntax (non-fatal)"
    fi
  fi

  # NB: Maestro 2.x REMOVED the `maestro validate` subcommand (it errors with
  # "Unmatched arguments … Did you mean: test"). Static validation therefore
  # relies on the config-reference + YAML-parse checks above; real flow execution
  # is the runtime path (scripts/run-mobile-e2e.sh → `maestro test`, gated behind
  # MOBILE_E2E_LOCAL=1). An earlier `maestro validate --config …` call here failed
  # on every host that actually had the CLI installed.

  if [[ "$errors" -gt 0 ]]; then
    echo "$errors Maestro validation error(s) found"; return 1
  fi

  # Store-submission preflight unit tests (#1900/#1924). Guards the enforcement
  # wiring that blocks `eas submit` until real App Store Connect / Google Play
  # credentials are provisioned — a human gate (docs/49-mobile-store-submission.md
  # §7). These pure-shell tests have no other home in the repo gate spine, so run
  # them here alongside the other static mobile-config validation.
  if [[ -f mobile/scripts/test-check-submit-config.sh ]]; then
    bash mobile/scripts/test-check-submit-config.sh || return 1
  fi

  # run-mobile-e2e.sh skip/run-semantics tests (#1970). Pure-shell, no emulator
  # needed — they guard the 77-on-missing-infra contract the runtime phase below
  # relies on (a regression there would false-FAIL infra-less hosts or mask a
  # real failure). Like the submit-config test, they have no other home in the
  # repo gate spine, so run them here in the static preflight.
  if [[ -f scripts/test-run-mobile-e2e.sh ]]; then
    bash scripts/test-run-mobile-e2e.sh || return 1
  fi

  local count
  count=$(find "$maestro_dir" -name '*.yaml' ! -name 'config.yaml' -type f | wc -l)
  echo "Maestro flows validated ($count flow files, config consistent)"

  # ── Phase 2: runtime execution ───────────────────────────────────────────────
  # Delegate to the project hook (like gate_e2e → run-e2e.sh). It boots the
  # hermetic mock server and runs the Maestro flows on a device, returning
  # maestro's exit code — or 77 (SKIP) when the emulator/maestro prerequisites are
  # absent or MOBILE_E2E_LOCAL!=1, so an infra-less host records SKIP (not a false
  # PASS on static validation alone, and not a false FAIL). Its per-gate wall-clock
  # is capped by QG_GATE_TIMEOUT via _exec_gate.
  if [[ -x scripts/run-mobile-e2e.sh ]]; then
    scripts/run-mobile-e2e.sh
    return $?
  fi
  echo "mobile-e2e: no runtime runner (scripts/run-mobile-e2e.sh) — static validation only"
}

gate_mobile_perf() {
  # MOB-150 performance budget validation gate.
  #
  # Reads measurement artifacts from mobile/artifacts/ and enforces budgets.
  # The measurements are produced by mobile/scripts/run-perf-measurements.sh
  # (bundle size + emulator metrics); this gate validates that the artifacts exist
  # and that measured values are within their configured budgets.
  #
  # Emulator-dependent measurements (cold start, tutor latency, video start) skip
  # gracefully when no artifacts exist — only bundle size is required.
  #
  # Deliberately NOT in any REQUIRED_BY_TIER set: the measurement artifacts are
  # produced by an emulator run (mobile/scripts/run-perf-measurements.sh), so
  # mobile/artifacts/ is normally absent locally and a required gate would promote
  # that 77-skip to FAIL on every local run. This gate enforces the budgets only
  # when the artifacts are present (e.g. after running the measurement scripts on
  # a host with an emulator).
  #
  # Use --skip mobile-perf to bypass this gate in emergency situations.
  if [[ ! -f mobile/performance-budgets.json ]]; then
    echo "no mobile performance budgets at mobile/performance-budgets.json"; return 77
  fi
  if [[ ! -f mobile/scripts/perf-validate.sh ]]; then
    echo "no perf-validate.sh script found"; return 77
  fi

  # Unit tests for perf-validate.sh's own helper functions (get_previous()) —
  # run before the real gate so a broken helper fails loudly instead of just
  # silently mis-scoring deltas.
  if [[ -f mobile/tests/perf-validate-unit.test.sh ]]; then
    bash mobile/tests/perf-validate-unit.test.sh || return 1
  fi

  # Smoke-test the trend-dashboard CLIs (issue #1913) — append/prune + render +
  # PR-delta. Pure-lib logic is covered by vitest; this guards the node CLIs.
  if [[ -f mobile/tests/perf-dashboard-cli.test.sh ]]; then
    bash mobile/tests/perf-dashboard-cli.test.sh || return 1
  fi

  # Run the validation gate. It exits 1 on budget violations, 77 if no artifacts.
  bash mobile/scripts/perf-validate.sh
  local rc=$?
  if [[ "$rc" -eq 77 ]]; then
    echo "mobile-perf: no measurement artifacts found (run scripts/bundle-size.sh first)"
    return 77
  fi
  return "$rc"
}

gate_a11y() {
  # Project hook: scripts/run-a11y.sh boots the ISOLATED e2e stack (its own
  # compose project + high ports + ephemeral DB) and runs the axe-core / WCAG
  # 2.1 AA sweep over key authenticated routes (delegating to run-e2e.sh, same
  # as gate_e2e). Exit 77 when docker/compose is absent → skip-as-pass below
  # tier 'launch', fail at launch+ where it is required.
  if [[ -x scripts/run-a11y.sh ]]; then
    # Distinct compose project from gate_e2e (issue #2412). a11y delegates to run-e2e.sh,
    # which derives BOTH the container namespace and its lock file from $E2E_PROJECT — so
    # inheriting the ambient value would put a11y and e2e on one project and one lock. Under
    # the serial dispatch that merely wasted a stack boot; under concurrent dispatch the
    # second gate blocks on the first's flock for up to E2E_LOCK_TIMEOUT (2700s) and the run
    # looks hung. Suffixing the project gives it its own containers, volumes and lock.
    E2E_PROJECT="$(_stack_project a11y)" scripts/run-a11y.sh
    return $?
  fi
  echo "no a11y runner (scripts/run-a11y.sh missing)"; return 77
}

gate_lighthouse() {
  # Project hook: scripts/run-lighthouse.sh boots an ISOLATED ephemeral full stack (own compose
  # project + high port band — never the dev DB) and runs Lighthouse against the BUILT production
  # frontend's /auth/login route, enforcing LIGHTHOUSE_PERF_BUDGET. lighthouse is launch-required,
  # so on a host WITHOUT docker run-lighthouse.sh returns 77 → promoted to FAIL (you can't be
  # green on a gate you never ran). Falls back to the remote-URL path when the script is absent.
  if [[ -x scripts/run-lighthouse.sh ]]; then
    LIGHTHOUSE_PERF_BUDGET="$LIGHTHOUSE_PERF_BUDGET" \
      E2E_PROJECT="$(_stack_project lh)" scripts/run-lighthouse.sh
    return $?
  fi
  if ! command -v npx >/dev/null; then echo "npx unavailable"; return 77; fi
  if [[ -z "${LIGHTHOUSE_URL:-}" ]]; then
    echo "LIGHTHOUSE_URL unset"; return 77
  fi
  # Per-run path. /tmp/lh.json was fixed, so two concurrent gate runs on this host (three
  # pipeline lanes are live) would each read whichever report finished last and score the
  # other's page (issue #2387, M3 — the #2211 class). QG_LOGDIR is already PID-namespaced.
  local LH_JSON="$QG_LOGDIR/lighthouse.json"
  npx --yes lighthouse "$LIGHTHOUSE_URL" \
    --output=json --output-path="$LH_JSON" --quiet \
    --chrome-flags='--headless=new --no-sandbox'
  local perf
  perf=$(node -e "console.log(Math.round(require('$LH_JSON').categories.performance.score * 100))")
  echo "lighthouse perf: $perf (budget $LIGHTHOUSE_PERF_BUDGET)"
  [[ "$perf" -ge "$LIGHTHOUSE_PERF_BUDGET" ]]
}

gate_visual() {
  # Project hook: scripts/run-visual.sh boots an ISOLATED ephemeral full stack (own compose
  # project skillforge-visual + high port band — never the dev DB), seeds it, and runs the
  # Playwright visual-regression suite (the `visual` project, toHaveScreenshot) INSIDE the pinned
  # playwright:v1.49.1-jammy container so screenshots are host-independent, comparing against the
  # committed -linux baselines. Exit 77 when docker/compose is absent → skip-as-pass below tier
  # 'launch' (visual is not yet in REQUIRED_BY_TIER — promotion is a separate PR).
  if [[ -x scripts/run-visual.sh ]]; then
    scripts/run-visual.sh
    return $?
  fi
  echo "no visual runner (scripts/run-visual.sh missing)"; return 77
}

# repro-tests — red-before-green. Every still-open bug (typically filed by
# adversarial-tester) must carry a committed reproducing test on disk. This
# stops a filed bug from being silently dropped and guarantees the regression
# lands in the permanent suite (tests/ is already run by unit/e2e gates).
gate_repro_tests() {
  # `.open_issues` moved to state/findings.json when state.json was sharded, and this
  # gate kept reading the old file. state.json's `.open_issues` is 0; findings.json holds
  # 76 open/routed issues — so the gate printed "no open issues requiring a repro test",
  # returned 0, and the red-before-green invariant went unenforced for every one of them
  # (issue #2387, C2). CLAUDE.md's rule — never read a state JSON path directly, resolve it
  # through the shard map — exists precisely to stop this; verify-loop.sh and
  # adversarial-loop.sh already resolve it correctly, so the three disagreed.
  local sf; sf="$(state_shard_file '.open_issues')"
  [[ -f "$sf" ]] || { echo "no findings shard ($sf)"; return 77; }
  command -v jq >/dev/null || { echo "jq required"; return 1; }
  # Only structured (object) issues carry status/repro_test; legacy free-form
  # string notes are not adversarial bugs and never gate.
  local sel='.open_issues[]? | select(type == "object") | select((.status // "open") | . == "open" or . == "routed")'
  local n; n=$(jq "[$sel] | length" "$sf")
  [[ "$n" -eq 0 ]] && { echo "no open issues requiring a repro test"; return 0; }
  local missing=""
  while IFS=$'\t' read -r id rt; do
    [[ -z "$id" ]] && continue
    if [[ -z "$rt" || "$rt" == "null" ]]; then
      missing+="  - ${id}: no repro_test recorded"$'\n'
    elif [[ ! -e "$rt" ]]; then
      missing+="  - ${id}: repro_test '${rt}' missing on disk"$'\n'
    fi
  done < <(jq -r "$sel | [(.id // \"?\"), (.repro_test // \"null\")] | @tsv" "$sf")
  if [[ -n "$missing" ]]; then
    echo "open bugs lack a committed reproducing test (red-before-green):"
    printf '%s' "$missing"
    return 1
  fi
  echo "all $n open issue(s) carry a repro test on disk"
}

# coverage — the GLOBAL backend statement-coverage floor (NFR-MAINT-001, #2017).
# Complements wedge-coverage rather than replacing it: wedge-coverage answers "is every
# wedge-critical FILE touched by some test" (a per-file wedge, cheap and targeted), which says
# nothing about whether coverage across app/ is drifting DOWN as the agent pipeline lands PRs.
# That drift is what this gate measures. scripts/coverage.sh runs the hermetic backend unit
# suite with --cov=app and enforces the ratchet floor in state/artifacts/coverage-floor.json
# (77 when pytest-cov/python is absent → promoted to FAIL on tiers where coverage is required).
gate_coverage() {
  # The gate's own hermetic suite runs first — scripts/*.test.sh are otherwise only *grepped*
  # by wedge-coverage, never executed (see scripts/docs-script-refs.sh check 4), so a coverage
  # script that silently stopped failing would go unnoticed. ~1s, no pytest.
  if [[ -f scripts/coverage.test.sh ]]; then
    bash scripts/coverage.test.sh || return 1
  fi
  [[ -x scripts/coverage.sh ]] || { echo "no coverage runner (scripts/coverage.sh missing)"; return 77; }
  # Reuse the report the `unit` gate already produced rather than replaying the identical
  # backend suite (issue #2412). $QG_COVERAGE_JSON is only set when both gates are scheduled,
  # and unit.sh DELETES the file if its suite went red — so a missing/empty artifact always
  # falls through to measuring here, never to a stale or partial number.
  if [[ -n "${QG_COVERAGE_JSON:-}" && -s "${QG_COVERAGE_JSON}" ]]; then
    echo "coverage: reusing the unit gate's coverage report (${QG_COVERAGE_JSON}) — suite not re-run"
    scripts/coverage.sh --from-json "$QG_COVERAGE_JSON"
    return $?
  fi
  scripts/coverage.sh
  return $?
}

# i18n (#2394) — catalog key parity across web + mobile, CLDR plural completeness, and a
# hardcoded-string ratchet. Nothing enforced i18n before this: the web catalogs were in sync
# by discipline alone and mobile had silently drifted 69 keys. It has to precede the #2398 UI
# extraction, or that 138-file sweep reopens the gap as fast as it closes it.
gate_i18n() {
  # The gate's own hermetic suite runs first — same reasoning as gate_coverage: a runner that
  # silently stopped failing would otherwise go unnoticed. ~2s, synthetic fixtures only.
  if [[ -f scripts/i18n-check.test.sh ]]; then
    local test_rc=0
    bash scripts/i18n-check.test.sh || test_rc=$?
    # 77 means the suite couldn't measure anything (python3/node absent) — that is the same
    # "cannot measure" verdict scripts/i18n-check.sh itself returns for a missing tool, and
    # must be passed through so it can skip instead of reading as a broken suite.
    if [[ $test_rc -eq 77 ]]; then
      echo "i18n-check.test.sh: cannot measure (python3/node absent)"
      return 77
    elif [[ $test_rc -ne 0 ]]; then
      return 1
    fi
  fi
  [[ -x scripts/i18n-check.sh ]] || { echo "no i18n runner (scripts/i18n-check.sh missing)"; return 77; }
  scripts/i18n-check.sh
  return $?
}

# wedge-coverage — the wedge workflow must be unbreakable. Every wedge-critical
# source file listed in state/artifacts/wedge-files.json must be referenced by
# at least one test (cheaper and more aligned than a global coverage %).
gate_wedge_coverage() {
  local manifest="state/artifacts/wedge-files.json"
  [[ -f "$manifest" ]] || { echo "no $manifest (emit it to enforce wedge coverage)"; return 77; }
  command -v jq >/dev/null || { echo "jq required"; return 1; }
  # Collect the actual test+spec files and grep ONLY those — never whole src trees, or a
  # source→source import would fake "coverage". (Layout is backend/tests + frontend, set below.)
  local testfiles=()
  local tf
  while IFS= read -r tf; do [[ -n "$tf" ]] && testfiles+=("$tf"); done < <(
    {
      # skillforge layout (NOT a services/* monorepo): backend pytest + frontend vitest +
      # Playwright e2e + repo-level shell tests. Collect the test files only — the matcher
      # below greps ONLY these, never src trees, so a source→source import can't fake coverage.
      [[ -d backend/tests ]] && find backend/tests -type f -name '*.py' 2>/dev/null
      [[ -d frontend/src ]] && find frontend/src -type f \( -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.spec.ts' -o -name '*.spec.tsx' \) 2>/dev/null
      [[ -d frontend/tests ]] && find frontend/tests -type f -name '*.spec.ts' 2>/dev/null
      find scripts -type f -name '*.test.sh' 2>/dev/null
    } | sort -u
  )
  [[ ${#testfiles[@]} -eq 0 ]] && { echo "no test/spec files found"; return 77; }
  local uncovered="" count=0
  while read -r src; do
    [[ -z "$src" ]] && continue
    count=$((count+1))
    local stem; stem="$(basename "$src")"; stem="${stem%.*}"
    if ! grep -qsF -- "$src" "${testfiles[@]}" 2>/dev/null \
       && ! grep -qsE "\\b${stem}\\b" "${testfiles[@]}" 2>/dev/null; then
      uncovered+="  - ${src} (no test references it)"$'\n'
    fi
  done < <(jq -r '(.files // .) | .[]?' "$manifest" 2>/dev/null)
  [[ "$count" -eq 0 ]] && { echo "wedge-files manifest lists no files"; return 77; }
  if [[ -n "$uncovered" ]]; then
    echo "wedge-critical files with no test coverage:"
    printf '%s' "$uncovered"
    return 1
  fi
  echo "all $count wedge-critical file(s) referenced by a test (searched ${#testfiles[@]} test files)"
}

# journey-coverage — every catalogued USER JOURNEY must have an e2e spec
# (journey->test, vs wedge-coverage's file->test). Delegates to the project hook,
# which reads state/artifacts/journeys.json and enforces P0 (preview) / P0+P1
# (launch+). Tier is passed through so --tier overrides the state value.
gate_journey_coverage() {
  if [[ -x scripts/journey-coverage.sh ]]; then
    TIER="$TIER" scripts/journey-coverage.sh
    return $?
  fi
  echo "no journey-coverage script"; return 77
}

# quarantine — known-flaky adversarial tests run here NON-BLOCKING. Reports the
# outcome but never fails the build, so a flake can't either gate forever or get
# deleted. Never appears in any REQUIRED set.
gate_quarantine() {
  # skillforge's adversarial suite is pytest (backend/tests/adversarial); the flaky lane
  # therefore lives at backend/tests/adversarial/quarantine and runs under pytest. A frontend
  # vitest lane (frontend/tests/quarantine) is also supported. Both run NON-BLOCKING: failures
  # are reported but swallowed (|| echo) so this gate always returns 0 once a lane exists.
  local ran=0
  if [[ -d backend/tests/adversarial/quarantine ]]; then
    ran=1
    ( cd backend && python -m pytest tests/adversarial/quarantine -q --no-cov -p no:cacheprovider ) \
      || echo "quarantine (backend) has failing tests (non-blocking)"
  fi
  if [[ -d frontend/tests/quarantine && ( -f frontend/vite.config.ts || -f frontend/vitest.config.ts ) ]]; then
    ran=1
    ( cd frontend && npx --no-install vitest run tests/quarantine --reporter=dot ) \
      || echo "quarantine (frontend) has failing tests (non-blocking)"
  fi
  [[ "$ran" -eq 0 ]] && { echo "no quarantine lane"; return 77; }
  echo "quarantine executed (non-blocking)"
}

# ---- single-runner lock: gate runs SERIALIZE per repo ----
# Concurrent quality-gates runs on one host collide: the ephemeral stacks use FIXED compose
# project names (skillforge-itest/-lh/-visual/-e2e), so one run's setup/teardown destroys the
# other's containers mid-suite, and heavyweight runners (Stryker, mutmut, Playwright) trample
# each other's worker processes. Observed 2026-07-17: an agent-inbox build's gate run terminated
# a release cut's Stryker half → "frontend=n/a" mutation FAIL. Callers that must never wait can
# set QG_NO_WAIT=1 to fail fast (exit 75) instead of queueing.
# The `:-nogit` fallbacks below were DEAD: `sha1sum` of empty input still prints a digest, so
# outside a git repo _qg_ns held the sha1 of the empty string rather than being empty, and the
# fallback never fired. Worse, that also made the not-a-repo case silently share ONE lock across
# every non-repo caller. Detect the failure where it happens instead (issue #2387, hygiene).
#
# It also differed from lib/pr-lock.sh's namespace for the SAME repo — that one pipes with
# `printf '%s'` (no trailing newline), this one piped `git`'s newline-terminated output straight
# into sha1sum. Two different digests for one directory. Matched up here so the harness's locks
# agree about what "this repo" means.
_qg_ns=""
_qg_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || _qg_common_dir=""
if [[ -n "$_qg_common_dir" ]]; then
  _qg_common_dir="$(cd "$_qg_common_dir" 2>/dev/null && pwd)" || _qg_common_dir=""
fi
[[ -n "$_qg_common_dir" ]] && _qg_ns="$(printf '%s' "$_qg_common_dir" | sha1sum | cut -c1-12)"
[[ -n "$_qg_ns" ]] || _qg_ns="nogit"
QG_LOCK="${QG_LOCK:-/tmp/quality-gates-${_qg_ns}.lock}"

# Only the gates that boot a shared stack or run a heavyweight worker pool need the exclusion.
# `typecheck`/`lint`/`unit`/`coverage`/`contract`/`docs-refs`/`migration-drift`/`repro-tests` touch
# no ports, no compose project and no docker volume — serialising them buys nothing and costs the
# whole review⇄fix loop its wall-clock. Set QG_LOCK_ALL=1 to restore the old lock-everything
# behaviour.  seed-integrity is conditional: static manifest checks by default, but it boots its own
# throwaway Postgres under SEED_INTEGRITY_FULL=1.
_qg_run_needs_stack() {
  local g stack="integration e2e mobile-e2e mobile-perf lighthouse visual a11y mutation"
  [ "${QG_LOCK_ALL:-0}" = 1 ] && return 0
  [ "${SEED_INTEGRITY_FULL:-0}" = 1 ] && stack="$stack seed-integrity"
  for g in "${GATES[@]}"; do
    should_run "$g" || continue
    case " $stack " in *" $g "*) return 0;; esac
  done
  return 1
}

QG_SLOTS="${QG_SLOTS:-1}"
QG_SLOT=0
if ! _qg_run_needs_stack; then
  # Nothing in this run touches shared infrastructure — no lock at all.
  echo "quality-gates: no stack gate selected — running unlocked (QG_LOCK_ALL=1 to force)"
elif [ "$QG_SLOTS" -le 1 ]; then
  # Single-slot mode is the historical behaviour, byte for byte: one repo-wide mutex on the same
  # path, same wait message, same QG_NO_WAIT escape. This is the default, so nothing changes until
  # an operator raises QG_SLOTS.
  exec 8>"$QG_LOCK"
  if ! flock -n 8; then
    if [ "${QG_NO_WAIT:-0}" = 1 ]; then
      echo "quality-gates: another gate run holds ${QG_LOCK} and QG_NO_WAIT=1 — exiting" >&2
      exit 75
    fi
    echo "quality-gates: another gate run is in progress (${QG_LOCK}) — waiting for it to finish…"
    flock 8
  fi
else
  # Multi-slot: at most QG_SLOTS stack-bearing runs at once, each with a PRIVATE compose project
  # and port band. The index is the whole point — `run-e2e.sh`/`integration.sh` already lock per
  # project name and probe for free ports, so distinct projects are already safe to run in
  # parallel; what was missing was a way to hand each run a distinct identity.
  # shellcheck source=lib/slot-lock.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/slot-lock.sh"
  _qg_slot_prefix="/tmp/qg-slot-${_qg_ns}"
  # NOT `$(slot_acquire …)`: command substitution would take the lock in a subshell that exits
  # immediately, so every run would "get" slot 0 while holding nothing. slot_acquire assigns.
  if [ "${QG_NO_WAIT:-0}" = 1 ]; then
    slot_acquire QG_SLOT "$_qg_slot_prefix" "$QG_SLOTS" 8 1 || {
      echo "quality-gates: all ${QG_SLOTS} slots busy and QG_NO_WAIT=1 — exiting" >&2; exit 75; }
  else
    echo "quality-gates: acquiring 1 of ${QG_SLOTS} stack slots…"
    slot_acquire QG_SLOT "$_qg_slot_prefix" "$QG_SLOTS" 8 || exit 75
  fi
  echo "quality-gates: stack slot ${QG_SLOT}/${QG_SLOTS}"

  # Per-slot identity. Ports are OFFSET rather than probed-from-a-shared-base on purpose:
  # `pick_port` probes upward and only binds much later, so two runs starting from the same base
  # can select the same "free" port before either binds it (TOCTOU). A 1000-wide band per slot
  # makes that collision structurally impossible, and probing still handles a busy port within a
  # band. Any value the caller pinned is overridden — a fixed port is precisely what defeats this.
  export E2E_PROJECT="${E2E_PROJECT:-skillforge-e2e}-s${QG_SLOT}"
  export INTEGRATION_PROJECT="${INTEGRATION_PROJECT:-skillforge-itest}-s${QG_SLOT}"
  export SF_FRONTEND_PORT=$(( 13000 + QG_SLOT * 1000 ))
  export SF_API_PORT=$((     18000 + QG_SLOT * 1000 ))
  export SF_PG_PORT=$((      15432 + QG_SLOT * 1000 ))
  export SF_REDIS_PORT=$((   16379 + QG_SLOT * 1000 ))
  echo "quality-gates: slot ${QG_SLOT} → project ${E2E_PROJECT} / ports fe=${SF_FRONTEND_PORT} api=${SF_API_PORT} pg=${SF_PG_PORT} redis=${SF_REDIS_PORT}"
fi
export QG_SLOT QG_SLOTS

# ---- unit⇄coverage report handoff (issue #2412) ----
# `unit` and `coverage` ran the SAME backend suite back to back — 3489 tests, twice, ~55s
# of pure duplication. When both are scheduled, have `unit` measure coverage once and hand
# the report to `coverage`. Scheduling both is the ONLY trigger: `--only unit` keeps the
# historical --no-cov fast path, and `--only coverage` measures for itself as before.
if should_run unit && should_run coverage; then
  # Per-run path under QG_LOGDIR, never a fixed name: a stale report from an earlier run
  # would be indistinguishable from this run's and could green a ratchet on old numbers.
  export QG_COVERAGE_JSON="$QG_LOGDIR/backend-coverage.json"
  export UNIT_EMIT_COVERAGE="$QG_COVERAGE_JSON"
  rm -f "$QG_COVERAGE_JSON"
fi

# ---- run ----
echo "Quality gates — root: $ROOT"
echo "  tier=$TIER  only=${ONLY:-<all>}  skip=${SKIP:-<none>}  keep_going=$KEEP_GOING"
echo "  required=[$REQUIRED]"
echo

_gate_fn() { # <gate> → its implementing function ("" when unknown)
  case "$1" in
    typecheck) echo gate_typecheck;;         lint) echo gate_lint;;
    docs-refs) echo gate_docs_refs;;         iteration-immutable) echo gate_iteration_immutable;;
    seed-integrity) echo gate_seed_integrity;; migration-drift) echo gate_migration_drift;;
    unit) echo gate_unit;;                   coverage) echo gate_coverage;;
    i18n) echo gate_i18n;;
    repro-tests) echo gate_repro_tests;;     mutation) echo gate_mutation;;
    integration) echo gate_integration;;     contract) echo gate_contract;;
    e2e) echo gate_e2e;;                     mobile-e2e) echo gate_mobile_e2e;;
    mobile-perf) echo gate_mobile_perf;;     wedge-coverage) echo gate_wedge_coverage;;
    journey-coverage) echo gate_journey_coverage;; a11y) echo gate_a11y;;
    lighthouse) echo gate_lighthouse;;       visual) echo gate_visual;;
    quarantine) echo gate_quarantine;;       *) echo "";;
  esac
}

# In-flight children, so a fail-fast `exit` from record() cannot orphan a running gate
# (a leaked pytest/compose tree would keep its slot's ports and volumes held).
_QG_INFLIGHT=()
_qg_reap_inflight() {
  local p
  for p in ${_QG_INFLIGHT[@]+"${_QG_INFLIGHT[@]}"}; do
    kill -0 "$p" 2>/dev/null && _kill_tree "$p" 2>/dev/null
  done
  _QG_INFLIGHT=()
}
trap _qg_reap_inflight EXIT

# Concurrent dispatcher. Honours both class budgets and the coverage⇄unit ordering, keeps
# the ▶/✓/✗ lines readable by emitting one combined heartbeat instead of N interleaved
# ones, and defers to the serial path when QG_PARALLEL=0.
_dispatch_parallel() {
  local g fn dep cls
  local -a pending=()
  local -A PID2GATE=() PID2RC=() START_OF=()
  local -A FINISHED=()
  local cpu_busy=0 stack_busy=0 tick=0
  local interval="${QG_PROGRESS_INTERVAL:-30}" next_tick

  # Filtered-out gates are decided (and recorded) up front, in registry order, so --only /
  # --skip policy and the summary's ordering are untouched by scheduling.
  for g in "${GATES[@]}"; do
    if ! should_run "$g"; then
      if is_required "$g" && [[ -n "$SKIP" && ",${SKIP}," == *",${g},"* ]]; then
        record "$g" fail "REQUIRED for tier '$TIER' but removed via --skip"
      else
        record "$g" skip "filtered out"
      fi
      continue
    fi
    # A gate listed in GATES but absent from _gate_fn used to be dropped here in SILENCE:
    # it never ran, never recorded, and the run still printed "all gates pass". That is the
    # same "silently green because it never ran" hole the 77→FAIL promotion and the
    # scripts/*.test.sh opt-out list each exist to close, reached through a third door —
    # and it is a one-line omission away on every new gate (#2394 added `i18n` to GATES and
    # the serial dispatcher before this table, and would have shipped exactly that).
    # An unregistered gate is a harness bug, so fail closed and name it.
    if [[ -z "$(_gate_fn "$g")" ]]; then
      record "$g" fail "no implementing function — add it to _gate_fn()"
      continue
    fi
    pending+=("$g")
  done
  (( ${#pending[@]} )) || return 0
  next_tick=$(( SECONDS + interval ))

  echo "  scheduling ${#pending[@]} gate(s): cpu×${QG_CPU_JOBS} stack×${QG_STACK_JOBS}"
  while (( ${#pending[@]} || ${#PID2GATE[@]} )); do
    # ── dispatch ────────────────────────────────────────────────────────────────
    local -a still=()
    for g in ${pending[@]+"${pending[@]}"}; do
      dep="$(_gate_after "$g")"
      # Hold a gate whose dependency is scheduled this run and has not finished yet.
      if [[ -n "$dep" ]] && [[ " ${pending[*]} " == *" $dep "* || " ${PID2GATE[*]} " == *" $dep "* ]] \
         && [[ -z "${FINISHED[$dep]:-}" ]]; then
        still+=("$g"); continue
      fi
      cls="$(_gate_class "$g")"
      if [[ "$cls" == stack ]]; then
        (( stack_busy >= QG_STACK_JOBS )) && { still+=("$g"); continue; }
      else
        (( cpu_busy >= QG_CPU_JOBS )) && { still+=("$g"); continue; }
      fi
      fn="$(_gate_fn "$g")"
      local logf="$QG_LOGDIR/${g}.log" rcf="$QG_LOGDIR/${g}.rc"
      rm -f "$rcf"
      printf '  ▶ %-14s running… [%s] (log: %s)\n' "$g" "$cls" "$logf"
      # QG_PROGRESS=0: per-gate heartbeats would interleave across N children. _exec_gate
      # still gives the child its hard timeout and _kill_tree semantics.
      ( QG_PROGRESS=0 _exec_gate "$fn" "$logf" "$g"; echo $? >"$rcf" ) &
      local pid=$!
      PID2GATE[$pid]="$g"; PID2RC[$pid]="$rcf"
      START_OF[$pid]=$SECONDS
      _QG_INFLIGHT+=("$pid")
      [[ "$cls" == stack ]] && stack_busy=$((stack_busy + 1)) || cpu_busy=$((cpu_busy + 1))
    done
    pending=(${still[@]+"${still[@]}"})

    # Nothing running and nothing dispatchable ⇒ an unsatisfiable dependency. Fail loudly
    # rather than spin: a silent hang here would look exactly like a wedged gate.
    if (( ${#PID2GATE[@]} == 0 && ${#pending[@]} )); then
      echo "quality-gates: INTERNAL — ${#pending[@]} gate(s) blocked with nothing running: ${pending[*]}" >&2
      for g in "${pending[@]}"; do record "$g" fail "scheduler deadlock (unsatisfiable dependency)"; done
      return 1
    fi

    sleep 1

    # ── reap ────────────────────────────────────────────────────────────────────
    local p
    for p in "${!PID2GATE[@]}"; do
      kill -0 "$p" 2>/dev/null && continue
      wait "$p" 2>/dev/null
      g="${PID2GATE[$p]}"
      GATE_SECONDS["$g"]=$(( SECONDS - START_OF[$p] ))
      local rc; rc="$(cat "${PID2RC[$p]}" 2>/dev/null || echo 1)"
      if [[ "$(_gate_class "$g")" == stack ]]; then stack_busy=$((stack_busy - 1)); else cpu_busy=$((cpu_busy - 1)); fi
      unset 'PID2GATE[$p]' 'PID2RC[$p]' 'START_OF[$p]'
      FINISHED[$g]=1
      # May `exit 1` via record() when a gate fails and --keep-going is off; the EXIT trap
      # reaps whatever is still in flight.
      _record_gate_result "$g" "$rc" "$QG_LOGDIR/${g}.log"
    done

    # ── combined heartbeat ──────────────────────────────────────────────────────
    if [[ "${QG_PROGRESS:-1}" == "1" ]] && (( SECONDS >= next_tick )) && (( ${#PID2GATE[@]} )); then
      next_tick=$(( SECONDS + interval ))
      local live=""
      for p in "${!PID2GATE[@]}"; do
        live+="${PID2GATE[$p]}($(( SECONDS - START_OF[$p] ))s) "
      done
      tick=$((tick + 1))
      printf '    ⏳ in flight: %s\n' "${live% }"
    fi
  done
  return 0
}

if [[ "$QG_PARALLEL" != "0" ]] && (( QG_CPU_JOBS > 1 || QG_STACK_JOBS > 1 )); then
  _dispatch_parallel
  summary
  exit "$fail_count"
fi

for g in "${GATES[@]}"; do
  case "$g" in
    typecheck)       run_gate "$g" gate_typecheck;;
    lint)            run_gate "$g" gate_lint;;
    docs-refs)       run_gate "$g" gate_docs_refs;;
    iteration-immutable) run_gate "$g" gate_iteration_immutable;;
    seed-integrity)  run_gate "$g" gate_seed_integrity;;
    migration-drift) run_gate "$g" gate_migration_drift;;
    unit)            run_gate "$g" gate_unit;;
    coverage)        run_gate "$g" gate_coverage;;
    i18n)            run_gate "$g" gate_i18n;;
    repro-tests)     run_gate "$g" gate_repro_tests;;
    mutation)        run_gate "$g" gate_mutation;;
    integration)     run_gate "$g" gate_integration;;
    contract)        run_gate "$g" gate_contract;;
    e2e)             run_gate "$g" gate_e2e;;
    mobile-e2e)      run_gate "$g" gate_mobile_e2e;;
    mobile-perf)     run_gate "$g" gate_mobile_perf;;
    wedge-coverage)  run_gate "$g" gate_wedge_coverage;;
    journey-coverage) run_gate "$g" gate_journey_coverage;;
    a11y)            run_gate "$g" gate_a11y;;
    lighthouse)      run_gate "$g" gate_lighthouse;;
    visual)          run_gate "$g" gate_visual;;
    quarantine)      run_gate "$g" gate_quarantine;;
  esac
done

summary
exit "$fail_count"
