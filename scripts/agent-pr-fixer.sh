#!/usr/bin/env bash
# agent-pr-fixer.sh — the unattended "pick a PR with requested changes → fix them → hand back".
#
# Stage 4 of the build pipeline (docs/35). agent-pr-reviewer (model R) requested changes on a
# PR (label `changes-requested`); THIS agent — a DIFFERENT model F — addresses each finding in
# an ISOLATED worktree on the PR's head branch, RE-RUNS the project gates, and:
#   - gates green → pushes the branch + comments what changed + relabels `review-needed`
#                   (round++) so the reviewer re-reviews.
#   - gates red   → does NOT push; routes to `review-stuck` with the gate log (never push red).
# The reviewer⇄fixer loop runs until APPROVED or PR_MAX_ROUNDS → `review-stuck` (human).
#
# ISOLATION: the fix happens in a DEDICATED git worktree checked out on the PR head branch —
# never your primary working copy, never `main`. Only the PR branch is pushed.
#
# Single-pass (the timer re-invokes it); one PR per run; a flock guarantees one instance.
# Hermetically testable (scripts/agent-pr-fixer.test.sh) — gh/claude injectable + stubbed.
#
#   Labels: changes-requested → fix-wip → {review-needed (round++) | review-stuck}
#   Plan: docs/35-pr-review-fix-loop-iteration-plan.md
set -uo pipefail

# ── Injectable dependencies ──────────────────────────────────────────────────────
ROOT="${PR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Libs live NEXT TO this script, so resolve them from BASH_SOURCE — never from $ROOT.
# $ROOT is overridable (AGENT_ROOT/PR_ROOT/SCOUT_ROOT) and every hermetic suite points it at a
# sandbox clone with no scripts/lib, so a $ROOT-relative source silently fails there: without
# `set -e` the script sails on with classify_model_result AND agent_trace_span undefined, and
# the span the gate believes it is checking is never emitted (#2390).
# shellcheck source=scripts/lib/agent-model-call.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/agent-model-call.sh"
# shellcheck source=scripts/lib/deps-verify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deps-verify.sh"
# shellcheck source=lib/pr-lock.sh
source "$ROOT/scripts/lib/pr-lock.sh"
# Fail LOUD if it did not load. `source` on a missing file is non-fatal without `set -e`, and the
# next call to pr_lock_try would be command-not-found → non-zero → "every PR is held by another
# stage" → a stage that silently does nothing on every tick, forever. Exactly how this landed the
# first time (the hermetic harnesses copy libs into a fake clone and this one was not on the list).
if ! declare -F pr_lock_try >/dev/null 2>&1; then
  echo "FATAL: scripts/lib/pr-lock.sh did not load from ROOT='$ROOT' — refusing to run blind" >&2
  exit 2
fi
GH="${PR_GH:-gh}"
CLAUDE="${PR_CLAUDE:-claude}"
REMOTE="${PR_REMOTE:-origin}"
HEAD_GLOB="${PR_HEAD_GLOB:-agent/}"
REVIEWER_MODEL="${PR_REVIEWER_MODEL:-opus}"
FIXER_MODEL="${PR_FIXER_MODEL:-sonnet}"           # model F — must DIFFER from R (FR-075)
MAX_ROUNDS="${PR_MAX_ROUNDS:-4}"
GATES_CMD="${PR_GATES_CMD:-scripts/quality-gates.sh --only unit --tier launch}"  # unit only; e2e runs at merge time
FIXER_MAX_SELF_REPAIR="${PR_FIXER_MAX_SELF_REPAIR:-3}"   # gate-fix retries per round (inline loop)
FIXER_SELF_REPAIR="${PR_FIXER_SELF_REPAIR:-1}"            # 0 = old binary gate-fail → review-stuck
DEPS_MODE="${PR_DEPS:-install}"                   # install | symlink (node_modules into the worktree)
# ── Per-repo namespace — so the PR loop in DIFFERENT repos never collides on a global /tmp
# lock (or clobbers a shared PR_LOGDIR). The git common dir is stable across a repo's own
# worktrees yet unique per repo; resolve to an ABSOLUTE path (`--git-common-dir` returns a bare
# ".git" at a repo root, so every repo would hash identically otherwise). The three PR-loop
# stages (reviewer/fixer/merger) derive the SAME key in the SAME repo → they still share
# PR_LOGDIR intra-repo while staying isolated across repos. All paths stay overridable.
pr_repo_ns() {
  local d
  d="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  d="$(cd "$ROOT" 2>/dev/null && cd "$d" 2>/dev/null && pwd)" || return 1
  printf '%s' "$d" | sha1sum | cut -c1-12
}
NS="$(pr_repo_ns || true)"; [ -n "$NS" ] || NS="nogit"
LOCK="${PR_FIXER_LOCK:-/tmp/agent-pr-fixer-$NS.lock}"
LOGDIR="${PR_LOGDIR:-/tmp/agent-pr-review-$NS}"
WORKTREE_BASE="${PR_WORKTREE_BASE:-/tmp/agent-pr-review-$NS/worktrees}"

cd "$ROOT" || { echo "[pr-fixer] cannot cd to $ROOT" >&2; exit 2; }
mkdir -p "$LOGDIR" "$WORKTREE_BASE"
log() { printf '[pr-fixer] %s\n' "$*"; }

# Label ops via REST (gh pr edit --add-label hits the deprecated projectCards GraphQL field
# and flakily drops the label, docs/35). Non-fatal; add LOGGED on failure, remove tolerates 404.
add_label()    { "$GH" api -X POST   "repos/{owner}/{repo}/issues/$1/labels"     -f "labels[]=$2" >/dev/null 2>&1 || log "WARN: could not add label '$2' to #$1"; }
remove_label() { "$GH" api -X DELETE "repos/{owner}/{repo}/issues/$1/labels/$2"                   >/dev/null 2>&1 || true; }

# ── Toolchain bootstrap ──────────────────────────────────────────────────────────
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
[ -s "$HOME/miniconda3/etc/profile.d/conda.sh" ] && . "$HOME/miniconda3/etc/profile.d/conda.sh" >/dev/null 2>&1 || true
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) [ -d "$PNPM_HOME" ] && PATH="$PNPM_HOME:$PATH";; esac

# ── FR-075: the fixer must DIFFER from the reviewer ──────────────────────────────
if [ "$FIXER_MODEL" = "$REVIEWER_MODEL" ]; then
  log "REFUSING: PR_FIXER_MODEL ('$FIXER_MODEL') must DIFFER from PR_REVIEWER_MODEL (separation of duties)."
  exit 2
fi

# ── Preflight ───────────────────────────────────────────────────────────────────
for t in git jq "$GH" "$CLAUDE"; do
  command -v "$t" >/dev/null 2>&1 || { log "PREFLIGHT FAILED — not on PATH: $t"; exit 1; }
done

# ── Single-instance lock ─────────────────────────────────────────────────────────
# A counting semaphore, not a mutex. At the default of 1 this is the historical behaviour
# byte for byte: one fixer at a time, exit quietly if another holds it. Raised above 1, N fixers
# run concurrently — safe ONLY because each one takes a PER-PR lock before acting (see
# scripts/lib/pr-lock.sh), so two of them can never land on the same PR. Do not raise this
# without that: it is how #2152 happened at N=1-by-accident (two fixer runs, one round,
# divergent commits).
PR_FIXER_SLOTS="${PR_FIXER_SLOTS:-1}"
if [ "$PR_FIXER_SLOTS" -le 1 ]; then
  exec 9>"$LOCK"
  if ! flock -n 9; then log "another fixer run in progress — exiting"; exit 0; fi
else
  # shellcheck source=lib/slot-lock.sh
  source "$ROOT/scripts/lib/slot-lock.sh"
  # slot_acquire ASSIGNS (never $(…)) — command substitution would take the lock in a subshell
  # that exits immediately, so every instance would "hold" slot 0 while holding nothing.
  if ! slot_acquire _fixer_slot "${LOCK%.lock}-slot" "$PR_FIXER_SLOTS" 9 1; then
    log "all $PR_FIXER_SLOTS fixer slots busy — exiting"; exit 0
  fi
  log "fixer slot ${_fixer_slot}/$PR_FIXER_SLOTS"
fi

# ── Find one PR with requested changes (not claimed/terminal) ────────────────────
# (no server-side --label here: gh implements it via the SEARCH API, whose index can
#  lag label churn by hours and hide the PR — the label is filtered client-side below
#  from live data instead)
prs_json="$("$GH" pr list --state open \
  --json number,headRefName,labels,title --limit 50 2>/dev/null || echo '[]')"
[ -z "$prs_json" ] && prs_json='[]'
# Candidates in order, then take the first PR no OTHER stage is holding. Was `.[0] // empty`:
# a single mutex per stage made that safe, but with a parallel driver two instances would both
# select the same head-of-list PR and both act on it (#2152 — two fixer runs in one round,
# divergent commits). The `fix-wip` label is a claim SIGNAL, not a mutex: it is written after this
# read, over the network, with no compare-and-set. The flock closes the window the label cannot.
# Non-blocking + skip-ahead, so a PR another instance owns costs us nothing but a candidate.
_cand_json="$(jq -c --arg pfx "$HEAD_GLOB" 'map(select(
  (.headRefName | startswith($pfx)) and
  ([.labels[]?.name] | index("changes-requested")) and
  ([.labels[]?.name] | index("fix-wip")         | not) and
  ([.labels[]?.name] | index("review-wip")      | not) and
  ([.labels[]?.name] | index("review-approved") | not) and
  ([.labels[]?.name] | index("review-stuck")    | not)
))' <<<"$prs_json")"
mapfile -t _cands < <(jq -r '.[].number' <<<"$_cand_json")
eligible=""; PR_LOCK_FD=""
if [ "${#_cands[@]}" -gt 0 ]; then
  if pr_lock_first_free _picked_pr PR_LOCK_FD "${_cands[@]}"; then
    eligible="$(jq -c --argjson n "$_picked_pr" 'map(select(.number == $n)) | .[0] // empty' <<<"$_cand_json")"
  else
    log "all fix candidate PR(s) (${_cands[*]}) are held by another stage — nothing to do this tick"
  fi
fi
if [ -z "$eligible" ]; then log "no PRs awaiting a fix"; exit 0; fi

n="$(jq -r '.number' <<<"$eligible")"
head="$(jq -r '.headRefName' <<<"$eligible")"
log "fixing PR #${n} (${head})"
add_label "$n" fix-wip; remove_label "$n" changes-requested

# ── Round cap: stop before attempting a fix we've already attempted MAX_ROUNDS times ──
round="$("$GH" pr view "$n" --json comments --jq '[.comments[].body | capture("pr-loop-round: (?<r>[0-9]+)").r | tonumber] | max // 0' 2>/dev/null || echo 0)"
[[ "$round" =~ ^[0-9]+$ ]] || round=0
if [ "$round" -ge "$MAX_ROUNDS" ]; then
  "$GH" pr comment "$n" -b "🛑 agent-pr-fixer: round cap (${round}/${MAX_ROUNDS}) reached — handing to a human." >/dev/null 2>&1 || true
  add_label "$n" review-stuck; remove_label "$n" fix-wip
  log "PR #${n} at round cap → review-stuck"
  exit 0
fi
next_round=$((round + 1))

# ── The latest findings: the reviewer's CHANGES REQUESTED comment, or the merger's
# INTEGRATION GATES FAILED comment (the merger routes red integrations into this loop
# instead of dead-ending at merge-stuck) — whichever is most recent. ──────────────
review_body="$("$GH" pr view "$n" --json comments \
  --jq '[.comments[] | select(.body | test("agent-pr-reviewer: CHANGES REQUESTED|agent-pr-merger: INTEGRATION GATES FAILED"))] | last.body // ""' 2>/dev/null || echo "")"
[ -z "$review_body" ] && review_body="(no reviewer comment found — address any obvious gate failures)"

# ── Isolated worktree ON the PR head branch ──────────────────────────────────────
git fetch -q "$REMOTE" "$head" >/dev/null 2>&1 || true
wt="${WORKTREE_BASE}/pr-${n}"
git worktree remove --force "$wt" >/dev/null 2>&1 || true; rm -rf "$wt" >/dev/null 2>&1 || true
# DETACHED worktree at the remote head — NOT `-B <branch>`. A `-B` reset of the branch fails with
# "Cannot force update the current branch" when the PR branch happens to be checked out in the
# primary working copy (the repo gets parked on stray agent/* branches). Detached at the commit
# never touches the branch ref, so it works regardless; we push HEAD:<head> at the end.
if ! git worktree add -f --detach "$wt" "${REMOTE}/${head}" >/dev/null 2>&1; then
  log "could not create worktree on ${head}"
  "$GH" pr comment "$n" -b "⚠️ agent-pr-fixer: could not check out the PR branch — needs a human." >/dev/null 2>&1 || true
  add_label "$n" review-stuck; remove_label "$n" fix-wip
  exit 0
fi
cleanup() { cd "$ROOT" 2>/dev/null || true; git worktree remove --force "$wt" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Guarded (issue #2387): an unguarded `cd "$wt"` that fails leaves the process in the
# PRIMARY checkout and every subsequent build/gate/git command below runs against it
# instead of the isolated worktree — the exact "runs in the wrong directory" failure
# SC2164 warns about, in the one place it would do the most damage.
cd "$wt" || { log "FATAL: cannot enter worktree $wt — aborting fix"; exit 2; }

# ── Provision deps the gates need (fresh worktree has no node_modules) ───────────
# The repo is an npm-WORKSPACES monorepo (frontend, mobile, packages/*), so provisioning
# runs at the WORKTREE ROOT — the old frontend-only install left `mobile/` without deps and
# every mobile vitest file died in <1s on `extends: expo/tsconfig.base`, so the fixer could
# NEVER produce green gates and each PR dead-ended at review-stuck (PR #1942 false positive;
# same root cause as the merger's PR #1926 one). Loud (no --silent), never `|| true`-swallowed
# (#1829). Backend Python deps come from the active conda/venv on PATH.
#
# …and VERIFIED, not merely exit-code-checked (#2438). `npm ci` returns 0 on an install that left
# a workspace short of a package; `mobile/` without `expo` kills all ~154 mobile suites at
# transform time and the fixer then burns a round chasing a red that no edit can clear. Shared
# with agent-inbox.sh (#2124) and agent-pr-merger.sh via lib/deps-verify.sh.
DEPS_MISSING=""
provision_deps() {
  local d rc=0
  if [ "$DEPS_MODE" = "symlink" ]; then
    for d in . frontend mobile packages/*; do
      [ -d "$ROOT/$d/node_modules" ] || continue
      [ -d "$wt/$d" ] || continue
      [ -e "$wt/$d/node_modules" ] || ln -s "$ROOT/$d/node_modules" "$wt/$d/node_modules" 2>/dev/null || rc=1
    done
    [ "$rc" = 0 ] || return $rc
    # Verified, never repaired: `npm install` here writes THROUGH the symlinks into the host's
    # shared node_modules.
    DEPS_MISSING="$(deps_unresolved_summary "$wt")"
    [ -z "$DEPS_MISSING" ] || return 3
    return 0
  fi
  [ -f "$wt/package.json" ] || return 0
  if [ -f "$wt/package-lock.json" ]; then
    ( cd "$wt" && npm ci --no-audit --no-fund ) >>"${LOGDIR}/deps-${n}.log" 2>&1; rc=$?
  else
    ( cd "$wt" && npm install --no-audit --no-fund ) >>"${LOGDIR}/deps-${n}.log" 2>&1; rc=$?
  fi
  # npm may rewrite lockfiles; never let that end up in the fix commit.
  git -C "$wt" checkout -q -- package-lock.json frontend/package-lock.json >/dev/null 2>&1 || true
  [ "$rc" = 0 ] || return $rc
  DEPS_MISSING="$(deps_unresolved_summary "$wt")"
  if [ -n "$DEPS_MISSING" ]; then
    log "deps: incomplete install (repairing) — unresolved: ${DEPS_MISSING}"
    printf 'deps: unresolved after provisioning: %s\ndeps: repairing with npm install…\n' \
      "$DEPS_MISSING" >>"${LOGDIR}/deps-${n}.log"
    ( cd "$wt" && npm install --no-audit --no-fund ) >>"${LOGDIR}/deps-${n}.log" 2>&1 \
      || log "deps: repair npm install failed (see deps-${n}.log)"
    git -C "$wt" checkout -q -- package-lock.json frontend/package-lock.json >/dev/null 2>&1 || true
    DEPS_MISSING="$(deps_unresolved_summary "$wt")"
  fi
  [ -z "$DEPS_MISSING" ] || return 3
  return 0
}
# Bounded across ticks, and NOT counted from PR comments — comment-counting would force a
# comment every tick just to keep score. Same shape as agent-inbox.sh's DEPS_MAX_RETRY /
# agent-pr-merger.sh's MERGER_MAX_ENV_DEFER: those two bound their own deps-unresolvable loop,
# and this one inherited the skip logic from the inbox without inheriting the bound, so a
# permanently-unresolvable tree refused the same PR forever (never fixed, never `review-stuck`,
# no human notified) — the PR is re-selected next tick by the very `changes-requested` label this
# branch re-applies.
FIXER_DEPS_MAX_RETRY="${PR_FIXER_DEPS_MAX_RETRY:-3}"
deps_retry_file="${LOGDIR}/deps-retry-${n}.count"
deps_retries() { local c; c="$(cat "$deps_retry_file" 2>/dev/null || true)"; [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo 0; }

DEPS_UNDECLARED_NOTE=""
provision_rc=0; provision_deps || provision_rc=$?
if [ "$provision_rc" != 0 ]; then
  # Infra failure, not the PR's fault — defer like a transient model failure: retry next
  # tick, no round consumed, never review-stuck (see ${LOGDIR}/deps-${n}.log).
  if [ "$provision_rc" = 3 ]; then
    # An unresolved package that is DECLARED nowhere was never going to be there — the PR's own
    # diff broke the dependency graph (deleted the declaration, or added a consumer without
    # adding one), same discrimination agent-pr-merger.sh makes via deps_unresolved_all_declared
    # (J-MG-31). That is a code defect the model can fix, not an install gap, and must not take
    # the environmental skip below: this exact PR is re-selected next tick by the same
    # `changes-requested` label (see the selector above), so skipping it with "round NOT
    # consumed" refuses it forever — never fixed, never `review-stuck`, no human notified. The
    # merger already routes precisely this shape into this loop via route_red_integration; let it
    # fall through to the normal fix round below instead of dead-ending it again.
    if deps_unresolved_all_declared "$wt"; then
      attempt="$(( $(deps_retries) + 1 ))"
      printf '%s' "$attempt" > "$deps_retry_file" 2>/dev/null || true
      if [ "$attempt" -ge "$FIXER_DEPS_MAX_RETRY" ]; then
        log "deps: workspace(s) unresolved ${attempt}x in a row (${DEPS_MISSING}) — a model fix cannot repair the environment; escalating to review-stuck"
        "$GH" pr comment "$n" -b "$(printf '🛑 agent-pr-fixer: dependency provisioning failed %s times in a row — `%s` cannot be resolved in the fix worktree even after a repair attempt. No model fix was attempted on any of the %s ticks: a tree that cannot load its own modules is not something an edit to this PR can fix. Needs a human.' "$attempt" "$DEPS_MISSING" "$attempt")" >/dev/null 2>&1 || true
        add_label "$n" review-stuck; remove_label "$n" fix-wip
        exit 0
      fi
      if [ "$DEPS_MODE" = "symlink" ]; then
        log "deps: workspace(s) unresolved in the mirrored host install (${DEPS_MISSING}) — symlink mode never repairs, so this reports the host's own state; no model fix attempted on a tree that cannot load its own modules; leaving PR #${n} as changes-requested (round NOT consumed, deps retry ${attempt}/${FIXER_DEPS_MAX_RETRY})"
      else
        log "deps: workspace(s) still unresolved after repair (${DEPS_MISSING}) — no model fix attempted on a tree that cannot load its own modules; leaving PR #${n} as changes-requested (round NOT consumed, deps retry ${attempt}/${FIXER_DEPS_MAX_RETRY})"
      fi
      add_label "$n" changes-requested; remove_label "$n" fix-wip
      exit 0
    fi
    log "deps: workspace(s) unresolved (${DEPS_MISSING}) but the missing package is DECLARED NOWHERE — a code defect, not an install gap; falling through to the normal fix round (bounded by the round cap above) instead of skipping"
    DEPS_UNDECLARED_NOTE="deps provisioning also failed: ${DEPS_MISSING} — unresolved because the package is not declared in any package.json on that path (this is not an install gap; the PR's own diff broke its dependency graph). Declare the missing package where it belongs and, if a package-lock.json is in use, run \`npm install\` to regenerate it so the workspace resolves again."
  else
    log "deps provisioning FAILED (see ${LOGDIR}/deps-${n}.log) — leaving PR #${n} as changes-requested; retry next tick (round NOT consumed)"
    add_label "$n" changes-requested; remove_label "$n" fix-wip
    exit 0
  fi
fi
# Provisioning is healthy (or the failure was a code defect routed to the fix round below) —
# clear any prior brick counter so an old streak can't escalate later.
rm -f "$deps_retry_file" 2>/dev/null || true

# ── Drive the fix headlessly (model F) ───────────────────────────────────────────
prompt="$(cat <<EOF
You are agent-pr-fixer, working UNATTENDED in an isolated git worktree on branch '${head}'.
A reviewer (a different model) requested the changes below on this PR. Address EACH finding:
either change the code to fix it, OR, if the reviewer is mistaken, leave the code and note why.
Add or update tests for each behavioural fix. Keep the change SCOPED to the findings — do not
make unrelated changes. Work ONLY in this worktree. When finished, stop.

LEAVE YOUR EDITS UNCOMMITTED in the working tree. The harness stages, commits, re-runs the
gates and pushes for you. Do NOT run git commit / git branch / git checkout / git reset /
git stash / git push: a clean tree is one of the signals the harness reads as "the model
declined to change anything", and anything you commit yourself is not what gets reviewed.

=== REVIEWER FINDINGS ===
${review_body}
${DEPS_UNDECLARED_NOTE:+
=== DEPENDENCY PROVISIONING ALSO FAILED (fix this too) ===
${DEPS_UNDECLARED_NOTE}
}
EOF
)"
log "running fixer model ${FIXER_MODEL} in ${wt}…"
fix_log="${LOGDIR}/agent-fix-${n}.json"
"$CLAUDE" -p "$prompt" --permission-mode bypassPermissions --model "$FIXER_MODEL" --output-format json \
  >"$fix_log" 2>"${fix_log%.json}.stderr" || log "fixer model exited non-zero — proceeding to gates"

# CLAUDE.md: every `claude` invocation emits a span (#2390). The review⇄fix loop is where the
# pipeline's token spend concentrates, so this round is recorded before any disposition returns.
fix_cls="$(classify_model_result "$fix_log")"
agent_trace_span "$fix_log" fix pr="$n" round="$next_round" model="$FIXER_MODEL" \
  outcome="$fix_cls" template="pr-fixer-v1" prompt="$prompt"

# ── Transient failure (rate/usage limit, overload) → the model never ran, so it produced no fix.
# Restore the PR to changes-requested and retry on the next tick — do NOT escalate to review-stuck
# and do NOT consume a round. MUST come BEFORE the "no code changes" branch (a transient run leaves
# the worktree untouched, which would otherwise be misread as "nothing to fix" and burn a round). ─
if [ "$fix_cls" = "transient" ]; then
  log "fixer model hit a transient limit (rate-limit/usage-limit/overload) — leaving PR #${n} as changes-requested; retry next tick (round NOT consumed)"
  add_label "$n" changes-requested; remove_label "$n" fix-wip
  exit 0
fi

# ── Did the model commit its own work? ──────────────────────────────────────────
# Nothing STOPS it from doing so, and it does: PR #2196 rounds 2 and 3 each edited five or six
# files, ran the tests, then `git commit`-ed inside the worktree (round 3 also `git branch -f`'d
# the local head ref). A committed fix leaves a CLEAN tree, which the dirty-index test below read
# as "produced no code changes" — the canned no-change comment went up, the EXIT trap removed the
# worktree, and two complete fixes were left as unreachable commits while the reviewer re-reviewed
# stale code for two more rounds. So measure work as "HEAD moved OR the tree is dirty".
base_sha="$(git rev-parse "${REMOTE}/${head}" 2>/dev/null || true)"
model_committed=0
if [ -n "$base_sha" ] && [ "$base_sha" != "$(git rev-parse HEAD)" ]; then
  model_committed=1
  log "fixer model committed in-worktree ($(git rev-list --count "${base_sha}..HEAD" 2>/dev/null || echo '?') commit(s) ahead of ${REMOTE}/${head}) — keeping them"
  # A commit that is not a descendant of the remote tip cannot be fast-forward pushed (the model
  # rebased, reset or grafted). Bail rather than force anything over a branch a human may share.
  if ! git merge-base --is-ancestor "$base_sha" HEAD 2>/dev/null; then
    "$GH" pr comment "$n" -b "🛑 agent-pr-fixer: the fixer model rewrote history in its worktree — HEAD is not a descendant of \`${REMOTE}/${head}\`, so the fix cannot be fast-forwarded. Needs a human (the work is tagged \`fixer/pr-${n}-round-${next_round}\` in the local clone)." >/dev/null 2>&1 || true
    git tag -f "fixer/pr-${n}-round-${next_round}" HEAD >/dev/null 2>&1 || true
    add_label "$n" review-stuck; remove_label "$n" fix-wip
    log "PR #${n}: model commit is not a descendant of ${REMOTE}/${head} → review-stuck (tagged)"
    exit 0
  fi
  # `git add -A && git commit` by the model can sweep in the node_modules we provisioned. Never
  # push those; a human decides, and the tag below keeps the work reachable.
  if git diff --name-only "${base_sha}..HEAD" 2>/dev/null \
     | grep -qE '(^|/)node_modules(/|$)|(^|/)\.env(\.|$)|(^|/)\.gcp(/|$)'; then
    "$GH" pr comment "$n" -b "🛑 agent-pr-fixer: the fixer model committed provisioned artefacts (node_modules/.env) — not pushing. Needs a human (the work is tagged \`fixer/pr-${n}-round-${next_round}\` in the local clone)." >/dev/null 2>&1 || true
    git tag -f "fixer/pr-${n}-round-${next_round}" HEAD >/dev/null 2>&1 || true
    add_label "$n" review-stuck; remove_label "$n" fix-wip
    log "PR #${n}: model commit contains provisioned artefacts → review-stuck (tagged)"
    exit 0
  fi
fi

# Commit what the agent changed (worktree only). Strip provisioned node_modules/env
# (root + every workspace — provisioning is root-level now).
git add -A
git reset -q -- node_modules frontend/node_modules mobile/node_modules 'packages/*/node_modules' \
  .env .env.local .gcp \
  backend/.env backend/.env.local frontend/.env frontend/.env.local 2>/dev/null || true
if git diff --cached --quiet && [ "$model_committed" -eq 0 ]; then
  log "fixer produced no code changes"
  "$GH" pr comment "$n" -b "ℹ️ agent-pr-fixer (round ${next_round}): no code changes — the reviewer's points may be replies/justifications. Re-review.
<!-- pr-loop-round: ${next_round} -->" >/dev/null 2>&1 || true
  add_label "$n" review-needed; remove_label "$n" fix-wip
  exit 0
fi
# Uncommitted leftovers ride on top of whatever the model committed itself.
if ! git diff --cached --quiet; then
  git commit -q -m "fix(pr #${n}): address review findings (round ${next_round})

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
fi

# Reachable name for the work BEFORE the gates run. Every bail-out below removes the worktree
# (trap cleanup), which orphans a detached-HEAD commit — that is how finished fixes have gone
# missing (#1764, #2152, #2196). The tag is deleted again once the push succeeds.
git tag -f "fixer/pr-${n}-round-${next_round}" HEAD >/dev/null 2>&1 || true

# ── Provision local env-files the gates need (AFTER the commit, so never committed) ──
shopt -s nullglob
for src in "$ROOT"/.env "$ROOT"/.env.local "$ROOT"/.gcp "$ROOT"/backend/.env "$ROOT"/backend/.env.local "$ROOT"/frontend/.env "$ROOT"/frontend/.env.local; do
  [ -e "$src" ] || continue
  rel="${src#"$ROOT"/}"; dst="$wt/$rel"
  [ -e "$dst" ] || { mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" 2>/dev/null; } || true
done
shopt -u nullglob

# ── Re-run the gates: NEVER push red. Self-repair on failure. ──────────────────
#
# Differential gating (round 2+): the first round already proved the full suite
# green, so subsequent rounds scope gates to what the fix actually touched.
# Re-evaluated inside the while loop so each self-repair iteration's changes
# determine the scope — a self-repair that crosses into a new area naturally
# falls back to the full set.
#
# The scoping SUBTRACTS from whatever `--only` the caller configured; it never substitutes a
# hardcoded list. It used to substitute, and after the 2026-07-31 build/merge gate split that
# silently ADDED gates: a backend-only round 2 rewrote the configured build-side set to one
# containing `integration`, re-importing at fix time exactly the slow gate the split moved to
# merge time. A scoping rule that can widen the set is not a scoping rule.
fixer_gates_drop() { # <cmd> <gate>[,<gate>…] — remove gates from an `--only` list
  local cmd="$1" drop="$2" only new g keep
  only="$(printf '%s' "$cmd" | sed -nE 's/.*--only[[:space:]]+([^[:space:]]+).*/\1/p')"
  [ -n "$only" ] || { printf '%s' "$cmd"; return; }
  new=""
  for g in ${only//,/ }; do
    keep=1
    case ",${drop}," in *",${g},"*) keep=0;; esac
    [ "$keep" = 1 ] && new="${new}${new:+,}${g}"
  done
  # Dropping everything would turn the re-gate into a no-op that reports green: keep the original.
  [ -n "$new" ] || { printf '%s' "$cmd"; return; }
  printf '%s' "$cmd" | sed -E "s/--only[[:space:]]+[^[:space:]]+/--only ${new}/"
}
fixer_repair_attempt=0
while true; do
  _effective_gates="$GATES_CMD"
  if [ "$next_round" -gt 1 ]; then
    _diff_files="$(git diff --name-only HEAD~1 2>/dev/null || true)"
    if [ -n "$_diff_files" ]; then
      _has_backend=0; _has_frontend=0
      echo "$_diff_files" | grep -q '^backend/' && _has_backend=1 || true
      echo "$_diff_files" | grep -qE '^(frontend/|packages/)' && _has_frontend=1 || true
      if [ "$_has_backend" = 1 ] && [ "$_has_frontend" = 0 ]; then
        _effective_gates="$(fixer_gates_drop "$GATES_CMD" "e2e")"
        log "round ${next_round}: backend-only changes — scoping gates (dropping e2e where configured)"
      elif [ "$_has_frontend" = 1 ] && [ "$_has_backend" = 0 ]; then
        _effective_gates="$(fixer_gates_drop "$GATES_CMD" "docs-refs,seed-integrity,migration-drift,repro-tests,integration,contract")"
        log "round ${next_round}: frontend-only changes — scoping gates (dropping backend-only gates where configured)"
      fi
    fi
  fi
  log "re-running gates: ${_effective_gates}"
  if bash -c "$_effective_gates" >"${LOGDIR}/gates-${n}.log" 2>&1; then
    # Detached HEAD → push the commit to the remote PR branch explicitly (HEAD:<head>).
    # A SWALLOWED push failure is the other way a finished fix goes missing: the comment claimed
    # "pushed", the label moved to review-needed, and the reviewer re-reviewed the old tip while
    # the fix sat unpushed (#1764). Never claim a push that did not happen.
    if ! git push "$REMOTE" "HEAD:${head}" >"${LOGDIR}/push-${n}.log" 2>&1; then
      log "PR #${n}: gates green but PUSH FAILED (see ${LOGDIR}/push-${n}.log) → review-stuck (tagged)"
      "$GH" pr comment "$n" -b "$(printf '🛑 agent-pr-fixer (round %s): the fix passed the gates but the push to `%s` FAILED — nothing landed. Needs a human; the commit is tagged `fixer/pr-%s-round-%s` in the local clone.\n\n```\n%s\n```' "$next_round" "$head" "$n" "$next_round" "$(tail -15 "${LOGDIR}/push-${n}.log")")" >/dev/null 2>&1 || true
      add_label "$n" review-stuck; remove_label "$n" fix-wip
      exit 0
    fi
    git tag -d "fixer/pr-${n}-round-${next_round}" >/dev/null 2>&1 || true
    "$GH" pr comment "$n" -b "$(printf '🔧 agent-pr-fixer (model %s, round %s): addressed the findings — gates green, pushed. Re-review please.\n<!-- pr-loop-round: %s -->' "$FIXER_MODEL" "$next_round" "$next_round")" >/dev/null 2>&1 || true
    add_label "$n" review-needed; remove_label "$n" fix-wip
    log "PR #${n} fixed + gates green → review-needed (round ${next_round})"
    exit 0
  fi

  # ── Gates red — self-repair (if enabled and not exhausted) ────────────────────
  if [ "${FIXER_SELF_REPAIR:-1}" != "1" ]; then
    "$GH" pr comment "$n" -b "$(printf '🛑 agent-pr-fixer: the fix did not pass the gates (not pushed) — needs a human.\n\n```\n%s\n```' "$(tail -25 "${LOGDIR}/gates-${n}.log")")" >/dev/null 2>&1 || true
    add_label "$n" review-stuck; remove_label "$n" fix-wip
    log "PR #${n} fix failed gates → review-stuck (not pushed)"
    exit 0
  fi

  fixer_repair_attempt=$((fixer_repair_attempt + 1))
  if [ "$fixer_repair_attempt" -gt "$FIXER_MAX_SELF_REPAIR" ]; then
    "$GH" pr comment "$n" -b "$(printf '🛑 agent-pr-fixer: the fix did not pass the gates after %s self-repair attempt(s) — needs a human.\n\n```\n%s\n```' "$FIXER_MAX_SELF_REPAIR" "$(tail -25 "${LOGDIR}/gates-${n}.log")")" >/dev/null 2>&1 || true
    add_label "$n" review-stuck; remove_label "$n" fix-wip
    log "PR #${n} fix failed gates → review-stuck (self-repair exhausted after ${FIXER_MAX_SELF_REPAIR})"
    exit 0
  fi

  log "PR #${n}: gates FAILED — self-repair attempt ${fixer_repair_attempt}/${FIXER_MAX_SELF_REPAIR}"
  "$GH" pr comment "$n" -b "$(printf '🔧 agent-pr-fixer: gates failed on the fix. Self-repair attempt %s/%s — feeding the failure back to the model.\n\n```\n%s\n```\n<!-- fixer-self-repair -->' "$fixer_repair_attempt" "$FIXER_MAX_SELF_REPAIR" "$(tail -25 "${LOGDIR}/gates-${n}.log")")" >/dev/null 2>&1 || true

  # ── Invoke the fixer model again with the gate failure fed back ──────────────
  repair_prompt="$(cat <<EOF
You are agent-pr-fixer's self-repair loop, working UNATTENDED in an isolated git worktree
on branch '${head}'. Your previous fix for the review findings was committed, but the
quality gates FAILED. Fix the ROOT CAUSE so the gates pass. The failing test may be
CORRECT and exposing a pre-existing bug your fix uncovered — fix THAT (the real defect),
not just your own change. Keep the change SCOPED to the gate failure; do not make
unrelated changes. Work ONLY in this worktree. When finished, stop.

LEAVE YOUR EDITS UNCOMMITTED in the working tree — the harness commits, re-gates and pushes.
Do NOT run git commit / git branch / git checkout / git reset / git stash / git push.

=== GATE FAILURE (self-repair attempt ${fixer_repair_attempt}/${FIXER_MAX_SELF_REPAIR}) ===
$(tail -80 "${LOGDIR}/gates-${n}.log")

=== ORIGINAL REVIEW FINDINGS (for context) ===
${review_body}
EOF
)"
  repair_head_before="$(git rev-parse HEAD 2>/dev/null || true)"
  repair_log="${LOGDIR}/agent-fix-repair-${n}-${fixer_repair_attempt}.json"
  "$CLAUDE" -p "$repair_prompt" --permission-mode bypassPermissions --model "$FIXER_MODEL" --output-format json \
    >"$repair_log" 2>"${repair_log%.json}.stderr" || log "self-repair model exited non-zero — proceeding"

  # CLAUDE.md: every `claude` invocation emits a span (#2390). Its own stage, not `fix`: self-repair
  # turns are re-gating attempts on an ALREADY-fixed tree, so folding their cost into `fix` would
  # inflate the apparent price of a fix round and hide how much the gate loop itself costs.
  # `round` stays the PR-loop round (same value as the `fix` span above) so the two are joinable on
  # the same PR; the self-repair ordinal rides the separate `attempt` axis instead (#2390 review —
  # reusing `round` for it silently attributed round-N gate-loop cost to rounds 1..attempt).
  repair_cls="$(classify_model_result "$repair_log")"
  agent_trace_span "$repair_log" fix-repair pr="$n" round="$next_round" attempt="$fixer_repair_attempt" \
    model="$FIXER_MODEL" outcome="$repair_cls" template="pr-fixer-repair-v1" prompt="$repair_prompt"

  # Transient model failure → defer, don't consume an attempt, don't dead-end.
  if [ "$repair_cls" = "transient" ]; then
    log "PR #${n}: self-repair hit transient limit — deferring; retry next tick (attempt NOT consumed)"
    add_label "$n" changes-requested; remove_label "$n" fix-wip
    exit 0
  fi

  # Commit what the model changed.
  git add -A
  git reset -q -- node_modules frontend/node_modules mobile/node_modules 'packages/*/node_modules' \
    .env .env.local .gcp \
    backend/.env backend/.env.local frontend/.env frontend/.env.local 2>/dev/null || true
  # Same as the first pass: a self-repair model that commits its own work leaves a clean tree,
  # which must NOT be read as "it changed nothing" (that would re-gate the identical tree and
  # burn every remaining attempt).
  if git diff --cached --quiet; then
    if [ "$(git rev-parse HEAD 2>/dev/null || true)" != "$repair_head_before" ]; then
      log "PR #${n}: self-repair committed in-worktree (attempt ${fixer_repair_attempt}) — re-gating its commit(s)"
      git tag -f "fixer/pr-${n}-round-${next_round}" HEAD >/dev/null 2>&1 || true
    else
      log "PR #${n}: self-repair produced no code changes (attempt ${fixer_repair_attempt})"
      continue
    fi
  else
    git commit -q -m "fix(pr #${n}): self-repair gate failure (round ${next_round}, attempt ${fixer_repair_attempt})

Co-Authored-By: Claude <noreply@anthropic.com>"
    git tag -f "fixer/pr-${n}-round-${next_round}" HEAD >/dev/null 2>&1 || true
  fi

  # Re-provision env files stripped by git reset so the next gate run can use them.
  shopt -s nullglob
  for src in "$ROOT"/.env "$ROOT"/.env.local "$ROOT"/.gcp "$ROOT"/backend/.env "$ROOT"/backend/.env.local "$ROOT"/frontend/.env "$ROOT"/frontend/.env.local; do
    [ -e "$src" ] || continue
    rel="${src#"$ROOT"/}"; dst="$wt/$rel"
    [ -e "$dst" ] || { mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" 2>/dev/null; } || true
  done
  shopt -u nullglob
  # loop back to re-run gates
done
