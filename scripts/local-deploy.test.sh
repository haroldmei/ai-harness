#!/usr/bin/env bash
# Hermetic end-to-end test for the deploy-on-merge journey (scripts/local-deploy.sh).
#
# There is no browser surface, so this drives the REAL script against a REAL local git
# (a bare "origin" + a live clone), with docker and gh STUBBED: zero real docker builds,
# zero real GitHub side-effects, deterministic. It proves the poll→deploy contract:
#
#   1. main advanced  → clones a pinned checkout, pins it to the new SHA, runs
#                        `docker compose up --build` + seed, records the SHA, notifies.
#   2. unchanged      → cheap no-op: NO docker invocation, SHA unchanged.
#   3. advanced again → redeploys; docker runs again; recorded SHA updates.
#   4. lock held      → defers (exit 0, NO docker) — shared with agent-inbox.
#   5. compose fails  → does NOT record the SHA (retries next tick) + notifies failed.
#   6. pr-merge       → the default trigger deploys on a merged PR; a bare direct push to main
#                       is IGNORED (and isolation: live WIP untouched, .env provisioned).
#   7. batched merge  → issue #48: when the latest-merged PR sits BEHIND main's tip (batched /
#                       out-of-order merge), deploy the TIP — never the stale commit — and never
#                       wedge (a later fix still deploys).
#   8. forward-only   → a tip moved BACKWARD (force-push) never rolls the stack back.
#
#   Run: bash scripts/local-deploy.test.sh     (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/local-deploy.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_grep()   { if grep -qF "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected to find: $2)"; fi; }
assert_nogrep() { if grep -qF "$2" "$1" 2>/dev/null; then bad "$3 (unexpectedly found: $2)"; else ok "$3"; fi; }

# ── Build a hermetic env: bare origin + a live clone on main + a stubbed docker/gh ───────
make_env() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/logs" "$tmp/state"

  git init -q --bare "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
  ( cd "$tmp/clone"
    git config user.email t@t; git config user.name tester
    echo base > base.txt
    echo 'services:' > docker-compose.yml
    # The deploy overlay local-deploy.sh layers on (`-f docker-compose.yml -f docker-compose.deploy.yml`);
    # its container_name:s drive the pre-`up` take-over block, so pin one to exercise that path.
    printf 'services:\n  api:\n    container_name: skillforge_api\n' > docker-compose.deploy.yml
    git add -A; git commit -qm init
    git branch -M main; git push -q origin main ) 2>/dev/null

  # The user's live state: dirty, uncommitted WIP in the live copy. A deploy must NEVER
  # touch it (it builds from a separate pinned checkout, not this copy).
  echo "user work in progress" > "$tmp/clone/USER_WIP.txt"
  # A git-ignored .env the stack needs — must be provisioned into the pinned checkout, never committed.
  echo "SECRET=1" > "$tmp/clone/.env"

  # docker stub: records every `compose …` call; obeys DOCKER_STUB_FAIL to fail `up`.
  cat > "$tmp/bin/docker" <<DK
#!/usr/bin/env bash
echo "docker \$*" >> "$tmp/logs/docker-calls.log"
# Fail a \`compose … up …\` when DOCKER_STUB_FAIL is set. \`up\` is no longer arg #2 (it follows the
# \`-f docker-compose.yml -f docker-compose.deploy.yml\` flags), so scan all args for it.
if [ "\$1" = "compose" ] && [ -n "\${DOCKER_STUB_FAIL:-}" ]; then
  for a in "\$@"; do [ "\$a" = "up" ] && exit 1; done
fi
exit 0
DK
  chmod +x "$tmp/bin/docker"

  # gh stub: answers the `pr list` merged-PR query that the default `pr-merge` trigger uses.
  # The "latest merged PR's merge commit" is whatever is in $tmp/merged-sha; when that file is
  # empty it falls back to the current origin/main tip (cwd is the pinned checkout). Writing an
  # OLD sha into merged-sha simulates "main advanced by a direct push, no new PR" → ignored.
  : > "$tmp/merged-sha"
  cat > "$tmp/bin/gh" <<GH
#!/usr/bin/env bash
echo "gh \$*" >> "$tmp/logs/gh-calls.log"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  if [ -s "$tmp/merged-sha" ]; then cat "$tmp/merged-sha"; else git rev-parse origin/main 2>/dev/null; fi
  exit 0
fi
exit 0
GH
  chmod +x "$tmp/bin/gh"
}

# Advance origin/main by one commit (simulates a merged PR landing on main).
advance_main() { ( cd "$1/clone" && echo "$2" > "feature-$2.txt" && git add -A \
  && git commit -qm "merge $2" && git push -q origin main ) 2>/dev/null; }

origin_head() { git -C "$1/clone" rev-parse origin/main 2>/dev/null; }

# Force main BACKWARD to an older commit (simulates a force-push that rewinds the tip).
reset_main_to() { ( cd "$1/clone" && git reset --hard -q "$2" && git push -qf origin main ) 2>/dev/null; }

run_deploy() {  # extra env passed as KEY=VAL args
  local tmp="$1"; shift
  env "$@" \
    DEPLOY_ROOT="$tmp/clone" \
    DEPLOY_DOCKER="$tmp/bin/docker" \
    DEPLOY_GH="$tmp/bin/gh" \
    DEPLOY_REMOTE="origin" DEPLOY_BASE="main" \
    DEPLOY_LOCK="$tmp/deploy.lock" \
    DEPLOY_STATE_DIR="$tmp/state" \
    DEPLOY_LOGDIR="$tmp/logs" \
    DEPLOY_PREFLIGHT_TOOLS="git" \
    DEPLOY_SKIP_HEALTH=1 \
    DEPLOY_NOTIFY_CMD='echo "NOTIFY $DEPLOY_STATUS $DEPLOY_SHA $DEPLOY_MSG" >> '"$tmp/logs/notify.log" \
    PATH="$tmp/bin:$PATH" \
      bash "$RUNNER" > "$tmp/logs/run.out" 2>&1
}

# ── Scenario 1: first deploy (main is ahead of the empty recorded SHA) ───────────────────
echo "Scenario 1 — main advanced → clone pinned checkout, build, seed, record, notify"
T1="$(mktemp -d)"; make_env "$T1"
HEAD1="$(origin_head "$T1")"
run_deploy "$T1"
assert_grep "$T1/logs/docker-calls.log" "up -d --build --force-recreate --wait" "docker compose up --build was invoked"
# deploys the PRODUCTION-STYLE stack: base + the deploy overlay (so the dev override / bind mount is excluded)
assert_grep "$T1/logs/docker-calls.log" "compose -f docker-compose.yml -f docker-compose.deploy.yml up" "up layered base + deploy overlay (-f set)"
assert_grep "$T1/logs/docker-calls.log" "compose -f docker-compose.yml -f docker-compose.deploy.yml exec -T api" "seed ran through the same -f set"
# container_name take-over: the deploy overlay's skillforge_* names are stopped/removed before up
assert_grep "$T1/logs/docker-calls.log" "stop skillforge_api" "took over the pinned container_name before up"
assert_grep "$T1/logs/docker-calls.log" "exec -T api python scripts/seed_courses.py" "reseed was invoked"
# issue #26: after seeding, the deploy asserts the seed is COMPLETE (fails the tick otherwise)
assert_grep "$T1/logs/docker-calls.log" "exec -T api python scripts/verify_seed.py" "seed completeness was verified"
[ "$(cat "$T1/state/last-deployed-sha" 2>/dev/null)" = "$HEAD1" ] && ok "recorded SHA == origin/main" || bad "recorded SHA must equal origin/main"
[ -d "$T1/state/checkout/.git" ] && ok "pinned checkout was cloned (separate from the live copy)" || bad "pinned checkout not created"
[ "$(git -C "$T1/state/checkout" rev-parse HEAD 2>/dev/null)" = "$HEAD1" ] && ok "pinned checkout pinned to the new SHA" || bad "checkout not pinned to new SHA"
assert_grep "$T1/logs/notify.log" "NOTIFY deployed $HEAD1" "notified deployed with the SHA"
# isolation: the live copy's WIP is untouched and never reaches the checkout
[ -f "$T1/clone/USER_WIP.txt" ] && git -C "$T1/clone" status --porcelain | grep -qF USER_WIP.txt && ok "live copy WIP left untouched" || bad "live WIP disturbed"
[ ! -e "$T1/state/checkout/USER_WIP.txt" ] && ok "live WIP never reached the pinned checkout" || bad "live WIP leaked into checkout"
# .env provisioned into the checkout (so the stack can read it), as a symlink
[ -L "$T1/state/checkout/.env" ] && ok ".env provisioned into the pinned checkout (symlink)" || bad ".env not provisioned into checkout"

# ── Scenario 2: second run, main unchanged → cheap no-op ─────────────────────────────────
echo "Scenario 2 — origin/main unchanged → no-op (no docker, SHA unchanged)"
: > "$T1/logs/docker-calls.log"   # reset the call log
run_deploy "$T1"
assert_nogrep "$T1/logs/docker-calls.log" "up -d --build" "no docker build when main is unchanged"
[ "$(cat "$T1/state/last-deployed-sha")" = "$HEAD1" ] && ok "recorded SHA unchanged on a no-op tick" || bad "SHA changed on a no-op"

# ── Scenario 3: main advances again → redeploy ───────────────────────────────────────────
echo "Scenario 3 — main advanced again → redeploy, SHA updates"
: > "$T1/logs/docker-calls.log"
advance_main "$T1" two
HEAD2="$(origin_head "$T1")"
[ "$HEAD2" != "$HEAD1" ] || bad "fixture: main did not actually advance"
run_deploy "$T1"
assert_grep "$T1/logs/docker-calls.log" "up -d --build" "docker rebuild ran on the new merge"
[ "$(cat "$T1/state/last-deployed-sha")" = "$HEAD2" ] && ok "recorded SHA advanced to the new HEAD" || bad "SHA did not advance"
[ "$(git -C "$T1/state/checkout" rev-parse HEAD)" = "$HEAD2" ] && ok "pinned checkout fast-forwarded to the new HEAD" || bad "checkout not advanced"

# ── Scenario 4: the shared lock is held → defer (no docker) ───────────────────────────────
echo "Scenario 4 — shared lock held (agent-inbox building) → defer, no docker"
T4="$(mktemp -d)"; make_env "$T4"
( exec 8>"$T4/deploy.lock"; flock -n 8     # hold the lock for the duration of the run
  : > "$T4/logs/docker-calls.log"
  run_deploy "$T4"
  assert_nogrep "$T4/logs/docker-calls.log" "up -d --build" "deploy deferred while the shared lock is held"
)
assert_grep "$T4/logs/run.out" "deferring to next tick" "logged that it deferred to the next tick"

# ── Scenario 5: compose up fails → do NOT record the SHA + notify failed ──────────────────
echo "Scenario 5 — compose up fails → SHA NOT recorded, notify failed (retries next tick)"
T5="$(mktemp -d)"; make_env "$T5"
HEAD5="$(origin_head "$T5")"
run_deploy "$T5" DOCKER_STUB_FAIL=1
[ ! -f "$T5/state/last-deployed-sha" ] && ok "SHA NOT recorded when compose up failed" || bad "SHA must not be recorded on build failure"
assert_grep "$T5/logs/notify.log" "NOTIFY failed $HEAD5" "notified failed with the SHA"
# next tick (compose now healthy) recovers and deploys
: > "$T5/logs/docker-calls.log"
run_deploy "$T5"
assert_grep "$T5/logs/docker-calls.log" "up -d --build" "recovers and rebuilds on the next tick"
[ "$(cat "$T5/state/last-deployed-sha" 2>/dev/null)" = "$HEAD5" ] && ok "records the SHA once the build succeeds" || bad "SHA not recorded after recovery"

# ── Scenario 6: pr-merge trigger — a direct push to main (no new PR) is IGNORED ───────────
echo "Scenario 6 — direct push to main (no merged PR) → NOT deployed; a real merge IS"
T6="$(mktemp -d)"; make_env "$T6"
HEAD6a="$(origin_head "$T6")"
run_deploy "$T6"                                   # merged-sha empty → deploys the tip
[ "$(cat "$T6/state/last-deployed-sha" 2>/dev/null)" = "$HEAD6a" ] && ok "first merge deployed (pr-merge trigger)" || bad "first merge not deployed"
# Pin the "latest merged PR" at HEAD6a, then advance main by a DIRECT PUSH (no new PR).
echo "$HEAD6a" > "$T6/merged-sha"
advance_main "$T6" pushed
HEAD6b="$(origin_head "$T6")"
[ "$HEAD6b" != "$HEAD6a" ] || bad "fixture: direct push did not advance main"
: > "$T6/logs/docker-calls.log"
run_deploy "$T6"
assert_nogrep "$T6/logs/docker-calls.log" "up -d --build" "direct push did NOT trigger a build"
[ "$(cat "$T6/state/last-deployed-sha")" = "$HEAD6a" ] && ok "recorded SHA stays at the last merged PR (push ignored)" || bad "a direct push wrongly redeployed"
# Now a real PR merge lands at HEAD6b → it DOES deploy.
echo "$HEAD6b" > "$T6/merged-sha"
: > "$T6/logs/docker-calls.log"
run_deploy "$T6"
assert_grep "$T6/logs/docker-calls.log" "up -d --build" "a real PR merge triggers the deploy"
[ "$(cat "$T6/state/last-deployed-sha")" = "$HEAD6b" ] && ok "recorded SHA advances on the merge" || bad "merge did not advance the SHA"

# ── Scenario 7: issue #48 — a batched / out-of-order merge leaves the most-recently-MERGED PR
# BEHIND main's tip. The poller must deploy the TIP, never that stale mid-history commit (which
# would anchor it and wedge the stack on old code forever). ──────────────────────────────────
echo "Scenario 7 — batched merge: latest merged PR sits BEHIND the tip → deploy the TIP (#48)"
T7="$(mktemp -d)"; make_env "$T7"
run_deploy "$T7"                                   # first deploy → records the tip C1
C1="$(origin_head "$T7")"
[ "$(cat "$T7/state/last-deployed-sha")" = "$C1" ] || bad "fixture: first deploy did not record C1"
advance_main "$T7" mid                              # C2 — a PR merge whose commit lands mid-history
C2="$(origin_head "$T7")"
advance_main "$T7" tip                              # C3 — a later PR merge advances the tip
C3="$(origin_head "$T7")"
[ "$C2" != "$C3" ] || bad "fixture: tip did not advance past the mid-history commit"
# Simulate GitHub's merge-recency order returning the MID-history PR (#48's core): the latest
# merged PR's commit is C2, even though main's tip is C3 — ahead of it.
echo "$C2" > "$T7/merged-sha"
: > "$T7/logs/docker-calls.log"
run_deploy "$T7"
assert_grep "$T7/logs/docker-calls.log" "up -d --build" "a batched merge still triggers a deploy"
[ "$(cat "$T7/state/last-deployed-sha")" = "$C3" ] && ok "deployed the TIP (C3), not the stale mid-history PR commit (C2)" || bad "wedged on the stale merged-PR commit instead of the tip"
[ "$(git -C "$T7/state/checkout" rev-parse HEAD)" = "$C3" ] && ok "pinned checkout pinned to the tip, not the mid-history PR commit" || bad "checkout pinned to the wrong commit"
# And it does NOT wedge: a subsequent fix merged at the new tip still deploys on the next tick.
advance_main "$T7" fix
C4="$(origin_head "$T7")"
echo "$C4" > "$T7/merged-sha"
: > "$T7/logs/docker-calls.log"
run_deploy "$T7"
assert_grep "$T7/logs/docker-calls.log" "up -d --build" "a later fix still deploys (poller did not wedge)"
[ "$(cat "$T7/state/last-deployed-sha")" = "$C4" ] && ok "advanced to the newer tip (no wedge)" || bad "poller wedged — newer commit never deployed"

# ── Scenario 8: forward-only — a tip moved BACKWARD (force-push) never rolls the stack back. ─
echo "Scenario 8 — forward-only: a tip rewound behind the deployed commit never rolls back"
T8="$(mktemp -d)"; make_env "$T8"
B1="$(origin_head "$T8")"
advance_main "$T8" ahead
B2="$(origin_head "$T8")"
run_deploy "$T8" DEPLOY_TRIGGER=any-push            # deploy the advanced tip B2 → record B2
[ "$(cat "$T8/state/last-deployed-sha")" = "$B2" ] || bad "fixture: did not deploy the advanced tip B2"
reset_main_to "$T8" "$B1"                            # force-push main BACKWARD to B1
: > "$T8/logs/docker-calls.log"
run_deploy "$T8" DEPLOY_TRIGGER=any-push
assert_nogrep "$T8/logs/docker-calls.log" "up -d --build" "no roll-back when the tip moved behind the deployed commit"
assert_grep   "$T8/logs/run.out" "not rolling back" "logged the forward-only skip"
[ "$(cat "$T8/state/last-deployed-sha")" = "$B2" ] && ok "deployed SHA stays forward (no roll-back)" || bad "stack rolled back to an older commit"

rm -rf "$T1" "$T4" "$T5" "$T6" "$T7" "$T8" 2>/dev/null || true
echo
echo "local-deploy e2e: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
