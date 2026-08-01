#!/usr/bin/env bash
# Hermetic e2e for the PR merger (scripts/agent-pr-merger.sh). gh + claude STUBBED; a real
# bare origin + clone so the integrate→resolve→push-to-main path is exercised for real. Zero
# GitHub I/O, zero LLM cost, deterministic.
#
# The merger is SkillForge's local CI/CD gate (Buildkite retired): it re-gates the union of all
# `review-approved` PRs and fast-forwards `main` only on green. These scenarios prove it never
# ships red or marker-polluted work. See docs/AGENT-HARNESS.md.
#
# Scenarios:
#   J-MG-1  two non-conflicting approved PRs → integrated, gates green → BOTH on main, `merged`
#   J-MG-2  two CONFLICTING approved PRs → resolver includes both → union on main, `merged`
#   J-MG-3  gates red on integration AND base (main itself red) → main NOT advanced, `merge-stuck`
#   J-MG-4  no approved PRs → clean no-op exit
#   J-MG-5  conflict the resolver can't clear (markers remain) → abort, `merge-stuck`, main intact
#   J-MG-6  resolver hits a transient 429 (exit 0)  → deferred (review-approved), NOT merge-stuck
#   J-MG-7  stale branch vs an advanced main → pre-merge rebase clears the conflict, merge is clean
#   J-MG-8  resolver hits a transient 429 (exit 1, real CLI) → deferred (review-approved), NOT merge-stuck
#   J-MG-9  stale PR head branch force-pushed to rebased tip after merge → GitHub can auto-close PR
#   J-MG-10 gates red on integration but GREEN on base (solo PR) → routed to the fix loop
#           (`changes-requested` + INTEGRATION GATES FAILED findings), NOT merge-stuck
#   J-MG-11 gates red on integration, green base, BATCH → lowest PR blamed (`changes-requested`),
#           the rest requeued (`review-approved`), main intact
#   J-MG-17 base red on ONE sample but green on a targeted re-run → flake; PRs judged normally
#   J-MG-18 the confirmation re-run is scoped to the gates that actually failed
#   J-MG-19 base red on BOTH samples → still `merge-stuck`, and an `agent` issue is filed for main
#   J-MG-20 PR_MERGER_CONFIRM_BASE_RED=0 restores the single-sample wedge (fix is load-bearing)
#   J-MG-21 a resolver retry is handed the ORIGINAL conflict, not attempt 1's mangled output (#2185)
#   J-MG-22 a state/state.json-only conflict is auto-resolved for real — never with markers (#2185)
#   J-MG-23 the generated-file fallback fails to `merge-stuck` when it cannot resolve (#2185)
#   J-MG-24 a marker-polluted integration tree is never fast-forwarded onto main (#2185)
#   J-MG-25 …but a dormant marker elsewhere in main does not block an unrelated integration
#   J-MG-26 all merger entry points (3 units + 2 script defaults) resolve ONE lock path (#2387)
#   J-MG-27 the fixer-routing PR comment carries the failed-gate context (quoting bug, #2387)
#   J-MG-28..31 an unprovisioned worktree is never a verdict on main (#2438)
#   J-MG-32 a sibling workspace with no 'extends' is still caught when evicted (the self-link check)
#   J-MG-33 an unrelenting DEPS deferral escalates with the deps remedy, not the Docker one
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/agent-pr-merger.sh"
# Keep per-PR claim locks inside the suite's own tree. lib/pr-lock.sh defaults
# PR_LOCK_DIR to /tmp and names the file after the PR NUMBER alone, so this suite and
# its two siblings (reviewer/fixer/merger all drive PR #42) shared one lockfile the
# moment they ran concurrently — each stole the others' claim and the runs skipped the
# PR they were asserting on. It also raced any REAL lane's claim on the same number.
# Same fix agent-inbox.test.sh already carries (issues #2387 M4, #2412).
_SUITE_LOCKS="$(mktemp -d)"; export PR_LOCK_DIR="$_SUITE_LOCKS"
trap 'rm -rf "$_SUITE_LOCKS" 2>/dev/null || true' EXIT
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_grep()   { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_nogrep() { if grep -qF -- "$2" "$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
on_main() { git -C "$1/clone" fetch -q origin main 2>/dev/null; git -C "$1/clone" cat-file -e "origin/main:$2" 2>/dev/null; }
main_blob() { git -C "$1/clone" fetch -q origin main 2>/dev/null; git -C "$1/clone" show "origin/main:$2" 2>/dev/null; }

# make_env <tmp> <mode>  — mode: clean | conflict | stale | genfile | genfile-del | none
#   clean    → PR#7 adds a.txt, PR#8 adds b.txt (no overlap)
#   conflict → both PRs edit shared.txt (a merge conflict the resolver must reconcile)
#   stale    → ONE PR (#7) branched off the ORIGINAL main edits shared.txt, then main ADVANCES
#              with a conflicting edit to the same line. A direct `git merge` of #7 conflicts;
#              the pre-merge rebase (issue #822) must clear it BEFORE the merge commit.
#   genfile  → like `stale`, but the ONLY conflicting file is state/state.json — i.e. the
#              regeneratable allowlist. This reaches invoke_resolver's generated-file fallback at
#              REBASE time (the merge-time shortcut at the top of the merge loop never sees it),
#              which is the exact path #2185 found could commit conflict markers and report `ok`.
#   genfile-poison → same shape, but PR #7's state/state.json already CONTAINS a committed conflict
#              marker (which is how this class of pollution actually propagates — see #1473).
#              `git checkout --theirs` then "succeeds" while leaving a marker in the file, so the
#              fallback must verify its own result rather than trust the exit code.
#   none     → no approved PRs
make_env() {
  local tmp="$1" mode="$2"
  mkdir -p "$tmp/bin" "$tmp/logs"; : > "$tmp/logs/gh.log"; : > "$tmp/logs/claude.log"
  git init -q --bare "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
  mkdir -p "$tmp/clone/scripts/lib" && cp "$ROOT/scripts/lib/agent-model-call.sh" "$tmp/clone/scripts/lib/"
  cp "$ROOT/scripts/lib/pr-lock.sh" "$tmp/clone/scripts/lib/"
  ( cd "$tmp/clone"
    git config user.email t@t; git config user.name tester
    echo base > base.txt; echo '{"name":"t","scripts":{"test":"true"}}' > package.json
    mkdir -p node_modules; echo x > node_modules/.keep
    echo "line1" > shared.txt
    git add -A; git commit -qm init; git branch -M main; git push -q origin main
    if [ "$mode" = "conflict" ]; then
      git checkout -q -b agent/issue-5 main; printf 'line1\nFROM-PR7\n' > shared.txt; git add -A; git commit -qm p7; git push -q origin agent/issue-5
      git checkout -q -b agent/issue-6 main; printf 'line1\nFROM-PR8\n' > shared.txt; git add -A; git commit -qm p8; git push -q origin agent/issue-6
    elif [ "$mode" = "clean" ]; then
      git checkout -q -b agent/issue-5 main; echo a > a.txt; git add -A; git commit -qm p7; git push -q origin agent/issue-5
      git checkout -q -b agent/issue-6 main; echo b > b.txt; git add -A; git commit -qm p8; git push -q origin agent/issue-6
    elif [ "$mode" = "stale" ]; then
      # PR #7 off the ORIGINAL main…
      git checkout -q -b agent/issue-5 main; printf 'line1\nFROM-PR7\n' > shared.txt; git add -A; git commit -qm p7; git push -q origin agent/issue-5
      # …then main moves on with a CONFLICTING change to the same line (branch is now stale).
      git checkout -q main; printf 'line1\nFROM-MAIN\n' > shared.txt; git add -A; git commit -qm advance-main; git push -q origin main
    elif [ "$mode" = "genfile" ] || [ "$mode" = "genfile-poison" ]; then
      mkdir -p state; printf '{"iteration_count":1}\n' > state/state.json
      git add -A; git commit -qm seed-state; git push -q origin main
      git checkout -q -b agent/issue-5 main
      if [ "$mode" = "genfile-poison" ]; then
        printf '<<<<<<< HEAD\n{"iteration_count":7}\n=======\n{"iteration_count":8}\n>>>>>>> other\n' > state/state.json
      else printf '{"iteration_count":7}\n' > state/state.json; fi
      git add -A; git commit -qm p7; git push -q origin agent/issue-5
      git checkout -q main; printf '{"iteration_count":99}\n' > state/state.json
      git add -A; git commit -qm advance-main; git push -q origin main
    fi
    git checkout -q main ) 2>/dev/null

  # gh stub: serves the approved-PR list (empty for `none`); records labels/comments.
  local list='[]'
  if [ "$mode" = "stale" ] || [ "$mode" = "genfile" ] || [ "$mode" = "genfile-poison" ]; then
    list='[{"number":7,"headRefName":"agent/issue-5","title":"a","labels":[{"name":"review-approved"}]}]'
  elif [ "$mode" != "none" ]; then
    list='[{"number":7,"headRefName":"agent/issue-5","title":"a","labels":[{"name":"review-approved"}]},{"number":8,"headRefName":"agent/issue-6","title":"b","labels":[{"name":"review-approved"}]}]'
  fi
  cat > "$tmp/bin/gh" <<GH
#!/usr/bin/env bash
echo "gh \$*" >> "$tmp/logs/gh.log"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then echo '$list'; exit 0; fi
exit 0
GH
  chmod +x "$tmp/bin/gh"
  # claude stub: the conflict resolver. 'union' resolves EVERY conflicted file by stripping the
  # conflict markers and keeping BOTH sides (a real union — works for a rebase-time OR a
  # merge-time conflict, on any file); 'bad' leaves the markers in place (unresolvable);
  # 'transient' is a 429 (model never ran — markers untouched, but it must defer rather than
  # route to merge-stuck); 'retry-reset' mangles the file on attempt 1 and resolves cleanly on
  # attempt 2, snapshotting what each attempt was HANDED into $tmp/seen-attempt-N.txt so a test can
  # assert the retry started from the original conflict rather than attempt 1's output. The prompt
  # names the stage ("mid-rebase"/"mid-merge"), logged via $* so a test can assert WHICH step the
  # resolver fired on.
  local resolve="${3:-union}"
  cat > "$tmp/bin/claude" <<CL
#!/usr/bin/env bash
echo "claude \$*" >> "$tmp/logs/claude.log"
if [ "$resolve" = "retry-reset" ]; then
  _a=\$(cat "$tmp/attempts" 2>/dev/null || echo 0); _a=\$((_a + 1)); echo "\$_a" > "$tmp/attempts"
  cp shared.txt "$tmp/seen-attempt-\$_a.txt" 2>/dev/null || true
  if [ "\$_a" = "1" ]; then
    printf '<<<<<<< mangled\nATTEMPT1-GARBAGE\n>>>>>>> mangled\n' > shared.txt
  else
    grep -vE '^(<<<<<<<|=======|>>>>>>>)' shared.txt > shared.tmp 2>/dev/null && mv shared.tmp shared.txt
  fi
  echo '{"is_error":false,"result":"ok"}'; exit 0
fi
if [ "$resolve" = "transient" ] || [ "$resolve" = "transient-nz" ]; then
  echo '{"is_error":true,"api_error_status":429,"output_tokens":0,"result":"You'\''ve hit your session limit · resets 1:20pm (Australia/Sydney)"}'
  if [ "$resolve" = "transient-nz" ]; then exit 1; fi
  exit 0
fi
if [ "$resolve" = "union" ]; then
  for f in \$(git diff --name-only --diff-filter=U 2>/dev/null); do
    grep -vE '^(<<<<<<<|=======|>>>>>>>)' "\$f" > "\$f.ku" 2>/dev/null && mv "\$f.ku" "\$f"
  done
fi
# Self-repair invocation (merger gate-failure fix): the prompt carries "GATE FAILURE".
if echo "\$*" | grep -q "GATE FAILURE"; then
  touch gate-fixed   # create the file the stateful gate checks for
fi
echo '{"is_error":false,"result":"ok"}'; exit 0
CL
  chmod +x "$tmp/bin/claude"
}
# Every PR_MERGER_* / PR_* tunable the runner reads, cleared before each scenario. These tests are
# routinely executed BY the agent harness (agent-inbox runs the gates inside a build), and that
# harness exports PR_MERGER_GATES_CMD, PR_LOGDIR, PR_DEPS, … into the environment. Without the
# scrub the leaked values win — PR_MERGER_GATES_CMD outranks the PR_GATES_CMD each scenario sets,
# so every stub gate was silently replaced by the real quality-gates run and 47 assertions failed
# for reasons that had nothing to do with the code under test.
MERGER_ENV_SCRUB=(
  -u PR_MERGER_GATES_CMD -u PR_GATES_CMD -u PR_MERGER_MAX_PRS -u PR_DEPS -u PR_LOGDIR
  -u PR_WORKTREE_BASE -u PR_MERGER_LOCK -u PR_ROOT -u PR_GH -u PR_CLAUDE -u PR_REMOTE -u PR_BASE
  -u PR_MERGER_MODEL -u PR_MERGER_SELF_REPAIR -u PR_MERGER_MAX_SELF_REPAIR
  -u PR_MERGER_REBASE_ON_RETRY -u PR_MERGER_TRANSIENT_DEFER -u PR_MERGER_MAX_ENV_DEFER
  -u PR_MERGER_CONFIRM_BASE_RED -u MERGER_RESOLVER_RETRIES
)
run() {
  local tmp="$1" gates="$2"; shift 2
  # PR_MERGER_MAX_PRS=2: the shipped default became 1 in 53db46e0 ("sequential one-by-one
  # merging"), which is a deployment choice, not a property of the merge algorithm. The batch
  # scenarios below (J-MG-1/2/11/12) exist to prove the batch paths, so they ask for a batch
  # explicitly instead of riding on whatever the current default happens to be.
  env "${MERGER_ENV_SCRUB[@]}" \
    PR_ROOT="$tmp/clone" PR_GH="$tmp/bin/gh" PR_CLAUDE="$tmp/bin/claude" PR_REMOTE="origin" PR_BASE="main" \
    PR_GATES_CMD="$gates" PR_DEPS="symlink" PR_MERGER_LOCK="$tmp/mg.lock" PR_MERGER_MAX_PRS="${MAX_PRS_OVERRIDE:-2}" \
    PR_LOGDIR="$tmp/logs" PR_WORKTREE_BASE="$tmp/wt" \
    "$@" bash "$RUNNER" > "$tmp/logs/out" 2>&1
}

echo "J-MG-1 — two non-conflicting approved PRs → both auto-merged into main"
T1="$(mktemp -d)"; make_env "$T1" clean; run "$T1" "true"
on_main "$T1" a.txt && ok "PR #7's work (a.txt) is on main" || bad "PR #7's work on main"
on_main "$T1" b.txt && ok "PR #8's work (b.txt) is on main" || bad "PR #8's work on main"
[ "$(grep -c "labels\[\]=merged" "$T1/logs/gh.log")" = "2" ] && ok "both PRs labelled merged" || bad "both PRs labelled merged"
assert_grep   "$T1/logs/gh.log" "labels[]=merge-wip" "PRs claimed (merge-wip) before integrating"
assert_nogrep "$T1/logs/gh.log" "labels[]=merge-stuck" "clean integration did not get stuck"

echo "J-MG-2 — two CONFLICTING approved PRs → resolver includes BOTH, merged"
T2="$(mktemp -d)"; make_env "$T2" conflict union; run "$T2" "true"
blob="$(main_blob "$T2" shared.txt)"
printf '%s' "$blob" | grep -q FROM-PR7 && printf '%s' "$blob" | grep -q FROM-PR8 \
  && ok "main's shared.txt includes BOTH PRs' work (conflict resolved as a union)" || bad "union of both PRs on main"
printf '%s' "$blob" | grep -qE '^(<<<<<<<|>>>>>>>|=======)' && bad "conflict markers leaked onto main" || ok "no conflict markers on main"
[ "$(grep -c "labels\[\]=merged" "$T2/logs/gh.log")" = "2" ] && ok "both conflicting PRs labelled merged" || bad "both PRs merged"
assert_grep "$T2/logs/claude.log" "claude" "resolver model was invoked on the conflict"
# Telemetry (#2390): invoke_resolver's span is emitted from inside a `$(…)` return-channel
# function (STDOUT IS THE RETURN CHANNEL there) — a regression that made agent_trace_span print
# to stdout, or broke its lib source (e.g. reverting to a $ROOT-relative resolve that no-ops in a
# sandbox like this one), would corrupt invoke_resolver's verdict AND leave no span, silently.
t2_spans="$(ls "$T2/clone"/state/traces/spans-*.jsonl 2>/dev/null | head -1)"
if [ -n "$t2_spans" ]; then
  t2_stage="$(jq -rs '[.[] | select(.stage=="merge-resolve" or .stage=="merge-rebase")][0].stage // empty' "$t2_spans")"
  [ -n "$t2_stage" ] && ok "resolver span written ($t2_stage) for the conflict-resolution run" \
    || bad "no merge-resolve/merge-rebase stage span found in $t2_spans"
else
  bad "no trace spans file written for the conflict-resolution run"
fi

echo "J-MG-3 — red gates on integration AND base (main itself red) → NOT merged, merge-stuck"
T3="$(mktemp -d)"; make_env "$T3" clean; run "$T3" "false"
on_main "$T3" a.txt && bad "must NOT advance main when gates fail" || ok "main NOT advanced on red gates"
[ "$(grep -c "labels\[\]=merge-stuck" "$T3/logs/gh.log")" = "2" ] && ok "both PRs routed to merge-stuck (base is red — a human owns main)" || bad "PRs routed to merge-stuck"
assert_grep   "$T3/logs/gh.log" "itself is red" "comment names the red BASE as the cause"
assert_nogrep "$T3/logs/gh.log" "labels[]=changes-requested" "no PR blamed when the base itself is red"
assert_nogrep "$T3/logs/gh.log" "labels[]=merged" "nothing marked merged on red gates"

echo "J-MG-4 — no approved PRs → clean no-op"
T4="$(mktemp -d)"; make_env "$T4" none; run "$T4" "true"
assert_grep   "$T4/logs/out"    "no approved PRs to merge" "no-op logged"
assert_nogrep "$T4/logs/gh.log" "labels[]=merge-wip" "did not claim anything when nothing is approved"

echo "J-MG-5 — unresolvable conflict (markers remain) → abort, merge-stuck, main intact"
T5="$(mktemp -d)"; make_env "$T5" conflict bad; run "$T5" "true"
blob5="$(main_blob "$T5" shared.txt)"
printf '%s' "$blob5" | grep -q FROM-PR8 && bad "main must stay intact when conflicts are unresolvable" || ok "main untouched on unresolvable conflict"
[ "$(grep -c "labels\[\]=merge-stuck" "$T5/logs/gh.log")" -ge 1 ] && ok "routed to merge-stuck on unresolvable conflict" || bad "merge-stuck on unresolvable conflict"
assert_nogrep "$T5/logs/gh.log" "labels[]=merged" "nothing merged when a conflict could not be cleared"

echo "J-MG-6 — resolver hits a transient 429 on a conflict → deferred (review-approved), NOT merge-stuck, main intact"
T6="$(mktemp -d)"; make_env "$T6" conflict transient; run "$T6" "true"
blob6="$(main_blob "$T6" shared.txt)"
printf '%s' "$blob6" | grep -q FROM-PR8 && bad "main must stay intact when the resolver was rate-limited" || ok "main untouched on a transient resolver limit"
assert_nogrep "$T6/logs/gh.log" "labels[]=merge-stuck" "a transient limit did NOT escalate to a human"
assert_nogrep "$T6/logs/gh.log" "labels[]=merged" "nothing merged when the resolver was rate-limited"
[ "$(grep -c "labels\[\]=review-approved" "$T6/logs/gh.log")" -ge 2 ] && ok "both PRs returned to review-approved for the next tick" || bad "PRs returned to review-approved"
assert_grep   "$T6/logs/out" "transient limit" "logged the transient-limit deferral"

echo "J-MG-7 — stale branch (conflicts with advanced main) → rebase clears it BEFORE merge (issue #822)"
T7="$(mktemp -d)"; make_env "$T7" stale union; run "$T7" "true"
blob7="$(main_blob "$T7" shared.txt)"
printf '%s' "$blob7" | grep -q FROM-PR7 && printf '%s' "$blob7" | grep -q FROM-MAIN \
  && ok "main's shared.txt unions the stale PR's work with main's advance" || bad "union of stale PR + main on main"
printf '%s' "$blob7" | grep -qE '^(<<<<<<<|>>>>>>>|=======)' && bad "conflict markers leaked onto main" || ok "no conflict markers on main"
assert_grep   "$T7/logs/claude.log" "mid-rebase" "resolver fired at REBASE time (conflict cleared before the merge)"
assert_nogrep "$T7/logs/claude.log" "mid-merge"  "the --no-ff merge was clean — NO merge-time resolver (acceptance criterion)"
assert_grep   "$T7/logs/gh.log"     "labels[]=merged"      "stale PR auto-merged after a clean rebase"
assert_nogrep "$T7/logs/gh.log"     "labels[]=merge-stuck" "stale branch did not get stuck"

echo "J-MG-8 — resolver hits a transient 429 AND exits non-zero (real CLI) → deferred, NOT merge-stuck"
T8="$(mktemp -d)"; make_env "$T8" conflict transient-nz; run "$T8" "true"
blob8="$(main_blob "$T8" shared.txt)"
printf '%s' "$blob8" | grep -q FROM-PR8 && bad "main must stay intact when the resolver exits non-zero on a 429" || ok "main untouched on a non-zero-exit transient resolver"
assert_nogrep "$T8/logs/gh.log" "labels[]=merge-stuck" "non-zero-exit transient did NOT escalate to merge-stuck"
assert_nogrep "$T8/logs/gh.log" "labels[]=merged"      "nothing merged when the resolver exited non-zero on a 429"
[ "$(grep -c "labels\[\]=review-approved" "$T8/logs/gh.log")" -ge 2 ] && ok "both PRs returned to review-approved for the next tick" || bad "PRs returned to review-approved"
assert_grep   "$T8/logs/out" "transient limit" "logged the transient-limit deferral on non-zero exit"

echo "J-MG-9 — stale PR head branch force-pushed to rebased tip after merge → GitHub can auto-close PR"
T9="$(mktemp -d)"; make_env "$T9" stale union
orig_sha="$(git -C "$T9/clone" ls-remote origin refs/heads/agent/issue-5 2>/dev/null | awk '{print $1}')"
run "$T9" "true"
git -C "$T9/clone" fetch -q origin main "agent/issue-5" 2>/dev/null || true
new_sha="$(git -C "$T9/clone" rev-parse "origin/agent/issue-5" 2>/dev/null || echo "")"
[ -n "$new_sha" ] && [ "$new_sha" != "$orig_sha" ] \
  && ok "PR head branch force-pushed to rebased tip (SHA changed from original)" \
  || bad "PR head branch NOT updated — still at original pre-rebase SHA"
git -C "$T9/clone" merge-base --is-ancestor "$new_sha" "origin/main" 2>/dev/null \
  && ok "rebased PR head is now an ancestor of main (GitHub will auto-close PR as merged)" \
  || bad "rebased PR head is NOT an ancestor of main — PR would stay OPEN"

echo "J-MG-10 — red integration, GREEN base, solo PR, self-repair OFF → routed to the fix loop (old behaviour)"
# Gate fails only when the PR's content is present (FROM-PR7 lands via the union rebase);
# on the bare base (FROM-MAIN only) the same gate is green → the PR is blamed and routed.
T10="$(mktemp -d)"; make_env "$T10" stale union; run "$T10" "! grep -q FROM-PR7 shared.txt" PR_MERGER_SELF_REPAIR=0
on_main "$T10" a.txt && bad "must NOT advance main when integration gates fail" || ok "main NOT advanced on red integration"
assert_grep   "$T10/logs/gh.log" "labels[]=changes-requested" "solo PR routed to the fix loop (changes-requested)"
assert_grep   "$T10/logs/gh.log" "INTEGRATION GATES FAILED" "findings comment carries the fixer's intake marker"
assert_nogrep "$T10/logs/gh.log" "labels[]=merge-stuck" "fixable failure did NOT dead-end at merge-stuck"
assert_nogrep "$T10/logs/gh.log" "labels[]=merged" "nothing marked merged on a red integration"

echo "J-MG-11 — red integration, green base, BATCH, self-repair OFF → lowest PR blamed (old behaviour)"
T11="$(mktemp -d)"; make_env "$T11" clean; run "$T11" "test ! -f a.txt" PR_MERGER_SELF_REPAIR=0
on_main "$T11" b.txt && bad "must NOT advance main when the batch integration fails" || ok "main NOT advanced on red batch integration"
[ "$(grep -c "labels\[\]=changes-requested" "$T11/logs/gh.log")" = "1" ] && ok "exactly ONE PR (lowest) blamed with changes-requested" || bad "exactly one PR blamed"
assert_grep   "$T11/logs/gh.log" "pr comment 7" "the blame comment landed on the lowest-numbered PR (#7)"
[ "$(grep -c "labels\[\]=review-approved" "$T11/logs/gh.log")" = "1" ] && ok "the other PR requeued as review-approved for the next tick" || bad "other PR requeued"
assert_nogrep "$T11/logs/gh.log" "labels[]=merge-stuck" "batch failure did NOT dead-end at merge-stuck"
assert_nogrep "$T11/logs/gh.log" "labels[]=merged" "nothing marked merged on a red batch"

echo "J-MG-12 — self-repair isolates the failing PR → routes to fixer, requeues the clean PR"
T12="$(mktemp -d)"; make_env "$T12" clean union
# Gate: passes on base (a.txt absent), fails on integration (a.txt present from PR #7).
# In isolation, PR #7 fails (its a.txt triggers the gate) but PR #8 passes (no a.txt).
# Self-repair routes the failing PR to its fixer and requeues the clean one.
run "$T12" '[ ! -f a.txt ]'
assert_nogrep "$T12/logs/gh.log" "labels[]=merged" "nothing merged on a red integration"
assert_grep   "$T12/logs/gh.log" "labels[]=changes-requested" "failing PR routed to fixer"
# Only the failing PR (#7) gets changes-requested; the clean PR (#8) is requeued.
[ "$(grep -c "labels\[\]=changes-requested" "$T12/logs/gh.log")" = "1" ] && ok "exactly ONE PR routed to fixer" || bad "expected 1 changes-requested, got $(grep -c 'labels\[\]=changes-requested' "$T12/logs/gh.log")"
assert_nogrep "$T12/logs/gh.log" "labels[]=merge-stuck" "did NOT dead-end at merge-stuck (some PRs were at fault)"

echo "J-MG-13 — all PRs pass individually → genuine PR-vs-PR interaction → merge-stuck"
T13="$(mktemp -d)"; make_env "$T13" clean union
# Gate: passes on base, fails on integration (both a.txt AND b.txt exist), but each PR
# alone passes (only one of the files exists in isolation). This is the signature of a
# genuine PR-vs-PR conflict — two PRs that are independently green but break combined.
run "$T13" '[ ! -f a.txt ] || [ ! -f b.txt ]'
assert_grep   "$T13/logs/gh.log" "labels[]=merge-stuck" "both PRs routed to merge-stuck (genuine PR-vs-PR conflict)"
assert_nogrep "$T13/logs/gh.log" "labels[]=merged" "nothing merged on a PR-vs-PR conflict"
assert_nogrep "$T13/logs/gh.log" "labels[]=changes-requested" "no PR blamed — the conflict is between PRs, not within one"

# ── J-MG-16: a retry rebases onto the LATEST base before re-gating ────────────────
# base_ref/base_sha are captured once, before the first gate run. With the widened gate set one
# attempt is ~20-30 min and three are allowed, so `main` moves underneath a run. Re-gating the stale
# integration fails on defects main has already fixed (PR #2154: two attempts, identical e2e specs,
# no progress) and the closing fast-forward is then refused anyway.
#
# The gate below can ONLY pass after a rebase: it requires a file that exists solely on the advanced
# main. It also advances main itself on the first call, modelling a push that lands mid-run.
echo "J-MG-16 — a failed gate's retry rebases onto the advanced base before re-gating"
T16="$(mktemp -d)"; make_env "$T16" clean
cat > "$T16/bin/advancing-gate" <<GATE
#!/usr/bin/env bash
# First call: land a commit on origin/main (a human push mid-run) and FAIL.
# Later calls: pass only if that commit's file is present — i.e. only if the retry rebased.
if [ ! -f "$T16/advanced" ]; then
  touch "$T16/advanced"
  wt="\$(mktemp -d)"
  git clone -q "$T16/origin.git" "\$wt" 2>/dev/null
  ( cd "\$wt" && git checkout -q main \
    && echo "landed on main mid-run" > FROM_NEW_MAIN.txt \
    && git -c user.email=t@t -c user.name=t add -A \
    && git -c user.email=t@t -c user.name=t commit -qm "human push during the merger run" \
    && git push -q origin main ) 2>/dev/null
  rm -rf "\$wt"
  echo "gate failed: FROM_NEW_MAIN.txt absent (integration is on the stale base)"
  exit 1
fi
[ -f FROM_NEW_MAIN.txt ] || { echo "gate failed: still on the stale base"; exit 1; }
echo "gate passed: integration carries the advanced base"
GATE
chmod +x "$T16/bin/advancing-gate"
run "$T16" "$T16/bin/advancing-gate"
assert_grep "$T16/logs/out" "advanced" "the merger noticed main moved mid-run"
assert_grep "$T16/logs/out" "rebasing the integration before retrying" "it rebased before re-gating (not just re-ran the gate)"
on_main "$T16" a.txt && ok "the PR still merged after the mid-run rebase" || bad "the PR should merge once rebased onto the advanced base"
( cd "$T16/clone" && git fetch -q origin main 2>/dev/null
  git cat-file -e "origin/main:FROM_NEW_MAIN.txt" 2>/dev/null ) \
  && ok "the mid-run commit survived (the merger did not clobber main)" || bad "the mid-run commit was lost"

# The opt-out restores the old stale-base behaviour, so the same gate can never go green.
T16b="$(mktemp -d)"; make_env "$T16b" clean
sed "s#$T16#$T16b#g" "$T16/bin/advancing-gate" > "$T16b/bin/advancing-gate"; chmod +x "$T16b/bin/advancing-gate"
run "$T16b" "$T16b/bin/advancing-gate" env PR_MERGER_REBASE_ON_RETRY=0 PR_MERGER_MAX_SELF_REPAIR=1
assert_nogrep "$T16b/logs/out" "rebasing the integration before retrying" "PR_MERGER_REBASE_ON_RETRY=0 keeps the stale base"
on_main "$T16b" a.txt && bad "must NOT merge while stuck on the stale base" || ok "stale base never goes green (the bug this fixes)"

rm -rf "$T16" "$T16b" 2>/dev/null || true

# ── J-MG-17: a gate that could not RUN defers; it does not blame main ─────────────
# The failure mode this closes, observed 2026-07-26: nine integration modules each start their own
# testcontainers Postgres and immediately run `alembic upgrade head` against it. Under load the box
# cannot bring a container to listening in time and the fixture dies with ConnectionRefusedError at
# setup. The BASE run hits the same starvation, so base_is_red() returned true and the batch was
# parked at merge-stuck with "no PR is at fault; a human must fix main" — false, and unclearable by
# retry or self-repair because no code was broken.
echo "J-MG-17 — an environmental gate failure defers the batch instead of blaming main"
T17="$(mktemp -d)"; make_env "$T17" clean
cat > "$T17/bin/starved-gate" <<'GATE'
#!/usr/bin/env bash
# The exact shape the container-starvation failure produces.
echo "ERROR tests/integration/test_rls_support_conversations.py::test_cross_tenant_isolation"
echo "E    AssertionError: alembic upgrade failed:"
echo "E      ConnectionRefusedError: [Errno 111] Connect call failed ('127.0.0.1', 58084)"
exit 1
GATE
chmod +x "$T17/bin/starved-gate"
run "$T17" "$T17/bin/starved-gate"
assert_grep   "$T17/logs/out"    "ENVIRONMENTAL" "classified as environmental, not a code defect"
assert_nogrep "$T17/logs/gh.log" "labels[]=merge-stuck" "did NOT park the batch at merge-stuck"
assert_nogrep "$T17/logs/out"    "itself is red" "did NOT accuse the base of being red"
assert_grep   "$T17/logs/gh.log" "labels[]=review-approved" "batch handed back as review-approved for the next tick"
assert_nogrep "$T17/logs/out"    "self-repair attempt" "no self-repair attempt consumed on an env failure"
on_main "$T17" a.txt && bad "nothing may be merged on a failed gate" || ok "nothing merged"

# A genuine code failure (no environmental signature) must still reach the existing paths, so this
# classifier cannot become a blanket "never blame anyone".
T17b="$(mktemp -d)"; make_env "$T17b" clean
cat > "$T17b/bin/code-fail-gate" <<'GATE'
#!/usr/bin/env bash
echo "FAILED tests/unit/test_billing.py::test_seat_math - AssertionError: expected 4 got 5"
exit 1
GATE
chmod +x "$T17b/bin/code-fail-gate"
run "$T17b" "$T17b/bin/code-fail-gate" env PR_MERGER_SELF_REPAIR=0
assert_nogrep "$T17b/logs/out" "ENVIRONMENTAL" "a plain assertion failure is NOT called environmental"

# And the opt-out restores the old always-blame behaviour.
T17c="$(mktemp -d)"; make_env "$T17c" clean
cp "$T17/bin/starved-gate" "$T17c/bin/starved-gate"; chmod +x "$T17c/bin/starved-gate"
run "$T17c" "$T17c/bin/starved-gate" env PR_MERGER_TRANSIENT_DEFER=0
assert_nogrep "$T17c/logs/out" "ENVIRONMENTAL" "PR_MERGER_TRANSIENT_DEFER=0 keeps the old behaviour"

# Bounded: a box that stays starved must eventually tell a human WHAT to fix, rather than deferring
# silently forever. The gh stub is made to report prior deferral markers.
T17d="$(mktemp -d)"; make_env "$T17d" clean
cp "$T17/bin/starved-gate" "$T17d/bin/starved-gate"; chmod +x "$T17d/bin/starved-gate"
run "$T17d" "$T17d/bin/starved-gate" env PR_MERGER_MAX_ENV_DEFER=0
assert_grep "$T17d/logs/gh.log" "labels[]=merge-stuck" "an unrelenting environment eventually escalates"
assert_grep "$T17d/logs/out"    "merge-stuck on the ENVIRONMENT" "escalated on the ENVIRONMENT, not on main"

rm -rf "$T17" "$T17b" "$T17c" "$T17d" 2>/dev/null || true

# ── J-MG-14: config guard — every enforced gate must be owned by SOME stage ──────
# Not a journey: a static assertion on the units we ship. `--only unit,e2e` at merge time is how
# five regressions reached main in a single day (iteration 342) — a red org-admin auth guard, a
# permanent seat leak, a six-iteration-stale openapi.yaml, unparseable PEP 695 syntax, and a test
# whose mock had stopped intercepting so it billed real LLM calls. Each was caught the first time
# `integration`, `contract` or `typecheck` ran, and none of those ran before a merge. This fails
# loudly if someone narrows it back, because the cost of the narrowing stays invisible until main
# is already broken.
#
# Since 2026-07-31 the enforced set is SPLIT, not duplicated. One lane builds one issue at a time,
# so paying `integration`/`e2e` on every fixer round bought nothing the merge-time run did not
# already prove; the build side (inbox + fixer) now owns the fast deterministic gates and the merge
# side owns the slow interaction/infra ones. No stage runs all eleven any more, so the invariant
# this guard defends is the UNION: a gate in neither list is enforced NOWHERE and reaches main
# unchecked. The two lists below ARE the policy — change them here and in deploy/systemd together.
BUILD_GATES="typecheck lint unit coverage contract"          # inbox + fixer (fast, per-file)
MERGE_GATES="unit migration-drift integration e2e docs-refs seed-integrity repro-tests"  # merger
# `unit` is the ONE gate deliberately run on both sides, so the disjointness rule below exempts it.
# The merge-time run happens on the integration branch — the PR rebased onto whatever `main` has
# become since the fixer last gated it — so it catches a main-side change that breaks this PR's
# tests semantically without conflicting textually. It is the cheapest gate in the set (~90s), which
# is why it is worth paying twice and why nothing else is. Anything ADDED here needs the same
# justification: it must catch something the build-side run structurally cannot see.
DUP_GATES="unit"
#
# Deliberately NO pipelines below: `ok`/`bad` mutate PASS/FAIL, and a `while read` on the right of
# a pipe runs in a subshell where those increments are silently discarded — the assertion would
# then "pass" no matter what the units say.
#
# The unit list is a GLOB, not a hardcoded set of names. It used to name three services, none of
# them a template, and that blind spot cost three days: 8bb46028 narrowed the merger gate set in
# skillforge-agent-pipeline.service (which is `disabled` and never runs) and missed
# skillforge-agent-pipeline@.service (which is what the @0/@1/@2 lanes actually instantiate). The
# guard stayed green the whole time while the live merger ran the full 11-gate set on every
# integration. Any unit that configures a gate command is now in scope automatically, so adding a
# unit file cannot silently opt out of the assertion.
#
# `build_cmd_of` / `merge_cmd_of` are the ONE place that maps a unit file to a side. The standalone
# merger service configures itself through PR_GATES_CMD (not PR_MERGER_GATES_CMD), so keying off
# the variable name alone would read it as a fixer and demand the build set of it.
build_cmd_of() { # <unit> — the gate command(s) that run BEFORE review/merge
  local u="$1" out=""
  out="$(grep -oE 'AGENT_GATES_CMD=[^"]*' "$u" 2>/dev/null || true)"
  case "$(basename "$u")" in
    *pr-merger*) ;;
    *) out="${out}
$(grep -oE 'PR_GATES_CMD=[^"]*' "$u" 2>/dev/null || true)";;
  esac
  printf '%s' "$out"
}
merge_cmd_of() { # <unit> — the gate command that runs on the integration branch
  local u="$1" out=""
  out="$(grep -oE 'PR_MERGER_GATES_CMD=[^"]*' "$u" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    case "$(basename "$u")" in
      *pr-merger*) out="$(grep -oE 'PR_GATES_CMD=[^"]*' "$u" 2>/dev/null || true)";;
    esac
  fi
  printf '%s' "$out"
}

echo "J-MG-14 — each stage's shipped gate set is complete for its side (config guard)"
_mg14_build=0
_mg14_merge=0
for unit in "$ROOT"/deploy/systemd/*.service; do
  [ -f "$unit" ] || continue
  base="$(basename "$unit")"
  bcmd="$(build_cmd_of "$unit")"
  mcmd="$(merge_cmd_of "$unit")"
  if [ -n "${bcmd//[[:space:]]/}" ]; then
    _mg14_build=$((_mg14_build + 1))
    missing=""
    for g in $BUILD_GATES; do
      case "$bcmd" in *"$g"*) ;; *) missing="${missing} ${g}";; esac
    done
    if [ -n "$missing" ]; then bad "$base: build-side gate omits:${missing}"
    else ok "$base: build-side gate covers $BUILD_GATES"; fi
  fi
  if [ -n "${mcmd//[[:space:]]/}" ]; then
    _mg14_merge=$((_mg14_merge + 1))
    missing=""
    for g in $MERGE_GATES; do
      case "$mcmd" in *"$g"*) ;; *) missing="${missing} ${g}";; esac
    done
    if [ -n "$missing" ]; then bad "$base: merge-side gate omits:${missing}"
    else ok "$base: merge-side gate covers $MERGE_GATES"; fi
    if grep -qE '(PR_GATES_CMD|PR_MERGER_GATES_CMD)=scripts/quality-gates\.sh( --keep-going)? --only unit,e2e' "$unit"; then
      bad "$base: merge gate narrowed back to the iteration-342 value '--only unit,e2e'"
    else
      ok "$base: merge gate not narrowed to unit,e2e"
    fi
  fi
done
# A glob that matches nothing, or a grep that stops matching because the Environment= line was
# reworded, would make every assertion above vacuous — the loop body would simply never run and
# J-MG-14 would report all-green having inspected zero units. Assert the coverage itself.
if [ "$_mg14_build" -ge 5 ]; then
  ok "J-MG-14 inspected $_mg14_build build-side unit(s)"
else
  bad "J-MG-14 inspected only $_mg14_build build-side unit(s) — expected >=5 (inbox, inbox@, pipeline, pipeline@, pr-fixer); the guard is passing vacuously"
fi
if [ "$_mg14_merge" -ge 3 ]; then
  ok "J-MG-14 inspected $_mg14_merge merge-side unit(s)"
else
  bad "J-MG-14 inspected only $_mg14_merge merge-side unit(s) — expected >=3 (pipeline, pipeline@, pr-merger); the guard is passing vacuously"
fi

# ── J-MG-14b: the split is DISJOINT — no gate is paid for on both sides ───────────
# The point of the split is that the slow gates run once, at merge time, on the tree that actually
# lands. A merge-side list that also carries `unit` or `typecheck` re-pays work the fixer already
# proved on the same commits and silently gives back the throughput the split bought.
# Globbed for the same reason as J-MG-14: the template carried the un-narrowed value for three
# days precisely because it was not on the hardcoded list.
echo "J-MG-14b — merge-side gate set does not duplicate build-side gates"
_mg14b_checked=0
for unit in "$ROOT"/deploy/systemd/*.service; do
  [ -f "$unit" ] || continue
  base="$(basename "$unit")"
  mcmd="$(merge_cmd_of "$unit")"
  [ -n "${mcmd//[[:space:]]/}" ] || continue
  _mg14b_checked=$((_mg14b_checked + 1))
  for g in $BUILD_GATES; do
    case " $DUP_GATES " in *" $g "*) continue;; esac   # deliberately paid twice — see DUP_GATES
    case "$mcmd" in
      *"$g"*) bad "$base: merger includes $g (already proven build-side — duplicated work)";;
      *) ok "$base: merger correctly skips $g";;
    esac
  done
  # The exemption must not become a blanket one: an exempted gate still has to be PRESENT on the
  # merge side, or DUP_GATES would be silently documenting a duplication that no longer happens.
  for g in $DUP_GATES; do
    case "$mcmd" in
      *"$g"*) ok "$base: merger keeps $g (intentional both-sides gate)";;
      *) bad "$base: $g is listed in DUP_GATES but the merger does not run it";;
    esac
  done
done
if [ "$_mg14b_checked" -ge 3 ]; then
  ok "J-MG-14b inspected $_mg14b_checked merger unit(s)"
else
  bad "J-MG-14b inspected only $_mg14b_checked merger unit(s) — expected >=3 (pipeline, pipeline@, pr-merger); the guard is passing vacuously"
fi

# ── J-MG-14c: the build side stays FAST — no slow merge-side gate leaks into it ───
# inbox and fixer run on every build and every fix round. A stack-booting gate there costs that
# many multiples; `e2e` and `integration` belong to the single merge-time run.
echo "J-MG-14c — build-side gate set carries no merge-side (slow) gate"
_mg14c_checked=0
for unit in "$ROOT"/deploy/systemd/*.service; do
  [ -f "$unit" ] || continue
  base="$(basename "$unit")"
  bcmd="$(build_cmd_of "$unit")"
  [ -n "${bcmd//[[:space:]]/}" ] || continue
  _mg14c_checked=$((_mg14c_checked + 1))
  for g in $MERGE_GATES; do
    case " $DUP_GATES " in *" $g "*) continue;; esac   # deliberately paid twice — see DUP_GATES
    case "$bcmd" in
      *"$g"*) bad "$base: build-side includes $g — that gate runs once, at merge time";;
      *) ok "$base: build-side correctly skips $g";;
    esac
  done
done
if [ "$_mg14c_checked" -ge 5 ]; then
  ok "J-MG-14c inspected $_mg14c_checked build-side unit(s)"
else
  bad "J-MG-14c inspected only $_mg14c_checked build-side unit(s) — expected >=5 (inbox, inbox@, pipeline, pipeline@, pr-fixer); the guard is passing vacuously"
fi

# ── J-MG-15: the merger lock must stay GLOBAL across pipeline instances ───────────
# Static assertion on the shipped template. Every other lock in skillforge-agent-pipeline@.service
# is namespaced by %i so lanes run in parallel; PR_MERGER_LOCK must NOT be, because the merger is
# the only stage that advances `main`. Two mergers would each build an integration from a different
# base and race to fast-forward. Templating that path would break the one exclusivity guarantee in
# the design and nothing would fail loudly — you would simply lose commits. Hence a test.
echo "J-MG-15 — PR_MERGER_LOCK is shared across pipeline lanes (no %i), other locks are not"
tpl="$ROOT/deploy/systemd/skillforge-agent-pipeline@.service"
if [ ! -f "$tpl" ]; then
  bad "missing template: $tpl"
else
  mlock="$(grep -oE 'PR_MERGER_LOCK=[^ ]*' "$tpl" || true)"
  case "$mlock" in
    *%i*) bad "PR_MERGER_LOCK is per-instance ($mlock) — two mergers could race to advance main";;
    "")   bad "template does not set PR_MERGER_LOCK at all";;
    *)    ok "PR_MERGER_LOCK is shared: $mlock";;
  esac
  # And the counter-check: the locks that MUST be per-instance actually are, or the lanes would
  # serialise and the template would buy nothing.
  for v in PIPELINE_LOCK PR_REVIEWER_LOCK PR_FIXER_LOCK AGENT_LOCK; do
    val="$(grep -oE "${v}=[^ ]*" "$tpl" | head -1 || true)"
    case "$val" in
      *%i*) ok "$v is per-instance";;
      "")   bad "template does not set $v";;
      *)    bad "$v is NOT per-instance ($val) — lanes would serialise on it";;
    esac
  done
fi

# ── J-MG-26: every entry point to the merger must resolve the SAME lock path ─────
# J-MG-15 above proves the template carries no %i. That is necessary and not sufficient:
# it never compared the path against the OTHER units, or against the script default the
# pipeline probes. Both gaps were live (issue #2387, H3):
#
#   agent-pipeline.sh   ${PR_MERGER_LOCK:-/tmp/agent-pr-merger.lock}       ← no $NS
#   agent-pr-merger.sh  ${PR_MERGER_LOCK:-/tmp/agent-pr-merger-$NS.lock}   ← $NS
#   skillforge-agent-pr-merger.service   (set nothing → the script default)
#   skillforge-agent-pipeline*.service   PR_MERGER_LOCK=/tmp/skillforge-agent-pr-merger.lock
#
# So outside systemd the pipeline probed a file the merger never creates, and if the
# standalone merger timer were re-enabled the two mergers would take DIFFERENT locks —
# the "globally exclusive merger" invariant gone, silently, with two processes racing to
# fast-forward `main`. A path mismatch must fail loudly here, not become lost commits.
echo "J-MG-26 — all merger entry points resolve the same PR_MERGER_LOCK"
units=(
  "$ROOT/deploy/systemd/skillforge-agent-pipeline.service"
  "$ROOT/deploy/systemd/skillforge-agent-pipeline@.service"
  "$ROOT/deploy/systemd/skillforge-agent-pr-merger.service"
)
declare -A seen_paths=()
for u in "${units[@]}"; do
  if [ ! -f "$u" ]; then bad "missing unit: $(basename "$u")"; continue; fi
  p="$(grep -oE '^Environment=PR_MERGER_LOCK=.*' "$u" | head -1 | sed 's/.*PR_MERGER_LOCK=//' || true)"
  if [ -z "$p" ]; then
    bad "$(basename "$u") does not set PR_MERGER_LOCK — it would fall through to the script default while the others override it"
  else
    seen_paths["$p"]=1
    ok "$(basename "$u") sets PR_MERGER_LOCK=$p"
  fi
done
if [ "${#seen_paths[@]}" -eq 1 ]; then
  ok "all units agree on one merger lock path: ${!seen_paths[*]}"
else
  bad "merger lock paths DIVERGE across units (${!seen_paths[*]}) — two mergers could hold different locks and both advance main"
fi

# The two scripts' built-in defaults must agree too, for any run started outside systemd
# (a hand-run pipeline, a test host, a port of the harness that ships no units).
# `${NS}` and `$NS` are the same path spelled two ways, so normalise the brace form before
# comparing — otherwise this asserts a cosmetic convention rather than the actual invariant.
lock_default() { # <script>
  sed 's/\${NS}/$NS/g' "$1" | grep -oE 'PR_MERGER_LOCK:-[^}]*' | head -1 | sed 's/PR_MERGER_LOCK:-//'
}
pl_default="$(lock_default "$ROOT/scripts/agent-pipeline.sh" || true)"
mg_default="$(lock_default "$ROOT/scripts/agent-pr-merger.sh" || true)"
if [ -n "$pl_default" ] && [ "$pl_default" = "$mg_default" ]; then
  ok "agent-pipeline.sh and agent-pr-merger.sh share a default lock path ($pl_default)"
else
  bad "default lock paths differ — pipeline='$pl_default' merger='$mg_default'; the pipeline would probe a file the merger never creates"
fi

# ── J-MG-27: the fixer-routing comment must actually carry the failed gates ──────
# The `pr comment` that routes a PR to the fixer after a full-gate failure had its printf
# format wrapped in `'"'"'` at the OUTER boundary — the idiom for embedding a single quote
# INSIDE a single-quoted string, used as the quoting itself. The body and its ``` fences
# were therefore unquoted: the backticks ran as command substitution, `\n` degraded to a
# literal `n`, and the posted comment came out corrupted (empty, in the merger's `$( … )`
# context). The fixer lost the only machine-readable statement of WHICH gates failed, and
# nothing failed loudly (issue #2387, C4; shellcheck SC1012 flags it).
#
# This lifts the real line out of the shipped script and executes it against a recorder,
# so it tests the production quoting rather than a copy of it.
echo "J-MG-27 — the fixer-routing PR comment carries the failed-gate context"
T27="$(mktemp -d)"
cmt_line="$(grep -nF 'FAILED the full gate suite after a flaky narrow-gate pass' "$RUNNER" | grep 'pr comment' | head -1 | cut -d: -f2-)"
if [ -z "$cmt_line" ]; then
  bad "could not locate the fixer-routing pr-comment line in $RUNNER"
else
  {
    # the body is the last argument (`pr comment <n> -b <body>`)
    echo 'GH() { printf "%s" "${!#}" > "'"$T27"'/body"; }'
    echo 'PR_NUMS=(4242); LOGDIR="'"$T27"'"'
    echo 'failed_gates() { printf "unit  fail  3 tests failed\nlint  fail  ruff E501\n"; }'
    # `"$GH" pr comment …` → `GH pr comment …`, keeping every byte of the quoting intact.
    printf '%s\n' "${cmt_line//\"\$GH\"/GH}"
  } > "$T27/render.sh"
  bash "$T27/render.sh" 2>"$T27/err"
  body="$(cat "$T27/body" 2>/dev/null || true)"
  [ -n "$body" ] && ok "the comment body is non-empty" \
    || bad "the comment body is EMPTY — the quoting is mangled again"$'\n'"stderr: $(cat "$T27/err" 2>/dev/null)"
  grep -q '4242' <<<"$body" && ok "the body names the PR number" \
    || bad "the body does not name the PR (got: ${body:0:120})"
  grep -q 'unit  fail' <<<"$body" && ok "the body includes the failed gates" \
    || bad "the body drops the failed-gate context (got: ${body:0:120})"
  grep -q 'command not found' "$T27/err" 2>/dev/null \
    && bad "backticks in the body executed as command substitution" \
    || ok "no command substitution leaked out of the body"
fi
# And no sibling has copied the idiom. It appeared exactly once in the tree.
# NB: `… | grep -q …` would be wrong here. Under this file's `set -o pipefail`, grep -q exits
# on the first match, SIGPIPEs the producer, and the PIPELINE reports 141 — so the `if` takes
# the else branch and the assertion passes exactly when it should fail. (Observed while
# mutation-checking this very test.) `grep -c` drains its input, so no SIGPIPE.
idiom_hits="$(grep -rn "pr comment" "$ROOT/scripts"/*.sh | grep -c "'\"'\"'" || true)"
if [ "${idiom_hits:-0}" -gt 0 ]; then
  bad "the '\"'\"' outer-quoting idiom is back in ${idiom_hits} pr-comment call(s)"
else
  ok "no pr-comment call uses the mangled outer-quoting idiom"
fi
rm -rf "$T27" 2>/dev/null || true

# ── J-MG-17..20: a flaky gate must not be able to wedge the merge queue (#2175) ──────────────
# base_is_red() used to believe ONE sample. On 2026-07-26 that marked PRs #2154/#2162/#2165
# merge-stuck at 30691a6 because seven mobile tests blew a 5000ms timeout on dynamic imports
# under load — the same seven pass in 783ms, and main was never broken. A red first sample is
# now CONFIRMED by re-running only the gates it reported as failed.
#
# The stub gate below emits a quality-gates-style summary so failed_gates() can parse it, fails
# the FULL run every time, and passes any narrowed `--only` re-run — i.e. exactly a flake.
mk_flaky_base_gate() { # <tmp> <path>
  cat > "$2" <<GATE
#!/usr/bin/env bash
# The integration run (no --only) always fails, so the merger reaches base_is_red().
# A narrowed re-run (--only …) PASSES → the first red sample was a flake.
if printf '%s' "\$*" | grep -q -- '--only'; then
  echo "re-run of the narrowed gate set passed"
  exit 0
fi
cat <<'SUM'
── Quality gates summary (tier: launch) ──
  typecheck      pass    ok
  unit           fail  see /tmp/qg-x/unit.log — timed out
SUM
exit 1
GATE
  chmod +x "$2"
}

echo "J-MG-17 — a flaky red base is re-confirmed; PRs are judged normally, NOT merge-stuck"
T17="$(mktemp -d)"; make_env "$T17" clean
mk_flaky_base_gate "$T17" "$T17/bin/flaky-base-gate"
run "$T17" "$T17/bin/flaky-base-gate" PR_MERGER_SELF_REPAIR=0
assert_grep   "$T17/logs/out" "re-running just those gates" "the merger re-confirmed the red base instead of trusting one sample"
assert_grep   "$T17/logs/out" "was a flake" "the re-run cleared the base"
assert_nogrep "$T17/logs/gh.log" "labels[]=merge-stuck" "a flaky base did NOT wedge the queue"
assert_grep   "$T17/logs/gh.log" "labels[]=changes-requested" "the PR was judged normally (routed to the fix loop)"

echo "J-MG-18 — the confirmation re-runs ONLY the gates the first sample failed"
assert_grep "$T17/logs/out" "[unit]" "the re-run was scoped to the failing gate (unit), not the full set"

echo "J-MG-19 — a genuinely red base (both samples fail) still goes merge-stuck + files an issue"
T19="$(mktemp -d)"; make_env "$T19" clean
cat > "$T19/bin/really-red-gate" <<'GATE'
#!/usr/bin/env bash
cat <<'SUM'
── Quality gates summary (tier: launch) ──
  unit           fail  see /tmp/qg-x/unit.log — genuinely broken
SUM
exit 1
GATE
chmod +x "$T19/bin/really-red-gate"
run "$T19" "$T19/bin/really-red-gate"
assert_grep "$T19/logs/out"    "genuinely red"  "both samples failed → the base is believed red"
[ "$(grep -c "labels\[\]=merge-stuck" "$T19/logs/gh.log")" = "2" ] && ok "a truly red base still stops the queue (J-MG-3 property intact)" || bad "truly red base must still merge-stuck"
assert_grep "$T19/logs/gh.log" "issue create" "an agent issue was filed so the inbox can fix main (a red base now has an owner)"
assert_grep "$T19/logs/gh.log" "--label agent" "the filed issue carries the agent label (agent-inbox picks it up)"

echo "J-MG-20 — the fix is opt-out-able, and disabling it restores the old wedge (so this test fails if the fix is a no-op)"
T20="$(mktemp -d)"; make_env "$T20" clean
mk_flaky_base_gate "$T20" "$T20/bin/flaky-base-gate"
run "$T20" "$T20/bin/flaky-base-gate" PR_MERGER_CONFIRM_BASE_RED=0
[ "$(grep -c "labels\[\]=merge-stuck" "$T20/logs/gh.log")" = "2" ] && ok "with confirmation disabled the flake wedges the queue again (the fix is load-bearing)" || bad "PR_MERGER_CONFIRM_BASE_RED=0 should restore the single-sample behaviour"
assert_nogrep "$T20/logs/out" "re-running just those gates" "no confirmation run when opted out"

# ── J-MG-21..24: the resolver must reset between retries, and no marker may reach main (#2185) ──
# Three defects lined up here. (1) invoke_resolver staged the model's output with `git add -A`
# before checking it, collapsing index stages 1/2/3 into stage 0 and destroying the conflict — so
# the `git checkout -- $conflicted` meant to reset for the retry restored the file FROM THE INDEX,
# i.e. the marker-laden text the model had just written. "3 escalating attempts" was one attempt
# plus two on progressively more degraded input. (2) With the stages gone, the generated-file
# fallback's `git checkout --theirs` updated 0 paths and exited 0 — a silent no-op — after which
# `git add` staged the marker text and the function returned `ok`. (3) has_conflict_markers(),
# whose whole reason for existing is "refuse to ship a tree with a marker in it", was never called
# on the push path; its only caller was inside the resolver loop.
#
# A fourth defect only visible once (1) and (2) are exercised together: invoke_resolver returns its
# verdict on STDOUT, and three of its `log` calls wrote to stdout too, so the caller read
# "…retrying\n…\nstuck" instead of "stuck", matched no `case` arm, and fell through to the
# success branch. J-MG-22 below is the end-to-end proof: before this fix, that path fast-forwarded
# `main` onto a tree of conflict markers and logged "MERGED 2 PR(s)".

echo "J-MG-21 — a resolver retry is handed the ORIGINAL conflict, not the previous attempt's output"
T21="$(mktemp -d)"; make_env "$T21" conflict retry-reset; run "$T21" "true"
if [ -f "$T21/seen-attempt-2.txt" ]; then
  ok "the resolver was retried after attempt 1 left markers"
  seen2="$(cat "$T21/seen-attempt-2.txt")"
  printf '%s' "$seen2" | grep -q FROM-PR7 && printf '%s' "$seen2" | grep -q FROM-PR8 \
    && ok "attempt 2 saw the ORIGINAL conflict (both sides present)" \
    || bad "attempt 2 did not see the original conflict — the tree was not reset"
  printf '%s' "$seen2" | grep -q ATTEMPT1-GARBAGE \
    && bad "attempt 2 was handed attempt 1's mangled output (the bug)" \
    || ok "attempt 2 was NOT handed attempt 1's mangled output"
else
  bad "the resolver was retried after attempt 1 left markers"
  bad "attempt 2 saw the ORIGINAL conflict (both sides present)"
  bad "attempt 2 was NOT handed attempt 1's mangled output"
fi
blob21="$(main_blob "$T21" shared.txt)"
printf '%s' "$blob21" | grep -q FROM-PR7 && printf '%s' "$blob21" | grep -q FROM-PR8 \
  && ok "attempt 2's clean resolution unioned both PRs onto main" || bad "union of both PRs on main"
printf '%s' "$blob21" | grep -q ATTEMPT1-GARBAGE && bad "attempt 1's garbage reached main" || ok "attempt 1's garbage never reached main"
printf '%s' "$blob21" | grep -qE '^(<<<<<<<|>>>>>>>)' && bad "conflict markers leaked onto main" || ok "no conflict markers on main"

echo "J-MG-22 — a state/state.json-only conflict the resolver never clears is auto-resolved for real, never with markers"
# The regeneratable allowlist (docs/06-iteration-log.md, its digest, state/state.json) is the one
# path where marker pollution can survive the gates: the first two are regenerated after the merge
# loop, but state/state.json is NOT, and no gate parses it. Resolver never resolves → all retries
# exhausted → generated-file fallback. It must produce a real resolution or refuse.
T22="$(mktemp -d)"; make_env "$T22" genfile bad; run "$T22" "true"
blob22="$(main_blob "$T22" state/state.json)"
printf '%s' "$blob22" | grep -qE '^(<<<<<<<|>>>>>>>)' \
  && bad "conflict markers reached main in state/state.json (Bug 2 + Bug 3)" \
  || ok "state/state.json on main is marker-free"
printf '%s' "$blob22" | jq -e . >/dev/null 2>&1 && ok "state/state.json on main is still valid JSON" || bad "state/state.json on main is not valid JSON"
assert_grep   "$T22/logs/out"    "auto-resolving generated files" "the generated-file fallback is the path under test (retries were exhausted first)"
assert_nogrep "$T22/logs/gh.log" "labels[]=merge-stuck" "a genuinely auto-resolvable generated-file conflict did not need a human"
assert_grep   "$T22/logs/gh.log" "labels[]=merged" "the PR merged once the fallback really resolved it"

echo "J-MG-23 — the generated-file fallback fails to STUCK when it cannot actually resolve"
# `git checkout --theirs` reports success on a tree it did not clean: here "theirs" is a
# state/state.json that already carries a committed conflict marker, so taking it wholesale exits 0
# and still leaves a marker. The fallback must check its own output, not its exit code.
T23="$(mktemp -d)"; make_env "$T23" genfile-poison bad; run "$T23" "true"
assert_grep   "$T23/logs/out"    "could not actually resolve" "the fallback reported its own failure instead of returning ok"
assert_grep   "$T23/logs/gh.log" "labels[]=merge-stuck" "an unresolvable generated-file conflict goes to merge-stuck"
assert_nogrep "$T23/logs/gh.log" "labels[]=merged" "nothing merged when the fallback could not resolve"
( cd "$T23/clone" && git fetch -q origin main 2>/dev/null
  [ "$(git show origin/main:state/state.json 2>/dev/null)" = '{"iteration_count":99}' ] ) \
  && ok "main's state/state.json is untouched" || bad "main's state/state.json was modified"

echo "J-MG-24 — a marker-polluted integration tree is never fast-forwarded onto main"
# The guard is the last line of defence and must hold no matter HOW the marker got in, so this
# plants one directly: a gate that commits a marker into the integration and then reports green,
# standing in for any resolver/self-repair step that leaves pollution behind. Before #2185 nothing
# looked at the tree between "gates green" and `git push HEAD:main`.
T24="$(mktemp -d)"; make_env "$T24" clean
cat > "$T24/bin/polluting-gate" <<'GATE'
#!/usr/bin/env bash
# Commit a conflict marker into the integration, then report success.
printf 'line1\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n' > shared.txt
git -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm "gate left a marker" >/dev/null 2>&1
echo "gates green"
GATE
chmod +x "$T24/bin/polluting-gate"
run "$T24" "$T24/bin/polluting-gate"
blob24="$(main_blob "$T24" shared.txt)"
printf '%s' "$blob24" | grep -qE '^(<<<<<<<|>>>>>>>)' && bad "a marker-polluted tree was pushed to main" || ok "marker-polluted tree NOT pushed to main"
on_main "$T24" a.txt && bad "main must not advance when the integration carries markers" || ok "main not advanced"
assert_grep   "$T24/logs/out"    "refusing to push" "the pre-push guard fired"
assert_grep   "$T24/logs/gh.log" "labels[]=merge-stuck" "the polluted integration was routed to merge-stuck"
assert_nogrep "$T24/logs/gh.log" "labels[]=merged" "nothing marked merged when markers were found"

# Counter-check: the guard is scoped to what the integration CHANGED, so a marker that is merely
# committed elsewhere in main must not abort every merge. That false positive is not hypothetical —
# a stray marker pair in docs/06-gap-analysis.md (PR #726 squash edad2cdc) sat dormant for weeks and
# then failed PR #1473's integration, and was cleaned in 8a392463.
echo "J-MG-25 — a dormant marker elsewhere in main does not block an unrelated integration"
T25="$(mktemp -d)"; make_env "$T25" clean
( cd "$T25/clone" && git checkout -q main
  mkdir -p docs && printf 'text\n<<<<<<< dormant\nA\n=======\nB\n>>>>>>> dormant\n' > docs/quoted-markers.md
  git add -A && git commit -qm "a marker legitimately committed in main" >/dev/null && git push -q origin main ) 2>/dev/null
run "$T25" "true"
on_main "$T25" a.txt && ok "the unrelated PR still merged despite the dormant marker in main" || bad "a dormant marker in main blocked an unrelated integration"
assert_nogrep "$T25/logs/gh.log" "labels[]=merge-stuck" "a dormant marker in an untouched file did not wedge the queue"

# ── J-MG-28/29/30 — an unprovisioned worktree is never a verdict on main (#2438) ──────
# `npm ci` exits 0 on an install that left a workspace short of a package. When that workspace is
# `mobile/`, `extends: expo/tsconfig.base` fails to resolve and all ~154 mobile suites die at
# TRANSFORM time — no assertion ever runs. The `unit` gate goes red, and because a missing package
# is perfectly deterministic the base re-run and the anti-flake confirmation re-run reproduce it
# exactly. On 2026-08-01 that chain concluded `main` was red at c4b2609a, parked the queue at
# merge-stuck and filed a p0 issue against a `main` whose unit gate is green in any healthy
# worktree. Every flake guard held; none of them was measuring the right thing.
# <bare-extends-specifier> is DECLARED as a dependency of the workspace, matching a real
# mobile/package.json ("expo": "~54.0.36") — these fixtures model an install gap (declared but not
# yet on disk), which is the only shape gate_failure_is_deps() may excuse as environmental. J-MG-31
# below is the counter-fixture: same unresolved tsconfig, but the package is declared NOWHERE.
add_broken_workspace() { # <clone> <workspace-dir> <bare-extends-specifier>
  local clone="$1" ws="$2" spec="$3" pkg ws_json
  mkdir -p "$clone/$ws"
  printf '{\n  "compilerOptions": { "paths": { "@/*": ["./src/*"] } },\n  "extends": "%s"\n}\n' "$spec" \
    > "$clone/$ws/tsconfig.json"
  pkg="$(printf '%s\n' "$spec" | sed -E 's#^(@[^/]+/[^/]+|[^/]+).*#\1#')"
  printf '{"name":"%s","version":"1.0.0","private":true,"dependencies":{"%s":"*"}}\n' "$ws" "$pkg" \
    > "$clone/$ws/package.json"
  ws_json="$(jq -c --arg w "$ws" '.workspaces = ((.workspaces // []) + [$w] | unique)' "$clone/package.json")"
  printf '%s\n' "$ws_json" > "$clone/package.json"
  # npm workspaces always symlinks a member into the root node_modules by its own package.json
  # name (deps_workspace_unlinked's self-link check, J-MG-32/33 below). Model that so these
  # fixtures isolate the THIRD-PARTY dependency (expo, present or not per test) as the only
  # variable — an "added" workspace is never itself missing from a healthy install. Committed
  # (like the base fixture's own node_modules/.keep in make_env), not just written to $clone: the
  # merger's worktree is a `git worktree add` checkout of the integration branch, which only sees
  # tracked files, and $ROOT's ".": case in provision_deps() never symlinks $wt/node_modules over
  # it because make_env already committed node_modules/.keep there as a real (non-symlink)
  # directory.
  mkdir -p "$clone/node_modules/$ws"; : > "$clone/node_modules/$ws/.keep"
  ( cd "$clone" && git add -A "$ws" package.json "node_modules/$ws" \
      && git commit -qm "add $ws workspace" && git push -q origin main ) 2>/dev/null
}

echo "J-MG-28 — an unresolvable workspace dep defers the batch instead of running the gates blind"
T28="$(mktemp -d)"; make_env "$T28" clean
add_broken_workspace "$T28/clone" mobile "expo/tsconfig.base"
run "$T28" "touch $T28/gates-ran; false"
[ ! -e "$T28/gates-ran" ] && ok "the gates were never run on a tree that cannot load its modules" \
  || bad "the gates ran against an unprovisioned worktree"
assert_grep   "$T28/logs/out"    "expo (mobile)"        "the diagnosis names the unresolved package and workspace"
assert_grep   "$T28/logs/out"    "ENVIRONMENTAL"        "classified as environmental, not as a code failure"
# Symlink mode (what `run()` always uses) never runs an npm command, so deps-integration.log would
# otherwise stay empty and the PR comment's fenced log block would be blank. provision_deps() must
# write a summary into it before returning, so the comment actually explains itself.
assert_grep   "$T28/logs/gh.log" "host install mirrored, never repaired" "the deferral comment quotes a non-empty log (symlink mode wrote its own summary)"
assert_grep   "$T28/logs/gh.log" "labels[]=review-approved" "the batch was handed back for the next tick"
assert_nogrep "$T28/logs/gh.log" "labels[]=merge-stuck" "main was NOT accused (this is what wedged the queue)"
assert_nogrep "$T28/logs/gh.log" "labels[]=changes-requested" "no PR was blamed either"
assert_nogrep "$T28/logs/gh.log" "issue create"        "no p0 base-red issue filed against a green main"
on_main "$T28" a.txt && bad "main advanced on an unverified tree" || ok "main not advanced"

echo "J-MG-29 — the same check is re-measured when the install is evicted DURING the gate run"
# provision_deps() cannot catch an install that disappears after it returns. A per-package
# `npm ci` in a concurrent stage resolves the root lockfile but installs only its own subtree,
# deleting what the siblings needed (measured on #2395), so the tree can go from healthy to
# unloadable mid-run. The gate stub below stands in for exactly that: it breaks the workspace and
# then fails, the shape that previously reached base_is_red() and came back "main is red".
T29="$(mktemp -d)"; make_env "$T29" clean
cat > "$T29/bin/evicting-gate" <<'GATE'
#!/usr/bin/env bash
# Simulate a concurrent per-package install evicting the sibling workspace mid-gate, then go red.
mkdir -p mobile
printf '{\n  "extends": "expo/tsconfig.base"\n}\n' > mobile/tsconfig.json
printf '{"name":"mobile","version":"1.0.0","private":true,"dependencies":{"expo":"*"}}\n' > mobile/package.json
jq -c '.workspaces = ((.workspaces // []) + ["mobile"] | unique)' package.json > package.json.new \
  && mv package.json.new package.json
echo "FAIL Error: Cannot find base config file \"expo/tsconfig.base\""
exit 1
GATE
chmod +x "$T29/bin/evicting-gate"
run "$T29" "$T29/bin/evicting-gate"
assert_grep   "$T29/logs/out"    "expo (mobile)"        "the mid-run eviction is diagnosed by re-measuring the tree"
assert_nogrep "$T29/logs/gh.log" "labels[]=merge-stuck" "a red produced by an unloadable tree is not merge-stuck"
assert_nogrep "$T29/logs/gh.log" "issue create"         "and files no issue blaming main"
assert_grep   "$T29/logs/gh.log" "labels[]=review-approved" "the batch is deferred for the next tick"
on_main "$T29" a.txt && bad "main advanced on a red integration" || ok "main not advanced"

echo "J-MG-30 — a healthy tree is unaffected, and a genuine red base still reaches merge-stuck"
# The guard must not become a blanket excuse: it keys off the TREE, not off the log text, so a
# real 'Cannot find module' from a deleted import still fails the way it always did. Same broken
# workspace as J-MG-28, but with the package actually installed — the merge must proceed.
T30="$(mktemp -d)"; make_env "$T30" clean
add_broken_workspace "$T30/clone" mobile "expo/tsconfig.base"
mkdir -p "$T30/clone/mobile/node_modules/expo"; echo '{}' > "$T30/clone/mobile/node_modules/expo/package.json"
run "$T30" "true"
assert_nogrep "$T30/logs/out"    "ENVIRONMENTAL"        "a resolvable workspace is not flagged as a deps failure"
on_main "$T30" a.txt && ok "a healthy tree merges normally" || bad "the deps guard blocked a healthy merge"
# …and a code-shaped red on a tree that resolves fine still goes to merge-stuck via the base check.
# NB: `expo` goes under mobile/node_modules, not the clone's root node_modules — make_env COMMITS
# a root node_modules/.keep, so the worktree checks one out and the symlink to the host's root
# install is never created. mobile/node_modules is untracked, so it is the one that gets mirrored.
T31="$(mktemp -d)"; make_env "$T31" clean
add_broken_workspace "$T31/clone" mobile "expo/tsconfig.base"
mkdir -p "$T31/clone/mobile/node_modules/expo"; echo '{}' > "$T31/clone/mobile/node_modules/expo/package.json"
run "$T31" "echo 'FAIL Cannot find module ./deleted-helper'; false"
assert_grep   "$T31/logs/gh.log" "labels[]=merge-stuck" "a genuine red base on a RESOLVABLE tree is still merge-stuck"
assert_nogrep "$T31/logs/out"    "ENVIRONMENTAL"        "'Cannot find module' in the log alone never excuses a red"

rm -rf "$T28" "$T29" "$T30" "$T31" 2>/dev/null || true

echo "J-MG-31 — a PR that breaks its OWN workspace dependency is blamed, not excused as environmental"
# Same unresolvable "extends: expo/tsconfig.base" signature as J-MG-28, but this time the package
# is committed on the PR BRANCH only (base/main never has a mobile workspace at all), and it is
# declared NOWHERE — the shape of a PR that deletes `expo` from `mobile/package.json` while
# `mobile/tsconfig.json` still extends it. deps_unresolved_summary reports this identically to a
# genuine install gap, so only the declared-dependency check tells them apart: the base re-run
# never reproduces it (base has no mobile workspace to fail), so it must reach the ordinary
# red-integration path and blame the PR — never `defer_batch`, never ENVIRONMENTAL.
T32="$(mktemp -d)"; make_env "$T32" clean
( cd "$T32/clone" && git checkout -q agent/issue-5
  mkdir -p mobile
  printf '{\n  "compilerOptions": { "paths": { "@/*": ["./src/*"] } },\n  "extends": "expo/tsconfig.base"\n}\n' \
    > mobile/tsconfig.json
  printf '{"name":"mobile","version":"1.0.0","private":true}\n' > mobile/package.json
  jq -c '.workspaces = ((.workspaces // []) + ["mobile"] | unique)' package.json > package.json.new \
    && mv package.json.new package.json
  git add -A mobile package.json && git commit -qm "PR breaks the mobile workspace dependency" \
    && git push -q origin agent/issue-5 ) 2>/dev/null
run "$T32" "[ ! -f mobile/tsconfig.json ] || [ -d mobile/node_modules/expo ]" PR_MERGER_SELF_REPAIR=0
assert_grep   "$T32/logs/gh.log" "labels[]=changes-requested" "the PR that broke its own workspace dependency is blamed, not excused"
assert_grep   "$T32/logs/gh.log" "INTEGRATION GATES FAILED"   "routed through the normal fix loop"
assert_nogrep "$T32/logs/out"    "ENVIRONMENTAL"    "an undeclared dependency is never classified environmental"
assert_nogrep "$T32/logs/gh.log" "labels[]=merge-stuck" "not blamed on main either — main never had the broken workspace"
on_main "$T32" a.txt && bad "main advanced on a red integration" || ok "main not advanced"
rm -rf "$T32" 2>/dev/null || true

echo "J-MG-32 — a sibling workspace with NO 'extends' at all is still caught when evicted mid-run"
# The extends-only check is blind to a workspace whose tsconfig has no bare `extends` (frontend,
# packages/api-client, extensions/vscode in the real repo have none) — the other half of the
# eviction class this file exists to close. deps_workspace_unlinked() catches it via the missing
# npm-workspaces self-link instead.
T33="$(mktemp -d)"; make_env "$T33" clean
cat > "$T33/bin/evicting-sibling-gate" <<'GATE'
#!/usr/bin/env bash
# A per-package `npm ci` in a concurrent stage installed only its own subtree and evicted the
# frontend/ workspace's root symlink mid-run, then the gate goes red at module-load time.
mkdir -p frontend
printf '{ "compilerOptions": {} }\n' > frontend/tsconfig.json   # no "extends" — invisible to that check
printf '{"name":"frontend","version":"1.0.0","private":true}\n' > frontend/package.json
jq -c '.workspaces = ((.workspaces // []) + ["frontend"] | unique)' package.json > package.json.new \
  && mv package.json.new package.json
echo "FAIL Error: Cannot find module 'vitest/config'"
exit 1
GATE
chmod +x "$T33/bin/evicting-sibling-gate"
run "$T33" "$T33/bin/evicting-sibling-gate"
assert_grep   "$T33/logs/out"    "frontend (frontend)"  "the evicted sibling is diagnosed by its own package name, not an 'extends' target"
assert_grep   "$T33/logs/out"    "ENVIRONMENTAL"        "classified as environmental, not as a code failure"
assert_nogrep "$T33/logs/gh.log" "labels[]=merge-stuck" "a red produced by an unloadable sibling is not merge-stuck"
assert_nogrep "$T33/logs/gh.log" "issue create"         "and files no issue blaming main"
assert_grep   "$T33/logs/gh.log" "labels[]=review-approved" "the batch is deferred for the next tick"
on_main "$T33" a.txt && bad "main advanced on a red integration" || ok "main not advanced"
rm -rf "$T33" 2>/dev/null || true

echo "J-MG-33 — an unrelenting DEPS deferral escalates with the deps remedy, not the Docker one"
# The two environmental shapes need different fixes; telling a human staring at an unresolved npm
# workspace to lower ITEST_XDIST_MAX would send them to the wrong knob — the same misattribution
# class this file exists to close (#2438).
T34="$(mktemp -d)"; make_env "$T34" clean
add_broken_workspace "$T34/clone" mobile "expo/tsconfig.base"
run "$T34" "true" env PR_MERGER_MAX_ENV_DEFER=0
assert_grep   "$T34/logs/gh.log" "labels[]=merge-stuck" "an unrelenting deps failure eventually escalates"
assert_grep   "$T34/logs/out"    "merge-stuck on the ENVIRONMENT" "escalated on the ENVIRONMENT, not on main"
assert_grep   "$T34/logs/gh.log" "npm ci" "the deps remedy tells the human to run a root npm ci"
assert_nogrep "$T34/logs/gh.log" "Docker resource starvation" "the Docker remedy is not shown for a deps failure"
rm -rf "$T34" 2>/dev/null || true

rm -rf "$T21" "$T22" "$T23" "$T24" "$T25" 2>/dev/null || true

rm -rf "$T1" "$T2" "$T3" "$T4" "$T5" "$T6" "$T7" "$T8" "$T9" "$T10" "$T11" "$T12" "$T13" "$T17" "$T19" "$T20" 2>/dev/null || true
echo; echo "agent-pr-merger e2e: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
