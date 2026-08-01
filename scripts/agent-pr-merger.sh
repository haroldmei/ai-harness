#!/usr/bin/env bash
# agent-pr-merger.sh — the unattended "select ONE reviewed PR → integrate → merge to main →
# resolve conflicts by including ALL the work → re-gate → AUTO-MERGE to main".
#
# The close of the PR loop (docs/AGENT-HARNESS.md). agent-pr-reviewer approves a PR (label
# `review-approved`) and historically stopped there — "merging stays human". THIS agent closes
# the last manual step: it collects ONE `review-approved` PR, merges it
# onto an integration branch off the latest main, resolves any conflicts BETWEEN the PRs by
# including every PR's work (via a `claude -p` turn, model M), re-runs the FULL project gates on
# the combined result, and — only if green — fast-forwards `main` to the integration. After this,
# the ONLY human input in the whole pipeline is filing + labelling the issue.
#
# This is also SkillForge's local CI/CD gate: with Buildkite retired, the green checkmark that
# used to gate the merge is replaced by these gates running on YOUR machine at merge time. Nothing
# reaches `main` unless `scripts/quality-gates.sh` (incl. the full-stack browser e2e) passes here.
#
# WHY ONE INTEGRATION (not N independent merges): two approved PRs can be individually green but
# conflict with each other, or pass alone yet break combined. Integrating them together and
# gating the union is the only way to ship them all without a human untangling conflicts. So
# unlike the reviewer/fixer (which fan out per-PR), the merger is intentionally SERIAL — one
# integration per run, guarded by a single global flock.
#
# WHY PRE-MERGE REBASE (issue #822): a branch many commits behind main (PR #821 was 115 behind)
# produces conflicts at `git merge --no-ff` time even when `gh pr view` reports MERGEABLE —
# GitHub computes mergeability against a different base. The reactive merge-time resolver then
# fires on a phantom conflict and (observed across several PRs) can hang for minutes holding the
# lock. So each PR is first REBASED onto the integration base (resolving any conflicts THERE,
# before the merge commit); the subsequent `--no-ff` merge of the rebased branch is clean by
# construction. Only a genuine PR-vs-PR conflict (two approved PRs touching the same lines) can
# still reach the merge-time resolver.
#
# SAFETY (non-negotiable, even though merging is now automatic):
#   1. Isolation  — all work in a dedicated worktree; the integration is pushed to `main` ONLY
#                   after the gates pass. Never your primary working copy.
#   2. Gates gate the merge — a red integration is NEVER pushed. The failure is routed BACK
#      into the reviewer⇄fixer loop (`changes-requested` + findings comment) so the pipeline
#      iterates fix→review→merge until green; the fixer's round cap bounds the loop. Only a
#      red BASE (main itself fails the same gates) goes to `merge-stuck` — a human owns main.
#   3. Conflicts that the resolver can't clear (markers remain) → `merge-stuck`, never a forced
#      or marker-polluted commit.
#   4. Fast-forward only — if `main` moved under us the push is refused (no force) → `merge-stuck`.
#
# Hermetically testable (scripts/agent-pr-merger.test.sh) — gh/claude injectable + stubbed.
#
#   Labels: review-approved → merge-wip → {merged | changes-requested (fix loop) | merge-stuck}
#   Setup: scripts/agent-pr-loop-setup.sh  ·  Docs: docs/AGENT-HARNESS.md
set -uo pipefail

# ── Injectable dependencies (defaults = production; tests override) ──────────────
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
BASE="${PR_BASE:-main}"
REMOTE="${PR_REMOTE:-origin}"
HEAD_GLOB="${PR_HEAD_GLOB:-agent/}"               # only merge agent-authored PRs
MERGER_MODEL="${PR_MERGER_MODEL:-opus}"           # model M (resolves conflicts)
MAX_PRS="${PR_MERGER_MAX_PRS:-1}"                # cap PRs integrated per run
GATES_CMD="${PR_MERGER_GATES_CMD:-${PR_GATES_CMD:-scripts/quality-gates.sh --tier launch}}"   # the FULL gates on the union
DEPS_MODE="${PR_DEPS:-install}"
INTEGRATION_BRANCH="${PR_INTEGRATION_BRANCH:-agent/integration}"
MERGER_MAX_SELF_REPAIR="${PR_MERGER_MAX_SELF_REPAIR:-3}"   # gate-fix retries on the integration
# NB: there is deliberately no MERGER_FIX_MODEL here. One used to be declared and documented
# as "model for fixing (per-PR isolation)" and was referenced by nothing — both model calls in
# this file (the conflict resolver and its retry) use MERGER_MODEL. It read as a live
# model-separation control while doing nothing, which under FR-075 (reviewer model ≠ fixer
# model) is worse than no control at all: an operator setting PR_MERGER_FIX_MODEL would
# believe they had separated the models (issue #2387, M6).
# The merger does not fix anything itself — it labels a failing PR `changes-requested` and
# agent-pr-fixer.sh does the fixing, in its own process, under PR_FIXER_MODEL. That is where
# the separation is expressed and enforced.
MERGER_SELF_REPAIR="${PR_MERGER_SELF_REPAIR:-1}"            # 0 = old route_red_integration behaviour
# When self-repair is enabled, the merger isolates which PR in the batch is at fault by
# testing each individually against the base. Failing PRs are routed to their own fixer
# (changes-requested); the shared integration worktree is never mutated. Between attempts
# the integration is reset to the last merge commit so fixes never accumulate (#2175 follow-up).
# ── Per-repo namespace — so the PR loop in DIFFERENT repos never collides on a global /tmp
# lock (or clobbers a shared PR_LOGDIR). The git common dir is stable across a repo's own
# worktrees yet unique per repo; resolve to an ABSOLUTE path (`--git-common-dir` returns a bare
# ".git" at a repo root, so every repo would hash identically otherwise). The three PR-loop
# stages (reviewer/fixer/merger) derive the SAME key in the SAME repo → they still share
# PR_LOGDIR intra-repo while staying isolated across repos. Replaces the old hardcoded
# `skillforge-` prefix (one source of truth, not a per-repo string baked into the script).
pr_repo_ns() {
  local d
  d="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  d="$(cd "$ROOT" 2>/dev/null && cd "$d" 2>/dev/null && pwd)" || return 1
  printf '%s' "$d" | sha1sum | cut -c1-12
}
NS="$(pr_repo_ns || true)"; [ -n "$NS" ] || NS="nogit"
LOCK="${PR_MERGER_LOCK:-/tmp/agent-pr-merger-$NS.lock}"
LOGDIR="${PR_LOGDIR:-/tmp/agent-pr-review-$NS}"
WORKTREE_BASE="${PR_WORKTREE_BASE:-/tmp/agent-pr-review-$NS/worktrees}"
# Commit identity for the integration merge commits (works even on a bare systemd env).
GIT_ID=( -c "user.name=${MERGER_GIT_NAME:-agent-pr-merger}" -c "user.email=${MERGER_GIT_EMAIL:-agent-pr-merger@skillforge.local}" )

cd "$ROOT" || { echo "[pr-merger] cannot cd to $ROOT" >&2; exit 2; }
mkdir -p "$LOGDIR" "$WORKTREE_BASE"
log() { printf '[pr-merger] %s\n' "$*"; }

# ── Conflict-marker detector ──────────────────────────────────────────────────────
# Refuse to ship any tree that still contains a git conflict marker. The old check was
# `git grep -lE '^(<<<<<<<|>>>>>>>) '` — it REQUIRED a trailing space, so a resolver (especially a
# weaker model) that left a bare `<<<<<<<` / `>>>>>>>` at end-of-line slipped through and a
# marker-polluted, broken merge could reach `main`. Match a 7-char start/end marker followed by a
# space, tab, OR end-of-line; the alternation is exactly 7 chars, so an 8+-char run (not a real
# git marker) still won't match. Start/end markers only (never bare `=======`, which legitimately
# appears as a Markdown/RST heading underline).
CONFLICT_MARKER_RE='^(<<<<<<<|>>>>>>>)([ '$'\t'']|$)'

# Print every path (of those given) that carries a marker. ALWAYS pass a pathspec: an unscoped
# scan of the whole worktree false-positives on a marker that is legitimately committed or quoted
# in an unrelated tracked file, and then aborts every conflicted integration as `merge-stuck` even
# when the resolver succeeded. That is not hypothetical — a stray marker pair in
# docs/06-gap-analysis.md (PR #726 squash edad2cdc) sat dormant for weeks and then failed PR
# #1473's integration; cleaned in 8a392463. The two callers below scope it differently on purpose:
# the resolver loop scopes to the files it was asked to resolve, the pre-push guard scopes to
# everything this integration actually changed over the base.
conflict_marker_paths() { # <paths…>
  [ "$#" -gt 0 ] || return 0
  git grep -lE "$CONFLICT_MARKER_RE" -- "$@" 2>/dev/null
}
# Returns 0 if any of the given paths contains a marker.
has_conflict_markers() { # <paths…>
  [ -n "$(conflict_marker_paths "$@")" ]
}
# Same scan against a COMMITTED tree. The push ships HEAD, not the worktree, and the two can
# differ (a gate or a self-repair step that edited without committing, or committed without the
# edit landing in the worktree) — so the guard on the push path must read what is actually shipped.
conflict_marker_paths_in_rev() { # <rev> <paths…>
  local rev="$1"; shift
  [ "$#" -gt 0 ] || return 0
  git grep -lE "$CONFLICT_MARKER_RE" "$rev" -- "$@" 2>/dev/null | sed "s|^${rev}:||"
}

# ── Conflicted-state snapshot / restore ───────────────────────────────────────────
# The resolver loop stages its output with `git add -A`, which collapses index stages 1/2/3 into
# stage 0 and DESTROYS the conflict. A later `git checkout -- <file>` therefore restores the file
# from the index — i.e. the marker-laden text the resolver just wrote — not the original conflict,
# so every retry compounded the previous attempt's mangling instead of restarting from the real
# conflict, and `git checkout --theirs` in the fallback silently updated 0 paths and exited 0.
# Snapshot the unmerged index entries plus the marker-laden worktree files up front so a retry can
# hand the model a genuine conflict. `git ls-files -u` emits exactly the format
# `git update-index --index-info` consumes.
snapshot_conflict() { # <dir> <paths…>
  local dir="$1" f; shift
  [ "$#" -gt 0 ] || return 1
  rm -rf "$dir" 2>/dev/null || true
  mkdir -p "$dir/wt" || return 1
  git ls-files -u -- "$@" > "$dir/stages" 2>/dev/null || return 1
  [ -s "$dir/stages" ] || return 1
  for f in "$@"; do
    [ -f "$f" ] || continue
    mkdir -p "$dir/wt/$(dirname "$f")" || return 1
    cp -p "$f" "$dir/wt/$f" || return 1
  done
  return 0
}
restore_conflict() { # <dir> <paths…>
  local dir="$1" f; shift
  [ -s "$dir/stages" ] || return 1
  # Drop the collapsed stage-0 entry first — update-index refuses to add unmerged stages beside it.
  for f in "$@"; do git update-index --force-remove -- "$f" >/dev/null 2>&1 || true; done
  git update-index --index-info < "$dir/stages" >/dev/null 2>&1 || return 1
  for f in "$@"; do
    [ -f "$dir/wt/$f" ] || continue
    cp -p "$dir/wt/$f" "$f" || return 1
  done
  return 0
}

# ── Asserted "take theirs" for regeneratable files ────────────────────────────────
# `git checkout --theirs` exits 0 having updated 0 paths whenever the path no longer has unmerged
# stages, so its success can never be assumed — it must be verified. Requires a stage-3 ("theirs")
# entry for every path, then proves the result is marker-free. Returns non-zero on any doubt so the
# caller routes to `stuck` instead of committing conflict markers while reporting success.
take_theirs_verified() { # <paths…>
  local f
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    [ -n "$f" ] || continue
    git ls-files -u -- "$f" 2>/dev/null | awk '{print $3}' | grep -qx 3 || return 1
    git checkout --theirs -- "$f" >/dev/null 2>&1 || return 1
    git add -- "$f" >/dev/null 2>&1 || return 1
  done
  ! has_conflict_markers "$@"
}

# ── Serialize worktree add/remove under a per-REPO lock (shared with the other agent-* scripts
# via the git common dir) — parallel `git worktree add`s race on `.git/worktrees`. ──
WT_LOCK="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)"
case "$WT_LOCK" in /*) ;; *) WT_LOCK="$ROOT/$WT_LOCK";; esac
WT_LOCK="${WT_LOCK%/}/.agent-worktree.lock"
git_worktree_locked() { local rc; exec 7>"$WT_LOCK"; flock 7; git worktree "$@"; rc=$?; exec 7>&-; return $rc; }

# Label ops via REST (gh pr edit --add-label hits the deprecated projectCards GraphQL field
# and flakily drops the label, docs/35). Non-fatal; add LOGGED on failure, remove tolerates 404.
add_label()    { "$GH" api -X POST   "repos/{owner}/{repo}/issues/$1/labels"     -f "labels[]=$2" >/dev/null 2>&1 || log "WARN: could not add label '$2' to #$1"; }
remove_label() { "$GH" api -X DELETE "repos/{owner}/{repo}/issues/$1/labels/$2"                   >/dev/null 2>&1 || true; }
# Mark every PR in this integration with a terminal label + comment, then exit.
finish_all() { # <label> <comment>
  local lbl="$1" msg="$2" p
  for p in "${PR_NUMS[@]:-}"; do
    [ -n "$p" ] || continue
    "$GH" pr comment "$p" -b "$msg" >/dev/null 2>&1 || true
    add_label "$p" "$lbl"; remove_label "$p" merge-wip
  done
}

# ── Toolchain bootstrap ──────────────────────────────────────────────────────────
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
[ -s "$HOME/miniconda3/etc/profile.d/conda.sh" ] && . "$HOME/miniconda3/etc/profile.d/conda.sh" >/dev/null 2>&1 || true

# ── Preflight ───────────────────────────────────────────────────────────────────
for t in git jq "$GH" "$CLAUDE"; do
  command -v "$t" >/dev/null 2>&1 || { log "PREFLIGHT FAILED — not on PATH: $t"; exit 1; }
done

# ── Single-instance lock — one integration at a time (the merger is intentionally serial) ──
exec 9>"$LOCK"
if ! flock -n 9; then log "another merger run in progress — exiting"; exit 0; fi

# ── Select EVERY approved PR (head agent/*, not already merging/terminal) ─────────
# (no server-side --label here: gh implements it via the SEARCH API, whose index can
#  lag label churn by hours and hide the PR — the label is filtered client-side below
#  from live data instead)
prs_json="$("$GH" pr list --state open \
  --json number,headRefName,labels,title --limit 50 2>/dev/null || echo '[]')"
[ -z "$prs_json" ] && prs_json='[]'
selected="$(jq -c --arg pfx "$HEAD_GLOB" --argjson max "$MAX_PRS" 'map(select(
  (.headRefName | startswith($pfx)) and
  ([.labels[]?.name] | index("review-approved")) and
  ([.labels[]?.name] | index("merge-wip")   | not) and
  ([.labels[]?.name] | index("merged")       | not) and
  ([.labels[]?.name] | index("merge-stuck")  | not)
)) | sort_by(.number) | .[0:$max]' <<<"$prs_json")"

count="$(jq 'length' <<<"$selected")"
if [ "${count:-0}" -eq 0 ]; then log "no approved PRs to merge"; exit 0; fi

# Parallel arrays of the selected PR numbers + head branches.
mapfile -t _CAND_NUMS  < <(jq -r '.[].number'      <<<"$selected")
mapfile -t _CAND_HEADS < <(jq -r '.[].headRefName' <<<"$selected")

# Take a per-PR lock for every PR in the batch and DROP any a reviewer/fixer is still holding.
# The merger is globally exclusive (one merger at a time via PR_MERGER_LOCK), so this is not about
# merger-vs-merger — it is about not integrating a branch while a fixer is mid-push to it, which
# would bake a half-written commit into main. Excluding it costs one tick; the next run picks it up.
# Locks are held for the whole run: fds close on exit, so a crash cannot strand a PR.
PR_NUMS=(); PR_HEADS=(); PR_LOCK_FDS=()
for i in "${!_CAND_NUMS[@]}"; do
  if pr_lock_try _mfd "${_CAND_NUMS[$i]}"; then
    PR_NUMS+=("${_CAND_NUMS[$i]}"); PR_HEADS+=("${_CAND_HEADS[$i]}"); PR_LOCK_FDS+=("$_mfd")
  else
    log "excluding PR #${_CAND_NUMS[$i]} from this integration — another stage holds it"
  fi
done
count="${#PR_NUMS[@]}"
if [ "$count" -eq 0 ]; then log "every approved PR is held by another stage — nothing to integrate"; exit 0; fi
log "integrating ${count} approved PR(s): ${PR_NUMS[*]}"

# Claim them all so a concurrent run (or the reviewer/fixer) won't touch them mid-merge.
for i in "${!PR_NUMS[@]}"; do add_label "${PR_NUMS[$i]}" merge-wip; remove_label "${PR_NUMS[$i]}" review-approved; done

# ── Integration worktree on a branch off the LATEST main ─────────────────────────
git fetch -q "$REMOTE" "$BASE" >/dev/null 2>&1 || true
base_ref="${REMOTE}/${BASE}"; git rev-parse --verify -q "$base_ref" >/dev/null || base_ref="$BASE"
base_sha="$(git rev-parse "$base_ref" 2>/dev/null || echo "")"
wt="${WORKTREE_BASE}/integration"
git_worktree_locked remove --force "$wt" >/dev/null 2>&1 || true; rm -rf "$wt" >/dev/null 2>&1 || true
if ! git_worktree_locked add -f -B "$INTEGRATION_BRANCH" "$wt" "$base_ref" >/dev/null 2>&1; then
  log "could not create the integration worktree"
  finish_all merge-stuck "⚠️ agent-pr-merger: could not create an integration worktree — needs a human."
  exit 0
fi
cleanup() { cd "$ROOT" 2>/dev/null || true; git_worktree_locked remove --force "$wt" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Guarded (issue #2387): an unguarded `cd "$wt"` that fails leaves the process in the
# PRIMARY checkout and every subsequent build/gate/git command below runs against it
# instead of the isolated worktree — the exact "runs in the wrong directory" failure
# SC2164 warns about, in the one place it would do the most damage.
cd "$wt" || { log "FATAL: cannot enter worktree $wt — aborting merge"; exit 2; }

# ── Conflict resolver (model M): reconcile to INCLUDE every PR's work ─────────────
# Invoked at REBASE time (preferred — a stale branch's conflicts with main are cleared BEFORE
# the merge commit, issue #822) and, for genuine PR-vs-PR conflicts, at MERGE time. Writes the
# CLI envelope to <out-json> and prints the transient|hard|ok classification so the caller can
# defer the whole integration on a self-healing limit.
# With MERGER_RESOLVER_RETRIES > 1: if markers survive, re-invoke the resolver with feedback about
# which markers remain. Escalates: attempt 1 asks for union, attempt 2+ pinpoints the remaining
# markers and asks for a different strategy, attempt N auto-resolves generated files.
#
# STDOUT IS THE RETURN CHANNEL. Callers read this function with `$(…)`, so anything it prints on
# stdout other than the final verdict becomes part of the verdict. Three `log` calls in here were
# missing their `1>&2`, so on the unresolvable path the caller received
# "…left conflict markers — retrying\n…\nstuck" instead of "stuck": neither `case` arm matched, the
# merger fell through to the success branch, committed the conflict, and fast-forwarded `main` onto
# a tree full of markers while logging "MERGED". Every diagnostic in here therefore goes through
# rlog(), which is hard-wired to stderr, and the callers below take only the last line.
rlog() { log "$@" 1>&2; }
invoke_resolver() { # <pr-num> <head> <stage:rebase|merge> <conflicted-files> <out-json>
  local n="$1" head="$2" stage="$3" conflicted="$4" out="$5" prompt attempt retries cls snap snapped=0 left_over=""
  local -a cfiles
  # shellcheck disable=SC2206  # deliberate word-split: the caller passes a space-separated list
  cfiles=( $conflicted )
  retries="${MERGER_RESOLVER_RETRIES:-3}"
  # Preserve the REAL conflict before the first attempt can collapse it, so attempts 2..N (and the
  # generated-file fallback) start from the original conflict rather than the previous attempt's
  # output. Without this the "3 escalating attempts" are one attempt plus two on degraded input.
  snap="${LOGDIR}/conflict-snap-${n}-$$"
  if snapshot_conflict "$snap" "${cfiles[@]}"; then snapped=1
  else rlog "PR #${n}: WARN could not snapshot the conflicted state — retries will not reset the tree"; fi
  attempt=0
  while [ "$attempt" -lt "$retries" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -eq 1 ]; then
      prompt="$(cat <<EOF
You are agent-pr-merger's conflict resolver, working in an isolated git worktree mid-${stage}.
We are integrating multiple INDEPENDENTLY-APPROVED pull requests onto '${BASE}'. The ${stage} of
PR #${n} (branch '${head}') hit conflicts in: ${conflicted}

Resolve EVERY conflict so the result INCLUDES ALL PRs' work — never drop one side to favour the
other; combine them so both intents survive (union of behaviour, both functions/imports/cases,
merged config). Remove every conflict marker (<<<<<<<, =======, >>>>>>>). If two changes are
genuinely mutually exclusive, prefer the union that keeps both code paths compiling. Edit the
files in place. Do NOT run git, do NOT commit, do NOT push — just leave the files resolved.
EOF
)"
    else
      # Escalation: tell the model exactly which markers it left behind and ask for a fresh approach.
      # Which files the PREVIOUS attempt left polluted — captured before the reset below, since the
      # tree the model is about to see has been restored to the original conflict.
      local remaining="${left_over:-$conflicted}"
      prompt="$(cat <<EOF
You are agent-pr-merger's conflict resolver. Your PREVIOUS attempt left unresolved conflict
markers in: ${remaining}

This is attempt ${attempt}/${retries}. The ${stage} of PR #${n} (branch '${head}') hit conflicts in:
${conflicted}

Your last resolution was NOT sufficient — conflict markers (<<<<<<<, =======, >>>>>>>) remain.
Try a DIFFERENT strategy: if you kept one side entirely, try merging the changes instead; if
you tried to merge, try keeping the side that preserves the most functionality. For generated
or config files, keeping one side entire is acceptable. Remove ALL markers. Edit in place.
Do NOT run git, do NOT commit, do NOT push.
EOF
)"
    fi
    "$CLAUDE" -p "$prompt" --permission-mode bypassPermissions --model "$MERGER_MODEL" --output-format json \
      >"$out" 2>&1 || rlog "PR #${n}: resolver attempt ${attempt} exited non-zero"

    cls="$(classify_model_result "$out")"
    # CLAUDE.md: every `claude` invocation emits a span (#2390). The stage records WHERE the resolver
    # ran — rebase-time (merge-rebase) vs merge-time (merge-resolve) — because they have different
    # retry budgets and a merge-time conflict is the expensive one worth costing separately.
    # `attempt` is the resolver retry ordinal, NOT the PR-loop round (the merger doesn't know that
    # round) — passing it as `round` made the field non-joinable with the fixer/reviewer's spans
    # for the same pr (#2390 review), so `round` is left null here and the ordinal rides `attempt`.
    agent_trace_span "$out" "$([ "$stage" = merge ] && echo merge-resolve || echo merge-rebase)" \
      pr="$n" attempt="$attempt" model="$MERGER_MODEL" outcome="$cls" \
      template="$([ "$stage" = merge ] && echo merge-resolve-v1 || echo merge-rebase-v1)" \
      prompt="$prompt"
    # Transient (rate/usage limit, overload) — abort immediately, don't retry.
    if [ "$cls" = "transient" ]; then echo transient; return; fi

    # Check the resolver's output BEFORE staging it: `git add -A` collapses the unmerged stages, so
    # everything that needs the conflict (the retry reset, the fallback) must happen while it exists.
    left_over="$(conflict_marker_paths "${cfiles[@]}" | tr '\n' ' ')"
    if [ -z "${left_over// /}" ]; then
      git add -A >/dev/null 2>&1 || true
      rlog "PR #${n}: resolver resolved conflicts on attempt ${attempt}"
      rm -rf "$snap" 2>/dev/null || true
      echo ok; return
    fi

    # Markers survive — reset to the ORIGINAL conflict and retry, so the next attempt gets a fresh
    # start rather than this attempt's mangled output.
    rlog "PR #${n}: resolver attempt ${attempt} left conflict markers in ${left_over}— resetting the tree and retrying"
    if [ "$snapped" = 1 ] && restore_conflict "$snap" "${cfiles[@]}"; then
      :
    else
      rlog "PR #${n}: WARN could not reset the tree to the original conflict"
      git checkout -q -- "${cfiles[@]}" 2>/dev/null || true
    fi
  done

  # All retries exhausted — one last attempt: for generated files only, auto-resolve. The tree is
  # back at the original conflict (restored above), so `--theirs` has real stages to take.
  local _real
  _real="$(echo "$conflicted" | tr ' ' '\n' | grep -vE '^(docs/06-iteration-log\.md|docs/06-iteration-log\.digest\.md|state/state\.json)$' || true)"
  if [ -z "$_real" ] && [ -n "${conflicted// /}" ]; then
    rlog "PR #${n}: exhausted ${retries} resolver attempts — auto-resolving generated files"
    if take_theirs_verified "${cfiles[@]}"; then
      rm -rf "$snap" 2>/dev/null || true
      echo ok; return
    fi
    # Never report `ok` on an unverified fallback: that is what let `rebase --continue` commit
    # conflict markers while the run logged success.
    rlog "PR #${n}: generated-file fallback could not actually resolve ${conflicted}— refusing to report success"
  fi

  rm -rf "$snap" 2>/dev/null || true
  echo stuck
}

# Is a rebase currently in progress (stopped on a conflict)?
rebase_in_progress() {
  [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] && return 0
  [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ] && return 0
  return 1
}

# Rebase the CURRENT branch onto $base_ref, resolving each conflict stop with the model so the
# stale branch lands on the same base as the integration (issue #822). A 100+-commit-behind
# branch can stop many times; we resolve, re-check for markers, and `--continue` until done.
# Prints exactly one of:  ok | stuck | transient.
rebase_onto_base() { # <pr-num> <head>
  local n="$1" head="$2" rc cls conflicted guard=0
  git "${GIT_ID[@]}" rebase --empty=drop "$base_ref" >>"${LOGDIR}/rebase-${n}.log" 2>&1; rc=$?
  while [ $rc -ne 0 ]; do
    # A non-conflict failure (or a rebase that's no longer in progress) is unrecoverable here.
    if ! rebase_in_progress; then echo stuck; return; fi
    # Runaway backstop — far above any real 100+-commit rebase; never spin forever.
    guard=$((guard+1)); if [ "$guard" -gt 1000 ]; then git rebase --abort >/dev/null 2>&1 || true; echo stuck; return; fi
    conflicted="$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
    if [ -n "${conflicted// /}" ]; then
      # tail -n1: the verdict is the LAST line, so a stray stdout diagnostic can never be read as
      # an unrecognised class and fall through to "resolved" (see rlog above).
      cls="$(invoke_resolver "$n" "$head" rebase "$conflicted" "${LOGDIR}/agent-rebase-${n}.json" | tail -n1)"
      if [ "$cls" = "transient" ]; then git rebase --abort >/dev/null 2>&1 || true; echo transient; return; fi
      # Anything that is not an explicit `ok` is stuck. Testing for "stuck" and treating everything
      # else as resolved is how a corrupted verdict became a merge; unknown must fail closed.
      if [ "$cls" != "ok" ]; then
        git rebase --abort >/dev/null 2>&1 || true; echo stuck; return
      fi
      # ok — resolved, continue the rebase
    fi
    GIT_EDITOR=true git "${GIT_ID[@]}" rebase --continue >>"${LOGDIR}/rebase-${n}.log" 2>&1; rc=$?
  done
  echo ok
}

# ── For each approved PR (low→high PR number): pre-merge rebase onto the integration base so
# branch-vs-main staleness is reconciled HERE (issue #822), THEN a clean --no-ff merge of the
# rebased branch into the integration. Only a genuine PR-vs-PR conflict can still reach the
# merge-time resolver; a branch merely behind main never does. ──
merged_nums=()
PR_REBASED_SHAS=()   # parallel to PR_NUMS: rebased tip SHA for each PR (used post-push)
for i in "${!PR_NUMS[@]}"; do
  n="${PR_NUMS[$i]}"; head="${PR_HEADS[$i]}"
  git fetch -q "$REMOTE" "$head" >/dev/null 2>&1 || true
  rb="rebased-${head//\//-}"   # slashes → dashes so the ref is a single segment

  # ── (a) Pre-merge rebase: replay the PR onto $base_ref, resolving conflicts before the merge.
  log "rebasing PR #${n} (${head}) onto ${base_ref} before merge…"
  if ! git checkout -q -B "$rb" "${REMOTE}/${head}" >>"${LOGDIR}/rebase-${n}.log" 2>&1; then
    log "PR #${n}: could not check out the PR head for rebase — aborting integration"
    git checkout -q "$INTEGRATION_BRANCH" >/dev/null 2>&1 || true
    finish_all merge-stuck "$(printf '🛑 agent-pr-merger: could not check out PR #%s (%s) to rebase — needs a human.' "$n" "$head")"
    exit 0
  fi
  cls="$(rebase_onto_base "$n" "$head" | tail -n1)"
  git checkout -q "$INTEGRATION_BRANCH" >>"${LOGDIR}/merge-${n}.log" 2>&1
  if [ "$cls" = "transient" ]; then
    log "resolver hit a transient limit (rate-limit/usage-limit/overload) while rebasing PR #${n} — deferring; PRs return to review-approved, retry next tick"
    git branch -D "$rb" >/dev/null 2>&1 || true
    for p in "${PR_NUMS[@]:-}"; do [ -n "$p" ] || continue; add_label "$p" review-approved; remove_label "$p" merge-wip; done
    exit 0
  fi
  if [ "$cls" = "stuck" ]; then
    log "PR #${n}: rebase conflicts could not be auto-resolved — aborting integration"
    git branch -D "$rb" >/dev/null 2>&1 || true
    finish_all merge-stuck "$(printf '🛑 agent-pr-merger: could not auto-resolve rebase conflicts while integrating PR #%s (%s) — needs a human.' "$n" "$head")"
    exit 0
  fi
  # Capture the rebased tip so we can force-push the PR head branch to it after the push to
  # main — rebasing rewrites SHAs, and GitHub only auto-closes a PR when its head commit is
  # reachable from the base branch.
  PR_REBASED_SHAS[$i]="$(git rev-parse "$rb" 2>/dev/null || echo "")"

  # ── (b) Merge the rebased branch into the integration. Clean by construction for a branch
  #        that was merely behind main; only a real PR-vs-PR conflict can still occur.
  log "merging PR #${n} (${head})…"
  if git "${GIT_ID[@]}" merge --no-ff --no-edit -m "merge: PR #${n} (${head})" "$rb" >/dev/null 2>>"${LOGDIR}/merge-${n}.log"; then
    git branch -D "$rb" >/dev/null 2>&1 || true
    merged_nums+=("$n"); continue
  fi

  conflicted="$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"

  # ── Generated files (index, digest) will ALWAYS conflict when two PRs in the batch
  # each regenerate them — the same pattern #2168 fixed for the iteration log itself.
  # Never waste a resolver call on them; regenerate after the merge loop instead. ──
  _real_conflicts="$(echo "$conflicted" | tr ' ' '\n' | grep -vE '^(docs/06-iteration-log\.md|docs/06-iteration-log\.digest\.md|state/state\.json)$' || true)"
  if [ -z "$_real_conflicts" ] && [ -n "${conflicted// /}" ]; then
    log "PR #${n}: conflicts are only in regeneratable files (${conflicted}) — auto-resolving, regenerate post-loop"
    # Take theirs over the ACTUAL unmerged set, and verify it worked — `git checkout --theirs`
    # silently updates 0 paths and exits 0 whenever a path has no unmerged stages, so committing on
    # the strength of its exit code is how marker text gets baked into an integration commit.
    # shellcheck disable=SC2206  # deliberate word-split of the space-separated conflicted list
    _gen_files=( $conflicted )
    if ! take_theirs_verified "${_gen_files[@]}"; then
      log "PR #${n}: could not auto-resolve the regeneratable files (${conflicted}) — aborting integration"
      git merge --abort >/dev/null 2>&1 || true
      git branch -D "$rb" >/dev/null 2>&1 || true
      finish_all merge-stuck "$(printf '🛑 agent-pr-merger: the only conflicts while integrating PR #%s (%s) were in regeneratable files (%s), but they could not be auto-resolved — needs a human.' "$n" "$head" "$conflicted")"
      exit 0
    fi
    git "${GIT_ID[@]}" commit --no-edit -m "merge: PR #${n} (${head}) — generated files auto-resolved" >/dev/null 2>&1 || true
    git branch -D "$rb" >/dev/null 2>&1 || true
    merged_nums+=("$n"); continue
  fi

  # PR-vs-PR conflict — ask the resolver (model M) to reconcile INCLUDING every PR's work.
  # invoke_resolver retries up to MERGER_RESOLVER_RETRIES (3) with escalating strategies.
  log "PR #${n}: conflict — invoking resolver model ${MERGER_MODEL} to include all work…"
  cls="$(invoke_resolver "$n" "$head" merge "$conflicted" "${LOGDIR}/agent-merge-${n}.json" | tail -n1)"

  case "$cls" in
    transient)
      log "resolver hit a transient limit (rate-limit/usage-limit/overload) while integrating PR #${n} — deferring; PRs return to review-approved, retry next tick"
      git merge --abort >/dev/null 2>&1 || true
      git branch -D "$rb" >/dev/null 2>&1 || true
      for p in "${PR_NUMS[@]:-}"; do [ -n "$p" ] || continue; add_label "$p" review-approved; remove_label "$p" merge-wip; done
      exit 0
      ;;
    ok) ;;   # resolved — fall through to the commit below
    *)
      # `stuck`, and ALSO anything unrecognised: the arms used to be transient/stuck with an
      # implicit "everything else is resolved", so a single corrupted verdict silently merged an
      # unresolved conflict. Fail closed.
      log "PR #${n}: conflicts could not be resolved after retries (resolver verdict: '${cls}') — aborting integration"
      git merge --abort >/dev/null 2>&1 || true
      git branch -D "$rb" >/dev/null 2>&1 || true
      finish_all merge-stuck "$(printf '🛑 agent-pr-merger: could not auto-resolve conflicts while integrating PR #%s (%s) after retries — needs a human.' "$n" "$head")"
      exit 0
      ;;
  esac
  # ok — resolved, commit and continue
  git "${GIT_ID[@]}" commit --no-edit -m "merge: PR #${n} (${head}) — conflicts resolved to include all work" >/dev/null 2>&1 || true
  git branch -D "$rb" >/dev/null 2>&1 || true
  merged_nums+=("$n")
done

# ── Regenerate generated files so they never carry stale merge-resolution content.
# Multiple PRs in a batch each create their own docs/iterations/ file but also
# regenerate the shared index and digest — the merge above may have auto-resolved
# them, but the result is stale. Rebuild from the directory so the output is
# deterministic and correct regardless of merge order (#2168 follow-up). ──
if [ -x scripts/generate-iteration-index.sh ]; then
  scripts/generate-iteration-index.sh >/dev/null 2>&1 || true
fi
if [ -x scripts/iteration-digest.sh ]; then
  scripts/iteration-digest.sh --seed-from-log >/dev/null 2>&1 || true
fi
# Commit the regenerated files if they changed.
if ! git diff --quiet -- docs/06-iteration-log.md docs/06-iteration-log.digest.md 2>/dev/null; then
  git add docs/06-iteration-log.md docs/06-iteration-log.digest.md state/state.json 2>/dev/null || true
  git "${GIT_ID[@]}" commit -q -m "chore: regenerate iteration index and digest post-integration" >/dev/null 2>&1 || true
fi

# ── No-op guard: nothing actually integrated beyond base ──────────────────────────
if [ "$(git rev-parse HEAD)" = "$base_sha" ]; then
  log "integration produced no new commits over ${BASE} — nothing to merge"
  finish_all merge-stuck "⚠️ agent-pr-merger: integrating the approved PR(s) produced no change over ${BASE} — needs a human."
  exit 0
fi

# ── Provision deps the gates need (fresh worktree has no node_modules) ────────────
# The repo is an npm-WORKSPACES monorepo (frontend, mobile, packages/*), so provisioning
# runs at the WORKTREE ROOT — the old frontend-only install left `mobile/` without deps and
# every mobile vitest file died in <1s on `extends: expo/tsconfig.base` (the PR #1926 false
# positive). Per the #1829 lesson, provisioning is LOUD (no --silent) and a failure is
# ROUTED, never `|| true`-swallowed into a phantom "test failure". Backend Python deps come
# from the active conda/venv on PATH; the full-stack e2e gate boots its own compose stack.
#
# …and then VERIFIED (#2438). `npm ci` exiting 0 is not evidence the install landed: on
# 2026-08-01 the integration worktree came up with `mobile/` short of `expo`, all 154 mobile
# suites died at transform time on `extends: expo/tsconfig.base`, the `unit` gate went red — and
# because a missing package is perfectly deterministic, the base re-run and the anti-flake
# confirmation re-run reproduced it exactly. The merger concluded `main` was red, parked the
# queue at `merge-stuck` and filed a p0 issue against a `main` whose unit gate is green (#2438).
# agent-inbox has had this check since #2124; it lives in lib/deps-verify.sh now so the merger
# and fixer cannot drift from it again.
#
# Exit codes: 0 healthy · 1 the install command itself failed (route to the fix loop)
#             3 the tree is STILL unresolvable after a repair — nobody's PR can fix that, so
#               the caller defers it as environmental rather than blaming a PR or `main`.
DEPS_MISSING=""
provision_deps() {
  local d rc=0
  if [ "$DEPS_MODE" = "symlink" ]; then
    # Mirror every node_modules the primary checkout has (root + each workspace).
    for d in . frontend mobile packages/*; do
      [ -d "$ROOT/$d/node_modules" ] || continue
      [ -d "$wt/$d" ] || continue
      [ -e "$wt/$d/node_modules" ] || ln -s "$ROOT/$d/node_modules" "$wt/$d/node_modules" 2>/dev/null || rc=1
    done
    [ "$rc" = 0 ] || return $rc
    # Verify but never REPAIR here: `npm install` inside $wt would write THROUGH the symlinks
    # into the host's shared node_modules — the corruption class this mode's comment warns
    # about. A broken host install is still environmental, so report it as such.
    DEPS_MISSING="$(deps_unresolved_summary "$wt")"
    if [ -n "$DEPS_MISSING" ]; then
      # No npm command ever ran on this path, so deps-integration.log would otherwise stay empty —
      # and defer_batch/route_red_integration `tail` it straight into the PR comment/issue body.
      printf 'deps (symlink mode): host install mirrored, never repaired; still unresolved: %s\n' \
        "$DEPS_MISSING" >>"${LOGDIR}/deps-integration.log"
      return 3
    fi
    return 0
  fi
  [ -f "$wt/package.json" ] || return 0
  if [ -f "$wt/package-lock.json" ]; then
    ( cd "$wt" && npm ci --no-audit --no-fund ) >>"${LOGDIR}/deps-integration.log" 2>&1; rc=$?
  else
    ( cd "$wt" && npm install --no-audit --no-fund ) >>"${LOGDIR}/deps-integration.log" 2>&1; rc=$?
  fi
  # npm may rewrite lockfiles; never let that leak into the pushed integration.
  git -C "$wt" checkout -q -- package-lock.json frontend/package-lock.json >/dev/null 2>&1 || true
  [ "$rc" = 0 ] || return $rc
  DEPS_MISSING="$(deps_unresolved_summary "$wt")"
  if [ -n "$DEPS_MISSING" ]; then
    log "deps: incomplete install (repairing) — unresolved: ${DEPS_MISSING}"
    printf 'deps: unresolved after provisioning: %s\ndeps: repairing with npm install…\n' \
      "$DEPS_MISSING" >>"${LOGDIR}/deps-integration.log"
    ( cd "$wt" && npm install --no-audit --no-fund ) >>"${LOGDIR}/deps-integration.log" 2>&1 \
      || log "deps: repair npm install failed (see deps-integration.log)"
    git -C "$wt" checkout -q -- package-lock.json frontend/package-lock.json >/dev/null 2>&1 || true
    DEPS_MISSING="$(deps_unresolved_summary "$wt")"
  fi
  [ -z "$DEPS_MISSING" ] || return 3
  return 0
}

# ── Provision local env-files the gates need (symlinked, never committed) ─────────
shopt -s nullglob
for src in "$ROOT"/.env "$ROOT"/.env.local "$ROOT"/.gcp "$ROOT"/backend/.env "$ROOT"/backend/.env.local "$ROOT"/frontend/.env "$ROOT"/frontend/.env.local; do
  [ -e "$src" ] || continue
  rel="${src#"$ROOT"/}"; dst="$wt/$rel"
  [ -e "$dst" ] || { mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" 2>/dev/null; } || true
done
shopt -u nullglob

# ── Route a red integration back into the reviewer⇄fixer loop ─────────────────────
# The merger used to dead-end EVERY red integration at `merge-stuck` (human). Now the
# failure re-enters the existing fix loop: comment the failure log with the
# "agent-pr-merger: INTEGRATION GATES FAILED" marker (agent-pr-fixer treats it as
# findings) and label `changes-requested`. The fixer fixes → re-gates → review-needed →
# reviewer → review-approved → the merger retries — iterating until merged. The fixer's
# round cap (PR_MAX_ROUNDS) still bounds the loop → review-stuck → human; no ping-pong.
#
# Blame: with ONE PR the failure is its own. With a BATCH blame is ambiguous — blame the
# LOWEST-numbered PR deterministically and requeue the rest as review-approved: next tick
# integrates the rest WITHOUT it, so innocent PRs still ship, and a mis-blamed PR
# self-corrects through the fixer's no-change-justification path (#1767).
route_red_integration() { # <log-file> <what: gates|deps provisioning>
  local logf="$1" what="$2" first="${PR_NUMS[0]}" p batch_note=""
  if [ "${#PR_NUMS[@]}" -gt 1 ]; then
    batch_note="$(printf '\nThis PR is the lowest-numbered of the batch (%s) and is blamed deterministically; the rest were requeued and will integrate without it. If the failure is not yours, justify a no-change and hand back to review.\n' "${PR_NUMS[*]}")"
  fi
  "$GH" pr comment "$first" -b "$(printf '🛑 **agent-pr-merger: INTEGRATION GATES FAILED** (%s) — routing to agent-pr-fixer.\n%s\n### Findings (address each, then the fixer hands back for re-review)\n- the integration of this PR onto %s failed %s; make the gates pass. Failure log (tail):\n\n```\n%s\n```' \
    "$what" "$batch_note" "$BASE" "$what" "$(tail -25 "$logf" 2>/dev/null)")" >/dev/null 2>&1 || true
  add_label "$first" changes-requested; remove_label "$first" merge-wip
  for p in "${PR_NUMS[@]}"; do
    [ "$p" = "$first" ] && continue
    add_label "$p" review-approved; remove_label "$p" merge-wip
  done
}

# Gate names the summary block reported as failed, e.g. "  unit           fail  see …" → "unit".
# quality-gates.sh prints one such line per gate; anything else in the log is ignored, so a
# GATES_CMD that is not quality-gates.sh (tests, custom hooks) simply yields nothing and the
# caller falls back to trusting its single sample.
failed_gates() { # <gate-log>
  [ -f "$1" ] || return 0
  awk '$2 == "fail" { print $1 }' "$1" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# GATES_CMD narrowed to a subset of gates: rewrite an existing `--only <list>`, or append one.
# When no gates are specified (non-quality-gates.sh commands, custom test hooks), returns the
# original command unchanged so the isolation test runs the same check that failed in integration.
gates_cmd_only() { # <space-separated gates>
  local only="${1// /,}"
  [ -z "$only" ] && { printf '%s' "$GATES_CMD"; return; }
  if printf '%s' "$GATES_CMD" | grep -q -- '--only'; then
    printf '%s' "$GATES_CMD" | sed -E "s/--only[[:space:]]+[^[:space:]]+/--only ${only}/"
  else
    printf '%s --only %s' "$GATES_CMD" "$only"
  fi
}

# ── Is a gate failure ENVIRONMENTAL rather than a code defect? ────────────────────
# The merger only knew two outcomes: "integration red, base green" → the PRs did it → self-repair;
# "integration red, base red" → main did it → merge-stuck, no retry, human required. A third case
# exists and was being funnelled into the second: the gates could not RUN.
#
# Observed 2026-07-26. Nine integration modules each start their own testcontainers Postgres in a
# module-scoped fixture and immediately shell out to `alembic upgrade head`; under load the box
# cannot bring a container to listening before alembic dials it and the fixture dies at setup with
# `ConnectionRefusedError: [Errno 111] Connect call failed`. Six consecutive runs failed that way,
# on DIFFERENT modules each time and with error counts scaling with load (2 → 9 → 14 → 15 → 20 → 36)
# — the signature of resource starvation, not of a bug. Because the base run hits the same
# starvation, base_is_red() returned true and the batch was parked at merge-stuck with
# "no PR is at fault; a human must fix main" — an accusation against main that was simply false, and
# which no retry or self-repair could ever clear because nothing was broken in the code.
#
# So: classify first. A transient/infra signature means DEFER — hand the PRs back as
# review-approved and let the next tick try again on a quieter box. Reuses the same vocabulary as
# agent-triage-failure.sh's is_transient(), plus the container-startup shapes this gate produces.
# PR_MERGER_TRANSIENT_DEFER=0 restores the old always-blame behaviour.
#
# Deps are the SECOND environmental shape, and the more dangerous one because it is perfectly
# deterministic — the anti-flake confirmation re-run reproduces it exactly, so it survives every
# guard built for flakes (#2438). Rather than pattern-match the log (a real deleted import also
# says "Cannot find module" and must NOT be excused), re-measure the tree itself: if a declared
# workspace's tsconfig cannot resolve the package it extends AT THE MOMENT THE GATES WENT RED,
# every JS suite in it died at module-load time and the red says nothing about the code. This
# catches an install that was evicted mid-run — e.g. a per-package `npm ci` in a concurrent
# stage, which resolves the root lockfile but installs only its own subtree, deleting what the
# sibling workspaces needed.
gate_failure_is_deps() { # → 0 when the worktree's workspaces are unresolvable right now AND every
                          # missing package is actually DECLARED somewhere — an install gap, not a
                          # PR that removed the dependency (or added a consumer without declaring
                          # it). A missing-but-undeclared package is a code defect: it must fall
                          # through to the ordinary base-red / self-repair path, not be excused as
                          # environmental (see lib/deps-verify.sh deps_unresolved_all_declared).
  [ "${PR_MERGER_DEPS_DEFER:-1}" = 1 ] || return 1
  DEPS_MISSING="$(deps_unresolved_summary "$wt")"
  [ -n "$DEPS_MISSING" ] || return 1
  deps_unresolved_all_declared "$wt"
}

gate_failure_is_transient() { # <log-file>
  local f="${1:-}"
  [ -f "$f" ] || return 1
  grep -qiE \
    'connectionrefusederror|connect call failed|cannot connect to the docker daemon|is the docker daemon running|docker daemon unreachable|no space left on device|oomkilled|error pulling image|manifest unknown|toomanyrequests|temporary failure in name resolution|network is unreachable|i/o timeout|tls handshake timeout|connection reset by peer|container did not start|failed to start container|error response from daemon' \
    "$f"
}

# Defer the whole batch without blaming anyone: drop the claim, restore review-approved, exit. The
# next tick re-selects them, and (since iteration 352) rebases onto whatever main has become.
# Bounded. Deferring restores review-approved, so the next tick re-selects the same batch — if the
# box stays starved this would defer forever, making no progress and saying nothing. After
# PR_MERGER_MAX_ENV_DEFER consecutive environmental deferrals the batch goes merge-stuck with an
# ENVIRONMENT diagnosis (not "main is red"), so a human is told what to actually fix. The counter is
# the number of marker comments already on the first PR of the batch — no extra state to lose.
MERGER_MAX_ENV_DEFER="${PR_MERGER_MAX_ENV_DEFER:-3}"
ENV_DEFER_MARKER="<!-- merger-env-defer -->"

env_defer_count() { # prior environmental deferrals recorded on the batch
  local first="${PR_NUMS[0]:-}" c
  [ -n "$first" ] || { echo 0; return; }
  c="$("$GH" pr view "$first" --json comments \
        --jq "[.comments[] | select(.body | contains(\"$ENV_DEFER_MARKER\"))] | length" 2>/dev/null)"
  [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo 0
}

defer_batch() { # <reason> <log-file> [class: transient|deps — which remedy to print at the cap]
  local reason="$1" f="${2:-}" class="${3:-transient}" p n remedy
  n="$(env_defer_count)"
  if [ "$n" -ge "$MERGER_MAX_ENV_DEFER" ]; then
    log "environmental gate failure persisted across ${n} deferral(s) — merge-stuck on the ENVIRONMENT"
    # The two environmental shapes need different fixes, and telling a human to chase the wrong
    # one is the same misattribution class this whole file exists to close (#2438): a Docker
    # remedy sent to someone staring at an unresolved npm workspace wastes the escalation.
    if [ "$class" = deps ]; then
      remedy="a workspace dependency is not installed. Run a root \`npm ci\` (not a per-package one — that installs only its own subtree and evicts its siblings, #2395) and verify with \`scripts/lib/deps-verify.sh\` before re-approving."
    else
      remedy="the test environment cannot start. Nine integration modules each boot their own testcontainers Postgres, so the usual cause is Docker resource starvation — lower \`ITEST_XDIST_MAX\` or \`QG_SLOTS\`, or free memory/disk, then re-approve."
    fi
    finish_all merge-stuck "$(printf '🛑 agent-pr-merger: the gates have failed to RUN %s times in a row — %s. This is NOT a defect in this PR and NOT `%s` being red: %s\n\n```\n%s\n```' "$n" "$reason" "$BASE" "$remedy" "$(tail -20 "$f" 2>/dev/null)")"
    exit 0
  fi
  log "gate failure looks ENVIRONMENTAL (${reason}) — deferring the batch (${n}/${MERGER_MAX_ENV_DEFER}), not blaming main"
  for p in "${PR_NUMS[@]:-}"; do
    [ -n "$p" ] || continue
    "$GH" pr comment "$p" -b "$(printf '⏳ agent-pr-merger: the gates could not RUN — %s. This is an environment failure, not a defect in this PR or in `%s`, so nothing is being blamed and no self-repair attempt was consumed. The batch is handed back as `review-approved` and the next tick will retry on a quieter box (rebasing onto the latest `%s` first). (environmental deferral %s/%s)\n\n```\n%s\n```\n%s' "$reason" "$BASE" "$BASE" "$((n+1))" "$MERGER_MAX_ENV_DEFER" "$(tail -20 "$f" 2>/dev/null)" "$ENV_DEFER_MARKER")" >/dev/null 2>&1 || true
    add_label "$p" review-approved; remove_label "$p" merge-wip
  done
}

# Discriminate "the PRs broke it" from "main was already red" (humans can push to main
# ungated). Re-run the SAME gates on the bare base: red base → no PR is at fault, and the
# fixer cannot repair main from a PR branch → merge-stuck (a human fixes main).
#
# A red first sample is CONFIRMED before it is believed (#2175). One noisy run must not be able
# to wedge the entire merge queue, and it did: on 2026-07-26 PRs #2154/#2162/#2165 were all
# marked merge-stuck at 30691a6 because seven mobile tests blew a 5000ms timeout on dynamic
# `await import()` calls while the box was saturated — the same seven pass in 783ms and main was
# never broken. The confirmation re-runs ONLY the gates the first sample reported as failed
# (`unit` alone is ~90s against ~25min for the full set), so the cost is small and paid only on
# the already-exceptional red-base path. Green on the re-run ⇒ flake ⇒ the base is green and the
# PRs are judged normally. `PR_MERGER_CONFIRM_BASE_RED=0` restores the single-sample behaviour.
BASE_DEPS_BROKEN=0
base_is_red() {
  BASE_DEPS_BROKEN=0
  git checkout -q --detach "$base_sha" >/dev/null 2>&1 || return 1
  local rc=0 failed confirm_cmd
  bash -c "$GATES_CMD" >"${LOGDIR}/gates-base.log" 2>&1 || rc=1
  if [ "$rc" = 1 ]; then
    # Environmental failure (container starvation, Docker unreachable) → base is NOT
    # red, just unlucky. Return green so the caller defers the integration instead of
    # accusing main. A genuine code bug never matches the transient signature.
    if [ "${PR_MERGER_TRANSIENT_DEFER:-1}" = 1 ] && gate_failure_is_transient "${LOGDIR}/gates-base.log"; then
      log "base gate failure looks ENVIRONMENTAL (container/Docker transient) — treating ${BASE} as green rather than red; a second environmental hit in the integration check defers the batch"
      git checkout -q "$INTEGRATION_BRANCH" >/dev/null 2>&1 || true
      return 1  # 1 = not red (green)
    fi
    # Same reasoning for an unresolvable workspace install, and checked HERE too rather than only
    # before the call: this run detaches to the base and re-runs the gates, so the tree can be
    # evicted between the two measurements. Never confirm a red base against a tree that cannot
    # load its own modules — that is the exact verdict that wedged the queue in #2438.
    if gate_failure_is_deps; then
      log "base gate failure is a DEPS failure (unresolved: ${DEPS_MISSING}) — the JS suites never ran, so this says nothing about ${BASE}; deferring instead of blaming anyone"
      BASE_DEPS_BROKEN=1
      git checkout -q "$INTEGRATION_BRANCH" >/dev/null 2>&1 || true
      return 1  # 1 = not red (green) — the caller sees BASE_DEPS_BROKEN and defers
    fi
    if [ "${PR_MERGER_CONFIRM_BASE_RED:-1}" = 1 ]; then
      failed="$(failed_gates "${LOGDIR}/gates-base.log")"
      if [ -n "$failed" ]; then
        confirm_cmd="$(gates_cmd_only "$failed")"
        log "base looks red on [${failed}] — re-running just those gates to rule out a flake"
        if bash -c "$confirm_cmd" >"${LOGDIR}/gates-base-confirm.log" 2>&1; then
          rc=0
          log "base re-run of [${failed}] PASSED — the first sample was a flake; treating ${BASE} as green"
        else
          log "base re-run of [${failed}] failed too — ${BASE} is genuinely red"
        fi
      else
        log "could not parse failed gate names from the base log — trusting the single sample"
      fi
    fi
  fi
  git checkout -q "$INTEGRATION_BRANCH" >/dev/null 2>&1 || true
  return $((1 - rc))
}

# A confirmed-red base has no owner: the fixer repairs PR branches, not main, so `merge-stuck`
# is where the queue stops. `rearm_stuck_prs()` only releases those PRs when main ADVANCES, and
# nothing was making it advance — so the queue stayed wedged until a human noticed (#2175).
# File an `agent` issue instead: agent-inbox builds the fix, main advances, and the re-arm frees
# the stuck PRs without anyone watching. Deduped by the failing-gate set (NOT the base SHA, which
# changes on every commit and would file one issue per tick).
# `PR_MERGER_FILE_BASE_RED_ISSUE=0` disables it.
file_base_red_issue() { # <failed-gates> <gate-log>
  [ "${PR_MERGER_FILE_BASE_RED_ISSUE:-1}" = 1 ] || return 0
  local gates="${1:-unknown}" logf="$2" marker existing body
  marker="<!-- merger-base-red:${gates// /,} -->"
  existing="$("$GH" issue list --state open --label agent --search "$marker in:body" \
    --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    log "base-red issue for [${gates}] already open (#${existing}) — not filing a duplicate"
    return 0
  fi
  body="$(printf '`%s` is red at `%s` with no PR applied, so agent-pr-merger stopped the merge queue (`merge-stuck`) — the fixer repairs PR branches, not `%s`, so nothing else can clear this.\n\nFailing gate(s): **%s** (confirmed by a second targeted run — this is not a flake).\n\nFix `%s` so the gate passes. Every approved PR is blocked until it does; `agent-pipeline` re-arms them automatically once `%s` advances.\n\n```\n%s\n```\n\n%s' \
    "$BASE" "${base_sha:0:12}" "$BASE" "$gates" "$BASE" "$BASE" "$(tail -30 "$logf" 2>/dev/null)" "$marker")"
  if "$GH" issue create \
      --title "$(printf '%s is red: %s gate failing at %s — merge queue blocked' "$BASE" "$gates" "${base_sha:0:12}")" \
      --body "$body" --label agent --label p0 >/dev/null 2>&1; then
    log "filed an agent issue for the red ${BASE} ([${gates}]) — the inbox will build the fix"
  else
    log "WARN: could not file the base-red issue — ${BASE} still needs a human"
  fi
}

provision_rc=0; provision_deps || provision_rc=$?
if [ "$provision_rc" = 3 ]; then
  # The install command succeeded and the tree is STILL missing packages. If that package is
  # DECLARED (a real install gap), no PR can fix it and `main` is not at fault, so this must never
  # reach the gates: it would fail the integration AND the base identically and be diagnosed as
  # "main is red" (#2438). Defer as environmental.
  #
  # But an unresolved package that is declared NOWHERE was never going to be there — a PR that
  # deleted it from package.json (or added a consumer without declaring it) broke the tree itself.
  # That is indistinguishable from a real install gap by `deps_unresolved_summary` alone (both
  # produce the identical "cannot resolve expo (mobile)" signature), so excusing it here would let
  # a PR that breaks its own dependency graph hide behind the same defer forever. Route it through
  # the ordinary red-integration path instead, exactly like any other gate failure the PR caused.
  if deps_unresolved_all_declared "$wt"; then
    if [ "$DEPS_MODE" = "symlink" ]; then
      log "deps: workspace(s) unresolved in the mirrored host install (${DEPS_MISSING}) — symlink mode never repairs, so this reports the host's own state; ENVIRONMENTAL, deferring the batch (not blaming ${BASE} or any PR)"
    else
      log "deps: workspace(s) still unresolved after repair (${DEPS_MISSING}) — ENVIRONMENTAL, deferring the batch (not blaming ${BASE} or any PR)"
    fi
    defer_batch "the integration worktree's workspace dependencies could not be provisioned (unresolved: ${DEPS_MISSING}) — the gates would fail at module-load time in every JS suite, which is not a code defect" \
      "${LOGDIR}/deps-integration.log" deps
    exit 0
  fi
  log "deps: workspace(s) unresolved (${DEPS_MISSING}) but the missing package is DECLARED NOWHERE — not an install gap, a code defect; routing to the fix loop instead of excusing it as environmental"
  route_red_integration "${LOGDIR}/deps-integration.log" "deps provisioning (undeclared dependency)"
  exit 0
elif [ "$provision_rc" != 0 ]; then
  log "deps provisioning FAILED (see ${LOGDIR}/deps-integration.log) — routing to the fix loop, not merging"
  route_red_integration "${LOGDIR}/deps-integration.log" "deps provisioning"
  exit 0
fi

# ── Gate the COMBINED result. A red integration is never merged. ──────────────────
# Self-repair: on integration gate failure (base green), fix directly in the integration
# worktree instead of routing back through the review→fix→merge loop.
# Re-link the git-IGNORED env/cred files the gates need. Called after anything that rewrites the
# worktree (a self-repair commit's `git reset`, a rebase onto a moved base) so the next gate run
# still finds them. Idempotent.
reprovision_env_links() {
  local src rel dst
  shopt -s nullglob
  for src in "$ROOT"/.env "$ROOT"/.env.local "$ROOT"/.gcp "$ROOT"/backend/.env "$ROOT"/backend/.env.local "$ROOT"/frontend/.env "$ROOT"/frontend/.env.local; do
    [ -e "$src" ] || continue
    rel="${src#"$ROOT"/}"; dst="$wt/$rel"
    [ -e "$dst" ] || { mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" 2>/dev/null; } || true
  done
  shopt -u nullglob
}

# ── Keep the integration on the LATEST base across retries ────────────────────────
# base_ref/base_sha are captured ONCE, before the first gate run. With the widened gate set one
# attempt is ~20-30 min and MERGER_MAX_SELF_REPAIR allows three, so a run routinely spans an hour
# while `main` moves underneath it. Re-gating a stale integration is wrong twice over:
#   • it fails on defects main has ALREADY fixed, burning the self-repair budget on nothing —
#     observed on PR #2154, where two attempts hit the identical e2e specs and made no progress;
#   • the closing fast-forward is refused because main advanced → merge-stuck after all that work.
# So every retry re-fetches and, when the base has moved, rebases the integration onto it BEFORE
# re-gating, reusing the same resolver the initial per-PR rebase uses so a conflict against the new
# base is resolved once rather than re-hit on every attempt. base_is_red() then evaluates the NEW
# base too, since it reads $base_sha.
# Returns 0 only when it actually rebased, so the caller re-gates BEFORE judging anyone. Ordering
# matters: base_is_red() reads $base_sha, so evaluating it first would run the gates on the STALE
# base and, when the new main is what fixes the failure, wrongly conclude "main itself is red" and
# go merge-stuck. Caught by J-MG-16 while building this.
# Bounded by PR_MERGER_MAX_REBASE_RETRY so a rapidly-moving main cannot spin the loop.
# PR_MERGER_REBASE_ON_RETRY=0 restores the old stale-base behaviour.
MERGER_MAX_REBASE_RETRY="${PR_MERGER_MAX_REBASE_RETRY:-2}"
merger_rebase_retries=0
refresh_integration_base() {
  [ "${PR_MERGER_REBASE_ON_RETRY:-1}" = 1 ] || return 1
  [ "$merger_rebase_retries" -lt "$MERGER_MAX_REBASE_RETRY" ] || return 1
  git fetch -q "$REMOTE" "$BASE" >/dev/null 2>&1 || return 1
  local new_sha st
  new_sha="$(git rev-parse "$base_ref" 2>/dev/null || echo "")"
  [ -n "$new_sha" ] || return 1
  [ "$new_sha" != "$base_sha" ] || return 1
  merger_rebase_retries=$((merger_rebase_retries + 1))

  log "${BASE} advanced ${base_sha:0:12} → ${new_sha:0:12} mid-run — rebasing the integration before retrying"
  base_sha="$new_sha"
  st="$(rebase_onto_base integration "$INTEGRATION_BRANCH")"
  case "$st" in
    ok)
      log "integration rebased onto the new ${BASE} (${base_sha:0:12}) — re-gating"
      # The rebase may have stripped provisioned env symlinks' targets from the index; re-link so
      # the next gate run still finds them (same treatment the self-repair commit path applies).
      reprovision_env_links
      return 0
      ;;
    transient)
      # The resolver never ran (rate/usage limit). Defer without consuming an attempt — the next
      # tick starts from a fresh base anyway.
      log "conflict resolver hit a transient limit while rebasing onto the new ${BASE} — deferring"
      local p
      for p in "${PR_NUMS[@]:-}"; do [ -n "$p" ] || continue; add_label "$p" review-approved; remove_label "$p" merge-wip; done
      exit 0
      ;;
    *)
      log "integration could not be rebased onto the new ${BASE} — merge-stuck"
      finish_all merge-stuck "$(printf '🛑 agent-pr-merger: `%s` advanced to %s mid-run and the integration could not be rebased onto it (unresolvable conflict). Nothing was merged. Rebase onto the latest `%s` and re-approve.\n\n```\n%s\n```' "$BASE" "${base_sha:0:12}" "$BASE" "$(tail -25 "${LOGDIR}/rebase-integration.log" 2>/dev/null)")"
      exit 0
      ;;
  esac
}

log "running full gates on the integration: ${GATES_CMD}"
merger_repair_attempt=0
while true; do
  if bash -c "$GATES_CMD" >"${LOGDIR}/gates-integration.log" 2>&1; then
    break   # green — proceed to fast-forward
  fi

  log "integration gates FAILED — not merging"

  # Before blaming anyone: if `main` moved under this run, rebase onto it and re-gate. A stale
  # integration fails on defects the new main has already fixed, and judging base_is_red() against
  # the old SHA would pin that on main.
  if refresh_integration_base; then continue; fi

  # Then: could the gates even RUN? An environmental failure (container starvation, docker daemon,
  # disk) fails the integration AND the base identically, so base_is_red() would call it "main is
  # red" and park the batch at merge-stuck forever — an accusation no self-repair can clear because
  # no code is broken. Defer instead and retry next tick.
  if [ "${PR_MERGER_TRANSIENT_DEFER:-1}" = 1 ] \
     && gate_failure_is_transient "${LOGDIR}/gates-integration.log"; then
    defer_batch "the test environment could not start (see the log tail)" "${LOGDIR}/gates-integration.log"
    exit 0
  fi
  if gate_failure_is_deps; then
    defer_batch "the worktree's workspace dependencies are unresolvable (${DEPS_MISSING}), so every JS suite failed at module-load time" \
      "${LOGDIR}/gates-integration.log" deps
    exit 0
  fi

  if base_is_red; then
    base_red_gates="$(failed_gates "${LOGDIR}/gates-base.log")"
    log "…but ${BASE} itself is red at ${base_sha} — no PR is at fault; filing an issue so the inbox fixes ${BASE}"
    file_base_red_issue "$base_red_gates" "${LOGDIR}/gates-base.log"
    finish_all merge-stuck "$(printf '🛑 agent-pr-merger: integration gates failed, but **%s itself is red** at %s (the same gates fail with no PR applied, confirmed by a second targeted run). No PR is at fault. An `agent` issue has been filed to fix %s; this PR is re-armed automatically once %s advances.\n\n```\n%s\n```' "$BASE" "${base_sha:0:12}" "$BASE" "$BASE" "$(tail -25 "${LOGDIR}/gates-base.log")")"
    exit 0
  fi
  # base_is_red() reports "not red" when the base run itself could not load its modules — but the
  # PRs are not to blame either, and falling through to self-repair would spend the whole repair
  # budget on a tree that cannot compile. Defer the batch instead.
  if [ "${BASE_DEPS_BROKEN:-0}" = 1 ]; then
    defer_batch "the worktree's workspace dependencies became unresolvable (${DEPS_MISSING}) while re-running the gates on ${BASE}, so neither result is a verdict on any code" \
      "${LOGDIR}/gates-base.log" deps
    exit 0
  fi

  # ── Integration red, base green — the combined PRs introduced the failure.
  # Self-repair (if enabled): isolate which PR is at fault, fix in that PR's own
  # worktree (never the shared integration), then rebuild. This prevents one PR's
  # self-repair from poisoning the batch (#2175 follow-up).
  if [ "${MERGER_SELF_REPAIR:-1}" != "1" ]; then
    route_red_integration "${LOGDIR}/gates-integration.log" gates
    exit 0
  fi

  merger_repair_attempt=$((merger_repair_attempt + 1))
  if [ "$merger_repair_attempt" -gt "$MERGER_MAX_SELF_REPAIR" ]; then
    log "integration gates still red after ${MERGER_MAX_SELF_REPAIR} self-repair attempt(s) — routing each PR to its fixer"
    # Route each PR individually instead of merge-stuck on the batch.
    for p in "${PR_NUMS[@]:-}"; do
      [ -n "$p" ] || continue
      add_label "$p" changes-requested; remove_label "$p" merge-wip
      "$GH" pr comment "$p" -b "$(printf '🛑 agent-pr-merger: integration gates failed after %s self-repair attempt(s).\n\nThis PR has been routed to its fixer. When the fixer pushes, the pipeline will re-integrate.\n\n```\n%s\n```' "$MERGER_MAX_SELF_REPAIR" "$(tail -25 "${LOGDIR}/gates-integration.log")")" >/dev/null 2>&1 || true
    done
    exit 0
  fi

  # ── Strip the previous failed self-repair commit (if any) before the next attempt.
  # Without this, each attempt layers on top of the last — three wrong fixes
  # accumulate and the model never starts fresh (#2175 follow-up). ──
  if [ "$merger_repair_attempt" -gt 1 ]; then
    _last_merge_commit="$(git log --format='%H' --grep='^merge: PR #' --max-count=1 2>/dev/null || echo "")"
    if [ -n "$_last_merge_commit" ]; then
      log "stripping previous self-repair attempt(s) — resetting to ${_last_merge_commit:0:12}"
      git reset --hard "$_last_merge_commit" >/dev/null 2>&1 || true
    fi
  fi

  # ── Isolate: which PR(s) in the batch are breaking the gates? Test each PR
  # individually against the base (one at a time, cheapest gate set first). If
  # every PR passes alone, the failure is a genuine PR-vs-PR interaction — no
  # self-repair can fix that, so route all to a human. ──
  failing_prs=()
  for i in "${!PR_NUMS[@]}"; do
    _ipn="${PR_NUMS[$i]}"; _iph="${PR_HEADS[$i]}"
    _iso_branch="agent/isolate-${_ipn}"
    log "isolating PR #${_ipn}: testing individually on ${base_sha:0:12}"
    git checkout -q -B "$_iso_branch" "$base_sha" >/dev/null 2>&1 || continue
    # Merge this single PR onto the base (--no-edit, accept theirs on conflict — we
    # only need to know if the result is green; real conflicts are handled at
    # integration time).
    if ! git merge --no-edit -X theirs "$_iph" >/dev/null 2>&1; then
      # Conflicts even in isolation — this PR can't be tested alone. Skip isolation,
      # assume it contributes to the failure.
      log "PR #${_ipn}: conflicts in isolation — skipping individual test"
      git merge --abort >/dev/null 2>&1 || true
      failing_prs+=("$_ipn")
      continue
    fi
    # Run only the failed gates, not the full suite. Gate names come from the
    # integration failure log.
    _failed="$(failed_gates "${LOGDIR}/gates-integration.log")"
    _iso_cmd="$(gates_cmd_only "$_failed")"
    if bash -c "$_iso_cmd" >"${LOGDIR}/gates-isolate-${_ipn}.log" 2>&1; then
      log "PR #${_ipn}: gates PASS in isolation — not the cause"
    else
      log "PR #${_ipn}: gates FAIL in isolation — this PR is at fault"
      failing_prs+=("$_ipn")
    fi
    # Clean up the isolation branch
    git checkout -q "$INTEGRATION_BRANCH" >/dev/null 2>&1 || true
    git branch -D "$_iso_branch" >/dev/null 2>&1 || true
  done

  # ── If NO PR fails individually, this is a genuine PR-vs-PR conflict. ──
  if [ "${#failing_prs[@]}" -eq 0 ]; then
    log "all PRs pass individually — genuine PR-vs-PR interaction; merge-stuck"
    # Issue #2254 follow-up: with MAX_PRS=1 (single-PR batch), "every PR passes
    # individually" is logically impossible as a PR-vs-PR conflict — the isolation
    # test ran a SUBSET of gates on the SAME code. Re-run the FULL gate suite once
    # to distinguish flake from genuine failure.
    if [ "$count" -eq 1 ]; then
      log "single-PR batch: all pass on narrowed gates — re-running full gates to rule out flake"
      if bash -c "$GATES_CMD" >"${LOGDIR}/gates-isolate-full-${PR_NUMS[0]}.log" 2>&1; then
        log "full gates PASS on single PR — previous integration failure was a flake; re-queuing as review-approved"
        add_label "${PR_NUMS[0]}" review-approved; remove_label "${PR_NUMS[0]}" merge-wip
        exit 0
      fi
      log "full gates FAIL on single PR — routing to fixer (not merge-stuck; one PR cannot conflict with itself)"
      add_label "${PR_NUMS[0]}" changes-requested; remove_label "${PR_NUMS[0]}" merge-wip
      # The format string used to be wrapped in `'"'"'` at its OUTER boundary — the idiom for
      # embedding a single quote INSIDE a single-quoted string, misapplied as the quoting
      # itself. The body and its ``` fences ended up unquoted, so the backticks ran as
      # command substitution and `\n` broke apart: the comment posted was corrupted (and
      # in the merger's `$( … )` context, empty), silently dropping the "here are the
      # failed gates" context the fixer depends on (issue #2387, C4; shellcheck SC1012).
      # Plain single quotes, matching the finish_all call below.
      "$GH" pr comment "${PR_NUMS[0]}" -b "$(printf '🔧 agent-pr-merger: PR #%s FAILED the full gate suite after a flaky narrow-gate pass. Routing to agent-pr-fixer.\n\nFailed gates:\n```\n%s\n```' "${PR_NUMS[0]}" "$(failed_gates "${LOGDIR}/gates-isolate-full-${PR_NUMS[0]}.log")")" >/dev/null 2>&1 || true
      exit 0
    fi
    finish_all merge-stuck "$(printf '🛑 agent-pr-merger: integration gates failed, but **every PR passes individually** on %s. This is a genuine PR-vs-PR conflict — two or more approved PRs interact badly. A human must decide which to merge and which to rework.\n\nFailed gates:\n```\n%s\n```' "$BASE" "$(failed_gates "${LOGDIR}/gates-integration.log")")"
    exit 0
  fi

  log "failing PR(s) in isolation: ${failing_prs[*]} — routing to fixer(s)"

  # ── Route each failing PR to its OWN fixer (isolated, never the shared
  # integration). The fixer repairs the PR branch and pushes; the next pipeline
  # tick picks up the fixed PR for re-integration. ──
  for _fp in "${failing_prs[@]}"; do
    [ -n "$_fp" ] || continue
    # Find this PR's head ref
    _fph=""
    for j in "${!PR_NUMS[@]}"; do
      [ "${PR_NUMS[$j]}" = "$_fp" ] && { _fph="${PR_HEADS[$j]}"; break; }
    done
    add_label "$_fp" changes-requested; remove_label "$_fp" merge-wip
    "$GH" pr comment "$_fp" -b "$(printf '🔧 agent-pr-merger: PR #%s FAILED in isolation on %s (same gates as the integration). Routing to agent-pr-fixer.\n\nFailed gates: %s\n\n```\n%s\n```\n\nThis PR will be re-integrated once the fixer pushes.' "$_fp" "$BASE" "$(failed_gates "${LOGDIR}/gates-integration.log")" "$(tail -25 "${LOGDIR}/gates-isolate-${_fp}.log")")" >/dev/null 2>&1 || true
  done

  # ── Re-queue the PRs that passed isolation; the failing ones go to fixer.
  # The next pipeline tick picks up the passing PRs in a new batch. ──
  for _pn in "${PR_NUMS[@]}"; do
    _is_failing=0
    for _fp in "${failing_prs[@]}"; do [ "$_fp" = "$_pn" ] && { _is_failing=1; break; }; done
    [ "$_is_failing" = 1 ] && continue
    add_label "$_pn" review-approved; remove_label "$_pn" merge-wip
  done
  exit 0
done

# ── Last line of defence: never fast-forward a marker-polluted tree onto ${BASE} ──────
# has_conflict_markers() exists precisely to stop this, but until #2185 its ONLY caller was inside
# the resolver loop — nothing checked the integration tree before the push. The gates catch marker
# text in anything they parse (Python, TS), so the exposure is the narrow path where they don't:
# conflicts confined to the regeneratable allowlist, with markers surviving into state/state.json
# (unlike the iteration log and digest, it is not regenerated post-loop above).
#
# Scoped to what THIS integration changed over the base, not the whole worktree: an unscoped scan
# would abort every merge on a marker that is legitimately committed or quoted somewhere in main
# (see conflict_marker_paths). Everything the integration touched is still covered.
mapfile -t _INTEGRATION_PATHS < <(git diff --name-only "$base_sha" HEAD 2>/dev/null)
if [ "${#_INTEGRATION_PATHS[@]}" -gt 0 ]; then
  _polluted="$(conflict_marker_paths_in_rev HEAD "${_INTEGRATION_PATHS[@]}" | tr '\n' ' ')"
  if [ -n "${_polluted// /}" ]; then
    log "integration tree still carries conflict markers in ${_polluted}— refusing to push to ${BASE}"
    finish_all merge-stuck "$(printf '🛑 agent-pr-merger: the integration still contains git conflict markers in `%s` — refusing to fast-forward `%s`. A conflict resolution did not complete; needs a human.' "${_polluted% }" "$BASE")"
    exit 0
  fi
fi

# ── Fast-forward main to the integration. No force — if main moved, bail to a human. ──
log "gates green — fast-forwarding ${BASE} to the integration"
if ! git push "$REMOTE" "HEAD:${BASE}" >/dev/null 2>>"${LOGDIR}/push-integration.log"; then
  log "push to ${BASE} was refused (main moved or remote rejected) — not merged"
  finish_all merge-stuck "🛑 agent-pr-merger: could not fast-forward ${BASE} (it moved under the integration) — re-review needed by a human."
  exit 0
fi

# ── Force-update each PR's head branch to its rebased tip so the commit is reachable
# from main → GitHub auto-marks the PR as merged (not just labelled). Without this,
# rebased PRs stay OPEN because the original head SHA was never pushed to main. ──
for i in "${!PR_NUMS[@]}"; do
  sha="${PR_REBASED_SHAS[$i]:-}"
  head="${PR_HEADS[$i]}"
  [ -n "$sha" ] || continue
  git push --force "$REMOTE" "${sha}:refs/heads/${head}" >/dev/null 2>>"${LOGDIR}/push-integration.log" \
    || log "WARN: PR #${PR_NUMS[$i]}: could not update head branch '${head}' to rebased tip — PR may not auto-close on GitHub"
done

# ── Success: each PR's rebased head is now on main → GitHub auto-closes them as merged.
# Label + comment explicitly so the state machine + the issue thread reflect it. ──
for i in "${!PR_NUMS[@]}"; do
  n="${PR_NUMS[$i]}"
  "$GH" pr comment "$n" -b "$(printf '🚀 agent-pr-merger: integrated with %s and auto-merged into %s (gates green). Shipped.' "${#PR_NUMS[@]} PR(s)" "$BASE")" >/dev/null 2>&1 || true
  add_label "$n" merged; remove_label "$n" merge-wip
done
log "MERGED ${#PR_NUMS[@]} PR(s) into ${BASE}: ${PR_NUMS[*]}"
exit 0
