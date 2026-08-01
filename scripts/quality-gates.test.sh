#!/usr/bin/env bash
# Regression test for quality-gates.sh's --only / --skip filtering policy.
#
# Background (the bug this guards against): a commit made any tier-REQUIRED gate that
# was filtered out via --only/--skip a hard FAIL. The deployed agent units run
# `--only unit,e2e --tier launch` on purpose (heavy Docker gates run elsewhere), so
# that change made every build fail closed on `typecheck` before running anything —
# wedging the inbox, pr-fixer, and pr-merger all at once.
#
# The fix splits the two opposite intents:
#   --only X,Y  → ALLOW-LIST (scoping). A required gate not named is a SKIP (run passes).
#   --skip Z    → DENY-LIST (dodge). Removing a required gate is a FAIL (run fails closed).
#
# The filtering cases use `--only __none__` (a token that matches NO gate) so EVERY
# gate is filtered before it can execute — pure filtering decisions, no stack boot.
# The positive allow-list case (4) names `quarantine`, the one tier-non-required gate
# that runs hermetically (a dir check, no stack / tool), so the whole suite stays fast.
#
#   Run: bash scripts/quality-gates.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATES="$ROOT/scripts/quality-gates.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# Every case below asserts what quality-gates.sh treats as REQUIRED at a given --tier, so the
# child MUST NOT inherit an ambient REQUIRED_GATES — that env var overrides REQUIRED_BY_TIER
# outright (quality-gates.sh:137) and silently rewrites the very set under test. The release cuts
# export it to narrow their spine, and it leaks the whole way down (cut → quality-gates.sh →
# unit.sh → this suite → this child), which turned cases 5/6 red inside every mobile cut while the
# suite stayed green everywhere else. unit.sh scrubs it for the pool via test_env_scrub; `env -u`
# keeps the suite hermetic when it is run standalone too, which is how a human reproduces it.
run() { # <args...> → captures stdout+exit into $OUT / $RC
  OUT="$(env -u REQUIRED_GATES bash "$GATES" "$@" 2>&1)"; RC=$?
}

echo "quality-gates.sh filtering policy"

# 1) --only scoping: required gates left out of the allow-list are SKIP, run passes.
run --only __none__ --tier launch
if [[ $RC -eq 0 ]]; then ok "--only scoping → exit 0 (required-but-unnamed gates skip)"
else bad "--only scoping → expected exit 0, got $RC"; fi
if grep -q "typecheck .*SKIP" <<<"$OUT"; then ok "--only: typecheck recorded SKIP, not FAIL"
else bad "--only: typecheck not recorded as SKIP"$'\n'"$OUT"; fi
if grep -q "RESULT: all gates pass" <<<"$OUT"; then ok "--only: RESULT all gates pass"
else bad "--only: expected 'all gates pass'"; fi

# 2) --skip dodge: removing a REQUIRED gate fails closed.
run --only __none__ --skip typecheck --tier launch
if [[ $RC -ne 0 ]]; then ok "--skip of a required gate → nonzero exit (fail-closed)"
else bad "--skip of a required gate → expected nonzero exit, got 0"; fi
if grep -q "typecheck .*removed via --skip" <<<"$OUT"; then ok "--skip: typecheck recorded FAIL (removed via --skip)"
else bad "--skip: typecheck not recorded as FAIL"$'\n'"$OUT"; fi

# 3) --skip of a NON-required gate is a benign SKIP (not every skip is a dodge).
#    quarantine is non-required by design; skipping it must not fail the run.
run --only __none__ --skip quarantine --tier launch
if [[ $RC -eq 0 ]]; then ok "--skip of a non-required gate → exit 0"
else bad "--skip of a non-required gate → expected exit 0, got $RC"; fi

# 4) --only is a TRUE allow-list: a gate NAMED in --only must actually RUN, not be
#    filtered out. Cases 1-3 only exercise filtering (every gate excluded), so an
#    inverted should_run() that skipped the *named* gate too would slip past them —
#    which is the exact shape that wedges `--only unit,e2e` (the named gate silently
#    not running reads as green). quarantine is non-required and hermetic (no stack
#    boot / tool), so it is the cheap, deterministic probe for "the named gate ran".
run --only quarantine --tier launch
if [[ $RC -eq 0 ]]; then ok "--only of the named gate → exit 0"
else bad "--only of the named gate → expected exit 0, got $RC"; fi
if grep -qE "quarantine +pass" <<<"$OUT"; then ok "--only: the named gate RAN (recorded pass, not filtered out)"
else bad "--only: named gate not recorded as run"$'\n'"$OUT"; fi
if grep -qE "quarantine .*filtered out" <<<"$OUT"; then bad "--only: named gate wrongly filtered out"
else ok "--only: the named gate was NOT filtered out"; fi

# 5) #1971 — contract is a REQUIRED launch gate. Both contract and migration-drift were WIRED
#    but in NO required set, so on a host missing their tooling they 77-skipped silently and the
#    run stayed green (stale openapi.yaml rode to release-cut time). Removing a required gate via
#    --skip must now fail closed — the deterministic, tooling-free proof of set membership. If a
#    future edit drops contract from REQUIRED_BY_TIER[launch], this reverts to a benign SKIP and
#    the assertion fires. (The --only path — a named required gate that 77s → FAIL — is the same
#    promotion covered by run_gate; here we lock in the membership.)
run --only __none__ --skip contract --tier launch
if [[ $RC -ne 0 ]]; then ok "--skip contract at launch → nonzero exit (contract is required)"
else bad "--skip contract at launch → expected nonzero exit, got 0 (contract not required?)"; fi
if grep -q "contract .*removed via --skip" <<<"$OUT"; then ok "--skip: contract recorded FAIL (required, removed via --skip)"
else bad "--skip: contract not recorded as a required-gate FAIL"$'\n'"$OUT"; fi

# 6) #1971 — migration-drift is a REQUIRED launch gate (its docker fallback means a Docker host
#    always has a Postgres, so the old "no PG ⇒ silent SKIP" escape is closed).
run --only __none__ --skip migration-drift --tier launch
if [[ $RC -ne 0 ]]; then ok "--skip migration-drift at launch → nonzero exit (migration-drift is required)"
else bad "--skip migration-drift at launch → expected nonzero exit, got 0 (not required?)"; fi
if grep -q "migration-drift .*removed via --skip" <<<"$OUT"; then ok "--skip: migration-drift recorded FAIL (required, removed via --skip)"
else bad "--skip: migration-drift not recorded as a required-gate FAIL"$'\n'"$OUT"; fi


# ── Concurrent scheduling (issue #2412) ──────────────────────────────────────────
# The dispatcher gained a parallel path. These guard the properties that make it safe
# to leave ON by default: the serial fallback still exists, the filtering policy above
# is unchanged by scheduling (cases 1-4 already run through the parallel path), gates
# are classified correctly, and the coverage⇄unit ordering that the report handoff
# depends on is declared.
echo
echo "quality-gates.sh concurrent scheduling"

# 5) The parallel path is the default and announces itself.
run --only iteration-immutable --tier launch
if grep -q "scheduling 1 gate" <<<"$OUT"; then ok "parallel dispatch is the default"
else bad "expected a 'scheduling N gate(s)' line"$'\n'"$OUT"; fi

# 6) QG_PARALLEL=0 restores the serial dispatcher — the escape hatch must actually work,
#    or there is no way to bisect a gate that misbehaves only under concurrency.
OUT="$(QG_PARALLEL=0 bash "$GATES" --only iteration-immutable --tier launch 2>&1)"; RC=$?
if [[ $RC -eq 0 ]] && ! grep -q "scheduling" <<<"$OUT"; then ok "QG_PARALLEL=0 → serial dispatch"
else bad "QG_PARALLEL=0 did not fall back to serial (rc=$RC)"$'\n'"$OUT"; fi

# 7) Durations are reported. Without this the whole optimisation is unmeasurable, which
#    is how the suite drifted to ~514s unnoticed in the first place.
run --only iteration-immutable --tier launch
if grep -qE "iteration-immutable +[0-9]+s" <<<"$OUT"; then ok "per-gate duration is reported"
else bad "no duration column on the gate line"$'\n'"$OUT"; fi
if grep -qE "wall-clock [0-9]+s · gate-time [0-9]+s" <<<"$OUT"; then ok "wall-clock vs gate-time reported"
else bad "no wall-clock/gate-time line"; fi

# 8) The scorecard keeps its legacy shape and gains duration_s. release-train and the
#    iteration log read .gate/.status/.reason — adding a field must not move them.
_J="$(mktemp)"; run --only iteration-immutable --tier launch --json "$_J"
if jq -e '.[0] | has("gate") and has("status") and has("reason") and has("duration_s")' "$_J" >/dev/null 2>&1; then
  ok "--json scorecard keeps gate/status/reason and adds duration_s"
else bad "scorecard shape changed: $(cat "$_J")"; fi
if jq -e '[.[] | select(.status=="skip" and .duration_s != null)] | length == 0' "$_J" >/dev/null 2>&1; then
  ok "a gate that never ran has duration_s null (not a fabricated 0)"
else bad "skipped gates report a duration"; fi
rm -f "$_J"

# 9) Resource classification, extracted from the script itself so the table cannot drift
#    away from the implementation. Every gate that boots containers MUST be 'stack' —
#    misclassifying one as 'cpu' lets N of them boot at once and re-enters the #2178
#    starvation regime (a Postgres container needs ~1.3s to listen idle, ~8.1s with 16 up).
eval "$(sed -n '/^_QG_STACK_CLASS=/p;/^_gate_class()/p' "$GATES")"
for g in integration e2e visual lighthouse a11y mobile-e2e mobile-perf mutation migration-drift seed-integrity; do
  [[ "$(_gate_class "$g")" == stack ]] || bad "gate '$g' must be classified stack, got $(_gate_class "$g")"
done
ok "every container-booting gate is classified 'stack'"
for g in typecheck lint unit coverage i18n contract docs-refs iteration-immutable repro-tests; do
  [[ "$(_gate_class "$g")" == cpu ]] || bad "gate '$g' must be classified cpu, got $(_gate_class "$g")"
done
ok "every hermetic gate is classified 'cpu'"

# 10) coverage must be declared as running AFTER unit. The handoff (unit writes the
#     coverage report, coverage reads it) is a real ordering dependency; drop it and
#     coverage silently re-runs the whole backend suite instead of reusing the report.
eval "$(sed -n '/^_gate_after()/p' "$GATES")"
if [[ "$(_gate_after coverage)" == unit ]]; then ok "coverage is ordered after unit (report handoff)"
else bad "coverage lost its ordering dependency on unit"; fi

# 11) EVERY gate in the registry must resolve to a function that actually exists.
#     There are two dispatch tables — the serial `case` and _gate_fn() for the concurrent
#     scheduler — and a new gate has to be added to BOTH. Adding it to only one used to be
#     invisible: the concurrent path dropped an unresolvable gate from `pending` without a
#     word, so the gate never ran and the run still printed "all gates pass". #2394's `i18n`
#     was one line away from shipping exactly that. The dispatcher now fails closed; this
#     asserts the registry is complete in the first place, which is the cheaper failure.
#     NB: the registry is evaluated under a DIFFERENT name — `$GATES` in this suite is the
#     path to the script, and pulling in `GATES=(typecheck …)` verbatim would clobber it
#     with an array whose first element then gets used as the filename by every sed below.
eval "$(sed -n 's/^GATES=(/REGISTERED=(/p' "$GATES")"
eval "$(sed -n '/^_gate_fn()/,/^}/p' "$GATES")"
_unwired=()
for g in "${REGISTERED[@]}"; do
  fn="$(_gate_fn "$g")"
  # Resolvable by _gate_fn, dispatched by the serial `case`, and actually defined.
  [[ -n "$fn" ]] || { _unwired+=("$g (not in _gate_fn)"); continue; }
  grep -q "^${fn}()" "$GATES" || _unwired+=("$g → $fn (function not defined)")
  grep -qE "^ *${g}\)( |\t)*run_gate " "$GATES" || _unwired+=("$g (not in the serial dispatch case)")
done
if (( ${#_unwired[@]} == 0 )); then ok "every registered gate is wired to a real function in BOTH dispatchers"
else bad "unwired gate(s): ${_unwired[*]}"; fi

# 12) gate_i18n must pass the hermetic suite's own 77 (deps absent) straight through as a
#     SKIP verdict, not fold it into a hard FAIL. scripts/i18n-check.test.sh exits 77 when
#     python3/node are missing — the repo convention for a dep-absent shell suite — and
#     `bash scripts/i18n-check.test.sh || return 1` used to turn that indistinguishably into
#     a broken-gate FAIL (pr-review finding on #2394/#2417).
eval "$(sed -n '/^gate_i18n()/,/^}/p' "$GATES")"
_I18N_TMP="$(mktemp -d)"; mkdir -p "$_I18N_TMP/scripts"
printf '#!/usr/bin/env bash\nexit 77\n' > "$_I18N_TMP/scripts/i18n-check.test.sh"
printf '#!/usr/bin/env bash\necho should-not-run; exit 1\n' > "$_I18N_TMP/scripts/i18n-check.sh"
chmod +x "$_I18N_TMP/scripts/i18n-check.sh"
_i18n_out="$(cd "$_I18N_TMP" && gate_i18n 2>&1)"; _i18n_rc=$?
if [[ $_i18n_rc -eq 77 ]]; then ok "gate_i18n: hermetic-suite 77 (deps absent) passes through as 77"
else bad "gate_i18n: expected 77 passthrough, got $_i18n_rc"$'\n'"$_i18n_out"; fi
if ! grep -q "should-not-run" <<<"$_i18n_out"; then ok "gate_i18n: does not fall through to i18n-check.sh once the suite reports 77"
else bad "gate_i18n: ran i18n-check.sh despite the hermetic suite reporting 77"$'\n'"$_i18n_out"; fi

# A genuine suite FAILURE (not 77) must still hard-fail the gate — the passthrough must not
# swallow real breakage.
printf '#!/usr/bin/env bash\necho boom; exit 1\n' > "$_I18N_TMP/scripts/i18n-check.test.sh"
_i18n_out="$(cd "$_I18N_TMP" && gate_i18n 2>&1)"; _i18n_rc=$?
if [[ $_i18n_rc -eq 1 ]]; then ok "gate_i18n: a real hermetic-suite failure still fails the gate"
else bad "gate_i18n: expected exit 1 on a real suite failure, got $_i18n_rc"$'\n'"$_i18n_out"; fi
rm -rf "$_I18N_TMP"

# 13) Ambient REQUIRED_GATES must not reach the child, and must not survive test_env_scrub.
#     Both layers are asserted because they fail independently: `env -u` in run() keeps THIS
#     suite hermetic when a human runs it standalone, while the scrub list keeps the whole
#     37-suite pool hermetic when unit.sh runs it inside a release cut. Losing either one
#     restores the loop where a mobile cut fails a gate that is green on every re-run.
#     The first assertion re-runs case 5 with the cut's exact narrowed spine in the SUITE's own
#     environment: run() must strip it, so the verdict is identical to the clean run above.
export REQUIRED_GATES="typecheck lint unit"
run --only __none__ --skip contract --tier launch
if [[ $RC -ne 0 ]]; then ok "ambient REQUIRED_GATES does not leak into the child (--skip contract still fails closed)"
else bad "ambient REQUIRED_GATES leaked into the child: --skip contract at launch exited 0"$'\n'"$OUT"; fi
unset REQUIRED_GATES

_scrubbed="$(REQUIRED_GATES="typecheck lint unit" bash -c \
  'source "$1"/scripts/lib/test-env.sh; test_env_scrub; printf %s "${REQUIRED_GATES-<unset>}"' _ "$ROOT" 2>&1)"
if [[ "$_scrubbed" == "<unset>" ]]; then ok "test_env_scrub unsets REQUIRED_GATES for the shell-suite pool"
else bad "test_env_scrub left REQUIRED_GATES set to '$_scrubbed' — the cut's narrowed spine leaks into every suite"; fi

# 14) REQUIRED_GATES must be CONSUMED, then dropped — the root fix for the leak case 13
#     guards from the other end. This one is deliberately a source assertion rather than a
#     behavioural one: the var's absence is only observable to a grandchild process, and
#     manufacturing one costs more than it proves. Case 13 already covers the behaviour that
#     matters; this pins the mechanism so a future edit cannot quietly re-export it.
_qg_req="$(grep -n 'REQUIRED="\${REQUIRED_GATES' -A 12 "$GATES" | grep -c '^[0-9]*-unset REQUIRED_GATES$')"
if [[ "$_qg_req" -eq 1 ]]; then ok "quality-gates.sh unsets REQUIRED_GATES once it has been consumed"
else bad "quality-gates.sh must 'unset REQUIRED_GATES' right after computing REQUIRED — a narrowing meant for one process must not be inherited by the gates it spawns"; fi

echo
echo "  passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
