#!/usr/bin/env bash
# agent-pr-reviewer.sh — the unattended "pick a PR → review it → approve or request changes".
#
# Stage 3 of the build pipeline (docs/35). agent-scout files issues; agent-inbox builds an
# `agent` issue into a PR labelled `review-needed`; THIS agent reviews that PR with a strong
# model (R), grounded in the linked issue's ACCEPTANCE CRITERION + the diff, and posts a
# verdict:
#   - approve         → label `review-approved` (ready to land — NOT merged; merge stays human)
#   - request-changes → label `changes-requested` (+ a comment listing the file:line findings)
# agent-pr-fixer.sh (a DIFFERENT model F) then addresses the findings; the two loop until
# approved or PR_MAX_ROUNDS → `review-stuck` (human).
#
# Self-review note: GitHub forbids `gh pr review --approve/--request-changes` on your OWN PR,
# and the agent runs as the PR's author. So the verdict is delivered as a PR COMMENT + a
# LABEL (the label IS the state machine). Set PR_FORMAL_REVIEW=1 to additionally post a formal
# `gh pr review` (only works when GH_TOKEN is a different account than the PR author).
#
# Single-pass (the timer re-invokes it); one PR per run; a flock guarantees one instance.
# Every external command + path is overridable so the journey is testable hermetically
# (scripts/agent-pr-reviewer.test.sh) with NO real GitHub side-effects and NO LLM cost.
#
#   Labels: review-needed → review-wip → {review-approved | changes-requested | review-stuck}
#   Setup: scripts/agent-pr-loop-setup.sh  ·  Plan: docs/35-pr-review-fix-loop-iteration-plan.md
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
# shellcheck source=lib/agent-sandbox.sh
source "$ROOT/scripts/lib/agent-sandbox.sh"
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
# No BASE here on purpose: `BASE="${PR_BASE:-main}"` used to be set and read by nothing
# (issue #2387, M6). This script gets its diff from `gh pr diff`, which resolves the base
# from the PR itself on GitHub — so a PR_BASE override looked effective and changed nothing.
HEAD_GLOB="${PR_HEAD_GLOB:-agent/}"               # only review agent-authored PRs (head prefix)
REVIEWER_MODEL="${PR_REVIEWER_MODEL:-opus}"       # model R
FIXER_MODEL="${PR_FIXER_MODEL:-sonnet}"           # model F — must DIFFER from R (FR-075)
MAX_ROUNDS="${PR_MAX_ROUNDS:-4}"
# Consecutive empty envelopes tolerated before escalating (see the `empty` branch below). 2 is
# deliberately small: the failure it covers is a CLI hiccup that clears on the next tick, so a
# larger cap only delays a real "the CLI is broken" signal from reaching a human.
EMPTY_ENVELOPE_RETRIES="${PR_EMPTY_ENVELOPE_RETRIES:-2}"
FORMAL_REVIEW="${PR_FORMAL_REVIEW:-0}"            # 1 = also post a formal gh pr review (needs a bot token)
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
LOCK="${PR_REVIEWER_LOCK:-/tmp/agent-pr-reviewer-$NS.lock}"
LOGDIR="${PR_LOGDIR:-/tmp/agent-pr-review-$NS}"
REMOTE="${PR_REMOTE:-origin}"
WORKTREE_BASE="${PR_WORKTREE_BASE:-/tmp/agent-pr-review-$NS/worktrees}"  # isolated review checkouts

cd "$ROOT" || { echo "[pr-reviewer] cannot cd to $ROOT" >&2; exit 2; }
mkdir -p "$LOGDIR" "$WORKTREE_BASE"
log() { printf '[pr-reviewer] %s\n' "$*"; }

# Label ops via REST (gh pr edit --add-label hits the deprecated projectCards GraphQL field
# and flakily drops the label — the bug that left labels unset, docs/35). Non-fatal; add is
# LOGGED on failure, remove tolerates a 404 (label already absent). `{owner}/{repo}` auto-resolve.
add_label()    { "$GH" api -X POST   "repos/{owner}/{repo}/issues/$1/labels"     -f "labels[]=$2" >/dev/null 2>&1 || log "WARN: could not add label '$2' to #$1"; }
remove_label() { "$GH" api -X DELETE "repos/{owner}/{repo}/issues/$1/labels/$2"                   >/dev/null 2>&1 || true; }

# ── Serialize worktree add/remove under a per-REPO lock (parallel `git worktree add`s race on
# the shared `.git/worktrees` admin area and one fails). ─
WT_LOCK="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)"
case "$WT_LOCK" in /*) ;; *) WT_LOCK="$ROOT/$WT_LOCK";; esac
WT_LOCK="${WT_LOCK%/}/.agent-worktree.lock"
git_worktree_locked() { local rc; exec 7>"$WT_LOCK"; flock 7; git worktree "$@"; rc=$?; exec 7>&-; return $rc; }

# ── Toolchain bootstrap (systemd/cron start bare — no shell init) ────────────────
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
[ -s "$HOME/miniconda3/etc/profile.d/conda.sh" ] && . "$HOME/miniconda3/etc/profile.d/conda.sh" >/dev/null 2>&1 || true

# ── FR-075: different-model enforcement (fail-fast — an independent review needs an
# independent model; never let one model both write and approve a change). ──────
if [ "$REVIEWER_MODEL" = "$FIXER_MODEL" ]; then
  log "REFUSING: PR_REVIEWER_MODEL ('$REVIEWER_MODEL') must DIFFER from PR_FIXER_MODEL — independent review needs a different model."
  exit 2
fi

# ── Preflight ───────────────────────────────────────────────────────────────────
for t in git jq "$GH" "$CLAUDE"; do
  command -v "$t" >/dev/null 2>&1 || { log "PREFLIGHT FAILED — not on PATH: $t"; exit 1; }
done

# ── Single-instance lock ─────────────────────────────────────────────────────────
# A counting semaphore, not a mutex. At the default of 1 this is the historical behaviour
# byte for byte: one reviewer at a time, exit quietly if another holds it. Raised above 1, N reviewers
# run concurrently — safe ONLY because each one takes a PER-PR lock before acting (see
# scripts/lib/pr-lock.sh), so two of them can never land on the same PR. Do not raise this
# without that: it is how #2152 happened at N=1-by-accident (two fixer runs, one round,
# divergent commits).
PR_REVIEWER_SLOTS="${PR_REVIEWER_SLOTS:-1}"
if [ "$PR_REVIEWER_SLOTS" -le 1 ]; then
  exec 9>"$LOCK"
  if ! flock -n 9; then log "another reviewer run in progress — exiting"; exit 0; fi
else
  # shellcheck source=lib/slot-lock.sh
  source "$ROOT/scripts/lib/slot-lock.sh"
  # slot_acquire ASSIGNS (never $(…)) — command substitution would take the lock in a subshell
  # that exits immediately, so every instance would "hold" slot 0 while holding nothing.
  if ! slot_acquire _reviewer_slot "${LOCK%.lock}-slot" "$PR_REVIEWER_SLOTS" 9 1; then
    log "all $PR_REVIEWER_SLOTS reviewer slots busy — exiting"; exit 0
  fi
  log "reviewer slot ${_reviewer_slot}/$PR_REVIEWER_SLOTS"
fi

# ── Find one PR to review: open, labelled `review-needed`, head under $HEAD_GLOB,
# not already claimed/terminal. ──────────────────────────────────────────────────
# (no server-side --label here: gh implements it via the SEARCH API, whose index can
#  lag label churn by hours and hide the PR — the label is filtered client-side below
#  from live data instead)
prs_json="$("$GH" pr list --state open \
  --json number,headRefName,labels,title,url --limit 50 2>/dev/null || echo '[]')"
[ -z "$prs_json" ] && prs_json='[]'

# Candidates in order, then take the first PR no OTHER stage is holding. Was `.[0] // empty`:
# a single mutex per stage made that safe, but with a parallel driver two instances would both
# select the same head-of-list PR and both act on it (#2152 — two fixer runs in one round,
# divergent commits). The `review-wip` label is a claim SIGNAL, not a mutex: it is written after this
# read, over the network, with no compare-and-set. The flock closes the window the label cannot.
# Non-blocking + skip-ahead, so a PR another instance owns costs us nothing but a candidate.
_cand_json="$(jq -c --arg pfx "$HEAD_GLOB" 'map(select(
  (.headRefName | startswith($pfx)) and
  ([.labels[]?.name] | index("review-needed")) and
  ([.labels[]?.name] | index("review-wip")        | not) and
  ([.labels[]?.name] | index("fix-wip")            | not) and
  ([.labels[]?.name] | index("review-approved")    | not) and
  ([.labels[]?.name] | index("review-stuck")       | not)
))' <<<"$prs_json")"
mapfile -t _cands < <(jq -r '.[].number' <<<"$_cand_json")
eligible=""; PR_LOCK_FD=""
if [ "${#_cands[@]}" -gt 0 ]; then
  if pr_lock_first_free _picked_pr PR_LOCK_FD "${_cands[@]}"; then
    eligible="$(jq -c --argjson n "$_picked_pr" 'map(select(.number == $n)) | .[0] // empty' <<<"$_cand_json")"
  else
    log "all review candidate PR(s) (${_cands[*]}) are held by another stage — nothing to do this tick"
  fi
fi

if [ -z "$eligible" ]; then log "no PRs awaiting review"; exit 0; fi

n="$(jq -r '.number' <<<"$eligible")"
head="$(jq -r '.headRefName' <<<"$eligible")"
title="$(jq -r '.title' <<<"$eligible")"
log "reviewing PR #${n} (${head}): ${title}"

add_label "$n" review-wip; remove_label "$n" review-needed

# ── Round accounting: a `<!-- pr-loop-round: N -->` marker is posted by the fixer each
# time it hands back. If we've already burned MAX_ROUNDS fix attempts, stop the loop. ──
round="$("$GH" pr view "$n" --json comments --jq '[.comments[].body | capture("pr-loop-round: (?<r>[0-9]+)").r | tonumber] | max // 0' 2>/dev/null || echo 0)"
[[ "$round" =~ ^[0-9]+$ ]] || round=0

# ── Gather review context: the diff + the linked issue's acceptance criterion. The head
# branch is `agent/issue-<N>`, so the linked issue is parseable from it. ──────────
issue_num="$(printf '%s' "$head" | sed -nE 's#.*issue[-/]([0-9]+).*#\1#p')"
issue_ctx="(no linked issue found from the head branch)"
if [ -n "$issue_num" ]; then
  issue_ctx="$("$GH" issue view "$issue_num" --json title,body --jq '"ISSUE #\(.title)\n\n\(.body)"' 2>/dev/null || echo "$issue_ctx")"
fi
diff="$("$GH" pr diff "$n" 2>/dev/null | head -c 60000)"   # bound the diff fed to the model

verdict_out="${LOGDIR}/verdict-${n}.json"; rm -f "$verdict_out"
prompt="$(cat <<EOF
You are agent-pr-reviewer, an INDEPENDENT, adversarial reviewer of a pull request. You did
NOT write this code. Review it strictly but fairly. Judge SUBSTANCE, not style:
  - Does it actually satisfy the linked issue's ACCEPTANCE CRITERION?
  - Real bugs, edge cases, security/tenant-isolation regressions, broken error handling?
  - Is it scoped (no unrelated drive-by changes)? Do the tests actually exercise the change
    (not deleted/weakened to pass a gate)?
Do NOT raise style/formatting nits. Every requested change MUST cite a file:line and the
concrete defect or the acceptance clause it fails — actionable and falsifiable.

This is review round ${round} (cap ${MAX_ROUNDS}).

=== LINKED ISSUE (acceptance criterion to verify against) ===
${issue_ctx}

=== PULL REQUEST #${n} DIFF ===
${diff}

Output ONLY a valid JSON object on stdout. No prose, no markdown fences, no explanation.
Schema:
{
  "verdict": "approve" | "request-changes",
  "summary": "2-4 sentences: the overall judgement + whether the acceptance criterion is met",
  "findings": [   // [] when approve
    { "file": "path", "line": "NN or range", "severity": "blocker|major|minor", "issue": "the concrete defect + what to change" }
  ]
}
Approve ONLY if the acceptance criterion is met and there are no blocker/major defects.
EOF
)"
log "running reviewer model ${REVIEWER_MODEL}…"
review_log="${LOGDIR}/agent-review-${n}.json"

# ── Isolated CLONE at the PR head — the reviewer model must ONLY ever touch its own clean temp
# checkout, NEVER the primary repo. It runs with bypassPermissions, so `cd`-ing it into a
# worktree and trusting it to stay there does not hold: on 2026-07-26 a review `git checkout`ed
# the PR branch in the PRIMARY tree, switching it off `main` and leaving a conflicted merge in
# the checkout the systemd timers execute from. The comment that used to sit here warned about
# precisely that, which is the point — a comment is not an enforcement mechanism.
#
# So the isolation is now structural, in two parts (scripts/lib/agent-sandbox.sh):
#   * a self-contained clone, because a linked worktree's `.git` is a pointer INTO the primary
#     and therefore cannot survive the primary being hidden;
#   * a bubblewrap tmpfs overlay that makes $ROOT an empty directory for the model's process.
# Reaching the primary checkout is now impossible, not merely discouraged. Cleaned up on EXIT. ─
git fetch -q "$REMOTE" "$head" >/dev/null 2>&1 || true
review_wt="${WORKTREE_BASE}/pr-${n}"
# The `worktree remove` stays for one migration: runs from before this change left a REAL linked
# worktree at this path, and `rm -rf` alone would orphan its entry in the primary's
# .git/worktrees/. Harmless (and a no-op) once the path holds a clone.
git_worktree_locked remove --force "$review_wt" >/dev/null 2>&1 || true; rm -rf "$review_wt" >/dev/null 2>&1 || true
if sandbox_clone "$ROOT" "$review_wt" "${REMOTE}/${head}"; then
  trap 'rm -rf "$review_wt" >/dev/null 2>&1 || true' EXIT
  sandbox_available || log "WARNING: bwrap unavailable — reviewing in an isolated clone, but \$ROOT is NOT hidden"
else
  # NEVER fall back to $ROOT: handing the model the primary checkout is the failure being fixed.
  # An empty scratch dir still reviews — the full diff is in the prompt either way.
  log "could not create review clone on ${head} — reviewing from the diff only"
  review_wt="${LOGDIR}/pr-${n}-norepo"; rm -rf "$review_wt"; mkdir -p "$review_wt"
fi

# $CLAUDE and $LOGDIR normally sit outside $ROOT and need nothing here; they are re-exposed
# because PR_CLAUDE / PR_LOGDIR may point inside it, and a hidden model binary or a hidden
( cd "$review_wt" || exit 1
  sandbox_run "$ROOT" \
    --expose "$(command -v "$CLAUDE" 2>/dev/null || echo "$CLAUDE")" \
    --expose "$LOGDIR" \
    -- "$CLAUDE" -p "$prompt" \
    --permission-mode bypassPermissions --model "$REVIEWER_MODEL" --output-format json \
    >"$review_log" 2>"${review_log%.json}.stderr" ) || log "reviewer model exited non-zero — continuing"

# CLAUDE.md: every `claude` invocation emits a span (#2390). Emitted HERE, in the parent shell and
# before any of the dispositions below exit, so a review is counted no matter which branch it takes
# — the transient early-return at :257 is precisely the path that used to record nothing.
review_cls="$(classify_model_result "$review_log")"
agent_trace_span "$review_log" review pr="$n" round="$round" model="$REVIEWER_MODEL" \
  outcome="$review_cls" template="reviewer-v1" prompt="$prompt"

# ── Transient failure (rate/usage limit, overload) → the model never ran. Leave the PR exactly
# as we found it (back to review-needed) and retry on the next tick — do NOT escalate or burn a
# round. MUST come BEFORE the "no parseable verdict" branch (a transient run writes no verdict). ─
model_cls="$review_cls"
if [ "$model_cls" = "transient" ]; then
  log "reviewer model hit a transient limit (rate-limit/usage-limit/overload) — leaving PR #${n} as review-needed; retry next tick (no round consumed)"
  add_label "$n" review-needed; remove_label "$n" review-wip
  exit 0
fi

# ── Empty envelope → the CLI exited without serialising its JSON, so we know NOTHING about
# whether the model ran. Retry like a transient, but BOUNDED: a permanently silent CLI (broken
# install, dead credentials) would otherwise bounce this PR between review-needed and review-wip
# every tick forever, which is worse than asking a human. On #2407 the model had in fact produced
# a complete verdict; escalating on the first empty envelope threw away a 7-minute opus review and
# burned a pipeline re-arm. The counter is per-PR and resets on ANY non-empty result, so isolated
# hiccups never accumulate toward the cap. ─
empty_count_file="${LOGDIR}/empty-envelope-${n}.count"
if [ "$model_cls" = "empty" ]; then
  empty_count=$(( $(cat "$empty_count_file" 2>/dev/null || echo 0) + 1 ))
  if [ "$empty_count" -le "$EMPTY_ENVELOPE_RETRIES" ]; then
    printf '%s' "$empty_count" >"$empty_count_file" 2>/dev/null || true
    log "reviewer model wrote NO output envelope (attempt ${empty_count}/${EMPTY_ENVELOPE_RETRIES}) — cannot tell whether it ran; leaving PR #${n} as review-needed; retry next tick (no round consumed)"
    add_label "$n" review-needed; remove_label "$n" review-wip
    exit 0
  fi
  log "reviewer model wrote NO output envelope ${empty_count}x in a row (cap ${EMPTY_ENVELOPE_RETRIES}) — escalating to a human"
  rm -f "$empty_count_file" 2>/dev/null || true
else
  # Any classifiable result clears the streak — the cap counts CONSECUTIVE empties only.
  rm -f "$empty_count_file" 2>/dev/null || true
fi

# ── Parse the verdict (robust) ───────────────────────────────────────────────────
# Read from $review_log.result (the model outputs on stdout, captured by the CLI JSON
# envelope), then write the clean JSON to $verdict_out so all downstream jq calls work
# unchanged.
#
# The RAW result is tried FIRST because that is precisely what the prompt above demands
# ("Output ONLY a valid JSON object on stdout. No prose, no markdown fences"). The fence and
# bare-object extractors are salvage for a model that ignores it — never the primary path.
#
# Each rung is accepted only if it PARSES. Chaining them on non-emptiness instead is what broke
# PR #2419: the bare-object rung was `sed -n '/^{/,/^}$/{p;q}'`, and `q` fires on the FIRST line
# of the range, so a pretty-printed object yielded the single character `{`. Non-empty — so the
# raw fallback never ran, jq failed, and the PR went review-stuck while the model's complete,
# valid verdict sat in the envelope. It only ever worked when the model happened to emit its
# object on ONE line (#2417, five minutes earlier, did — and was approved), which is why the
# failure read as a ~coin-flip and was misattributed to the PR_VERDICT_OUT env var removed in
# a8abc666. Non-empty is not the same test as valid; only jq gets to decide a rung succeeded.
verdict=""
if [ -s "$review_log" ]; then
  _raw="$(jq -r '.result // ""' "$review_log" 2>/dev/null)" || _raw=""
  _parses() { [ -n "$1" ] && printf '%s' "$1" | jq -e . >/dev/null 2>&1; }
  if [ -n "$_raw" ]; then
    _json="$_raw"
    _parses "$_json" || _json="$(printf '%s' "$_raw" | sed -n '/^```json/,/^```/{//!p;}' | head -c 32000)"
    _parses "$_json" || _json="$(printf '%s' "$_raw" | sed -n '/^{/,/^}$/p')"
    if _parses "$_json"; then
      printf '%s' "$_json" >"$verdict_out"
      verdict="$(jq -r '.verdict // empty' "$verdict_out" 2>/dev/null)"
    fi
  fi
  unset _raw _json; unset -f _parses
fi
if [ -z "$verdict" ]; then
  log "no parseable verdict — routing to review-stuck"
  # Name the actual failure. "could not produce a verdict" is wrong for an empty envelope — the
  # model may well have produced one (on #2407 it did, and the transcript still holds it); what
  # failed is the CLI never writing it. Sending a human to look for a bad review when the review
  # never reached us costs them the whole investigation.
  if [ "$model_cls" = "empty" ]; then
    "$GH" pr comment "$n" -b "⚠️ agent-pr-reviewer: the model CLI exited without writing an output envelope on ${EMPTY_ENVELOPE_RETRIES} consecutive attempts — needs a human. The model may have produced a verdict that was never captured; check the session transcript under \`~/.claude/projects/\` before assuming the review failed." >/dev/null 2>&1 || true
  else
    "$GH" pr comment "$n" -b "⚠️ agent-pr-reviewer: could not produce a verdict — needs a human." >/dev/null 2>&1 || true
  fi
  add_label "$n" review-stuck; remove_label "$n" review-wip
  exit 0
fi

summary="$(jq -r '.summary // ""' "$verdict_out")"

# ── Verdict↔findings reconciliation (deterministic, not model-trusted) ────────────
# The prompt says "approve ONLY if … no blocker/major defects", but a less-capable reviewer model
# routinely self-contradicts: it emits verdict="approve" while ALSO listing blocker/major findings.
# Trusting the verdict string verbatim is the single highest-impact false-approve, because the
# merger ships on the `review-approved` label alone. Enforce the rule in code: an "approve" that
# carries any blocker/major finding is downgraded to request-changes. (minor findings don't block.)
if [ "$verdict" = "approve" ]; then
  blocking="$(jq -r '[(.findings // [])[] | select((.severity // "") | ascii_downcase | (. == "blocker" or . == "major"))] | length' "$verdict_out" 2>/dev/null)"
  [[ "$blocking" =~ ^[0-9]+$ ]] || blocking=0
  if [ "$blocking" -gt 0 ]; then
    log "reviewer self-contradicted: verdict=approve with ${blocking} blocker/major finding(s) — downgrading to request-changes"
    summary="⚠️ Auto-downgraded from APPROVE: the review listed ${blocking} blocker/major finding(s), which contradict an approval. ${summary}"
    verdict="request-changes"
  fi
fi

if [ "$verdict" = "approve" ]; then
  body="$(printf '✅ **agent-pr-reviewer: APPROVED** (model %s, round %s)\n\n%s\n\n— gates green + acceptance criterion met. Ready to land (a human merges).\n<!-- pr-review: approved round %s -->' \
    "$REVIEWER_MODEL" "$round" "$summary" "$round")"
  "$GH" pr comment "$n" -b "$body" >/dev/null 2>&1 || true
  [ "$FORMAL_REVIEW" = "1" ] && "$GH" pr review "$n" --approve --body "$summary" >/dev/null 2>&1 || true
  add_label "$n" review-approved; remove_label "$n" review-wip; remove_label "$n" changes-requested
  log "PR #${n} APPROVED → review-approved"
  exit 0
fi

# request-changes — but if we've exhausted the rounds, stop the loop instead of looping again.
findings_md="$(jq -r '(.findings // []) | map("- `\(.file):\(.line)` **[\(.severity)]** \(.issue)") | join("\n")' "$verdict_out" 2>/dev/null)"
[ -z "$findings_md" ] && findings_md="_(no structured findings — see summary)_"

if [ "$round" -ge "$MAX_ROUNDS" ]; then
  body="$(printf '🛑 **agent-pr-reviewer: STILL requesting changes after %s round(s)** — handing to a human.\n\n%s\n\n### Outstanding\n%s' \
    "$round" "$summary" "$findings_md")"
  "$GH" pr comment "$n" -b "$body" >/dev/null 2>&1 || true
  add_label "$n" review-stuck; remove_label "$n" review-wip
  log "PR #${n} hit round cap (${round}/${MAX_ROUNDS}) → review-stuck"
  exit 0
fi

body="$(printf '🔧 **agent-pr-reviewer: CHANGES REQUESTED** (model %s, round %s)\n\n%s\n\n### Findings (address each, then the fixer hands back for re-review)\n%s\n<!-- pr-review: changes-requested round %s -->' \
  "$REVIEWER_MODEL" "$round" "$summary" "$findings_md" "$round")"
"$GH" pr comment "$n" -b "$body" >/dev/null 2>&1 || true
[ "$FORMAL_REVIEW" = "1" ] && "$GH" pr review "$n" --request-changes --body "$summary" >/dev/null 2>&1 || true
add_label "$n" changes-requested; remove_label "$n" review-wip
log "PR #${n} CHANGES REQUESTED → changes-requested"
exit 0
