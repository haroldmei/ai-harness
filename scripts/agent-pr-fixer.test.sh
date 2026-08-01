#!/usr/bin/env bash
# Hermetic e2e for the PR fixer (scripts/agent-pr-fixer.sh). gh + claude STUBBED; a real
# bare origin + clone so the worktree/push path is exercised. Zero GitHub I/O, zero LLM cost.
# Scenarios: J-PR-3 (fix+green→push→review-needed), J-PR-4 (red→stuck,no push),
#            J-PR-5 (round cap→stuck), J-PR-7 (isolation), J-PR-18/19/20 (deps #2438),
#            J-PR-21 (bounded deps-declared brick → review-stuck, not an infinite hand-back).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/agent-pr-fixer.sh"
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
assert_grep()   { if grep -qF "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_nogrep() { if grep -qF "$2" "$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

make_env() {
  local tmp="$1" claude_mode="$2" clone_on="${3:-main}"   # clone_on: which branch the primary copy sits on
  mkdir -p "$tmp/bin" "$tmp/logs"; : > "$tmp/logs/gh.log"; : > "$tmp/logs/claude.log"
  git init -q --bare "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
  mkdir -p "$tmp/clone/scripts/lib" && cp "$ROOT/scripts/lib/agent-model-call.sh" "$tmp/clone/scripts/lib/"
  cp "$ROOT/scripts/lib/pr-lock.sh" "$tmp/clone/scripts/lib/"
  ( cd "$tmp/clone"
    git config user.email t@t; git config user.name tester
    echo base > base.txt
    echo '{"name":"t"}' > package.json; mkdir -p node_modules; echo x > node_modules/.keep
    git add -A; git commit -qm init; git branch -M main; git push -q origin main
    # the PR head branch the fixer will check out + push to
    git checkout -q -b agent/issue-5; echo "needs fixing" > target.txt
    git add -A; git commit -qm "pr work"; git push -q origin agent/issue-5
    git checkout -q "$clone_on" ) 2>/dev/null   # may leave the clone ON the PR branch (the bug repro)
  echo "user work in progress" > "$tmp/clone/USER_WIP.txt"

  cat > "$tmp/bin/gh" <<GH
#!/usr/bin/env bash
echo "gh \$*" >> "$tmp/logs/gh.log"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  echo '[{"number":7,"headRefName":"agent/issue-5","title":"x","labels":[{"name":"changes-requested"}]}]'; exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  case "\$*" in *pr-loop-round*) echo "\${PR_TEST_ROUND:-0}";; *) echo "fix the null check at target.txt:1";; esac; exit 0; fi
exit 0
GH
  chmod +x "$tmp/bin/gh"
  cat > "$tmp/bin/claude" <<CL
#!/usr/bin/env bash
echo "claude \$*" >> "$tmp/logs/claude.log"
if [ "$claude_mode" = "transient" ]; then
  # The model NEVER ran (session/usage limit): no code change, is_error 429 envelope.
  echo '{"is_error":true,"api_error_status":429,"output_tokens":0,"result":"You'\''ve hit your session limit · resets 1:20pm (Australia/Sydney)"}'
  exit 0
fi
if [ "$claude_mode" = "change" ]; then
  if [ -f "$tmp"/claude-called ]; then
    touch gate-fixed   # self-repair call: create the fix marker the gate checks for
  else
    echo "fixed" > FIX_OUTPUT.txt   # initial fix
    touch "$tmp"/claude-called
  fi
fi
if [ "$claude_mode" = "commit" ]; then
  # The model does the work and COMMITS it itself, leaving a CLEAN tree (PR #2196 rounds 2-3).
  if [ -f "$tmp"/claude-called ]; then
    touch gate-fixed; git add gate-fixed
    git -c user.email=t@t -c user.name=tester commit -qm "self-repair, committed by the model"
  else
    echo "fixed" > FIX_OUTPUT.txt; git add FIX_OUTPUT.txt
    git -c user.email=t@t -c user.name=tester commit -qm "fix, committed by the model"
    touch "$tmp"/claude-called
  fi
fi
if [ "$claude_mode" = "commit-junk" ]; then
  # A self-committing model that reaches for \`git add -A\` sweeps in provisioned deps.
  echo "fixed" > FIX_OUTPUT.txt; mkdir -p node_modules/pkg; echo x > node_modules/pkg/index.js
  git add -A
  git -c user.email=t@t -c user.name=tester commit -qm "fix + provisioned artefacts"
fi
echo '{"is_error":false,"result":"ok"}'; exit 0
CL
  chmod +x "$tmp/bin/claude"
}
run() {
  local tmp="$1" gates="$2"; shift 2
  # `env` is required: VAR=val words from "$@" expansion are NOT treated as env assignments by
  # bash (only literal prefixes are) — env honours every VAR=val argument.
  env PR_ROOT="$tmp/clone" PR_GH="$tmp/bin/gh" PR_CLAUDE="$tmp/bin/claude" PR_REMOTE="origin" \
    PR_GATES_CMD="$gates" PR_DEPS="symlink" PR_FIXER_LOCK="$tmp/fx.lock" \
    PR_LOGDIR="$tmp/logs" PR_WORKTREE_BASE="$tmp/wt" \
    "$@" bash "$RUNNER" > "$tmp/logs/out" 2>&1
}
head_has() { git -C "$1/clone" fetch -q origin agent/issue-5 2>/dev/null; git -C "$1/clone" cat-file -e "origin/agent/issue-5:$2" 2>/dev/null; }

echo "J-PR-3 — fix + gates green → push to PR branch + review-needed"
T3="$(mktemp -d)"; make_env "$T3" change; run "$T3" "true"
head_has "$T3" FIX_OUTPUT.txt && ok "fix commit pushed to the PR branch" || bad "fix not pushed to PR branch"
assert_grep   "$T3/logs/gh.log" "labels[]=review-needed" "handed back to the reviewer (review-needed)"
assert_grep   "$T3/logs/gh.log" "pr-loop-round: 1" "round counter incremented"
assert_nogrep "$T3/logs/gh.log" "labels[]=review-stuck" "not stuck on a green fix"
# isolation (J-PR-7)
[ "$(git -C "$T3/clone" branch --show-current)" = "main" ] && ok "primary copy stayed on main" || bad "primary branch switched"
git -C "$T3/clone" status --porcelain | grep -qF USER_WIP.txt && ok "user WIP untouched" || bad "user WIP disturbed"
( cd "$T3/clone" && ! git cat-file -e "origin/main:FIX_OUTPUT.txt" 2>/dev/null ) && ok "main was NOT pushed to" || bad "main was modified"
# Telemetry (#2390): the fix span must actually be written — a regression that broke the span
# call site (e.g. reintroducing a $ROOT-relative lib source that no-ops in a sandbox like this
# one) would otherwise pass every other assertion here.
t3_spans="$(ls "$T3/clone"/state/traces/spans-*.jsonl 2>/dev/null | head -1)"
if [ -n "$t3_spans" ]; then
  t3_stage="$(jq -rs '[.[] | select(.stage=="fix")][0].stage // empty' "$t3_spans")"
  [ "$t3_stage" = "fix" ] && ok "fix span written for the happy-path fixer run" \
    || bad "no 'fix' stage span found in $t3_spans"
else
  bad "no trace spans file written for the happy-path fixer run"
fi

echo "J-PR-4 — fix fails gates, self-repair OFF → NOT pushed, review-stuck (old behaviour)"
T4="$(mktemp -d)"; make_env "$T4" change; run "$T4" "false" PR_FIXER_SELF_REPAIR=0
head_has "$T4" FIX_OUTPUT.txt && bad "red fix must NOT be pushed" || ok "red fix was NOT pushed"
assert_grep   "$T4/logs/gh.log" "labels[]=review-stuck" "routed to review-stuck on red gates"
assert_nogrep "$T4/logs/gh.log" "labels[]=review-needed" "did not hand back as review-needed"

echo "J-PR-5 — round cap → stuck, no fix attempt"
T5="$(mktemp -d)"; make_env "$T5" change; run "$T5" "true" PR_MAX_ROUNDS=2 PR_TEST_ROUND=2
assert_grep   "$T5/logs/gh.log" "labels[]=review-stuck" "round cap → review-stuck"
assert_nogrep "$T5/logs/claude.log" "claude" "no fix turn attempted at the cap"

echo "J-PR-10 — PR branch is checked out in the PRIMARY copy → detached worktree still fixes+pushes"
T10="$(mktemp -d)"; make_env "$T10" change head; run "$T10" "true"   # clone sits ON agent/issue-5
head_has "$T10" FIX_OUTPUT.txt && ok "fix pushed even though the branch was checked out in the primary copy" || bad "detached worktree failed to push"
assert_grep   "$T10/logs/gh.log" "labels[]=review-needed" "handed back to the reviewer (not stuck)"
assert_nogrep "$T10/logs/gh.log" "could not check out the PR branch" "no 'cannot force update the current branch' failure"
[ "$(git -C "$T10/clone" branch --show-current)" = "agent/issue-5" ] && ok "primary copy's checkout was left untouched" || bad "primary checkout was disturbed"

echo "J-PR-11 — transient 429 (session limit) → NOT pushed, NOT stuck, round NOT consumed"
T11="$(mktemp -d)"; make_env "$T11" transient; run "$T11" "true"
head_has "$T11" FIX_OUTPUT.txt && bad "a transient limit must NOT push anything" || ok "nothing pushed on a transient limit"
assert_grep   "$T11/logs/claude.log" "claude" "fixer model was invoked"
assert_nogrep "$T11/logs/gh.log" "labels[]=review-stuck" "a transient limit did NOT escalate to a human"
assert_grep   "$T11/logs/gh.log" "labels[]=changes-requested" "PR returned to changes-requested for the next tick"
assert_nogrep "$T11/logs/gh.log" "pr-loop-round: 1" "no fix round was consumed"
assert_nogrep "$T11/logs/gh.log" "no code changes" "did NOT misread the transient as 'nothing to fix'"
assert_grep   "$T11/logs/out" "transient limit" "logged the transient-limit skip"

echo "J-PR-12 — fix fails gates → self-repair re-invokes claude, gate passes on retry → push + review-needed"
T12="$(mktemp -d)"; make_env "$T12" change
# Stateful gate: fails first time (no gate-fixed file), passes second time (after self-repair creates it).
run "$T12" '[ -f gate-fixed ]'
head_has "$T12" FIX_OUTPUT.txt && ok "initial fix pushed to the PR branch" || bad "fix not pushed"
head_has "$T12" gate-fixed && ok "self-repair fix also on the PR branch" || bad "self-repair fix not pushed"
# Two claude invocations: initial fix + self-repair
[ "$(grep -c '^claude' "$T12/logs/claude.log")" -ge 2 ] && ok "claude invoked twice (initial fix + self-repair)" || bad "expected ≥2 claude invocations, got $(grep -c '^claude' "$T12/logs/claude.log" 2>/dev/null || echo 0)"
assert_grep   "$T12/logs/gh.log" "labels[]=review-needed" "handed back to the reviewer after self-repair"
assert_nogrep "$T12/logs/gh.log" "labels[]=review-stuck" "not stuck after a successful self-repair"
# Telemetry (#2390 review round 2): `fix` and `fix-repair` spans for the same self-repair run must
# share the same `.round` (the PR-loop round) — that's the join key across stages for one pr. The
# self-repair ordinal must ride the separate `.attempt` axis instead, never overwrite `.round`.
t12_spans="$(ls "$T12/clone"/state/traces/spans-*.jsonl 2>/dev/null | head -1)"
if [ -n "$t12_spans" ]; then
  t12_fix_round="$(jq -rs '[.[] | select(.stage=="fix")][0].round // "MISSING"' "$t12_spans")"
  t12_repair_round="$(jq -rs '[.[] | select(.stage=="fix-repair")][0].round // "MISSING"' "$t12_spans")"
  t12_repair_attempt="$(jq -rs '[.[] | select(.stage=="fix-repair")][0].attempt // "MISSING"' "$t12_spans")"
  [ "$t12_fix_round" = "$t12_repair_round" ] && [ "$t12_fix_round" != "MISSING" ] \
    && ok "fix and fix-repair spans share the same PR-loop .round ($t12_fix_round)" \
    || bad "fix.round ($t12_fix_round) != fix-repair.round ($t12_repair_round) — round axis re-diverged"
  [ "$t12_repair_attempt" = "1" ] && ok "fix-repair span carries the self-repair ordinal on .attempt" \
    || bad "expected fix-repair .attempt=1, got $t12_repair_attempt"
else
  bad "no trace spans file written for the self-repair run"
fi

echo "J-PR-13 — fix fails gates, self-repair exhausted → review-stuck"
T13="$(mktemp -d)"; make_env "$T13" change
# Gate always fails; self-repair creates gate-fixed but MAX=1 → exhausted after one attempt.
run "$T13" "false" PR_FIXER_MAX_SELF_REPAIR=1
assert_grep   "$T13/logs/gh.log" "labels[]=review-stuck" "self-repair exhausted → review-stuck"
assert_grep   "$T13/logs/gh.log" "self-repair" "self-repair mentioned in the stuck comment"

echo "J-PR-14 — the fixer model COMMITS its own work → gated + pushed, NOT read as 'no code changes'"
# PR #2196: rounds 2 and 3 both fixed everything and committed in-worktree; the clean tree was
# read as "the model declined", the canned no-change comment went up, and the EXIT trap removed
# the worktree — two complete fixes stranded as unreachable commits.
T14="$(mktemp -d)"; make_env "$T14" commit; run "$T14" "true"
head_has "$T14" FIX_OUTPUT.txt && ok "a self-committed fix reaches the PR branch" || bad "self-committed fix was DISCARDED (#2196 regression)"
assert_nogrep "$T14/logs/gh.log" "no code changes" "did NOT misread a self-committed fix as 'nothing to fix'"
assert_grep   "$T14/logs/gh.log" "labels[]=review-needed" "handed back to the reviewer"
assert_grep   "$T14/logs/gh.log" "pr-loop-round: 1" "round counter incremented"
assert_nogrep "$T14/logs/gh.log" "labels[]=review-stuck" "not stuck on a green self-committed fix"

echo "J-PR-15 — the SELF-REPAIR model commits its own work → re-gated and pushed"
T15="$(mktemp -d)"; make_env "$T15" commit; run "$T15" '[ -f gate-fixed ]'
head_has "$T15" FIX_OUTPUT.txt && ok "initial self-committed fix pushed" || bad "initial self-committed fix not pushed"
head_has "$T15" gate-fixed && ok "self-repair's own commit re-gated and pushed" || bad "self-repair's own commit was discarded"
assert_nogrep "$T15/logs/out" "self-repair produced no code changes" "clean tree after a self-repair commit is not 'no changes'"

echo "J-PR-16 — model commits provisioned artefacts → NOT pushed, review-stuck"
T16="$(mktemp -d)"; make_env "$T16" commit-junk; run "$T16" "true"
head_has "$T16" FIX_OUTPUT.txt && bad "a commit carrying node_modules must NOT be pushed" || ok "provisioned artefacts were not pushed"
assert_grep   "$T16/logs/gh.log" "labels[]=review-stuck" "routed to a human"
assert_nogrep "$T16/logs/gh.log" "labels[]=review-needed" "did not hand back an unpushable commit"

echo "J-PR-17 — gates green but the PUSH fails → review-stuck, never claims it pushed"
T17="$(mktemp -d)"; make_env "$T17" change
git -C "$T17/clone" remote set-url origin "$T17/gone.git"   # break the push, keep origin/<head> resolvable
run "$T17" "true"
assert_grep   "$T17/logs/gh.log" "labels[]=review-stuck" "a failed push routes to a human"
assert_nogrep "$T17/logs/gh.log" "gates green, pushed" "did not claim a push that never happened"
assert_nogrep "$T17/logs/gh.log" "labels[]=review-needed" "did not hand back a fix that never landed"

echo "J-PR-18 — an unresolvable workspace dep spends no round and no model call (#2438)"
# `npm ci` exits 0 on an install that left `mobile/` without `expo`; `extends: expo/tsconfig.base`
# then fails to resolve and all ~154 mobile suites die at TRANSFORM time. The fixer used to trust
# the exit code, hand the model a tree that cannot compile, and burn a round on a red no edit can
# clear. agent-inbox has verified this since #2124 — the fixer and merger had not.
# `expo` is DECLARED in mobile/package.json — a real install gap (declared but not yet on disk),
# the only shape this skip may excuse as environmental. J-PR-20 below is the counter-fixture:
# same unresolved tsconfig, but the package is declared NOWHERE (a code defect, not a gap).
T18="$(mktemp -d)"; make_env "$T18" change
( cd "$T18/clone" && git checkout -q agent/issue-5
  mkdir -p mobile
  printf '{\n  "compilerOptions": { "paths": { "@/*": ["./src/*"] } },\n  "extends": "expo/tsconfig.base"\n}\n' > mobile/tsconfig.json
  printf '{"name":"mobile","version":"1.0.0","private":true,"dependencies":{"expo":"*"}}\n' > mobile/package.json
  jq -c '.workspaces = ["mobile"]' package.json > package.json.new && mv package.json.new package.json
  git add -A mobile package.json && git commit -qm "add mobile workspace" && git push -q origin agent/issue-5
  git checkout -q main ) 2>/dev/null
run "$T18" "touch $T18/gates-ran; false"
assert_grep   "$T18/logs/out"    "expo (mobile)"            "the unresolved package and workspace are named"
# Symlink mode (used above) never runs an npm install/repair; the diagnostic must say so rather
# than the install-mode "still unresolved after repair" (misleading — no repair was attempted).
assert_grep   "$T18/logs/out"    "mirrored host install"    "the symlink-mode message does not claim a repair that never ran"
assert_nogrep "$T18/logs/out"    "still unresolved after repair" "the install-mode wording is not used in symlink mode"
[ ! -s "$T18/logs/claude.log" ] && ok "no model call spent on a tree that cannot load its modules" \
  || bad "the fixer model ran against an unprovisioned worktree"
[ ! -e "$T18/gates-ran" ] && ok "the gates were never run either" || bad "the gates ran on a broken tree"
assert_grep   "$T18/logs/gh.log" "labels[]=changes-requested" "the PR is handed back for the next tick"
assert_nogrep "$T18/logs/gh.log" "labels[]=review-stuck"      "not escalated to a human — a reinstall may fix it"
assert_nogrep "$T18/logs/gh.log" "pr-loop-round: 1"           "no fix round consumed"

echo "J-PR-21 — an unrelenting DEPS-declared brick escalates to review-stuck, not an infinite hand-back"
# Same declared-but-unresolved shape as J-PR-18, run repeatedly. Before this fix the declared-deps
# branch had no bound at all: it hands the PR back as `changes-requested` every tick, and PRs are
# selected off that exact label — a permanently broken environment refused this PR forever, never
# fixed and never `review-stuck`, with no human ever notified. agent-inbox.sh bounds its own
# equivalent loop via AGENT_DEPS_MAX_RETRY and agent-pr-merger.sh via MERGER_MAX_ENV_DEFER; the
# fixer needs the same shape.
T21="$(mktemp -d)"; make_env "$T21" change
( cd "$T21/clone" && git checkout -q agent/issue-5
  mkdir -p mobile
  printf '{\n  "compilerOptions": { "paths": { "@/*": ["./src/*"] } },\n  "extends": "expo/tsconfig.base"\n}\n' > mobile/tsconfig.json
  printf '{"name":"mobile","version":"1.0.0","private":true,"dependencies":{"expo":"*"}}\n' > mobile/package.json
  jq -c '.workspaces = ["mobile"]' package.json > package.json.new && mv package.json.new package.json
  git add -A mobile package.json && git commit -qm "add mobile workspace" && git push -q origin agent/issue-5
  git checkout -q main ) 2>/dev/null
run "$T21" "touch $T21/gates-ran; false"                        # tick 1
assert_grep   "$T21/logs/gh.log" "labels[]=changes-requested" "tick 1: handed back for the next tick"
assert_nogrep "$T21/logs/gh.log" "labels[]=review-stuck"      "tick 1: not yet escalated"
run "$T21" "touch $T21/gates-ran; false"                        # tick 2
assert_nogrep "$T21/logs/gh.log" "labels[]=review-stuck"      "tick 2: still not escalated (under the default cap of 3)"
run "$T21" "touch $T21/gates-ran; false"                        # tick 3 — hits the default cap
assert_grep "$T21/logs/gh.log" "labels[]=review-stuck"     "tick 3: escalated to a human once the cap is hit"
assert_grep "$T21/logs/out"    "escalating to review-stuck" "the escalation names its own reason"
[ ! -s "$T21/logs/claude.log" ] && ok "no model call spent across any of the 3 ticks" \
  || bad "the fixer model ran against a tree that cannot load its own modules"
rm -rf "$T21" 2>/dev/null || true

echo "J-PR-20 — a PR that breaks its OWN workspace dependency falls through to the fix round, not an infinite hand-back"
# Same unresolvable "extends: expo/tsconfig.base" signature as J-PR-18, but this time the package
# is declared NOWHERE — the shape of a PR that deletes `expo` from `mobile/package.json` while
# `mobile/tsconfig.json` still extends it (mirrors agent-pr-merger.test.sh's J-MG-31, which the
# merger already routes into this exact loop via route_red_integration). Before this fix the
# fixer treated ANY unresolved workspace as environmental, relabelled `changes-requested` with
# "round NOT consumed", and exited — and since PRs are selected off that same label, this PR was
# refused every tick forever: never fixed, never `review-stuck`, no human notified. It must
# instead fall through to the normal fix round (bounded by the existing round cap).
T20="$(mktemp -d)"; make_env "$T20" change
( cd "$T20/clone" && git checkout -q agent/issue-5
  mkdir -p mobile
  printf '{\n  "compilerOptions": { "paths": { "@/*": ["./src/*"] } },\n  "extends": "expo/tsconfig.base"\n}\n' > mobile/tsconfig.json
  printf '{"name":"mobile","version":"1.0.0","private":true}\n' > mobile/package.json
  jq -c '.workspaces = ["mobile"]' package.json > package.json.new && mv package.json.new package.json
  git add -A mobile package.json && git commit -qm "PR breaks the mobile workspace dependency" && git push -q origin agent/issue-5
  git checkout -q main ) 2>/dev/null
run "$T20" "true"
assert_nogrep "$T20/logs/out"    "no model fix attempted"      "an undeclared dependency is never waved off as environmental"
[ -s "$T20/logs/claude.log" ] && ok "the fixer model WAS invoked on a code defect it can actually fix" \
  || bad "the undeclared-dependency PR was skipped instead of routed to the model"
assert_grep   "$T20/logs/out"    "DECLARED NOWHERE"            "the diagnosis names this as a code defect, not an install gap"
assert_grep   "$T20/logs/claude.log" "expo"                    "the model prompt carries the dependency failure so it can fix package.json"
head_has "$T20" FIX_OUTPUT.txt && ok "the fix was pushed" || bad "the fix never reached the PR branch"
assert_grep   "$T20/logs/gh.log" "labels[]=review-needed"      "handed back to the reviewer, not stuck forever"
assert_grep   "$T20/logs/gh.log" "pr-loop-round: 1"             "a round WAS consumed — this is a bounded loop, not an infinite hand-back"
assert_nogrep "$T20/logs/gh.log" "labels[]=review-stuck"        "round 1 does not escalate — MAX_ROUNDS still governs that"

echo "J-PR-19 — counter-check: the same workspace, resolvable, still gets its fix"
# The guard must not become a blanket skip: it keys off whether the tree can resolve what it
# extends, not off the workspace merely existing.
T19="$(mktemp -d)"; make_env "$T19" change
( cd "$T19/clone" && git checkout -q agent/issue-5
  mkdir -p mobile
  printf '{\n  "extends": "expo/tsconfig.base"\n}\n' > mobile/tsconfig.json
  printf '{"name":"mobile","version":"1.0.0","private":true}\n' > mobile/package.json
  jq -c '.workspaces = ["mobile"]' package.json > package.json.new && mv package.json.new package.json
  # npm workspaces always symlinks a member into the root node_modules by its own package.json
  # name (deps_workspace_unlinked's self-link check). Committed, like the base fixture's own
  # node_modules/.keep, so the worktree checkout (not a live npm install) sees it as real.
  mkdir -p node_modules/mobile; : > node_modules/mobile/.keep
  git add -A mobile package.json node_modules/mobile && git commit -qm "add mobile workspace" && git push -q origin agent/issue-5
  git checkout -q main ) 2>/dev/null
# untracked, so PR_DEPS=symlink mirrors it into the worktree (a tracked one is checked out empty)
mkdir -p "$T19/clone/mobile/node_modules/expo"; echo '{}' > "$T19/clone/mobile/node_modules/expo/package.json"
run "$T19" "true"
head_has "$T19" FIX_OUTPUT.txt && ok "a resolvable workspace still gets its fix" || bad "the deps guard blocked a healthy fix"
assert_grep   "$T19/logs/gh.log" "labels[]=review-needed" "and is handed back to the reviewer"

rm -rf "$T18" "$T19" 2>/dev/null || true
rm -rf "$T3" "$T4" "$T5" "$T10" "$T11" "$T12" "$T13" "$T14" "$T15" "$T16" "$T17" 2>/dev/null || true
echo; echo "agent-pr-fixer e2e: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
