#!/usr/bin/env bash
# Hermetic end-to-end test for the agent-inbox journey (scripts/agent-inbox.sh).
#
# This is the honest e2e for a headless CLI automation — there is no browser surface,
# so it drives the REAL journey with the agent (`claude`), GitHub (`gh`), and the git
# remote all STUBBED: zero real GitHub side-effects, zero LLM cost, deterministic.
#
# Scenarios (the user-facing journey "file requirement → PR back"):
#   1. happy path   — agent makes a change, gates pass → branch pushed + PR opened + issue `done`
#   2. gate failure — agent makes a change, gates fail → NO push, NO PR, issue `needs-human`
#   3. no-op        — agent produces nothing            → NO PR, issue `needs-human`
#   5. push failure — gates green but `git push` keeps failing → needs-human, NOT `done` (issue #901)
#   6. epic guard   — an `[Epic]`/tracking issue is de-queued (drop `agent`), never built (issue #1077)
#   7. broken deps  — a workspace dep the provisioning failed to install → no build, re-queue,
#                     bounded (escalates after AGENT_DEPS_MAX_RETRY, comments once) (#2124)
#   8. symlink mode — the dep check is skipped there: it would false-positive on a healthy host
#                     and its repair install would write through into the host's node_modules
#   9. multi-dep     — three missing deps join with a real "; " (paste -d cycles its list)
#  11. resumability  — a killed build's pushed work is RESUMED, not discarded; AGENT_RESUME=0 opts
#                      out; an already-merged remote branch is never resumed
#
#   Run: bash scripts/agent-inbox.test.sh     (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/agent-inbox.sh"

# This suite is hermetic in its stubs but was NOT hermetic in its environment: the agent
# lane units export AGENT_SLOT (1 on lane 1, 2 on lane 2), agent-inbox.sh rotates its
# candidate list by that value, and Scenarios 2 and 16 assert the default single-lane
# claim order. Result: 86/86 on lane 0, 83/86 on lanes 1-2 — with the failure reported as
# "issues are not sorted by createdAt", which reads like a production bug and is not one.
# Scrub ambient harness config before any scenario runs (issue #2387).
# shellcheck source=scripts/lib/test-env.sh
source "$ROOT/scripts/lib/test-env.sh"
test_env_scrub
# Keep per-issue claim locks inside the suite's own tree. The default is /tmp, so every
# run of this file used to leave /tmp/skillforge-issue-42.lock on the host and race any
# other lane's real claim on issue #42.
_SUITE_LOCKS="$(mktemp -d)"; export PR_LOCK_DIR="$_SUITE_LOCKS"
trap 'rm -rf "$_SUITE_LOCKS" 2>/dev/null || true' EXIT
PASS=0; FAIL=0
ok()   { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_grep()   { if grep -qF "$2" "$1"; then ok "$3"; else bad "$3 (expected to find: $2)"; fi; }
assert_nogrep() { if grep -qF "$2" "$1"; then bad "$3 (unexpectedly found: $2)"; else ok "$3"; fi; }

# ── Build a hermetic env: bare origin + clone on main + stubbed gh/claude ────────
make_env() {
  local tmp="$1" claude_mode="$2"
  mkdir -p "$tmp/bin" "$tmp/logs"

  # bare "origin" + a clone with a main branch
  git init -q --bare "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
  mkdir -p "$tmp/clone/scripts/lib" && cp "$ROOT/scripts/lib/agent-model-call.sh" "$tmp/clone/scripts/lib/"
  cp "$ROOT/scripts/lib/pr-lock.sh" "$tmp/clone/scripts/lib/"
  ( cd "$tmp/clone"
    git config user.email t@t; git config user.name tester
    echo base > base.txt; git add -A; git commit -qm init
    git branch -M main; git push -q origin main ) 2>/dev/null

  # Simulate the user's live state: a dirty, uncommitted WIP file in the primary
  # working copy. The isolated build must NEVER touch it (no sweep, no branch switch).
  echo "user work in progress" > "$tmp/clone/USER_WIP.txt"

  # Local, git-ignored files the gates need (env files + cred dir) — the worktree must
  # be provisioned with them just like node_modules.
  echo "SECRET=1" > "$tmp/clone/.env"
  mkdir -p "$tmp/clone/.gcp"; echo "{}" > "$tmp/clone/.gcp/adc.json"
  # A root package.json + node_modules so the runner symlinks node_modules into the
  # worktree — and we can assert it is NOT committed into the PR.
  echo '{"name":"t","scripts":{"test":"true"}}' > "$tmp/clone/package.json"
  mkdir -p "$tmp/clone/node_modules"; echo x > "$tmp/clone/node_modules/.keep"
  ( cd "$tmp/clone" && git add package.json && git commit -qm pkg && git push -q origin main ) 2>/dev/null

  # one pending requirement (labelled `agent`)
  cat > "$tmp/issues.json" <<'JSON'
[ { "number": 42, "title": "Add a hello marker", "body": "Create AGENT_OUTPUT.txt.",
    "labels": [ { "name": "agent" } ] } ]
JSON

  # gh stub: records every call; serves the canned issue list; fakes pr create
  cat > "$tmp/bin/gh" <<GH
#!/usr/bin/env bash
echo "gh \$*" >> "$tmp/logs/gh-calls.log"
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then cat "$tmp/issues.json"; exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then echo "https://github.com/test/repo/pull/999"; exit 0; fi
exit 0
GH
  chmod +x "$tmp/bin/gh"

  # claude stub: 'change' writes a file (agent did work); 'noop' writes nothing
  cat > "$tmp/bin/claude" <<CL
#!/usr/bin/env bash
echo "claude \$*" >> "$tmp/logs/claude-calls.log"
if [ "$claude_mode" = "change" ]; then echo "implemented" > AGENT_OUTPUT.txt; fi
echo '{"result":"ok","session_id":"test"}'
exit 0
CL
  chmod +x "$tmp/bin/claude"
}

run_runner() { # <tmp> <gates-cmd> [deps-mode] [extra env assignments…]
  local tmp="$1" gates="$2" deps="${3:-symlink}"; shift 2; [ $# -gt 0 ] && shift
  AGENT_ROOT="$tmp/clone" \
  AGENT_GH="$tmp/bin/gh" \
  AGENT_CLAUDE="$tmp/bin/claude" \
  AGENT_REMOTE="origin" AGENT_BASE="main" AGENT_LABEL="agent" \
  AGENT_GATES_CMD="$gates" \
  AGENT_LOCK="$tmp/inbox.lock" AGENT_LOGDIR="$tmp/logs" \
  AGENT_WORKTREE_BASE="$tmp/worktrees" \
  AGENT_PREFLIGHT_TOOLS="git jq node npx" \
  AGENT_DEPS="$deps" "$@" \
    bash "$RUNNER" > "$tmp/logs/runner.out" 2>&1
}

branch_on_origin() { git -C "$1/clone" ls-remote --heads origin "agent/issue-42" 2>/dev/null; }

# ── Scenario 1: happy path ──────────────────────────────────────────────────────
echo "Scenario 1 — happy path (change + gates pass) → PR + done"
T1="$(mktemp -d)"; make_env "$T1" change; run_runner "$T1" "true"
[ -n "$(branch_on_origin "$T1")" ] && ok "branch agent/issue-42 pushed to origin" || bad "branch pushed to origin"
assert_grep "$T1/logs/gh-calls.log" "pr create" "gh pr create was invoked"
# docs/35 hook: the fresh PR is enrolled into the review loop via the REST labels endpoint
# (NOT gh pr edit, which hits the projectCards GraphQL bug). PR url ends /pull/999 → #999.
assert_grep "$T1/logs/gh-calls.log" "issues/999/labels" "PR enrolled into review loop (REST labels endpoint)"
assert_grep "$T1/logs/gh-calls.log" "labels[]=review-needed" "PR labelled review-needed via REST"
assert_grep "$T1/logs/gh-calls.log" "issue edit 42 --add-label done" "issue marked done"
assert_grep "$T1/logs/gh-calls.log" "issue edit 42 --add-label wip" "issue claimed (wip) first"
# the agent's change is committed on the branch
( cd "$T1/clone" && git cat-file -e "agent/issue-42:AGENT_OUTPUT.txt" 2>/dev/null ) \
  && ok "agent change committed on the branch" || bad "agent change committed on the branch"
# ── ISOLATION: the primary working copy is untouched ────────────────────────────
[ "$(git -C "$T1/clone" branch --show-current)" = "main" ] \
  && ok "primary working copy stayed on main (branch not switched)" || bad "primary copy branch was switched"
[ -f "$T1/clone/USER_WIP.txt" ] && git -C "$T1/clone" status --porcelain | grep -qF "USER_WIP.txt" \
  && ok "user's uncommitted WIP left untouched in the primary copy" || bad "user's WIP was disturbed"
( cd "$T1/clone" && ! git cat-file -e "agent/issue-42:USER_WIP.txt" 2>/dev/null ) \
  && ok "user's WIP was NOT swept onto the agent branch" || bad "user's WIP leaked onto the agent branch"
# the provisioned node_modules symlink must NEVER be committed into the PR
( cd "$T1/clone" && ! git cat-file -e "agent/issue-42:node_modules" 2>/dev/null ) \
  && ok "provisioned node_modules symlink was NOT committed into the PR" || bad "node_modules symlink leaked into the PR"

# ── Scenario 2: gate failure ────────────────────────────────────────────────────
echo "Scenario 2 — gates fail → no PR, needs-human"
T2="$(mktemp -d)"; make_env "$T2" change; run_runner "$T2" "false"
# The branch IS pushed even when the gate fails (iteration 350) — pushing is not proposing. The work
# has to survive so the next attempt resumes from it instead of starting over; what must NOT happen
# is a PR, because un-gated work is never put up for review.
[ -n "$(branch_on_origin "$T2")" ] && ok "branch pushed on gate failure (work preserved for the retry)" || bad "gate-failed work must still reach the remote"
assert_nogrep "$T2/logs/gh-calls.log" "pr create" "no PR opened on gate failure (pushed ≠ proposed)"
assert_grep   "$T2/logs/gh-calls.log" "add-label needs-human" "issue routed to needs-human"

# ── Scenario 3: agent produced nothing ──────────────────────────────────────────
echo "Scenario 3 — agent no-op → no PR, needs-human"
T3="$(mktemp -d)"; make_env "$T3" noop; run_runner "$T3" "true"
assert_nogrep "$T3/logs/gh-calls.log" "pr create" "no PR when the agent made no changes"
assert_grep   "$T3/logs/gh-calls.log" "add-label needs-human" "no-op routed to needs-human"

# ── Scenario 4: local env-files/creds are provisioned into the worktree ───────────
# The gate runs in the worktree (cwd); it passes ONLY if .env + .gcp were symlinked in.
echo "Scenario 4 — .env + .gcp provisioned into the build worktree"
T4="$(mktemp -d)"; make_env "$T4" change
run_runner "$T4" "test -f .env && test -d .gcp"
assert_grep "$T4/logs/gh-calls.log" "issue edit 42 --add-label done" ".env + .gcp present in the worktree (gate passed)"
assert_nogrep "$T4/logs/gh-calls.log" "add-label needs-human" "env-provisioned build did not fall to needs-human"
( cd "$T4/clone" && ! git cat-file -e "agent/issue-42:.env" 2>/dev/null ) \
  && ok ".env was NOT committed into the PR branch (provisioned after commit)" || bad ".env leaked into the PR branch"

# ── Scenario 5: gates green but git push keeps failing → needs-human, NOT done (issue #901) ──
# Regression guard: a transient push failure used to be swallowed (`git push … 2>/dev/null`),
# then `pr create` ran with no branch and the issue was STILL marked `done` — a built-but-
# unshipped branch behind an opaque "(pr create failed)" message. The runner must now retry,
# capture the real error, and hand back to a human instead of faking success.
echo "Scenario 5 — gates green, push fails → needs-human, NOT done"
T5="$(mktemp -d)"; make_env "$T5" change
# Diverge origin/agent/issue-42 so a non-force push is rejected (a deterministic hard push failure).
( cd "$T5/clone"
  git checkout -q -b agent/issue-42
  echo diverge > DIVERGE.txt; git add -A; git commit -qm diverge
  git push -q origin agent/issue-42
  git checkout -q main; git branch -q -D agent/issue-42 ) 2>/dev/null
# AGENT_RESUME=0 is required to isolate the push path: this scenario forces a hard push failure by
# diverging origin/agent/issue-42, and resume (iteration 350) would otherwise base the build ON that
# divergence, making the push a clean fast-forward and defeating the premise. Resume-from-diverged
# is covered on its own in scenario 11.
AGENT_PUSH_RETRIES=2 AGENT_PUSH_RETRY_DELAY=0 run_runner "$T5" "true" symlink env AGENT_RESUME=0 AGENT_EARLY_PUSH=0
assert_grep   "$T5/logs/runner.out"   "push attempt 1/2 failed" "push was retried (attempt 1)"
assert_grep   "$T5/logs/runner.out"   "push FAILED after 2 attempts" "handed back after exhausting retries"
[ -s "$T5/logs/push-42.log" ] && ok "real push error captured to push-42.log (not swallowed)" || bad "push error was not captured"
assert_grep   "$T5/logs/gh-calls.log" "add-label needs-human" "issue routed to needs-human on push failure"
assert_nogrep "$T5/logs/gh-calls.log" "add-label done" "issue NOT falsely marked done (the #901 bug)"
assert_nogrep "$T5/logs/gh-calls.log" "pr create" "no PR-create attempted once push failed"
# origin/agent/issue-42 still points at the diverge commit — the agent's work never reached it
( cd "$T5/clone" && git fetch -q origin agent/issue-42 2>/dev/null; ! git cat-file -e "origin/agent/issue-42:AGENT_OUTPUT.txt" 2>/dev/null ) \
  && ok "push was genuinely rejected — agent commit never reached origin" || bad "agent commit unexpectedly reached origin"

# ── Scenario 6: epic / tracking-issue guard (issue #1077) ────────────────────────
# A tracking epic must never be "built" — handed one, a weak driver flails (inject bugs,
# rewrite unrelated files). The runner must de-queue it BEFORE claiming/building: drop the
# `agent` label, never invoke the agent, never open a PR, never mark wip/needs-human/done.
echo "Scenario 6 — epic/tracking issue → de-queued, not built"
T6="$(mktemp -d)"; make_env "$T6" change
cat > "$T6/issues.json" <<'JSON'
[ { "number": 42, "title": "[Epic] Minors-readiness: serve students at all levels",
    "body": "Epic / tracking issue. Child phase tickets are intentionally **not** labeled `agent`.",
    "labels": [ { "name": "agent" } ] } ]
JSON
run_runner "$T6" "true"
assert_grep   "$T6/logs/gh-calls.log" "api -X DELETE" "epic: agent label removed via REST"
assert_grep   "$T6/logs/gh-calls.log" "issues/42/labels/agent" "epic: removal targets the agent label on #42"
assert_nogrep "$T6/logs/gh-calls.log" "pr create" "epic: no PR opened"
assert_nogrep "$T6/logs/gh-calls.log" "add-label wip" "epic: issue NOT claimed (no wip)"
assert_nogrep "$T6/logs/gh-calls.log" "add-label needs-human" "epic: NOT escalated to needs-human (just de-queued)"
[ ! -s "$T6/logs/claude-calls.log" ] && ok "epic: the build agent was never invoked" || bad "epic: agent should not have run"
[ -z "$(branch_on_origin "$T6")" ] && ok "epic: no branch pushed" || bad "epic: a branch was pushed"

# ── Scenario 7: unresolvable workspace dependency → no build attempted, retry (#2124) ──
# `npm ci` can exit 0 and still leave a workspace short of a package. Every test in that
# workspace then fails at LOAD time, which reads as a code failure: on 2026-07-25 a missing
# `expo` took out 138 mobile test files, the triage blamed the diff, three auto-fix rounds
# were spent on an innocent test, and the parent issue deadlocked behind the blocker.
# The `"@/*"` path below is deliberate — a literal `/*` inside JSONC is what makes parsing
# these files with a comment-stripping regex unsafe, hence the grep-based reader.
#
# `add_broken_workspace` also declares the workspace in the ROOT package.json — the check scans
# only declared workspaces, so a test that forgot this would silently assert nothing.
add_broken_workspace() { # <clone> <workspace-dir> <bare-extends-specifier>
  local clone="$1" ws="$2" spec="$3"
  mkdir -p "$clone/$ws"
  printf '{\n  "compilerOptions": { "paths": { "@/*": ["./src/*"] } },\n  "extends": "%s"\n}\n' "$spec" \
    > "$clone/$ws/tsconfig.json"
  printf '{"name":"%s","version":"1.0.0","private":true}\n' "$ws" > "$clone/$ws/package.json"
  local ws_json; ws_json="$(jq -c --arg w "$ws" '.workspaces = ((.workspaces // []) + [$w] | unique)' "$clone/package.json")"
  printf '%s\n' "$ws_json" > "$clone/package.json"
  # npm workspaces always symlinks a member into the root node_modules by its own package.json
  # name (deps_workspace_unlinked's self-link check). Committed, like the base fixture's own
  # node_modules/.keep, so these fixtures isolate the THIRD-PARTY dependency named by <spec> as
  # the only unresolved thing — an "added" workspace is never itself missing from a healthy tree.
  mkdir -p "$clone/node_modules/$ws"; : > "$clone/node_modules/$ws/.keep"
}
# A hoisted third-party package that ships its own tsconfig.json extending a bare specifier of
# ITS OWN devDependencies (never installed here) — the shape that made a `$wt/*/*/tsconfig.json`
# depth glob report ~20 nonsense missing deps on every healthy tree.
add_node_modules_decoy() { # <clone>
  mkdir -p "$1/node_modules/call-bind-apply-helpers"
  printf '{\n  "extends": "@ljharb/tsconfig"\n}\n' > "$1/node_modules/call-bind-apply-helpers/tsconfig.json"
}
echo "Scenario 7 — a workspace dep is unresolvable → no model build, issue re-queued (#2124)"
T7="$(mktemp -d)"; make_env "$T7" change
add_broken_workspace "$T7/clone" mobile "expo/tsconfig.base"
add_node_modules_decoy "$T7/clone"
( cd "$T7/clone" && git add -A mobile package.json node_modules/mobile && git commit -qm mobile && git push -q origin main ) 2>/dev/null
run_runner "$T7" "true" install
assert_nogrep "$T7/logs/runner.out" "@ljharb/tsconfig" "a node_modules package's own tsconfig is never scanned"
assert_grep   "$T7/logs/runner.out"   "dependency provisioning FAILED" "aborted on an unresolvable workspace dep"
assert_grep   "$T7/logs/gh-calls.log" "issue edit 42 --add-label agent --remove-label wip" "issue re-queued for the next tick"
assert_nogrep "$T7/logs/gh-calls.log" "pr create"        "no PR opened from a tree that cannot compile"
assert_nogrep "$T7/logs/gh-calls.log" "add-label needs-human" "not escalated to a human (a reinstall may fix it)"
[ ! -s "$T7/logs/claude-calls.log" ] && ok "no model build spent on a broken tree" || bad "the model ran despite unresolvable deps"
[ -z "$(branch_on_origin "$T7")" ] && ok "no branch pushed" || bad "a branch was pushed from a broken tree"
# The re-queue is BOUNDED: a tree that can never be provisioned must escalate rather than sit at
# the head of the eligibility list forever, and it must not comment once per tick while doing so.
run_runner "$T7" "true" install   # tick 2 — silent
run_runner "$T7" "true" install   # tick 3 — escalates
assert_grep "$T7/logs/gh-calls.log" "add-label needs-human" "bounded: escalates to a human after AGENT_DEPS_MAX_RETRY ticks"
assert_grep "$T7/logs/runner.out"   "FAILED 3×"              "the escalation states how many attempts were made"
# gh-calls.log accumulates across ticks, so assert the COUNT: exactly one retry comment for
# three bricked ticks (plus the one escalation comment), never one per tick.
[ "$(grep -cF 'Retrying on the next tick' "$T7/logs/gh-calls.log")" = "1" ] \
  && ok "commented once across 3 bricked ticks (no per-tick comment spam)" \
  || bad "the brick comment repeated per tick ($(grep -cF 'Retrying on the next tick' "$T7/logs/gh-calls.log")×)"

# ── Scenario 8: symlink deps mode must NOT run the workspace check (reviewer finding) ──
# AGENT_DEPS=symlink deliberately points $wt/node_modules at the HOST install, so a workspace-local
# node_modules (mobile/ is not hoisted) is legitimately absent from the worktree. Running the check
# there false-positives on every tick against a healthy host, and its `npm install` repair would
# write THROUGH the symlink into the host's shared node_modules.
echo "Scenario 8 — symlink deps mode skips the workspace dep check (no false positive, no host write)"
T8="$(mktemp -d)"; make_env "$T8" change
add_broken_workspace "$T8/clone" mobile "expo/tsconfig.base"
( cd "$T8/clone" && git add -A mobile package.json node_modules/mobile && git commit -qm mobile && git push -q origin main ) 2>/dev/null
host_nm_before="$(find "$T8/clone/node_modules" -mindepth 1 | sort)"
run_runner "$T8" "true" symlink
assert_nogrep "$T8/logs/runner.out"   "dependency provisioning FAILED" "symlink mode: no false-positive brick"
assert_grep   "$T8/logs/gh-calls.log" "pr create"                      "symlink mode: the build proceeded normally"
[ "$(find "$T8/clone/node_modules" -mindepth 1 | sort)" = "$host_nm_before" ] \
  && ok "symlink mode: the host's shared node_modules was not written through" \
  || bad "symlink mode: the repair install mutated the host node_modules"

# ── Scenario 9: THREE missing packages join with a real "; " separator (reviewer finding) ──
# `paste -sd'; '` treats "; " as a delimiter LIST that CYCLES, so three items joined as
# "a;b c" — the second separator a bare space, garbling both the log line and the issue comment.
# Two workspaces were not enough to catch it: the bug only shows from the SECOND separator on.
echo "Scenario 9 — three unresolvable workspace deps join with '; ', not a cycling delimiter"
T9="$(mktemp -d)"; make_env "$T9" change
add_broken_workspace "$T9/clone" mobile  "expo/tsconfig.base"
add_broken_workspace "$T9/clone" tablet  "react-native-tv/tsconfig"
add_broken_workspace "$T9/clone" desktop "electron-tsconfig/base"
( cd "$T9/clone" && git add -A mobile tablet desktop package.json node_modules/mobile node_modules/tablet node_modules/desktop \
    && git commit -qm ws && git push -q origin main ) 2>/dev/null
run_runner "$T9" "true" install
# `jq … | unique` sorts the workspaces, so the list is always desktop, mobile, tablet — the
# negative assertion must name the pair the CYCLING bug would join with a bare space at the
# SECOND separator, i.e. `…(mobile) react-native-tv…`. (An earlier `(tablet) electron` check here
# was vacuous: that substring cannot appear in sorted order whether the bug regresses or not.)
assert_grep   "$T9/logs/runner.out" "(desktop); expo"         "first separator is '; '"
assert_nogrep "$T9/logs/runner.out" "(mobile) react-native-tv" "second separator is NOT a bare space (the cycling bug)"
deps_line="$(grep -o 'unresolved: .*' "$T9/logs/runner.out" | head -1)"
[ "$(printf '%s' "$deps_line" | grep -o '; ' | wc -l)" = "2" ] \
  && ok "three items → exactly two '; ' separators" \
  || bad "three items produced $(printf '%s' "$deps_line" | grep -o '; ' | wc -l) '; ' separators — got: $deps_line"

# ── Scenario 10: work-stealing claims over a per-issue lock ───────────────────────
# AGENT_SLOT was a positional selector (lane k took the k-th eligible issue). Collision-free, but it
# STARVED a short queue: with one eligible issue only lane 0 could ever claim it, so while lane 0
# drained a PR the work sat untouched and the other lanes idled (observed with #2132). AGENT_SLOT is
# now only a preference offset; any lane may steal any issue nobody holds.
echo "Scenario 10 — AGENT_SLOT is a preference offset; any free lane can steal any free issue"
T10="$(mktemp -d)"; make_env "$T10" change
cat > "$T10/issues.json" <<'JSON'
[ { "number": 42, "title": "First eligible", "body": "Create AGENT_OUTPUT.txt.",
    "labels": [ { "name": "agent" } ] },
  { "number": 43, "title": "Second eligible", "body": "Create AGENT_OUTPUT.txt.",
    "labels": [ { "name": "agent" } ] } ]
JSON
export PR_LOCK_DIR="$T10/claims"; mkdir -p "$PR_LOCK_DIR"
run_runner "$T10" "true" symlink env AGENT_SLOT=1 PR_LOCK_DIR="$T10/claims"
assert_grep   "$T10/logs/gh-calls.log" "issue edit 43 --add-label wip" "slot 1 prefers the SECOND issue"
assert_nogrep "$T10/logs/gh-calls.log" "issue edit 42 --add-label wip" "slot 1 left the first issue alone"

T10b="$(mktemp -d)"; make_env "$T10b" change
cp "$T10/issues.json" "$T10b/issues.json"
mkdir -p "$T10b/claims"
run_runner "$T10b" "true" symlink env PR_LOCK_DIR="$T10b/claims"
assert_grep   "$T10b/logs/gh-calls.log" "issue edit 42 --add-label wip" "default slot 0 prefers the first issue"
assert_nogrep "$T10b/logs/gh-calls.log" "issue edit 43 --add-label wip" "default slot 0 did not skip ahead"

# THE starvation fix: ONE eligible issue must be claimable by a HIGH-numbered lane. Under the old
# positional rule lane 5 would index past the end and no-op forever while the issue went unbuilt.
T10c="$(mktemp -d)"; make_env "$T10c" change
cat > "$T10c/issues.json" <<'JSON'
[ { "number": 42, "title": "The only eligible issue", "body": "Create AGENT_OUTPUT.txt.",
    "labels": [ { "name": "agent" } ] } ]
JSON
mkdir -p "$T10c/claims"
run_runner "$T10c" "true" symlink env AGENT_SLOT=5 PR_LOCK_DIR="$T10c/claims"
assert_grep "$T10c/logs/gh-calls.log" "issue edit 42 --add-label wip" \
  "a lane past the end of a SHORT queue still claims the only issue (no starvation)"

# And the exclusion the lock exists for: an issue another lane is building is not claimed twice.
T10d="$(mktemp -d)"; make_env "$T10d" change
cp "$T10c/issues.json" "$T10d/issues.json"
mkdir -p "$T10d/claims"
( export PR_LOCK_DIR="$T10d/claims"
  source "$ROOT/scripts/lib/pr-lock.sh"
  issue_lock_try _f 42 && exec sleep 30 ) &
holder=$!
for _ in $(seq 1 50); do
  ( export PR_LOCK_DIR="$T10d/claims"; source "$ROOT/scripts/lib/pr-lock.sh"; issue_lock_is_held 42 ) && break
  sleep 0.1
done
run_runner "$T10d" "true" symlink env PR_LOCK_DIR="$T10d/claims"
assert_nogrep "$T10d/logs/gh-calls.log" "add-label wip" "an issue another lane is building is NOT claimed twice"
assert_grep   "$T10d/logs/runner.out"   "being built by another lane" "declined with a clear reason"
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
# The claim dies with its holder — the issue becomes claimable again with no reaper involved.
run_runner "$T10d" "true" symlink env PR_LOCK_DIR="$T10d/claims"
assert_grep "$T10d/logs/gh-calls.log" "add-label wip" "claimable again once the holder died"
export PR_LOCK_DIR="$_SUITE_LOCKS"   # back to the suite-wide sandbox, not the host /tmp default

rm -rf "$T10" "$T10b" "$T10c" "$T10d" 2>/dev/null || true

# ── Scenario 11: a killed build's work survives and the retry RESUMES from it ──────
# Before iteration 350 an interrupted build lost everything: the worktree is deleted by the EXIT
# trap and the retry did `worktree add -f -B <branch> origin/main`, resetting the branch, so the
# model started from scratch with its earlier work silently discarded. The branch is now pushed as
# soon as a commit exists, and the next attempt bases on it.
echo "Scenario 11 — a prior attempt's pushed work is resumed, not discarded"
T11="$(mktemp -d)"; make_env "$T11" change
# Simulate the survivor of a killed build: agent/issue-42 on origin carrying work main does not have.
( cd "$T11/clone"
  git checkout -q -b agent/issue-42
  echo "work from the killed attempt" > EARLIER.txt
  git add -A; git commit -qm "agent: partial work from a killed build"
  git push -q origin agent/issue-42
  git checkout -q main; git branch -q -D agent/issue-42 ) 2>/dev/null
run_runner "$T11" "true"
assert_grep "$T11/logs/runner.out" "RESUMING from origin/agent/issue-42" "the retry resumed from the surviving branch"
# Both the earlier work AND this round's output must be on the branch.
( cd "$T11/clone" && git fetch -q origin agent/issue-42 2>/dev/null
  git cat-file -e "origin/agent/issue-42:EARLIER.txt" 2>/dev/null ) \
  && ok "the killed attempt's work is still on the branch" || bad "resume dropped the earlier work"
( cd "$T11/clone" && git cat-file -e "origin/agent/issue-42:AGENT_OUTPUT.txt" 2>/dev/null ) \
  && ok "this round's work was added on top" || bad "this round's work is missing"

# AGENT_RESUME=0 is the escape hatch for a poisoned branch: start clean, earlier work dropped.
T11b="$(mktemp -d)"; make_env "$T11b" change
( cd "$T11b/clone"
  git checkout -q -b agent/issue-42
  echo poisoned > EARLIER.txt; git add -A; git commit -qm poisoned
  git push -q origin agent/issue-42
  git checkout -q main; git branch -q -D agent/issue-42 ) 2>/dev/null
run_runner "$T11b" "true" symlink env AGENT_RESUME=0
assert_nogrep "$T11b/logs/runner.out" "RESUMING from" "AGENT_RESUME=0 forces a clean start"

# A remote branch already merged into main must NOT be resumed — a reopened issue can leave one
# behind, and building on it would re-apply work that is already shipped.
T11c="$(mktemp -d)"; make_env "$T11c" change
( cd "$T11c/clone"
  git checkout -q -b agent/issue-42
  git push -q origin agent/issue-42          # same commit as main → an ancestor of it
  git checkout -q main; git branch -q -D agent/issue-42 ) 2>/dev/null
run_runner "$T11c" "true"
assert_grep   "$T11c/logs/runner.out" "already merged into main — starting clean" \
  "a merged remote branch is not resumed"
assert_nogrep "$T11c/logs/runner.out" "RESUMING from" "no resume attempted for merged work"

# ── Scenario 12: a resumed branch is rebased onto the CURRENT base (#2218) ────────
# Resuming preserved the prior attempt's WORK but also its BASE. The guard above asks only
# "is this branch already in main?", never the converse, so a branch cut hours earlier was
# rebuilt against the tree it was cut from — everything that landed on main since stayed
# invisible. #2138 resumed a branch cut before the #2212 landing-guard fix, its gates re-failed
# on 25 tests already green on main, and triage filed a fresh blocker (#2217) for them. Fixing
# main could never break that loop, because the build never saw main.
echo "Scenario 12 — a resumed branch is rebased onto a base that moved (#2218)"
T12="$(mktemp -d)"; make_env "$T12" change
( cd "$T12/clone"
  git checkout -q -b agent/issue-42
  echo "work from the killed attempt" > EARLIER.txt
  git add -A; git commit -qm "agent: partial work from a killed build"
  git push -q origin agent/issue-42
  # main then moves on — this is the fix the stale branch cannot see.
  git checkout -q main
  echo "the fix that landed while the build was down" > FIX_ON_MAIN.txt
  git add -A; git commit -qm "fix: landed on main after the branch was cut"
  git push -q origin main
  git branch -q -D agent/issue-42 ) 2>/dev/null
run_runner "$T12" "true"
assert_grep "$T12/logs/runner.out" "RESUMING from origin/agent/issue-42" "still resumes the prior work"
assert_grep "$T12/logs/runner.out" "commit(s) behind" "noticed the base had moved"
assert_grep "$T12/logs/runner.out" "rebased the resumed work" "rebased onto the current base"
( cd "$T12/clone" && git fetch -q origin agent/issue-42 2>/dev/null
  git cat-file -e "origin/agent/issue-42:FIX_ON_MAIN.txt" 2>/dev/null ) \
  && ok "the build now sees the fix that landed on main" \
  || bad "STALE BASE: the build gated against a tree missing main's fix (#2218)"
( cd "$T12/clone" && git cat-file -e "origin/agent/issue-42:EARLIER.txt" 2>/dev/null ) \
  && ok "the rebase kept the killed attempt's work" || bad "rebase dropped the earlier work"
( cd "$T12/clone" && git cat-file -e "origin/agent/issue-42:AGENT_OUTPUT.txt" 2>/dev/null ) \
  && ok "this round's work was added on top" || bad "this round's work is missing"
# The rebase rewrote history, so the push must survive a non-fast-forward remote.
assert_nogrep "$T12/logs/runner.out" "push FAILED" "the rewritten branch still pushed"

# ── Scenario 13: a resumed branch that is ALREADY COMPLETE ships (#2222) ─────────
# The no-op guard measured only "did THIS ROUND add commits?", so a model that resumed a branch,
# found the work already finished and correctly declined to duplicate it was indistinguishable
# from a model that failed. #2138 sat like that for three rounds — 1,703 lines of finished,
# passing code escalated as a failure, never once reaching `pr create`.
echo "Scenario 13 — a resumed branch already carrying the work is gated and shipped, not escalated (#2222)"
T13="$(mktemp -d)"; make_env "$T13" noop      # noop: this round adds nothing
( cd "$T13/clone"
  git checkout -q -b agent/issue-42
  echo "the finished work from an earlier round" > AGENT_OUTPUT.txt
  git add -A; git commit -qm "agent: the work, completed in an earlier round"
  git push -q origin agent/issue-42
  git checkout -q main; git branch -q -D agent/issue-42 ) 2>/dev/null
run_runner "$T13" "true"
assert_grep   "$T13/logs/runner.out"   "branch carries unshipped work" "recognised the branch already holds the work"
assert_grep   "$T13/logs/gh-calls.log" "pr create"                     "opened the PR earlier rounds never reached"
assert_nogrep "$T13/logs/gh-calls.log" "add-label needs-human"         "a complete branch is NOT escalated as a failure"
assert_grep   "$T13/logs/gh-calls.log" "issue edit 42 --add-label done" "issue marked done"

# A do-nothing round on a branch with nothing on it must STILL escalate — the guard is being
# made precise, not removed. (Scenario 3 covers the non-resume form of this.)
T13b="$(mktemp -d)"; make_env "$T13b" noop
( cd "$T13b/clone"
  git checkout -q -b agent/issue-42
  git commit -q --allow-empty -m "agent: an earlier round that also did nothing"
  git push -q origin agent/issue-42
  git checkout -q main; git branch -q -D agent/issue-42 ) 2>/dev/null
run_runner "$T13b" "true"
assert_grep   "$T13b/logs/gh-calls.log" "add-label needs-human" "an empty resumed branch still needs a human"
assert_nogrep "$T13b/logs/gh-calls.log" "pr create"             "and opens no PR"

# ── Scenario 14: a conflict in GENERATED files must not cost the attempt (#2222) ──
# `docs/06-iteration-log*.md` is generated from `docs/iterations/*` and `state/*.json` is shared
# bookkeeping, so two branches that each add an iteration collide there by construction while
# their product diffs stay disjoint. Rebasing #2138 conflicted in exactly those files and nothing
# else; the blunt discard would have destroyed the whole branch to avoid them.
echo "Scenario 14 — a rebase conflict confined to generated files is resolved, not discarded (#2222)"
T14="$(mktemp -d)"; make_env "$T14" change
( cd "$T14/clone"
  mkdir -p state
  mkdir -p docs; printf 'row A\n' > docs/06-iteration-log.md
  printf '{"n":1}\n' > state/state.json
  git add -A; git commit -qm "seed generated files"; git push -q origin main
  git checkout -q -b agent/issue-42
  echo "work from the killed attempt" > EARLIER.txt
  git add -A; git commit -qm "agent: real product work"
  printf 'row A\nrow B (this branch)\n' > docs/06-iteration-log.md
  printf '{"n":2}\n' > state/state.json
  git add -A; git commit -qm "agent: iteration bookkeeping only"   # becomes EMPTY after resolution
  git push -q origin agent/issue-42
  git checkout -q main
  printf 'row A\nrow C (landed on main)\n' > docs/06-iteration-log.md
  printf '{"n":3}\n' > state/state.json
  echo "the fix that landed while the build was down" > FIX_ON_MAIN.txt
  git add -A; git commit -qm "fix: landed on main, touching the same generated rows"
  git push -q origin main
  git branch -q -D agent/issue-42 ) 2>/dev/null
run_runner "$T14" "true"
assert_nogrep "$T14/logs/runner.out" "discarded the prior attempt" "a generated-file conflict does NOT discard the attempt"
assert_grep   "$T14/logs/runner.out" "rebased the resumed work"    "the rebase completed through the conflict"
( cd "$T14/clone" && git fetch -q origin agent/issue-42 2>/dev/null
  git cat-file -e "origin/agent/issue-42:EARLIER.txt" 2>/dev/null ) \
  && ok "the earlier attempt's product work survived the conflict" \
  || bad "generated-file conflict destroyed real work (#2222)"
( cd "$T14/clone" && git cat-file -e "origin/agent/issue-42:FIX_ON_MAIN.txt" 2>/dev/null ) \
  && ok "and the branch picked up main's fix" || bad "rebase did not bring main's fix across"
( cd "$T14/clone" && git show "origin/agent/issue-42:docs/06-iteration-log.md" 2>/dev/null | grep -q "row C" ) \
  && ok "the generated file resolved to base's copy" || bad "generated file did not resolve to base"
assert_grep "$T14/logs/gh-calls.log" "pr create" "the salvaged branch still opens its PR"

# ── Scenario 15: a PRODUCT-file conflict still discards ──────────────────────────
# The salvage path must stay narrow: a genuine disagreement about the change is exactly what the
# discard exists for, and silently resolving one would gate a tree nobody wrote.
echo "Scenario 15 — a rebase conflict in a product file still discards and starts clean (#2222)"
T15="$(mktemp -d)"; make_env "$T15" change
( cd "$T15/clone"
  git checkout -q -b agent/issue-42
  printf 'the branch rewrote this line\n' > base.txt
  git add -A; git commit -qm "agent: edit a product file"
  git push -q origin agent/issue-42
  git checkout -q main
  printf 'main rewrote the same line differently\n' > base.txt
  git add -A; git commit -qm "fix: main edits the same product line"
  git push -q origin main
  git branch -q -D agent/issue-42 ) 2>/dev/null
run_runner "$T15" "true"
assert_grep "$T15/logs/runner.out" "conflict in a product file" "the product-file conflict is named"
assert_grep "$T15/logs/runner.out" "discarded the prior attempt" "a real disagreement still discards"
( cd "$T15/clone" && git fetch -q origin agent/issue-42 2>/dev/null
  git show "origin/agent/issue-42:base.txt" 2>/dev/null | grep -q "main rewrote" ) \
  && ok "the clean start is based on main's version" || bad "clean start did not reset to base"

# ── Scenario 16: issues are sorted by createdAt ascending (earliest first) ──────────
# When the issue list contains items with different creation dates, the jq sort_by(.createdAt)
# must reorder them so the EARLIEST-created issue is picked first. This ensures dependent issues
# (filed in chronological order) are built in the order the author intended.
echo "Scenario 16 — issues sorted by createdAt ascending (earliest first)"
T16="$(mktemp -d)"; make_env "$T16" change
cat > "$T16/issues.json" <<'JSON'
[ { "number": 43, "title": "Second (newer)", "body": "Create AGENT_OUTPUT.txt.",
    "createdAt": "2026-07-29T12:00:00Z",
    "labels": [ { "name": "agent" } ] },
  { "number": 42, "title": "First (older)", "body": "Create AGENT_OUTPUT.txt.",
    "createdAt": "2026-07-29T10:00:00Z",
    "labels": [ { "name": "agent" } ] } ]
JSON
export PR_LOCK_DIR="$T16/claims"; mkdir -p "$PR_LOCK_DIR"
run_runner "$T16" "true"
# Issue 42 was created EARLIER (10:00 vs 12:00) AND appears SECOND in the JSON, so
# without sort_by(.createdAt) it would not be picked first. The test proves the sort works.
assert_grep   "$T16/logs/gh-calls.log" "issue edit 42 --add-label wip" \
  "sorted by createdAt ascending: earlier issue (#42, 10:00) claimed before newer (#43, 12:00)"
export PR_LOCK_DIR="$_SUITE_LOCKS"   # back to the suite-wide sandbox, not the host /tmp default
rm -rf "$T16" 2>/dev/null || true

# ── Scenario 17: inbox-build span keeps `result` off outcome's axis ────────────────
# `result` is the round's terminal disposition (pushed|no-change|stuck|transient — a different axis
# from `outcome`'s ok|transient|hard, per scripts/lib/agent-trace.sh). Stamping outcome into result
# would make `.result` mean two different things across stages, breaking any cold-vs-resumed
# success-rate query over it (pr-review round 0 finding on #2390).
echo "Scenario 17 — inbox-build span leaves result null (not stamped with outcome)"
T17="$(mktemp -d)"; make_env "$T17" change
export PR_LOCK_DIR="$T17/claims"; mkdir -p "$PR_LOCK_DIR"
run_runner "$T17" "true" symlink env AGENT_TRACE_DIR="$T17/traces" PR_LOCK_DIR="$T17/claims"
t17_spans="$(ls "$T17"/traces/spans-*.jsonl 2>/dev/null | head -1)"
if [ -n "$t17_spans" ]; then
  t17_result="$(jq -rs '[.[] | select(.stage=="inbox-build")][0].result' "$t17_spans" 2>/dev/null)"
  [ "$t17_result" = "null" ] \
    && ok "inbox-build span leaves result null (not stamped with outcome)" \
    || bad "inbox-build span's result is '$t17_result', expected null"
else
  bad "no trace spans file written for the happy-path inbox build"
fi
export PR_LOCK_DIR="$_SUITE_LOCKS"
rm -rf "$T17" 2>/dev/null || true

rm -rf "$T13" "$T13b" "$T14" "$T15" 2>/dev/null || true
rm -rf "$T11" "$T11b" "$T11c" "$T12" 2>/dev/null || true
rm -rf "$T1" "$T2" "$T3" "$T4" "$T5" "$T6" "$T7" "$T8" "$T9" 2>/dev/null || true
echo
echo "agent-inbox e2e: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
