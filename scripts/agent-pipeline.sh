#!/usr/bin/env bash
# agent-pipeline.sh — SEQUENTIAL, per-issue orchestrator for the agent build loop.
#
# The four stages (inbox / pr-reviewer / pr-fixer / pr-merger) used to run on four independent
# timers, each fanning out across its whole queue: the inbox built EVERY pending issue, then the
# reviewer reviewed EVERY PR, then the merger merged EVERY PR. A delivered PR was never picked up
# by the "next issue" — the stages just churned their own backlogs in parallel.
#
# This driver makes ONE issue flow end-to-end before the next is even started:
#   1. pick + build ONE issue → PR            (agent-inbox.sh)
#   2. drive that PR through review ⇄ fix      (agent-pr-reviewer.sh / agent-pr-fixer.sh)
#   3. merge it to main                        (agent-pr-merger.sh)
#   4. CLOSE the issue                         (the merger doesn't; there's no Closes-keyword)
#   …then the next timer tick starts again at step 1 with the next issue.
#
# It does NOT deploy. deploy-on-merge is disabled; the local stack is rebuilt BY HAND.
#
# One run advances the in-flight issue toward a terminal state (merged / *-stuck / needs-human)
# and is re-invoked by a single timer; a flock guarantees one instance. Stage scripts and gh are
# injectable so the journey is testable hermetically (scripts/agent-pipeline.test.sh).
#
#   Setup: scripts/agent-pr-loop-setup.sh (timers)  ·  Docs: docs/AGENT-HARNESS.md
set -uo pipefail

# Absolute dir this script lives in, captured BEFORE the `cd "$ROOT"` below — BASH_SOURCE[0] is
# frequently a relative path (e.g. invoked as `bash scripts/agent-pipeline.sh`), so resolving it
# again after that cd would silently walk it relative to the NEW cwd (AGENT_ROOT) instead.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Injectable dependencies (defaults = production; tests override) ───────────────
ROOT="${AGENT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GH="${AGENT_GH:-gh}"
GIT="${AGENT_GIT:-git}"
REMOTE="${AGENT_REMOTE:-origin}"
BASE="${AGENT_BASE:-main}"
HEAD_GLOB="${PIPELINE_HEAD_GLOB:-agent/}"           # only our agent-authored branches
INBOX="${PIPELINE_INBOX:-$ROOT/scripts/agent-inbox.sh}"
REVIEWER="${PIPELINE_REVIEWER:-$ROOT/scripts/agent-pr-reviewer.sh}"
FIXER="${PIPELINE_FIXER:-$ROOT/scripts/agent-pr-fixer.sh}"
MERGER="${PIPELINE_MERGER:-$ROOT/scripts/agent-pr-merger.sh}"
MAX_ROUNDS="${PIPELINE_MAX_ROUNDS:-10}"             # review⇄fix⇄merge rounds before giving up this run
REARM_MAX="${PIPELINE_REARM_MAX:-3}"                # how many times a stuck PR may be re-armed as main advances
MAX_OPEN_PRS="${PIPELINE_MAX_OPEN_PRS:-3}"         # cap on total open agent PRs before refusing new builds
ESCALATE_STUCK_HOURS="${PIPELINE_ESCALATE_STUCK_HOURS:-6}"  # hours before a stuck PR is escalated to needs-human
MERGE_STUCK_BATCH="${PIPELINE_MERGE_STUCK_BATCH:-2}"  # max merge-stuck PRs to recover per tick

agent_repo_ns() {
  local d; d="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  d="$(cd "$ROOT" 2>/dev/null && cd "$d" 2>/dev/null && pwd)" || return 1
  printf '%s' "$d" | sha1sum | cut -c1-12
}
NS="$(agent_repo_ns || true)"; [ -n "$NS" ] || NS="nogit"
# shellcheck source=lib/pr-lock.sh
source "$ROOT/scripts/lib/pr-lock.sh"
if ! declare -F pr_lock_is_held >/dev/null 2>&1; then
  echo "FATAL: scripts/lib/pr-lock.sh did not load from ROOT='$ROOT' — refusing to run blind" >&2
  exit 2
fi
LOCK="${PIPELINE_LOCK:-/tmp/agent-pipeline-$NS.lock}"
LOGDIR="${PIPELINE_LOGDIR:-/tmp/agent-pipeline-$NS}"

cd "$ROOT" || { echo "[pipeline] cannot cd to $ROOT" >&2; exit 2; }
mkdir -p "$LOGDIR"
log() { printf '[pipeline] %s\n' "$*"; }

# ── Toolchain bootstrap — systemd/cron start from a BARE env (no ~/.bashrc); source the tool
# managers so node/npx/python match an interactive shell (same gap the stage scripts handle). ─
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
[ -s "$HOME/miniconda3/etc/profile.d/conda.sh" ] && . "$HOME/miniconda3/etc/profile.d/conda.sh" >/dev/null 2>&1 || true
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) [ -d "$PNPM_HOME" ] && PATH="$PNPM_HOME:$PATH";; esac

# ── Single-instance lock — never two pipelines against the same repo ─────────────
exec 9>"$LOCK"
if ! flock -n 9; then log "another pipeline run in progress — exiting"; exit 0; fi

# ── Telemetry: mint this tick's run id up front and export it (#2390 docs/AGENT-HARNESS.md). Every
# stage below runs as a CHILD PROCESS via run_stage()'s `bash "$1"`, which inherits our exported env;
# each stage's own agent-model-call.sh source-time mint (see lib comment there) only mints a fresh id
# when AGENT_RUN_ID is unset, so exporting it here — not deriving it independently per stage — is what
# makes one tick's inbox/review/fix/merge spans nest under one run id instead of four.
# Libs live NEXT TO this script, so resolve them from SCRIPT_DIR (captured pre-cd, above) — never
# from $ROOT (which is AGENT_ROOT-overridable and won't hold scripts/lib in a sandboxed test tree).
# shellcheck source=lib/agent-trace.sh
source "$SCRIPT_DIR/lib/agent-trace.sh"
agent_trace_run_id >/dev/null

# Open agent PRs in a DRIVEABLE state (review-needed / changes-requested / review-approved),
# excluding ones already parked at a human-needed terminal (*-stuck). One per line.
active_prs() {
  "$GH" pr list --state open --json number,headRefName,labels --limit 50 2>/dev/null \
    | jq -r --arg g "$HEAD_GLOB" '
        [ .[]
          | select(.headRefName | startswith($g))
          | ([.labels[].name]) as $l
          | select($l | any(. == "review-needed" or . == "changes-requested" or . == "review-approved"))
          | select(($l | any(. == "review-stuck" or . == "merge-stuck")) | not)
          | .number ] | .[]' 2>/dev/null
}

# The driveable PRs THIS instance may take: repo-wide candidates minus any a stage in another
# instance is currently holding. Advisory by nature — the per-PR lock is re-tested inside the
# stage that acts, so a PR freed between this scan and the dispatch is simply picked up next tick.
# Without the filter, N pipeline instances would all see instance 1's PR and all drive it (#2152).
# PIPELINE_PR_FILTER=0 restores the unfiltered repo-wide view (single-instance behaviour).
drivable_prs() {
  local n
  if [ "${PIPELINE_PR_FILTER:-1}" != 1 ]; then active_prs; return; fi
  while read -r n; do
    [ -n "$n" ] || continue
    if pr_lock_is_held "$n"; then
      # stderr, NOT stdout: this function's stdout IS the PR list and is read via $(…). A
      # diagnostic on stdout gets captured as if it were a PR number, making the list non-empty
      # and sending the loop off to "drive" a line of prose.
      log "PR #${n} is being driven by another instance — leaving it" >&2
    else
      printf '%s\n' "$n"
    fi
  done < <(active_prs)
}

# Issue numbers behind the currently-driveable PRs (branch agent/issue-<N> → <N>).
inflight_issues() {
  "$GH" pr list --state open --json headRefName,labels --limit 50 2>/dev/null \
    | jq -r --arg g "$HEAD_GLOB" '
        .[] | select(.headRefName | startswith($g))
            | ([.labels[].name]) as $l
            | select($l | any(. == "review-needed" or . == "changes-requested" or . == "review-approved"))
            | .headRefName' 2>/dev/null | sed -E 's#.*/issue-##' | grep -E '^[0-9]+$' || true
}

# Count ALL open agent PRs regardless of label — including stuck, wip, everything.
# Used by the PR cap to prevent unbounded growth when stuck PRs accumulate.
# A PR counts against the cap whether the pipeline can drive it or not.
all_open_agent_pr_count() {
  local raw
  raw="$("$GH" pr list --state open --json headRefName --limit 50 2>/dev/null)" || { echo 0; return; }
  [ -n "$raw" ] || { echo 0; return; }
  # Handle both real JSON arrays (production) and raw integers (test stub).
  if printf '%s' "$raw" | grep -qE '^[0-9]+$'; then
    printf '%s' "$raw"
  else
    printf '%s' "$raw" | jq -r --arg g "$HEAD_GLOB" '[.[] | select(.headRefName | startswith($g))] | length' 2>/dev/null || echo 0
  fi
}

run_stage() { # <script> <logname>
  if [ ! -x "$1" ] && [ ! -f "$1" ]; then log "stage missing: $1 — skipping"; return 0; fi
  AGENT_GH="$GH" bash "$1" >>"${LOGDIR}/$2.log" 2>&1 || log "stage '$2' exited non-zero (continuing)"
}

# ── merge-stuck solo recovery (issue #2254 follow-up) ─────────────────────────────
# merge-stuck PRs are approved; the only blocker was a batch integration conflict.
# With PR_MERGER_MAX_PRS=1 the batch is now a solo merge. The merger already rebases
# onto latest main, so if the original conflict has cleared (the other PR merged or
# was reworked), the solo merge succeeds. This just promotes merge-stuck → review-approved
# so the existing merger flow handles the rest.
recover_merge_stuck() {
  # Don't race the real merger — but only stand down when the merger is PROVEN to be
  # running. Two stacked bugs used to make this function a permanent no-op (issue #2387, H3):
  #
  #   (a) the default lock path lacked the $NS suffix that agent-pr-merger.sh appends, so
  #       outside systemd the two never named the same file;
  #   (b) the guard read `[ -f "$lock" ] && flock -n …`, so a MISSING file took the else
  #       branch and logged "merger lock held" — the opposite of the truth.
  #
  # Net effect: merge-stuck solo recovery never ran, and said so in a message that read
  # like it was working. Now the skip requires positive proof — the file exists AND the
  # lock cannot be taken. Every unknown state (file absent, lock free, flock missing, path
  # wrong) proceeds.
  #
  # Failing open is safe here: recover_merge_stuck only relabels and comments — it never
  # merges and never touches git — and each PR is separately guarded by pr_lock_is_held
  # below, which is the authoritative per-PR flock. This global lock was only ever a coarse
  # pre-filter. Worst case in the TOCTOU window is a PR relabelled a tick early, which the
  # merger re-marks on its next pass.
  local merger_lock="${PR_MERGER_LOCK:-/tmp/agent-pr-merger-${NS}.lock}"
  if [ -e "$merger_lock" ] && ! flock -n "$merger_lock" -c true 2>/dev/null; then
    [ "${PIPELINE_RECOVER_MERGE_STUCK_QUIET:-0}" != 1 ] && log "merger holds ${merger_lock} — skipping merge-stuck recovery this tick"
    return 0
  fi
  local candidates; candidates="$("$GH" pr list --state open --json number,labels --limit 50 2>/dev/null \
    | jq -r --arg g "$HEAD_GLOB" '.[] | select(.headRefName|startswith($g))
        | select([.labels[].name] | index("merge-stuck"))
        | .number' 2>/dev/null | sort -n)"
  [ -n "$candidates" ] || return 0
  local count=0 n
  for n in $candidates; do
    [ -n "$n" ] || continue
    [ "$count" -lt "$MERGE_STUCK_BATCH" ] || break
    if pr_lock_is_held "$n"; then log "PR #${n}: held by another stage — skipping merge-stuck recovery"; continue; fi
    log "recovering merge-stuck PR #${n} — promoting to review-approved for solo re-merge"
    do_gh_rest DELETE "issues/${n}/labels/merge-stuck"
    do_gh_rest POST   "issues/${n}/labels" review-approved
    "$GH" pr comment "$n" -b "$(printf '🔄 agent-pipeline: merge-stuck PR #%s recovered — promoting to `review-approved` for solo re-merge. The original blocker was a batch integration conflict; with sequential merging the conflict may have cleared.' "$n")" >/dev/null 2>&1 || true
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] && log "recovered ${count} merge-stuck PR(s) → review-approved"
}

# ── Re-arm stuck PRs when main advances ──────────────────────────────────────────
# `review-stuck` / `merge-stuck` are excluded from active_prs, so a PR parked there ROTS even
# after `main` moves on and resolves whatever blocked it — e.g. PR #139 (issue #110) was stuck
# on a missing test fixture that a SIBLING PR later added to conftest, so its tests now pass but
# nothing re-checked it. When origin/main has advanced PAST a stuck PR's branch, give it ONE
# fresh attempt at this main SHA: review-stuck → review-needed (re-review), merge-stuck →
# review-approved (re-merge). Bounded by REARM_MAX total AND at most once per main SHA (a
# `<!-- rearm: <sha> -->` marker comment), so a permanently-broken PR can't loop forever.
rearm_stuck_prs() {
  "$GIT" -C "$ROOT" fetch -q "$REMOTE" >/dev/null 2>&1 || true
  local main_sha; main_sha="$("$GIT" -C "$ROOT" rev-parse --short "$REMOTE/$BASE" 2>/dev/null)" || return 0
  [ -n "$main_sha" ] || return 0
  local stuck; stuck="$("$GH" pr list --state open --json number,headRefName,labels --limit 50 2>/dev/null \
    | jq -r --arg g "$HEAD_GLOB" '.[] | select(.headRefName|startswith($g))
        | select([.labels[].name] | any(.=="review-stuck" or .=="merge-stuck"))
        | "\(.number)\t\(.headRefName)\t\([.labels[].name]|join(","))"' 2>/dev/null)"
  [ -n "$stuck" ] || return 0
  local num branch labels behind rearms last rearm_rc
  while IFS=$'\t' read -r num branch labels; do
    [ -n "$num" ] || continue
    behind="$("$GIT" -C "$ROOT" rev-list --count "$REMOTE/$branch..$REMOTE/$BASE" 2>/dev/null || echo 0)"
    [ "${behind:-0}" -gt 0 ] || continue          # main hasn't advanced past this branch → nothing new to try
    # Read the re-arm count fail-closed: a transient `gh` error must NOT reset it to 0 (the old
    # `|| echo 0` did exactly that, silently defeating REARM_MAX and letting a permanently-broken
    # PR be re-armed every tick). If we can't read a clean integer, skip re-arming this tick.
    rearms="$("$GH" pr view "$num" --json comments --jq '[.comments[]|select(.body|contains("<!-- rearm:"))]|length' 2>/dev/null)"
    if ! [[ "$rearms" =~ ^[0-9]+$ ]]; then log "PR #${num}: could not read re-arm count (gh error) — skipping re-arm this tick (fail-closed)"; continue; fi
    if [ "$rearms" -ge "$REARM_MAX" ]; then log "PR #${num}: re-arm budget exhausted (${rearms}/${REARM_MAX}) — leaving stuck"; continue; fi
    last="$("$GH" pr view "$num" --json comments --jq '[.comments[].body|capture("rearm: (?<s>[0-9a-f]+)").s]|last // ""' 2>/dev/null)"
    [ "$last" = "$main_sha" ] && continue          # already re-armed at THIS main SHA → don't spam every tick
    log "re-arming stuck PR #${num} (${labels}) — ${BASE} advanced to ${main_sha}, branch ${behind} behind"

    # ── Rebase the branch onto latest main BEFORE re-labeling (issue #2254 follow-up). ──
    # The old re-arm only relabelled, so the re-entered review/merge loop started from a
    # stale branch and immediately re-failed on the same code. Rebasing first ensures the
    # fresh attempt works against current reality. Generated-file conflicts (iteration log,
    # digest, state.json) are auto-resolved; real conflicts escalate to needs-human.
    # The rebase runs in a SUBSHELL, so its exit status — not `continue` — is what
    # decides whether the PR is re-armed afterwards. `continue` inside `( … )` is a bash
    # error ("only meaningful in a for/while/until loop"), not a skip: it printed to
    # stderr and execution carried on, out of the subshell and straight into the relabel
    # block below. A PR whose rebase hit REAL conflicts was therefore escalated to
    # needs-human AND re-labelled review-approved/review-needed, re-entering the merge
    # loop carrying a needs-human label (issue #2387, C1). shellcheck SC2106 flags all
    # three sites; nothing ran shellcheck on scripts/ until this same issue.
    #
    # Contract with the caller:
    #   0 → rebase clean (or generated-file conflicts auto-resolved) → re-arm
    #   2 → escalated to needs-human inside the subshell                → do NOT re-arm
    #   3 → transient failure, retry next tick                          → do NOT re-arm
    #   1 → could not even start (cd/checkout failed)                   → do NOT re-arm
    # Anything non-zero means "leave the labels alone", so a new failure mode added later
    # fails safe rather than silently re-arming.
    rearm_rc=0
    ( cd "$ROOT" || exit 1
      "$GIT" fetch -q "$REMOTE" "$BASE" "$branch" >/dev/null 2>&1 || true
      "$GIT" checkout -q -B "rearm-${num}" "$REMOTE/$branch" >/dev/null 2>&1 || exit 1
      if "$GIT" rebase "$REMOTE/$BASE" >/dev/null 2>&1; then
        # Clean rebase — push and proceed to relabel
        "$GIT" push --force-with-lease "$REMOTE" "HEAD:refs/heads/$branch" >/dev/null 2>&1 \
          || "$GIT" push --force "$REMOTE" "HEAD:refs/heads/$branch" >/dev/null 2>&1 \
          || log "PR #${num}: WARN could not force-push rebased branch"
        log "PR #${num}: rebased onto ${REMOTE}/${BASE} and force-pushed"
      else
        # Rebase had conflicts (or other failure) — classify them
        local _conflicted _real
        _conflicted="$("$GIT" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ' || true)"
        if [ -z "${_conflicted// /}" ]; then
          # Rebase failed with no unmerged files at all — non-conflict error
          # (e.g. dirty worktree, commit that could not be applied, transient git lock).
          # Abort and skip this re-arm; the next tick retries on a clean slate.
          log "PR #${num}: rebase failed with no conflict files — skipping re-arm this tick (will retry)"
          "$GIT" rebase --abort >/dev/null 2>&1 || true
          "$GIT" checkout -q - 2>/dev/null || "$GIT" checkout -q "$BASE" 2>/dev/null || true
          "$GIT" branch -D "rearm-${num}" >/dev/null 2>&1 || true
          exit 3
        fi
        # A byte-exact copy of the block above used to sit here (issue #2387, H5). It read
        # as unreachable dead code, but with the broken `continue` it was reachable and
        # actively harmful: the no-conflict-files path fell through into it, logged the
        # same line twice, and then — with _real empty — took the "generated files only"
        # branch below and force-pushed an UN-rebased branch. Deleted.
        _real="$(echo "$_conflicted" | tr ' ' '\n' \
          | grep -vE '^(docs/06-iteration-log\.md|docs/06-iteration-log\.digest\.md|state/state\.json)$' \
          | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//' || true)"
        if [ -z "$_real" ]; then
          # Only generated files conflict — auto-resolve and continue
          log "PR #${num}: rebase conflicts only in generated files (${_conflicted// /, }) — auto-resolving"
          "$GIT" checkout --theirs docs/06-iteration-log.md docs/06-iteration-log.digest.md state/state.json >/dev/null 2>&1 || true
          "$GIT" add docs/06-iteration-log.md docs/06-iteration-log.digest.md state/state.json >/dev/null 2>&1 || true
          GIT_EDITOR=true "$GIT" rebase --continue >/dev/null 2>&1 || true
          "$GIT" push --force-with-lease "$REMOTE" "HEAD:refs/heads/$branch" >/dev/null 2>&1 \
            || "$GIT" push --force "$REMOTE" "HEAD:refs/heads/$branch" >/dev/null 2>&1 \
            || log "PR #${num}: WARN could not force-push after generated-file resolution"
          log "PR #${num}: generated-file conflicts auto-resolved and pushed"
        else
          # Real conflicts — escalate, do NOT re-arm
          log "PR #${num}: rebase has real conflicts — escalating to needs-human (not re-arming)"
          "$GIT" rebase --abort >/dev/null 2>&1 || true
          # Drop whichever stuck label this PR actually carries. The old
          # `${labels%%:*}` was a no-op strip — $labels is a COMMA-joined list with no
          # colon in it, so the whole string ("review-stuck,agent") was sent as one
          # label name and the DELETE silently 404'd, leaving the stuck label in place.
          case ",${labels}," in
            *,merge-stuck,*)  do_gh_rest DELETE "issues/${num}/labels/merge-stuck";;
            *,review-stuck,*) do_gh_rest DELETE "issues/${num}/labels/review-stuck";;
          esac
          do_gh_rest POST "issues/${num}/labels" needs-human
          "$GH" pr comment "$num" -b "$(printf '🛑 agent-pipeline: tried to re-arm PR #%s but the rebase onto `%s` (%s) hit real conflicts. Escalating to `needs-human`. Conflict files: %s' "$num" "$BASE" "$main_sha" "${_real:-$_conflicted}")" >/dev/null 2>&1 || true
          "$GIT" checkout -q - 2>/dev/null || "$GIT" checkout -q "$BASE" 2>/dev/null || true
          "$GIT" branch -D "rearm-${num}" >/dev/null 2>&1 || true
          exit 2
        fi
      fi
      "$GIT" checkout -q - 2>/dev/null || "$GIT" checkout -q "$BASE" 2>/dev/null || true
      "$GIT" branch -D "rearm-${num}" >/dev/null 2>&1 || true
    ) || rearm_rc=$?
    # Only a clean (or auto-resolved) rebase may re-arm. Every other status already
    # logged and, where relevant, escalated inside the subshell.
    if [ "$rearm_rc" -ne 0 ]; then
      continue
    fi
    # ── Relabel (the rebase succeeded or was auto-resolved) ──
    if printf '%s' "$labels" | grep -q merge-stuck; then
      do_gh_rest DELETE "issues/${num}/labels/merge-stuck"; do_gh_rest POST "issues/${num}/labels" review-approved
    else
      do_gh_rest DELETE "issues/${num}/labels/review-stuck"; do_gh_rest POST "issues/${num}/labels" review-needed
    fi
    "$GH" pr comment "$num" -b "$(printf '🔄 agent-pipeline: \`%s\` advanced to %s (this branch was %s commit(s) behind); the blocker may be resolved — rebased and re-armed for a fresh attempt (%s/%s). <!-- rearm: %s -->' "$BASE" "$main_sha" "$behind" "$((rearms+1))" "$REARM_MAX" "$main_sha")" >/dev/null 2>&1 || true
  done <<< "$stuck"
}
# Label add/remove via REST (gh's --add-label hits the deprecated projectCards GraphQL field).
do_gh_rest() { # <POST|DELETE> <path-after-repo> [label-for-POST]
  if [ "$1" = POST ]; then "$GH" api -X POST "repos/{owner}/{repo}/$2" -f "labels[]=$3" >/dev/null 2>&1 || true
  else "$GH" api -X DELETE "repos/{owner}/{repo}/$2" >/dev/null 2>&1 || true; fi
}

# ── Stale-claim reaper ────────────────────────────────────────────────────────────
# `wip` / `review-wip` / `fix-wip` are claim LABELS, and a label outlives the process that wrote it.
# A build or fix killed by a systemd timeout, a host suspend or an OOM leaves its claim set with
# nobody working, and because those labels exclude the job from every lane's eligibility the job is
# stranded until a human relabels it — the #2086 deadlock, and the reason two PRs sat in `fix-wip`
# on 2026-07-25 while three lanes idled.
#
# The per-job flock makes the distinction decidable: it exists only while a live process holds the
# fd. "Labelled claimed but unlocked" is therefore reapable, which a label alone can never tell you.
#
# TWO conditions, both required, because the lock is taken just AFTER the label is written and a
# reaper racing that window would steal a live job:
#   1. nobody holds the job's lock, AND
#   2. the job has not been updated for REAP_GRACE_MIN minutes (default 20) — a live run comments,
#      pushes and relabels well inside that.
# Set PIPELINE_REAP=0 to disable.
REAP_GRACE_MIN="${PIPELINE_REAP_GRACE_MIN:-20}"

_stale_since() { # <iso8601-updatedAt> → 0 if older than the grace period
  # `then` was the variable name here. It is a bash RESERVED WORD, so shellcheck could not
  # parse the block and reported SC1010 on an unrelated line, and every reader has to
  # double-take. Renamed (issue #2387, hygiene).
  local ts="$1" seen_at now
  [ -n "$ts" ] || return 1
  seen_at="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
  [ "$seen_at" -gt 0 ] || return 1
  now="$(date +%s)"
  [ $(( now - seen_at )) -ge $(( REAP_GRACE_MIN * 60 )) ]
}

reap_stale_claims() {
  local n upd

  # Issues claimed by a builder that is gone.
  while IFS=$'\t' read -r n upd; do
    [ -n "$n" ] || continue
    issue_lock_is_held "$n" && continue
    _stale_since "$upd" || continue
    log "reaping stale \`wip\` on issue #${n} — no builder holds its claim and it is >${REAP_GRACE_MIN}m old"
    do_gh_rest DELETE "issues/${n}/labels/wip"
    do_gh_rest POST   "issues/${n}/labels" agent
    "$GH" issue comment "$n" -b "♻️ agent-pipeline: released a stale \`wip\` claim — the build holding it is no longer running (killed mid-flight, so the label outlived it). Re-queued for a fresh build. Note the previous attempt's un-pushed work is discarded: the next build resets the branch to \`origin/${BASE}\`." >/dev/null 2>&1 || true
  done < <("$GH" issue list --label wip --state open --json number,updatedAt \
             --jq '.[] | "\(.number)\t\(.updatedAt)"' 2>/dev/null || true)

  # PRs claimed by a stage that is gone. Restoring the label the stage consumed is what puts the PR
  # back in active_prs(): fix-wip → changes-requested, review-wip → review-needed,
  # merge-wip → review-approved.
  #
  # `merge-wip` is the one with the worst blast radius, and it was missed when this reaper was first
  # written. The merger BATCHES: PR_MERGER_MAX_PRS defaults to 20, and it labels every approved PR in
  # the batch `merge-wip` in one loop before integrating them together. `merge-wip` is not in
  # active_prs()'s driveable set, so a merger killed mid-integration (SIGTERM at the 3h timeout, host
  # suspend, OOM) can strand up to TWENTY PRs at once, invisible to every lane — where the other two
  # labels only ever strand one. A live batch is safe: the merger holds a per-PR lock for every PR in
  # it for the whole run, so condition 1 below protects it and only a dead batch is reaped.
  local lbl restore
  for lbl in fix-wip review-wip merge-wip; do
    case "$lbl" in
      fix-wip)    restore=changes-requested;;
      review-wip) restore=review-needed;;
      merge-wip)  restore=review-approved;;
    esac
    while IFS=$'\t' read -r n upd; do
      [ -n "$n" ] || continue
      pr_lock_is_held "$n" && continue
      _stale_since "$upd" || continue
      log "reaping stale \`${lbl}\` on PR #${n} — no stage holds its claim and it is >${REAP_GRACE_MIN}m old"
      do_gh_rest DELETE "issues/${n}/labels/${lbl}"
      do_gh_rest POST   "issues/${n}/labels" "$restore"
      "$GH" pr comment "$n" -b "♻️ agent-pipeline: released a stale \`${lbl}\` claim — the stage holding it is no longer running, so the label outlived its process and this PR was invisible to every lane (\`${lbl}\` is not in the driveable set). Restored \`${restore}\` so the loop picks it up again." >/dev/null 2>&1 || true
    done < <("$GH" pr list --label "$lbl" --state open --json number,updatedAt \
               --jq '.[] | "\(.number)\t\(.updatedAt)"' 2>/dev/null || true)
  done
}

# ── Escalate stale stuck PRs to needs-human ─────────────────────────────────────
# If a merge-stuck or review-stuck PR has been sitting past ESCALATE_STUCK_HOURS
# with its re-arm budget exhausted, escalate it so a human knows to investigate.
# Without this, stuck PRs silently rot while the pipeline builds around them (if
# below the cap) or idles (if at the cap). Controlled by PIPELINE_ESCALATE toggle.
escalate_stale_stuck() {
  local cutoff; cutoff="$(date -d "${ESCALATE_STUCK_HOURS} hours ago" +%s 2>/dev/null || echo 0)"
  [ "$cutoff" -gt 0 ] || return 0
  local stuck; stuck="$("$GH" pr list --state open --json number,updatedAt,labels,headRefName --limit 50 2>/dev/null \
    | jq -r --arg g "$HEAD_GLOB" --argjson cutoff "$cutoff" \
      '.[] | select(.headRefName|startswith($g))
          | select([.labels[].name] | any(.=="merge-stuck" or .=="review-stuck"))
          | select((.updatedAt | fromdateiso8601) < $cutoff)
          | "\(.number)\t\(.updatedAt)\t\([.labels[].name]|join(","))"' 2>/dev/null)"
  [ -n "$stuck" ] || return 0
  local num upd labels rearms
  while IFS=$'\t' read -r num upd labels; do
    [ -n "$num" ] || continue
    # Already escalated? (needs-human is terminal for us)
    if printf '%s' "$labels" | grep -q 'needs-human'; then continue; fi
    # Re-arm budget exhausted? Only escalate if we've already tried re-arming.
    rearms="$("$GH" pr view "$num" --json comments --jq '[.comments[]|select(.body|contains("<!-- rearm:"))]|length' 2>/dev/null)"
    if ! [[ "$rearms" =~ ^[0-9]+$ ]]; then continue; fi
    [ "$rearms" -lt "$REARM_MAX" ] && continue
    log "escalating stale stuck PR #${num} (${labels}, last updated ${upd})"
    if printf '%s' "$labels" | grep -q merge-stuck; then
      do_gh_rest DELETE "issues/${num}/labels/merge-stuck"
    else
      do_gh_rest DELETE "issues/${num}/labels/review-stuck"
    fi
    do_gh_rest POST "issues/${num}/labels" needs-human
    "$GH" pr comment "$num" -b "$(printf '⚠️ agent-pipeline: PR #%s has been stuck since %s (>%s hours) with re-arm budget exhausted (%s). Escalating to \`needs-human\` for manual review. To re-queue: remove \`needs-human\`, resolve the blocker, and set \`review-approved\` (merge-stuck) or \`review-needed\` (review-stuck).' "$num" "$upd" "$ESCALATE_STUCK_HOURS" "$REARM_MAX")" >/dev/null 2>&1 || true
  done <<< "$stuck"
}

# ── Phase 0 — re-arm any stuck PRs that main has advanced past (their blocker may be resolved). ─
[ "${PIPELINE_REAP:-1}" = 1 ] && reap_stale_claims
[ "${PIPELINE_RECOVER_MERGE_STUCK:-1}" = 1 ] && recover_merge_stuck
[ "${PIPELINE_REARM:-1}" = 1 ] && rearm_stuck_prs
[ "${PIPELINE_ESCALATE:-1}" = 1 ] && escalate_stale_stuck

# ── Phase 1 — STRICT SERIAL: only build a new issue when nothing is in flight. If a PR is still
# being reviewed/fixed/merged, finish IT first (e.g. a leftover from the old parallel timers). ─
# PR cap (issue #2254 follow-up): refuse to build new issues when the total number of open agent
# PRs is at or above the cap. This prevents unbounded growth when stuck PRs accumulate — stuck PRs
# are invisible to drivable_prs(), so without a cap the pipeline sees "nothing in flight" and
# keeps building new issues, compounding the backlog.
target_issues=""
total_open="$(all_open_agent_pr_count)"
if [ "$total_open" -ge "$MAX_OPEN_PRS" ]; then
  log "at capacity: ${total_open} open agent PRs (cap=${MAX_OPEN_PRS}) — not building new issues"
  target_issues="$(inflight_issues)"
elif [ -n "$(drivable_prs)" ]; then
  log "in-flight PR(s) present — draining them before building a new issue"
  target_issues="$(inflight_issues)"
else
  log "no in-flight PR — building the next issue"
  # Truncate the inbox log FIRST so the post-run scrape reads only THIS tick. run_stage appends
  # (`>>`), so without this a tick whose inbox claims nothing would `tail -1` a stale "claiming
  # issue #N" line from a PRIOR tick and mis-target an already-built issue. (flock ⇒ single writer.)
  : > "${LOGDIR}/inbox.log"
  run_stage "$INBOX" inbox
  target_issues="$(grep -oE 'claiming issue #[0-9]+' "${LOGDIR}/inbox.log" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)"
  [ -n "$target_issues" ] && log "built issue #${target_issues}" || log "inbox produced no PR (no eligible issue, or routed to needs-human/blocked)"
fi

# ── Phase 2 — drive the in-flight PR(s) review ⇄ fix → merge until terminal (bounded). ──
for ((r=1; r<=MAX_ROUNDS; r++)); do
  prs="$(drivable_prs)"
  if [ -z "$prs" ]; then log "no driveable PRs left — done after $((r-1)) round(s)"; break; fi
  log "round ${r}: driving PR(s) $(echo "$prs" | tr '\n' ' ')"
  run_stage "$REVIEWER" reviewer
  run_stage "$FIXER"    fixer
  run_stage "$MERGER"   merger
  [ "$r" -eq "$MAX_ROUNDS" ] && log "hit MAX_ROUNDS=$MAX_ROUNDS — leaving remainder for the next tick"
done

# ── Phase 3 — RECONCILE: close every OPEN issue whose agent PR has merged. The merger lands
# commits on main (GitHub auto-closes the PR as merged) but does NOT close the issue, and the PR
# carries no Closes-keyword — so we close it here. This is a STATELESS sweep, independent of
# target_issues, so it self-heals three failure modes the old this-run-only close could not:
#   (1) the post-merge index race — `pr list --state merged` can still read 0 in the seconds after
#       the merger lands the PR, silently skipping the close; next tick the index has caught up;
#   (2) a transient `gh issue close` failure — the issue stays open+`done`, retried next tick;
#   (3) a PR merged outside this run (e.g. by a human) — never in target_issues, but still swept.
# Candidates = OPEN issues marked `done` (the inbox's "PR opened" signal, set BEFORE merge) ∪ the
# issues we drove this run. Idempotent; closed issues drop out, so the set stays small. ──
close_candidates="$(
  { "$GH" issue list --state open --label done --json number --jq '.[].number' 2>/dev/null
    printf '%s\n' $target_issues
  } | grep -E '^[0-9]+$' | sort -u)"
for n in $close_candidates; do
  # Confirm the PR shipped via the merger's `merged` LABEL — the only reliable signal here.
  # The merger REBASES approved PRs onto an integration branch and FAST-FORWARDS `main`
  # (agent-pr-merger.sh) instead of using GitHub's merge, so a shipped PR's GitHub state is
  # `CLOSED` (not `MERGED`) with a null mergeCommit; it stamps `merged` only on a successful
  # fast-forward. `--head …issue-<N> --state all` matches the PR by its immutable head ref —
  # even after the branch is deleted — so this is independent of GitHub PR state, branch
  # existence, AND any issue comment. It closes inbox-built and manually-recovered strays alike.
  # (Earlier tries used `--state merged` — misses CLOSED rebase-ff PRs — and a `PR:…/pull/N`
  # issue comment only the inbox writes — misses manual PRs; both could strand `done` issues.)
  shipped="$("$GH" pr list --head "${HEAD_GLOB}issue-${n}" --state all --json labels \
    --jq 'map(select([.labels[].name] | index("merged"))) | length' 2>/dev/null || echo 0)"
  [ "${shipped:-0}" -ge 1 ] || continue
  state="$("$GH" issue view "$n" --json state --jq '.state' 2>/dev/null || echo CLOSED)"
  [ "$state" = "OPEN" ] || continue
  "$GH" issue close "$n" -c "✅ agent-pipeline: PR merged into main; closing the issue. (Deploy is manual — not triggered.)" >/dev/null 2>&1 \
    && log "closed issue #${n} (PR merged)" || log "WARN: could not close issue #${n} — will retry next tick"
done

log "pipeline run complete"
