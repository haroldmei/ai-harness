#!/usr/bin/env bash
# pr-lock.sh — per-JOB exclusion: per-PR for the review⇄fix⇄merge loop, per-ISSUE for the builders.
# (Filename kept for the four hermetic harnesses that copy it by name.)
#
# THE invariant for a parallel driver: reviewer and fixer must never touch PR 42 at the same time,
# while PRs 42 and 43 proceed independently. Per-STAGE mutexes (one reviewer, one fixer) get that
# by accident and pay for it with zero throughput; per-PR locks get it on purpose.
#
# This is what #2152 needed — two fixer runs dispatched in one round on the same PR and produced
# divergent commits. Labels (`review-wip`/`fix-wip`) are a claim signal but not a mutex: they are
# written AFTER the eligibility read, over the network, with no compare-and-set, so two stages can
# both read "unclaimed" and both write the label. A local flock closes the window that the label
# cannot.
#
#   source scripts/lib/pr-lock.sh
#   if pr_lock_try fd 42; then ... ; pr_lock_release "$fd"; else skip PR 42; fi
#
# NON-BLOCKING on purpose: a stage that cannot get PR 42 should move to the next candidate rather
# than queue, which turns the loop into work-stealing instead of head-of-line blocking.
#
# Like slot-lock.sh, it ASSIGNS the fd to a caller-named variable and prints nothing. Returning it
# on stdout would invite `fd=$(pr_lock_try …)`, where the lock is taken in a subshell that exits
# immediately and the caller believes it holds a PR it does not (the bug fixed in iteration 345).
# The fd is held open deliberately: the kernel releases on process exit, so a crashed stage cannot
# strand a PR — no reaper required.
#
# NOTE ON `set -`: this file is a LIBRARY and deliberately sets NO shell options. A sourced lib
# runs in the CALLER's shell, so a `set -e` here would silently abort every "collector" script
# (the gate and agent stages) at its first *tolerated* failure — the ones that must survive a
# failing step in order to report, classify or clean up. Signal failure with return codes only.
# This is a deliberate design choice, not an oversight: do not "fix" it by adding `set -e`.
# See "Shell-option classes" in docs/AGENT-HARNESS.md (#2390).

PR_LOCK_DIR="${PR_LOCK_DIR:-${TMPDIR:-/tmp}}"
# Ensure it exists, once, at source time. Every acquire opens a file INSIDE this directory, so a
# missing dir makes `exec {fd}>…` fail → pr_lock_try/issue_lock_try return 1 → the caller concludes
# "someone else holds it" and does nothing, on every tick, silently. The default (/tmp) always
# exists so production never hit it; a caller pointing PR_LOCK_DIR at a fresh path would.
mkdir -p "$PR_LOCK_DIR" 2>/dev/null || true

# ── Repo namespace (issue #2387, M4) ─────────────────────────────────────────────
# These lock files were `/tmp/skillforge-pr-<n>.lock` — keyed on the PR NUMBER alone, in a
# shared /tmp, with PR_LOCK_DIR set by no unit and no script. Every other lock in the harness
# (QG_LOCK, PIPELINE_LOCK, PR_MERGER_LOCK, PR_LOGDIR) hashes the git common dir precisely so
# two checkouts cannot collide. This one did not, so SkillForge's PR #42 and the FormMaster /
# PI ports' PR #42 — whose pipelines run on this same host — would contend for one file:
# head-of-line blocking between unrelated repositories, presenting as "held by another stage"
# and skipped forever.
#
# Same derivation as agent-pr-merger.sh's pr_repo_ns / agent-pipeline.sh's agent_repo_ns, so a
# lock taken by one is seen by the others.
#
# Rollout note: this CHANGES the lock filenames. During a deploy where old and new processes
# overlap, a stage on old code and one on new code hold differently-named locks for the same
# PR and cannot see each other. The window is one timer tick and self-corrects once every
# stage is on new code; the per-PR flock is advisory scheduling, and the authoritative
# `pr_lock_try` in the acting stage re-tests it.
_pr_lock_ns() {
  local d
  d="$(git rev-parse --git-common-dir 2>/dev/null)" || { printf 'nogit'; return; }
  [ -n "$d" ] || { printf 'nogit'; return; }
  d="$(cd "$d" 2>/dev/null && pwd)" || { printf 'nogit'; return; }
  printf '%s' "$d" | sha1sum | cut -c1-12
}
PR_LOCK_NS="${PR_LOCK_NS:-$(_pr_lock_ns)}"

pr_lock_path() { printf '%s/skillforge-pr-%s-%s.lock\n' "${PR_LOCK_DIR:-/tmp}" "$PR_LOCK_NS" "$1"; }

# pr_lock_try <out-fd-var> <pr-number>
# 0 → acquired, <out-fd-var> holds the open fd; 1 → another stage holds this PR.
# Delegates to _claim_lock_try (defined below with issue_lock_try, its other caller). This was
# a verbatim copy of that function's body — two implementations of one algorithm, each with its
# own copy of the load-bearing brace subtlety documented there, and only issue_lock_try actually
# delegated despite a comment claiming both did (issue #2387, M5).
pr_lock_try() {
  local __fdvar="$1" n="$2"
  [ -n "$n" ] || return 1
  _claim_lock_try "$__fdvar" "$(pr_lock_path "$n")"
}

# pr_lock_release <fd> — idempotent; safe on an empty/stale value.
pr_lock_release() {
  local fd="${1:-}"
  [ -n "$fd" ] || return 0
  eval "exec ${fd}>&-" 2>/dev/null || true
}

# pr_lock_is_held <pr-number> — true if SOMEONE ELSE holds it. Advisory only: the answer is stale
# the moment it returns, so use it to SCHEDULE (skip a PR another instance is driving), never to
# decide it is safe to act. The authoritative test is pr_lock_try in the stage that acts.
pr_lock_is_held() {
  local n="$1" f; f="$(pr_lock_path "$n")"
  [ -e "$f" ] || return 1
  if ( exec 198>"$f" && flock -n 198 ) 2>/dev/null; then return 1; fi
  return 0
}

# pr_lock_first_free <out-num-var> <out-fd-var> <pr-number>...
# Walks the candidates in order and takes the first one nobody else holds — the work-stealing
# primitive the reviewer and fixer use to pick a PR.
# The locals here carry a function-specific `__plff_`/`__ilff_` prefix (issue #2387, hygiene).
# These functions assign into a CALLER-NAMED variable via `printf -v`, and they also PASS a
# variable name down to pr_lock_try → _claim_lock_try, which has locals of its own. If the name
# passed down collides with a local in the callee, `printf -v` writes the callee's local and the
# caller reads its own uninitialised value — it then believes it holds a lock it does not.
#
# This is not hypothetical: the first attempt at this cleanup renamed the local to `__fd`, which
# is exactly what `_claim_lock_try` calls its own local, and every claim in agent-inbox.test.sh
# broke instantly ("__fd: unbound variable", 49 failures). A per-function prefix makes a
# collision impossible to introduce by accident.
pr_lock_first_free() {
  local __numvar="$1" __fdvar="$2"; shift 2
  local __plff_cand __plff_fd
  for __plff_cand in "$@"; do
    [ -n "$__plff_cand" ] || continue
    if pr_lock_try __plff_fd "$__plff_cand"; then
      printf -v "$__numvar" '%s' "$__plff_cand"
      printf -v "$__fdvar"  '%s' "$__plff_fd"
      return 0
    fi
  done
  return 1
}


# ── Generic core ──────────────────────────────────────────────────────────────────
# pr_lock_try/issue_lock_try are the same algorithm over a different lockfile prefix, so they
# delegate here rather than duplicating it.
_claim_lock_try() { # <out-fd-var> <lockfile>
  local __fdvar="$1" f="$2" __fd
  [ -n "$f" ] || return 1
  # Dynamic fd allocation: the merger holds locks for a whole batch at once, so a fixed number
  # would cap the batch at one PR.
  #
  # The braces are load-bearing. `exec {__fd}>"$f" 2>/dev/null` looks like "suppress exec's error
  # message", but `exec` WITHOUT a command word applies its redirections to the CURRENT SHELL
  # PERMANENTLY — so that `2>/dev/null` silently discarded stderr for the entire remainder of every
  # stage that took a lock. Found while tracing #2185: agent-pr-merger takes these locks before it
  # does any work, so from that point on every git error, every diagnostic written to stderr, and
  # every `>&2` log line in the run went to /dev/null. Grouping scopes the redirect to the group;
  # the fd opened inside still survives it.
  { exec {__fd}>"$f"; } 2>/dev/null || return 1
  if flock -n "$__fd" 2>/dev/null; then
    printf -v "$__fdvar" '%s' "$__fd"
    return 0
  fi
  { exec {__fd}>&-; } 2>/dev/null || true
  return 1
}
_claim_lock_is_held() { # <lockfile>
  local f="$1"
  [ -e "$f" ] || return 1
  if ( exec 197>"$f" && flock -n 197 ) 2>/dev/null; then return 1; fi
  return 0
}

# ── Per-ISSUE claims (the builders) ───────────────────────────────────────────────
# The `wip` label alone cannot express "someone is building this": it is written after the
# eligibility read and, crucially, it OUTLIVES the process that wrote it. A build killed by a
# systemd timeout, a host suspend or an OOM leaves `wip` set with nobody working, and since `wip`
# excludes the issue from every lane's eligibility the issue is stranded until a human relabels it
# (the #2086 shape). A flock is verifiable in the other direction: it exists only while a live
# process holds the fd, so "labelled wip but unlocked" is a decidable, reapable state.
#
# This also replaces positional AGENT_SLOT partitioning. Indexing (lane k takes the k-th eligible
# issue) is collision-free but STARVES a short queue: with one eligible issue only lane 0 can ever
# claim it, so if lane 0 is busy draining a PR the work waits while lanes 1 and 2 idle. Observed
# 2026-07-25 with #2132. Work-stealing over a lock fixes that — any free lane takes any free issue.
issue_lock_path() { printf '%s/skillforge-issue-%s-%s.lock\n' "${PR_LOCK_DIR:-/tmp}" "$PR_LOCK_NS" "$1"; }

# issue_lock_try <out-fd-var> <issue-number>
issue_lock_try() {
  local __fdvar="$1" n="$2"
  [ -n "$n" ] || return 1
  _claim_lock_try "$__fdvar" "$(issue_lock_path "$n")"
}

issue_lock_release() { pr_lock_release "${1:-}"; }

# issue_lock_is_held <issue-number> — someone ELSE is building it. Advisory for scheduling; the
# authoritative test is issue_lock_try in the builder that acts.
issue_lock_is_held() { _claim_lock_is_held "$(issue_lock_path "$1")"; }

# issue_lock_first_free <out-num-var> <out-fd-var> <issue-number>...
# Work-stealing: walk the candidates in the given order and take the first one nobody holds. The
# CALLER decides the order — the builders rotate the list by their lane index so lanes prefer
# different issues but can still steal any of them.
# Every local here is `__`-prefixed on purpose (issue #2387, hygiene). These functions
# assign into a CALLER-NAMED variable via `printf -v`, so a local sharing that name would
# be written instead of the caller's — the caller then reads its own stale value and
# believes it holds a lock it does not. Every call site today passes a distinct name, so
# this is a latent trap rather than a live bug; the prefix removes it by construction.
issue_lock_first_free() {
  local __numvar="$1" __fdvar="$2"; shift 2
  local __ilff_cand __ilff_fd
  for __ilff_cand in "$@"; do
    [ -n "$__ilff_cand" ] || continue
    if issue_lock_try __ilff_fd "$__ilff_cand"; then
      printf -v "$__numvar" '%s' "$__ilff_cand"
      printf -v "$__fdvar"  '%s' "$__ilff_fd"
      return 0
    fi
  done
  return 1
}
