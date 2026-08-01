#!/usr/bin/env bash
# agent-inbox.sh — the unattended "requirement inbox → build → PR" runner.
#
# Phone-friendly loop: you file a GitHub issue labelled `agent` from the GitHub
# mobile app; a systemd user timer calls this every couple of minutes; it picks
# ONE pending issue, builds it headlessly via `claude -p` (which invokes the project
# orchestrators — `iterate` for a change, `build-product-v2` for a new product), runs
# the project quality gates, and — only if green — pushes a branch + opens a PR +
# comments the link back on the issue. Never pushes to main.
#
# ISOLATION (important): the build runs in a DEDICATED git WORKTREE off origin/main,
# never in your primary working copy. So it can never switch your branch or sweep your
# uncommitted WIP — you can keep developing in the repo while a build runs.
#
# Single-pass by design (the timer re-invokes it); one requirement per run; a flock
# guarantees a single instance. Every external command + path is overridable via env
# so the journey is testable hermetically (scripts/agent-inbox.test.sh) with NO real
# GitHub side-effects and NO LLM cost.
#
#   Labels used: `agent` (inbox), `wip` (claimed), `done` (PR opened), `needs-human`.
#   Setup: scripts/agent-inbox-setup.sh  ·  Docs: docs/26-agent-inbox.md
set -uo pipefail

# ── Injectable dependencies (defaults = production; tests override) ──────────────
ROOT="${AGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GH="${AGENT_GH:-gh}"                       # GitHub CLI (stubbed in tests)
CLAUDE="${AGENT_CLAUDE:-claude}"           # Claude Code CLI (stubbed in tests)
BASE="${AGENT_BASE:-main}"                 # base branch for PRs
REMOTE="${AGENT_REMOTE:-origin}"           # git remote
LABEL="${AGENT_LABEL:-agent}"             # inbox label
MODEL="${AGENT_MODEL:-opus}"               # claude model alias
GATES_CMD="${AGENT_GATES_CMD:-scripts/quality-gates.sh --only unit --tier launch}"  # safety net (unit only; e2e runs at merge time)
PUSH_RETRIES="${AGENT_PUSH_RETRIES:-3}"    # `git push` attempts before handing back (transient blips)
PUSH_RETRY_DELAY="${AGENT_PUSH_RETRY_DELAY:-5}"  # base backoff seconds between push attempts (×attempt)
# Libs live NEXT TO this script, so resolve them from BASH_SOURCE — never from $ROOT.
# $ROOT is overridable (AGENT_ROOT/PR_ROOT/SCOUT_ROOT) and every hermetic suite points it at a
# sandbox clone with no scripts/lib, so a $ROOT-relative source silently fails there: without
# `set -e` the script sails on with classify_model_result AND agent_trace_span undefined, and
# the span the gate believes it is checking is never emitted (#2390).
# shellcheck source=scripts/lib/agent-model-call.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/agent-model-call.sh"
# shellcheck source=lib/pr-lock.sh
source "$ROOT/scripts/lib/pr-lock.sh"
if ! declare -F issue_lock_first_free >/dev/null 2>&1; then
  echo "FATAL: scripts/lib/pr-lock.sh did not load from ROOT='$ROOT' — refusing to claim blind" >&2
  exit 2
fi
# ── Per-repo namespace — so two inboxes in DIFFERENT repos never collide on a global /tmp
# lock (or clobber each other's logs/worktrees). The git common dir is stable across a repo's
# own worktrees yet unique per repo; resolve it to an ABSOLUTE path because `--git-common-dir`
# returns a bare ".git" at a repo root (every repo would hash identically otherwise). Two
# inboxes of the SAME repo still share the key → still serialize. All paths stay overridable.
agent_repo_ns() {
  local d
  d="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  d="$(cd "$ROOT" 2>/dev/null && cd "$d" 2>/dev/null && pwd)" || return 1
  printf '%s' "$d" | sha1sum | cut -c1-12
}
NS="$(agent_repo_ns || true)"; [ -n "$NS" ] || NS="nogit"
LOCK="${AGENT_LOCK:-/tmp/agent-inbox-$NS.lock}"
LOGDIR="${AGENT_LOGDIR:-/tmp/agent-inbox-$NS}"
WORKTREE_BASE="${AGENT_WORKTREE_BASE:-/tmp/agent-inbox-$NS/worktrees}"   # isolated build dirs

cd "$ROOT" || { echo "[agent-inbox] cannot cd to $ROOT" >&2; exit 2; }
mkdir -p "$LOGDIR" "$WORKTREE_BASE"
log() { printf '[agent-inbox] %s\n' "$*"; }

# Add a label via the REST issues/labels endpoint. `gh pr edit --add-label` hits the
# deprecated classic-Projects `projectCards` GraphQL field and flakily errors, silently
# dropping the label (the bug that left PRs un-enrolled from the review loop, docs/35).
# REST avoids it. Non-fatal but LOGGED (no silent failure). `{owner}/{repo}` auto-resolve.
add_label() { # <issue-or-pr-number> <label>
  "$GH" api -X POST "repos/{owner}/{repo}/issues/$1/labels" -f "labels[]=$2" >/dev/null 2>&1 \
    || log "WARN: could not add label '$2' to #$1"
}

# ── Toolchain bootstrap — systemd/cron start from a BARE environment (no ~/.bashrc,
# no nvm/conda init), so tools placed on PATH by shell init (node/npx via nvm, conda
# tools, …) are MISSING and the gates die "command not found". Source the tool managers
# here so the build env matches an interactive shell, however this script is launched. ─
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
[ -s "$HOME/miniconda3/etc/profile.d/conda.sh" ] && . "$HOME/miniconda3/etc/profile.d/conda.sh" >/dev/null 2>&1 || true
# pnpm (app-shell uses it) lives in PNPM_HOME, exported only by ~/.bashrc — add it too.
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) [ -d "$PNPM_HOME" ] && PATH="$PNPM_HOME:$PATH";; esac

# ── Preflight — fail LOUD + early on a missing/unhealthy dependency. A clear message
# beats a cryptic gate failure 3 layers down (the npx-not-found / wrong-tsc traps). ─
PREFLIGHT_TOOLS="${AGENT_PREFLIGHT_TOOLS:-git jq node npx python}"
missing=""
for t in $PREFLIGHT_TOOLS "$GH" "$CLAUDE"; do
  command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
done
if [ -n "$missing" ]; then
  log "PREFLIGHT FAILED — not on PATH:${missing}"
  log "  systemd/cron use a bare env; ensure nvm/conda/pnpm init is sourced (see docs/26 §PATH)."
  exit 1
fi
# Docker's CLI being on PATH ≠ the daemon being reachable — the e2e gate needs the daemon.
case " $PREFLIGHT_TOOLS " in *" docker "*)
  if ! docker info >/dev/null 2>&1; then
    log "PREFLIGHT FAILED — docker CLI present but the daemon is unreachable"
    log "  start Docker Desktop / check the socket (the e2e gate boots the stack)."
    exit 1
  fi ;;
esac

# ── Single-instance lock — never run two builds against the same repo/stack ─────
log "single-instance lock: $LOCK"
exec 9>"$LOCK"
if ! flock -n 9; then log "another run in progress — exiting"; exit 0; fi

# ── Find pending work: open `agent` issues not already claimed/finished ──────────
issues_json="$("$GH" issue list --label "$LABEL" --state open \
  --json number,title,body,labels,createdAt --limit 20 2>/dev/null || echo '[]')"
[ -z "$issues_json" ] && issues_json='[]'
# Sort by creation date ascending (earliest first) so that issues which are
# likely dependent on earlier issues are picked up in the right order.
issues_json="$(jq 'sort_by(.createdAt)' <<<"$issues_json")"

# ── Auto-unblock: an issue the triage marked `blocked` re-queues itself once the blocker
# it was waiting on closes. This is what makes the loop "continue" after a self-filed infra/
# test fix lands — without it, blocked issues would sit forever. Best-effort + cheap: only
# blocked issues are inspected; each names its blocker in a "blocked by #N" comment. ─
reconcile_blocked() {
  local blocked nums b blocker st
  blocked="$(jq -r 'map(select([.labels[]?.name] | index("blocked"))) | .[].number' <<<"$issues_json" 2>/dev/null)"
  [ -n "$blocked" ] || return 0
  for b in $blocked; do
    # newest "blocked by #N" wins (an issue can be re-blocked behind a different blocker).
    blocker="$("$GH" issue view "$b" --json comments \
      --jq '[.comments[].body | capture("blocked by #(?<n>[0-9]+)"; "g").n] | last // empty' 2>/dev/null)"
    [ -n "$blocker" ] || continue
    st="$("$GH" issue view "$blocker" --json state --jq '.state' 2>/dev/null)"
    if [ "$st" = "CLOSED" ]; then
      log "unblocking #${b}: blocker #${blocker} is closed"
      "$GH" api -X DELETE "repos/{owner}/{repo}/issues/${b}/labels/blocked" >/dev/null 2>&1 || true
      "$GH" issue comment "$b" -b "🔓 agent-inbox: unblocked — #${blocker} closed; re-queued for a fresh build." >/dev/null 2>&1 || true
    fi
  done
  # refresh the snapshot so a just-unblocked issue is eligible THIS tick
  issues_json="$("$GH" issue list --label "$LABEL" --state open \
    --json number,title,body,labels --limit 20 2>/dev/null || echo "$issues_json")"
}
[ "${AGENT_RECONCILE:-1}" = 1 ] && reconcile_blocked

# Pick the SLOT-th eligible issue, not always the first. With one inbox (AGENT_SLOT=0, the
# default) this is exactly the old `.[0]`. With N inboxes running concurrently it is what stops
# two of them claiming the same issue: `wip` is added AFTER this read, so two inboxes reading the
# same snapshot would both select `.[0]`, both label it, and both build it — duplicated spend and
# two branches racing for one issue. Indexing by slot makes the claim collision-free by
# construction, with no atomic-label primitive to invent (GitHub has none).
# ── Claim an issue: WORK-STEALING over a per-issue lock ───────────────────────────
# AGENT_SLOT used to select the slot-th eligible issue outright. That is collision-free but
# STARVES a short queue: with a single eligible issue only lane 0 could ever claim it, so while
# lane 0 was busy draining a PR (Phase 1 refuses to build with a drivable PR in hand) the work sat
# untouched and the other lanes idled. Observed 2026-07-25 — #2132 was the only claimable issue and
# went unbuilt for hours with three lanes running.
#
# Now AGENT_SLOT is only a STARTING OFFSET. The candidate list is rotated so lane k prefers the
# k-th issue (keeping lanes off each other's toes when the queue is deep), but any lane may steal
# any issue nobody holds — so one eligible issue is claimable by whichever lane is free first.
#
# The lock is what makes `wip` verifiable. The label is written after this read and OUTLIVES the
# process, so a build killed by a timeout/suspend/OOM leaves `wip` set with nobody working and the
# issue excluded from every lane forever (#2086). The flock exists only while a live process holds
# the fd, so "labelled wip but unlocked" becomes a decidable, reapable state — see
# reap_stale_claims() in agent-pipeline.sh. Held for the whole run: it releases on exit, crash
# included.
AGENT_SLOT="${AGENT_SLOT:-0}"
_elig_json="$(jq -c 'map(select(
  ([.labels[]?.name] | index("wip")         | not) and
  ([.labels[]?.name] | index("done")        | not) and
  ([.labels[]?.name] | index("needs-human") | not) and
  ([.labels[]?.name] | index("blocked")     | not)
))' <<<"$issues_json")"
mapfile -t _all_nums < <(jq -r '.[].number' <<<"$_elig_json" 2>/dev/null)
_elig_nums=()
if [ "${#_all_nums[@]}" -gt 0 ]; then
  _off=$(( AGENT_SLOT % ${#_all_nums[@]} ))
  for (( _j = 0; _j < ${#_all_nums[@]}; _j++ )); do
    _elig_nums+=( "${_all_nums[$(( (_j + _off) % ${#_all_nums[@]} ))]}" )
  done
fi

eligible=""; ISSUE_LOCK_FD=""
if [ "${#_elig_nums[@]}" -gt 0 ]; then
  if issue_lock_first_free _claimed_issue ISSUE_LOCK_FD "${_elig_nums[@]}"; then
    eligible="$(jq -c --argjson n "$_claimed_issue" 'map(select(.number == $n)) | .[0] // empty' <<<"$_elig_json")"
  else
    log "all ${#_elig_nums[@]} eligible issue(s) (${_elig_nums[*]}) are being built by another lane"
  fi
fi

if [ -z "$eligible" ]; then log "no pending requirements"; exit 0; fi

n="$(jq -r '.number' <<<"$eligible")"
title="$(jq -r '.title' <<<"$eligible")"
body="$(jq -r '.body // ""' <<<"$eligible")"

# ── Epic / tracking-issue guard ──────────────────────────────────────────────────
# An epic is a checklist of child tickets, not a single buildable requirement. Handed
# one, a less-capable driver flails — issue #1077 saw it inject a logic-inverting bug into
# error_classification.py and rewrite unrelated harness files rather than no-op. Detect the
# repo's epic convention (an `[Epic]` title, an "epic / tracking issue" body, or the explicit
# "intentionally not labeled `agent`" marker) and de-queue: drop `${LABEL}` so it is not
# re-picked, and point at the child tickets. Conservative on purpose (specific markers only,
# so a normal ticket is never caught). Disable with AGENT_EPIC_GUARD=0. ─
if [ "${AGENT_EPIC_GUARD:-1}" = 1 ] && {
     grep -qiE '^[[:space:]]*\[epic\]' <<<"$title" ||
     grep -qiE 'epic[[:space:]]*/[[:space:]]*tracking|tracking issue' <<<"$title"$'\n'"$body" ||
     grep -qiE 'intentionally [^[:space:]]*not[^[:space:]]* labeled' <<<"$body"; }; then
  log "issue #${n}: epic/tracking issue — de-queuing (not a buildable ticket)"
  "$GH" issue comment "$n" -b "🛑 agent-inbox: this looks like an **epic / tracking issue**, not a single buildable ticket, so I won't auto-build it (removing \`${LABEL}\`). Dispatch the individual child tickets by adding \`${LABEL}\` to *those* instead." >/dev/null 2>&1 || true
  "$GH" api -X DELETE "repos/{owner}/{repo}/issues/${n}/labels/${LABEL}" >/dev/null 2>&1 || true
  exit 0
fi

branch="agent/issue-${n}"
wt="${WORKTREE_BASE}/issue-${n}"
log "claiming issue #${n}: ${title} → ${branch} (isolated worktree)"

"$GH" issue edit "$n" --add-label wip >/dev/null 2>&1 || true
"$GH" issue comment "$n" -b "🤖 agent-inbox: starting on \`${branch}\` (isolated worktree)…" >/dev/null 2>&1 || true

# ── Isolated worktree off the latest base — NEVER touches the primary working copy ─
git fetch -q "$REMOTE" "$BASE" >/dev/null 2>&1 || true
base_ref="${REMOTE}/${BASE}"
git rev-parse --verify -q "$base_ref" >/dev/null || base_ref="$BASE"

# ── Resume a prior attempt instead of discarding it ───────────────────────────────
# A build killed mid-flight (systemd TimeoutStartSec, host suspend, OOM) used to lose everything:
# the worktree is removed by the EXIT trap and the retry reset the branch to origin/main with `-B`,
# so the model started from scratch and its earlier work was silently gone. Since the branch is now
# pushed as soon as a commit exists (see the early push below), a prior attempt's work is on the
# remote and can be built ON TOP OF.
#
# Three guards on resuming:
#  • The remote branch must NOT already be merged into $BASE. A closed-and-reopened issue can leave
#    a merged branch behind; resuming from it would re-apply work that is already in main.
#  • The resumed branch must CONTAIN $BASE, else it is rebased onto it (see below). Resuming is a
#    promise to keep the prior attempt's work, not to keep the tree it was written against.
#  • AGENT_RESUME=0 forces a clean start — the escape hatch when a branch is poisoned and the model
#    keeps building on a broken base.
# It cannot loop forever: the triage's self-repair cap (TRIAGE_MAX_SELF_REPAIR) sends the issue to
# needs-human after a bounded number of failed attempts, resumed or not.
resume_ref=""
if [ "${AGENT_RESUME:-1}" = 1 ]; then
  git fetch -q "$REMOTE" "$branch" >/dev/null 2>&1 || true
  if git rev-parse --verify -q "${REMOTE}/${branch}" >/dev/null 2>&1; then
    if git merge-base --is-ancestor "${REMOTE}/${branch}" "$base_ref" >/dev/null 2>&1; then
      log "issue #${n}: ${REMOTE}/${branch} is already merged into ${BASE} — starting clean"
    else
      resume_ref="${REMOTE}/${branch}"
      log "issue #${n}: RESUMING from ${resume_ref} — a prior attempt's work survived"
    fi
  fi
fi
start_ref="${resume_ref:-$base_ref}"

# Remove any stale worktree from a prior attempt, then create one at the start ref.
git worktree remove --force "$wt" >/dev/null 2>&1 || true
rm -rf "$wt" >/dev/null 2>&1 || true
if ! git worktree add -f -B "$branch" "$wt" "$start_ref" >/dev/null 2>&1; then
  log "issue #${n}: could not create worktree"
  "$GH" issue comment "$n" -b "⚠️ agent-inbox: could not create an isolated build worktree — needs a human." >/dev/null 2>&1 || true
  "$GH" issue edit "$n" --add-label needs-human --remove-label wip >/dev/null 2>&1 || true
  exit 0
fi
# Always clean the worktree up at the end (the branch ref persists for the PR / inspection).
cleanup() { cd "$ROOT" 2>/dev/null || true; git worktree remove --force "$wt" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Guarded (issue #2387): an unguarded `cd "$wt"` that fails leaves the process in the
# PRIMARY checkout and every subsequent build/gate/git command below runs against it
# instead of the isolated worktree — the exact "runs in the wrong directory" failure
# SC2164 warns about, in the one place it would do the most damage.
cd "$wt" || { log "FATAL: cannot enter worktree $wt — aborting build"; exit 2; }   # ── all build work happens HERE, in isolation ──

# ── A resumed branch must contain the CURRENT base ────────────────────────────────
# The resume guard above asks only "is this branch already IN ${BASE}?". It never asked the
# converse — "is ${BASE} already in this branch?" — so `base_ref` was fetched and then thrown
# away, and a branch cut hours ago was rebuilt against the tree it was cut from. Everything
# that landed on ${BASE} since stayed invisible, INCLUDING the fixes for the very blockers the
# issue had been waiting on: #2138 resumed a branch cut before the #2212 landing-guard fix,
# so its gates re-failed on 25 tests that were already green on ${BASE}, and triage filed a
# fresh blocker (#2217) for them. Fixing ${BASE} can never break that loop — the build never
# sees ${BASE}. Rebase the resumed work onto the live base before anything reads the tree.
#
# Not every conflict is a disagreement about the CHANGE. `docs/06-iteration-log*.md` are
# generated from `docs/iterations/*` and `state/*.json` is shared harness bookkeeping — two
# branches that each add an iteration collide there by construction, every time, while their
# actual product diffs are disjoint. Discarding an attempt over those is pure loss: rebasing
# #2138 conflicted in exactly those four files and nothing else, and the blunt fallback would
# have thrown away 1,703 lines of finished, passing code to avoid them. So resolve a conflict
# confined to generated paths by taking the base's copy and regenerating afterwards, and keep
# the discard for what it was meant for — a genuine product-file conflict.
GENERATED_CONFLICT_PATHS="${AGENT_GENERATED_PATHS:-docs/06-iteration-log.md docs/06-iteration-log.digest.md state/state.json state/iter-gates.json}"
is_generated_path() { # <repo-relative path>
  local g
  for g in $GENERATED_CONFLICT_PATHS; do [ "$1" = "$g" ] && return 0; done
  return 1
}
rebase_in_progress() {
  [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] ||
  [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]
}
# Carry an in-progress rebase through conflicts that are ALL in generated paths. Returns
# non-zero the moment a product file conflicts, leaving the rebase in progress for the caller
# to abort — so the discard path is still reached for real disagreements.
rebase_resolving_generated() {
  local rounds=0 unmerged p
  rebase_in_progress || return 1
  while :; do
    unmerged="$(git diff --name-only --diff-filter=U 2>/dev/null)"
    [ -n "$unmerged" ] || break
    rounds=$((rounds+1)); [ "$rounds" -gt 30 ] && return 1   # backstop: never spin
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      is_generated_path "$p" || { log "issue #${n}: rebase conflict in a product file (${p})"; return 1; }
      # During a rebase `--ours` is the BASE side, which is the copy to keep: it already
      # reflects everything that landed on ${BASE}, and regeneration re-adds this branch's rows.
      git checkout --ours -- "$p" >/dev/null 2>&1 || git checkout "$base_ref" -- "$p" >/dev/null 2>&1 || return 1
      git add -- "$p" >/dev/null 2>&1 || return 1
    done <<<"$unmerged"
    # A commit whose ONLY content was the generated files is empty once they resolve to base's
    # copy; `--continue` refuses it, and `--skip` is the correct disposition, not a failure.
    GIT_EDITOR=true git -c rebase.autoStash=false rebase --continue >>"${LOGDIR}/rebase-${n}.log" 2>&1 \
      || git rebase --skip >>"${LOGDIR}/rebase-${n}.log" 2>&1 \
      || return 1
    rebase_in_progress || break
  done
  ! rebase_in_progress
}
# Re-derive the generated files from the rebased tree and record the result. Both are built
# from `docs/iterations/*`, so running them after the rebase re-adds this branch's rows to the
# base's copy — which is why taking `--ours` above loses nothing.
regenerate_generated_files() {
  [ -x scripts/generate-iteration-index.sh ] && ./scripts/generate-iteration-index.sh >/dev/null 2>&1
  [ -x scripts/iteration-digest.sh ] && ./scripts/iteration-digest.sh >/dev/null 2>&1
  git add -- docs/06-iteration-log.md docs/06-iteration-log.digest.md >/dev/null 2>&1 || true
  git diff --cached --quiet || git commit -q -m "chore: regenerate the iteration index after rebasing onto ${BASE}"
  return 0
}
push_force=""   # set when this rewrites the resumed branch's history (see the push below)
if [ -n "$resume_ref" ] && ! git merge-base --is-ancestor "$base_ref" HEAD >/dev/null 2>&1; then
  behind="$(git rev-list --count "HEAD..${base_ref}" 2>/dev/null || echo '?')"
  log "issue #${n}: resumed branch is ${behind} commit(s) behind ${base_ref} — rebasing onto it"
  if git -c rebase.autoStash=false rebase "$base_ref" >>"${LOGDIR}/rebase-${n}.log" 2>&1 \
     || rebase_resolving_generated; then
    push_force="--force-with-lease"
    regenerate_generated_files
    log "issue #${n}: rebased the resumed work onto ${base_ref}"
  else
    # A conflict in a PRODUCT file means the prior attempt and ${BASE} genuinely disagree about
    # the change. Resuming would be worse than starting over: the gates would judge the change
    # against a tree that no longer exists. Discard and start clean — AGENT_RESUME trades
    # work-preservation for correctness only while the base is current.
    git rebase --abort >/dev/null 2>&1 || true
    git reset --hard "$base_ref" >/dev/null 2>&1 || true
    git clean -fd >/dev/null 2>&1 || true
    push_force="--force-with-lease"
    log "issue #${n}: rebase onto ${base_ref} CONFLICTED in a product file — discarded the prior attempt, starting clean"
    "$GH" issue comment "$n" -b "♻️ agent-inbox: the prior attempt's branch was ${behind} commit(s) behind \`${BASE}\` and could not be rebased onto it cleanly, so it was discarded and this build starts from a fresh \`${BASE}\`. Building on a stale base makes the gates re-fail on code that is already fixed on \`${BASE}\`." >/dev/null 2>&1 || true
  fi
fi

# ── Provision dependencies — a fresh worktree has NO node_modules (git ignores them),
# so the gates' `npx tsc`/lint/unit would fail / fetch the WRONG `tsc`.
#   AGENT_DEPS=install (default): a fresh per-service install IN the worktree — immune
#     to host node_modules drift (the corruption class that broke earlier builds), fast
#     with a warm pnpm/npm cache, and correctly handles requirements that ADD a dep.
#   AGENT_DEPS=symlink: reuse the host's node_modules (instant, but only as healthy as
#     the host install). ─
# SkillForge is an npm workspaces monorepo: `package-lock.json` and `node_modules` live
# at the ROOT, not inside individual workspaces (frontend/, packages/*). Running npm ci
# from a workspace subdirectory misses the root lockfile and fails to install hoisted
# deps — notably @vitejs/plugin-react (#1863). Always run npm ci from $wt (root).
# Backend (Python): mypy/pytest run from the worktree's backend/ and import the local
# `app` (pytest prepends backend/ to sys.path); third-party deps come from the active
# conda/venv on PATH, so no per-worktree pip install is needed.
deps_mode="${AGENT_DEPS:-install}"
fe="$ROOT/frontend"; wtfe="$wt/frontend"
# Guard: only provision if the project has a frontend workspace
if [ -f "$fe/package.json" ] && [ -d "$wtfe" ]; then
  if [ "$deps_mode" = "symlink" ]; then
    # npm workspaces hoist deps to root node_modules — symlink at root, not per-workspace
    [ -d "$ROOT/node_modules" ] && [ ! -e "$wt/node_modules" ] && ln -s "$ROOT/node_modules" "$wt/node_modules" 2>/dev/null || true
  elif [ -f "$wt/package-lock.json" ]; then
    ( cd "$wt" && npm ci --no-audit --no-fund --silent ) >>"${LOGDIR}/deps-${n}.log" 2>&1 || log "deps: npm ci failed (see deps-${n}.log)"
  else
    ( cd "$wt" && npm install --no-audit --no-fund --silent ) >>"${LOGDIR}/deps-${n}.log" 2>&1 || log "deps: npm install failed (see deps-${n}.log)"
  fi
fi

# ── Verify the provisioning actually LANDED (#2124) ───────────────────────────────
# `npm ci` can exit 0 and still leave a workspace unresolvable. On 2026-07-25 the `mobile`
# workspace came up without `expo`, so `mobile/tsconfig.json`'s `extends: expo/tsconfig.base`
# failed to resolve, ALL 138 mobile test files died at transform time, the `unit` gate went red
# — and the triage read that as a code failure, burning the whole auto-fix budget on a test
# that passes 15/15 on main. Nothing in deps-N.log hinted at it (npm ci had exited 0).
# Generic and dependency-free: any workspace tsconfig that `extends` a BARE package specifier
# must have that package installed somewhere up its tree. Repair once; if it still fails, hand
# the tick back instead of spending a full model build on a tree that cannot compile.
#
# The check itself lives in lib/deps-verify.sh (#2438): agent-pr-merger.sh and agent-pr-fixer.sh
# provision the same way and were still trusting `npm ci`'s exit code, so the same broken tree
# came back as "main is red" and wedged the merge queue. One implementation, three callers.
# shellcheck source=scripts/lib/deps-verify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deps-verify.sh"
unresolved_workspace_deps() { deps_unresolved "$wt"; }
join_deps() { deps_join; }
# Bounded across ticks, and NOT counted from issue comments — comment-counting would force a
# comment every tick just to keep score. The counter lives beside the other per-issue logs, so
# a tree that can never be provisioned escalates instead of re-queuing forever at the head of
# the eligibility list (`.[0]` of the label query), which would starve every other issue.
DEPS_MAX_RETRY="${AGENT_DEPS_MAX_RETRY:-3}"
deps_retry_file="${LOGDIR}/deps-retry-${n}.count"
deps_retries() { local c; c="$(cat "$deps_retry_file" 2>/dev/null || true)"; [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo 0; }

# Skipped entirely under AGENT_DEPS=symlink. That mode POINTS $wt/node_modules at the host's
# install, so (a) a workspace-local node_modules (mobile/ is not hoisted) is legitimately absent
# from the worktree and this check would false-positive on every tick against a perfectly healthy
# host, and (b) `npm install` inside $wt writes THROUGH the symlink into the host's shared
# node_modules — the corruption class the mode comment above exists to warn about. In symlink
# mode the host install's health is the host's problem by construction.
if [ "$deps_mode" = "symlink" ]; then
  missing_deps=""
else
  missing_deps="$(unresolved_workspace_deps | join_deps)"
fi
if [ -n "$missing_deps" ]; then
  # No `;` in the surrounding prose — the list itself is `; `-joined, and a stray one would make
  # the line ambiguous to read (and to assert on).
  log "deps: incomplete install (repairing) — unresolved: ${missing_deps}"
  printf 'deps: unresolved after provisioning: %s\ndeps: repairing with npm install…\n' \
    "$missing_deps" >>"${LOGDIR}/deps-${n}.log"
  ( cd "$wt" && npm install --no-audit --no-fund ) >>"${LOGDIR}/deps-${n}.log" 2>&1 \
    || log "deps: repair npm install failed (see deps-${n}.log)"
  missing_deps="$(unresolved_workspace_deps | join_deps)"
fi
if [ -n "$missing_deps" ]; then
  attempt="$(( $(deps_retries) + 1 ))"
  printf '%s' "$attempt" > "$deps_retry_file" 2>/dev/null || true
  printf 'deps: STILL unresolved after repair (attempt %s/%s): %s\n' \
    "$attempt" "$DEPS_MAX_RETRY" "$missing_deps" >>"${LOGDIR}/deps-${n}.log"
  if [ "$attempt" -ge "$DEPS_MAX_RETRY" ]; then
    log "issue #${n}: dependency provisioning FAILED ${attempt}× (${missing_deps}) — needs a human"
    "$GH" issue comment "$n" -b "$(printf '❌ agent-inbox: dependency provisioning failed %s times in a row — `%s` cannot be resolved in the build worktree even after an `npm install` repair. No build was attempted on any attempt. This is not a defect in this issue: either the package is genuinely missing from the manifest, the registry is unreachable, or the host install is broken. Needs a human.' "$attempt" "$missing_deps")" >/dev/null 2>&1 || true
    "$GH" issue edit "$n" --add-label needs-human --remove-label wip >/dev/null 2>&1 || true
    exit 0
  fi
  log "issue #${n}: dependency provisioning FAILED (${missing_deps}) — retry ${attempt}/${DEPS_MAX_RETRY} next tick"
  # Comment ONCE. Subsequent ticks are silent until the escalation above, so a bricked host
  # cannot bury the issue under one comment per minute.
  if [ "$attempt" -eq 1 ]; then
    "$GH" issue comment "$n" -b "$(printf '⏳ agent-inbox: dependency provisioning failed in the build worktree — `%s` unresolved even after an `npm install` repair. No build was attempted: a missing workspace dependency fails every test in that workspace at load time, which reads as a code failure and wastes the auto-fix budget (#2124). Retrying on the next tick (up to %s attempts, then a human).' "$missing_deps" "$DEPS_MAX_RETRY")" >/dev/null 2>&1 || true
  fi
  "$GH" issue edit "$n" --add-label agent --remove-label wip >/dev/null 2>&1 || true
  exit 0
fi
# Provisioning is healthy — clear any prior brick counter so an old streak can't escalate later.
rm -f "$deps_retry_file" 2>/dev/null || true

# Discard install-induced lockfile churn so it never lands in the PR. node_modules is
# already installed; if the agent genuinely adds a dependency it re-modifies the lockfile
# LATER (during the build below) — a real change that SHOULD be in the PR — so we only
# drop the spurious provisioning diff here. In npm workspaces the lockfile is at root.
[ -f package-lock.json ] && git checkout -q -- package-lock.json 2>/dev/null || true

# ── Self-repair feedback: if a PRIOR build of this issue failed its gate, the triage left a
# `<!-- self-repair -->` comment with the failure log and re-queued it. Feed that log back into
# the prompt so this attempt fixes the ROOT CAUSE instead of repeating the same failure. ─
retry_context=""
prior_fail="$("$GH" issue view "$n" --json comments \
  --jq '[.comments[] | select(.body | contains("<!-- self-repair -->"))] | last.body // empty' 2>/dev/null || true)"
if [ -n "$prior_fail" ]; then
  log "issue #${n}: re-building WITH prior gate-failure context (self-repair)"
  retry_context="$(cat <<EOF

## ⚠ A PREVIOUS BUILD OF THIS ISSUE FAILED THE QUALITY GATE
Do NOT just repeat your previous diff. Read the failure below and fix the ROOT CAUSE. The
failing test is often CORRECT and exposing a PRE-EXISTING bug in code you did not write — fix
THAT (the real defect), not only your own change. Prior attempt's failure:

${prior_fail}
EOF
)"
fi

# ── Drive the build headlessly (the orchestrators do the real work) ─────────────
prompt="$(cat <<EOF
You are the SkillForge build agent, running UNATTENDED in an isolated git worktree on
branch '${branch}'. SkillForge is an existing, deployed product (Python/FastAPI backend +
Vite/React frontend), so implement the requirement below by invoking the \`iterate\` skill
(the cold-start refinement loop for an existing product). Work ONLY in this worktree on
this branch — do NOT push, and never touch '${BASE}'. Add or update tests (backend pytest
under backend/tests, frontend vitest, Playwright e2e) for what you build. When finished, stop.

REQUIREMENT (issue #${n}): ${title}

${body}
${retry_context}
EOF
)"
log "invoking agent (model ${MODEL}) in ${wt}…"
# AGENT_CLAUDE_ARGS = extra flags for cost/time control, e.g. "--max-turns 40" (verify
# against `claude --help`). Empty by default; word-split intentionally.
read -ra CLAUDE_EXTRA <<<"${AGENT_CLAUDE_ARGS:-}"
"$CLAUDE" -p "$prompt" \
  --permission-mode bypassPermissions \
  --model "$MODEL" \
  --output-format json \
  "${CLAUDE_EXTRA[@]}" \
  >"${LOGDIR}/agent-${n}.json" 2>"${LOGDIR}/agent-${n}.stderr" || true

# CLAUDE.md: every `claude` invocation emits a span (#2390). Classified once and reused, so the
# span's outcome and the routing decision below can never disagree. `result=` is deliberately NOT
# passed here: per agent-trace.sh it's the round's terminal disposition (pushed|no-change|stuck|
# transient), a different axis from `outcome` (ok|transient|hard) — this build hasn't reached a
# terminal disposition yet at this point in the script, so stamping outcome into result would make
# `.result` mean two different things across stages. Proper disposition wiring is deferred.
inbox_cls="$(classify_model_result "${LOGDIR}/agent-${n}.json")"
agent_trace_span "${LOGDIR}/agent-${n}.json" inbox-build issue="$n" model="$MODEL" \
  outcome="$inbox_cls" template="inbox-build-v1" prompt="$prompt"

if [ "$inbox_cls" = "transient" ]; then
  log "issue #${n}: model call transient — resetting label; retry next tick"
  "$GH" issue edit "$n" --add-label agent --remove-label wip >/dev/null 2>&1 || true
  exit 0
fi
# ok or hard: falls through to existing build flow (commit, gates, push, PR)

# Commit anything the agent left uncommitted (worktree only — your main copy is untouched).
# Unstage the provisioned symlinks first so they NEVER land in the PR: git's
# `node_modules/` ignore (directory-only) does not match a *symlink* named node_modules,
# so a bare `git add -A` would track them. (.env/.gcp are provisioned after this, below.)
git add -A
git reset -q -- frontend/node_modules .env .env.local .gcp \
  backend/.env backend/.env.local frontend/.env frontend/.env.local 2>/dev/null || true
git diff --cached --quiet || git commit -q -m "agent: issue #${n} — ${title}"

# ── No-op guard: if the agent produced nothing, hand back to a human ────────────
# Measured from start_ref, not base_ref: on a resume the branch already carries the earlier
# attempt's commits, so comparing against main alone would call a do-nothing round "progress".
#
# But "this round added no commits" is TWO opposite states, and the round count cannot tell them
# apart. Either the model did nothing useful — a human is the right answer — or it found the work
# ALREADY COMPLETE on the resumed branch and correctly declined to duplicate it, which needs a PR,
# not a human. #2138 was the second: 1,703 lines of finished, passing product code sat on its
# branch across three rounds while every round escalated it as a failure, and it never once
# reached `pr create`. So ask the second question too — does the BRANCH carry work? — and let a
# do-nothing round through to the gates when it does. The gates are what decide if it ships;
# they are a far better judge of a finished branch than the commit count of the last round.
if [ -z "$(git rev-list "${start_ref}..HEAD" 2>/dev/null)" ]; then
  # Compared as TREES, not as a commit count: an earlier round can leave commits that carry no
  # content (an empty commit, or one whose changes ${BASE} has since absorbed), and those are
  # not work. "Does this branch differ from ${BASE}?" is the question worth asking.
  if ! git diff --quiet "$base_ref" HEAD 2>/dev/null; then
    log "issue #${n}: this round added nothing, but the branch carries unshipped work vs ${BASE} — gating it"
    "$GH" issue comment "$n" -b "ℹ️ agent-inbox: this round produced no new commits — the work was already complete on \`${branch}\` from an earlier attempt. Gating the branch as it stands rather than escalating; if the gates pass this opens the PR that earlier rounds never reached." >/dev/null 2>&1 || true
  else
    log "issue #${n}: agent produced no changes"
    "$GH" issue comment "$n" -b "⚠️ agent-inbox: the agent produced no changes — needs a human." >/dev/null 2>&1 || true
    "$GH" issue edit "$n" --add-label needs-human --remove-label wip >/dev/null 2>&1 || true
    exit 0
  fi
fi

# ── Early push: make the work survivable BEFORE gating ───────────────────────────
# Pushing a branch is not the same as proposing it. No PR is opened here and nothing consumes an
# un-gated `agent/issue-N` branch, but once it is on the remote a killed build no longer loses its
# work — the next attempt resumes from it (see the resume block above). This is the difference
# between "the gate failed, try again from here" and "the process died, start over from nothing".
# Non-fatal: the post-gate push retries properly and owns the needs-human escalation.
if [ "${AGENT_EARLY_PUSH:-1}" = 1 ]; then
  # `$push_force` is `--force-with-lease` iff the resume block above rewrote this branch's
  # history: after a rebase the remote tip is no longer an ancestor, so a plain push is
  # REJECTED as non-fast-forward and the rebased work would never leave the worktree. The
  # lease still refuses to clobber a remote that moved behind our back — only agent-inbox
  # writes `agent/issue-N`, so the expected value is the ref we fetched at claim time.
  if git push -u ${push_force:+"$push_force"} "$REMOTE" "$branch" >>"${LOGDIR}/push-${n}.log" 2>&1; then
    log "issue #${n}: work pushed to ${REMOTE}/${branch} before gating — survivable now"
  else
    log "issue #${n}: early push failed (non-fatal; the post-gate push retries and escalates)"
  fi
fi

# ── Provision local, git-IGNORED files the GATES need (same gap as node_modules):
# .env / .env.local (docker-compose + services read them) and the .gcp cred dir mounted
# into the worker. Done AFTER the commit above so these symlinks are never committed into
# the PR; the gates run right after. Override the set with AGENT_LOCAL_PATHS. ─
shopt -s nullglob
LOCAL_GLOBS=( "$ROOT"/.env "$ROOT"/.env.local "$ROOT"/.gcp "$ROOT"/backend/.env "$ROOT"/backend/.env.local "$ROOT"/frontend/.env "$ROOT"/frontend/.env.local )
for extra in ${AGENT_LOCAL_PATHS:-}; do LOCAL_GLOBS+=( "$ROOT/$extra" ); done
for src in "${LOCAL_GLOBS[@]}"; do
  [ -e "$src" ] || continue
  rel="${src#"$ROOT"/}"; dst="$wt/$rel"
  [ -e "$dst" ] || { mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" 2>/dev/null; } || true
done
shopt -u nullglob

# ── Safety net: the project's own gates decide ship vs. hand-back ────────────────
log "running gates: ${GATES_CMD}"
if bash -c "$GATES_CMD" >"${LOGDIR}/gates-${n}.log" 2>&1; then
  # ── Push with bounded retry, capturing the REAL error ───────────────────────────
  # A single transient push/network blip used to strand the build: the old one-shot
  # `git push … 2>/dev/null` swallowed the error, `pr create` then had no branch and
  # emitted "(pr create failed)", yet the issue was still marked `done` — leaving a
  # built-but-unshipped branch and an opaque message (issue #901). Retry with backoff
  # and, if it ultimately fails, hand back to a human with the captured error instead
  # of faking success. (`done` is set ONLY after a PR truly opens.)
  pushed=0
  for ((attempt=1; attempt<=PUSH_RETRIES; attempt++)); do
    if git push -u ${push_force:+"$push_force"} "$REMOTE" "$branch" >"${LOGDIR}/push-${n}.log" 2>&1; then pushed=1; break; fi
    log "issue #${n}: push attempt ${attempt}/${PUSH_RETRIES} failed (see push-${n}.log)"
    [ "$attempt" -lt "$PUSH_RETRIES" ] && sleep "$((attempt * PUSH_RETRY_DELAY))"
  done
  if [ "$pushed" -ne 1 ]; then
    log "issue #${n}: push FAILED after ${PUSH_RETRIES} attempts — needs a human"
    "$GH" issue comment "$n" -b "$(printf '⚠️ agent-inbox: gates were green but `git push` failed after %s attempts — needs a human.\n\n```\n%s\n```' "$PUSH_RETRIES" "$(tail -25 "${LOGDIR}/push-${n}.log" 2>/dev/null)")" >/dev/null 2>&1 || true
    "$GH" issue edit "$n" --add-label needs-human --remove-label wip >/dev/null 2>&1 || true
    exit 0
  fi
  # ── Open the PR — capture stderr; even with the branch pushed, `pr create` can fail ─
  if ! url="$("$GH" pr create --fill --head "$branch" --base "$BASE" 2>"${LOGDIR}/prcreate-${n}.log")" || [ -z "$url" ]; then
    log "issue #${n}: pr create FAILED (branch is pushed) — needs a human"
    "$GH" issue comment "$n" -b "$(printf '⚠️ agent-inbox: branch `%s` pushed (gates green) but `gh pr create` failed — needs a human to open the PR.\n\n```\n%s\n```' "$branch" "$(tail -25 "${LOGDIR}/prcreate-${n}.log" 2>/dev/null)")" >/dev/null 2>&1 || true
    "$GH" issue edit "$n" --add-label needs-human --remove-label wip >/dev/null 2>&1 || true
    exit 0
  fi
  # docs/35: hand the fresh PR to the review↔fix loop via REST (gh pr edit --add-label hits the
  # projectCards GraphQL bug and silently drops the label). The PR number is the URL's last segment.
  add_label "${url##*/}" review-needed
  "$GH" issue comment "$n" -b "✅ agent-inbox: gates green. PR: ${url}" >/dev/null 2>&1 || true
  "$GH" issue edit "$n" --add-label done --remove-label wip >/dev/null 2>&1 || true
  log "issue #${n} DONE → ${url}"
else
  log "issue #${n}: gates FAILED — triaging"
  # ── SELF-HEAL: don't dead-end on needs-human. Classify the failure and route it:
  # transient → retry next tick; the agent's OWN fault → needs-human; infra/unrelated
  # breakage (not caused by this change) → auto-file a deduped blocker issue + mark this
  # one `blocked` so the loop keeps moving (it re-queues when the blocker closes). The
  # triage script is the single source of that policy; fall back to the old needs-human
  # path if it is missing/unexecutable so a broken triage never strands the run. ─
  TRIAGE="${AGENT_TRIAGE:-$ROOT/scripts/agent-triage-failure.sh}"
  if [ -x "$TRIAGE" ] && TRIAGE_GH="$GH" bash "$TRIAGE" \
        --issue "$n" --branch "$branch" --base "$BASE" --root "$ROOT" \
        --worktree "$wt" --log "${LOGDIR}/gates-${n}.log" >>"${LOGDIR}/triage-${n}.log" 2>&1; then
    log "issue #${n}: triage routed it (see triage-${n}.log)"
  else
    log "issue #${n}: triage unavailable/failed — falling back to needs-human"
    "$GH" issue comment "$n" -b "$(printf '❌ agent-inbox: gates failed:\n\n```\n%s\n```' "$(tail -25 "${LOGDIR}/gates-${n}.log")")" >/dev/null 2>&1 || true
    "$GH" issue edit "$n" --add-label needs-human --remove-label wip >/dev/null 2>&1 || true
  fi
fi
