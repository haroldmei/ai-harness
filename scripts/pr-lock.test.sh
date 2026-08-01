#!/usr/bin/env bash
# Hermetic test for scripts/lib/pr-lock.sh — per-PR exclusion for a parallel review⇄fix⇄merge loop.
#
# The property under test is the one #2152 violated: two stages must never both believe they hold
# the same PR, while different PRs must stay independent.
#
#   Run: bash scripts/pr-lock.test.sh     (exit 0 = all pass)
#
# SC2154 is disabled file-wide, deliberately. Every acquire here reads a variable that
# pr_lock_try/pr_lock_first_free assigned via `printf -v` — `fd42`, `again`, `_got_fd` and
# friends are genuinely never assigned in this file's own text, which is exactly the calling
# convention under test. Baselining eight instances of a known-good pattern would have made
# the ratchet noisier without making anything safer (issue #2387).
# shellcheck disable=SC2154
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
export PR_LOCK_DIR="$T"
# shellcheck source=lib/pr-lock.sh
source "$ROOT/scripts/lib/pr-lock.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── 1: acquire, and it is genuinely held after the call returns ───────────────────
# (the iteration-345 footgun: a print-and-capture API takes the lock in a subshell that exits)
echo "1 — a taken PR lock is still held after the call returns"
if pr_lock_try fd42 42; then ok "acquired PR 42 (fd $fd42)"; else bad "should acquire a free PR"; fi
pr_lock_is_held 42 && ok "PR 42 reports held while we hold it" || bad "PR 42 must report held"

# ── 2: a second stage cannot take the same PR ─────────────────────────────────────
echo "2 — a second stage is refused the same PR"
if pr_lock_try other 42; then bad "two stages must not both hold PR 42"; else ok "second acquire of PR 42 refused"; fi

# ── 3: a DIFFERENT PR is unaffected — this is the whole point ──────────────────────
echo "3 — a different PR proceeds in parallel"
if pr_lock_try fd43 43; then ok "PR 43 acquired while PR 42 is held"; else bad "different PRs must not block each other"; fi

# ── 4: release frees it for the next stage ────────────────────────────────────────
echo "4 — releasing hands the PR to the next stage"
pr_lock_release "$fd42"
if pr_lock_try again 42; then ok "PR 42 reacquired after release"; else bad "release must free the PR"; fi
pr_lock_release "$again"; pr_lock_release "$fd43"

# ── 5: work-stealing — first_free skips what others hold ──────────────────────────
echo "5 — first_free skips held PRs and takes the first free one"
pr_lock_try h1 101 >/dev/null; pr_lock_try h2 102 >/dev/null
if pr_lock_first_free picked pfd 101 102 103; then
  [ "$picked" = "103" ] && ok "skipped 101/102, took 103" || bad "expected 103, picked $picked"
else
  bad "first_free should have found 103"
fi
pr_lock_release "$pfd"
# All held → must report failure rather than returning a PR it does not hold.
if pr_lock_first_free p2 f2 101 102; then
  bad "first_free must fail when every candidate is held"
else
  ok "all-held → first_free fails instead of over-claiming"
fi
pr_lock_release "$h1"; pr_lock_release "$h2"

# ── 6: a crashed stage does not strand its PR ─────────────────────────────────────
# `exec` so the holder IS the process: a forked child would inherit the fd and legitimately keep
# the lock (documented in slot-lock.sh).
echo "6 — a SIGKILLed stage releases its PR (no reaper needed)"
( source "$ROOT/scripts/lib/pr-lock.sh"; pr_lock_try v 77 && exec sleep 30 ) &
victim=$!
for _ in $(seq 1 50); do pr_lock_is_held 77 && break; sleep 0.1; done
kill -9 "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
if pr_lock_try rec 77; then ok "PR 77 recovered after SIGKILL"; else bad "a killed stage stranded PR 77"; fi
pr_lock_release "$rec"

# ── 7: an unheld PR reports free, and a bogus arg does not claim anything ─────────
echo "7 — unheld PRs report free; empty input claims nothing"
pr_lock_is_held 999 && bad "PR 999 was never locked — must report free" || ok "untouched PR reports free"
if pr_lock_try nope ""; then bad "empty PR number must not acquire"; else ok "empty PR number refused"; fi

# ── 8: taking a lock must not silence the caller's stderr ─────────────────────────
# `exec {fd}>"$f" 2>/dev/null` reads as "don't print exec's error", but `exec` with NO command word
# applies its redirections to the CURRENT SHELL permanently — so that one line sent the rest of the
# process's stderr to /dev/null. Every stage sources this lib and takes a lock before doing any
# work, so from the first claim onward agent-pr-merger/reviewer/fixer ran with stderr discarded:
# git's error output, and every `>&2` diagnostic, silently vanished. Found while tracing #2185,
# where it hid the resolver's own "could not resolve" reporting. Run in a child shell so the
# assertion is about a fresh process, exactly like a real stage.
echo "8 — claiming a lock leaves stderr intact (exec redirections must not leak into the shell)"
# LIBROOT/PR_LOCK_DIR go through the environment rather than being spliced into the script text:
# the docs-refs gate statically resolves every `source`/`.` line, and a nested-quoted path would
# reach it as an unparseable string and fail the gate. A `$`-bearing path is skipped as dynamic.
_stderr_probe="$(LIBROOT="$ROOT" PR_LOCK_DIR="$T" bash -c '
  . "$LIBROOT/scripts/lib/pr-lock.sh"
  pr_lock_try fd 4242 >/dev/null
  echo "STDERR-ALIVE" >&2
  pr_lock_release "$fd"
' 2>&1 >/dev/null)"
case "$_stderr_probe" in
  *STDERR-ALIVE*) ok "stderr still works after pr_lock_try";;
  *)              bad "pr_lock_try permanently redirected the caller's stderr to /dev/null";;
esac
# The failing branch must not leak either: a contended lock closes the fd on its way out.
_stderr_probe2="$(LIBROOT="$ROOT" PR_LOCK_DIR="$T" bash -c '
  . "$LIBROOT/scripts/lib/pr-lock.sh"
  ( pr_lock_try held 4243 >/dev/null 2>&1 && exec sleep 5 ) & sleep 0.4
  pr_lock_try fd 4243 >/dev/null   # NOT 2>&1: a redirect here would restore fd 2 on return and mask the leak
  echo "STDERR-ALIVE-2" >&2
  kill %1 2>/dev/null
' 2>&1 >/dev/null)"
case "$_stderr_probe2" in
  *STDERR-ALIVE-2*) ok "stderr still works after a CONTENDED pr_lock_try";;
  *)                bad "the contended path permanently redirected stderr to /dev/null";;
esac

# ── 9: lock paths are namespaced PER REPO (issue #2387, M4) ─────────────────────
# These were `/tmp/skillforge-pr-<n>.lock` — keyed on the PR number alone, in a shared /tmp,
# while every other lock in the harness hashes the git common dir. Two checkouts on one host
# (SkillForge plus the FormMaster / PI ports, whose pipelines run here) contended for one
# file, so an unrelated repo's PR #42 blocked ours indefinitely, reported as "held by
# another stage".
echo "9 — lock paths are namespaced per repository"
_ns_a="$(mktemp -d)"; _ns_b="$(mktemp -d)"
git init -q "$_ns_a/repo"; git init -q "$_ns_b/repo"
_path_in() { ( cd "$1/repo" && PR_LOCK_DIR=/tmp bash -c 'unset PR_LOCK_NS; source "'"$ROOT"'/scripts/lib/pr-lock.sh"; pr_lock_path 42; issue_lock_path 42' ); }
_a="$(_path_in "$_ns_a")"; _b="$(_path_in "$_ns_b")"
if [ -n "$_a" ] && [ "$_a" != "$_b" ]; then
  ok "two different repos derive different lock paths"
else
  bad "two repos share a lock path — cross-repo head-of-line blocking"$'\n'"a=[$_a]"$'\n'"b=[$_b]"
fi
# Same repo, two invocations → the SAME path, or stages could not see each other's locks.
if [ "$(_path_in "$_ns_a")" = "$_a" ]; then
  ok "the same repo derives a stable lock path across invocations"
else
  bad "the lock path is not stable within one repo — stages would not see each other's claims"
fi
# The PR number must still be in the name: namespacing must not collapse distinct PRs.
_p42="$( cd "$_ns_a/repo" && bash -c 'source "'"$ROOT"'/scripts/lib/pr-lock.sh"; pr_lock_path 42' )"
_p43="$( cd "$_ns_a/repo" && bash -c 'source "'"$ROOT"'/scripts/lib/pr-lock.sh"; pr_lock_path 43' )"
[ "$_p42" != "$_p43" ] && ok "distinct PRs still get distinct locks" \
  || bad "PR 42 and 43 collapsed to one lock path ($_p42)"
rm -rf "$_ns_a" "$_ns_b" 2>/dev/null || true

# ── 10: the out-var name a caller picks must never collide with an internal local ──
# `*_first_free` assigns into a caller-named variable AND passes a name down to
# _claim_lock_try, which has locals of its own. During #2387 a cleanup renamed the internal
# local to `__fd` — the same name _claim_lock_try uses — and every claim silently broke
# ("__fd: unbound variable"). The names below are the ones an internal collision would hit.
echo "10 — caller-supplied out-var names survive whatever the internals are called"
for _v in fd cand n f __fd __fdvar __cand __numvar; do
  _got_num=""; _got_fd=""
  # shellcheck disable=SC2016
  if ( unset "$_v" 2>/dev/null
       eval "$_v=SENTINEL"
       PR_LOCK_DIR="$T" pr_lock_first_free _got_num _got_fd 9101 >/dev/null 2>&1 \
         && [ -n "$_got_num" ] && [ -n "$_got_fd" ] ); then
    ok "an out-var works with a shell local named '$_v' in scope"
  else
    bad "pr_lock_first_free failed with '$_v' in scope — an internal local is shadowing it"
  fi
done
# And the caller may name its out-vars after the internals directly.
if PR_LOCK_DIR="$T" pr_lock_first_free __cand __fd 9102 >/dev/null 2>&1 \
   && [ -n "${__cand:-}" ] && [ -n "${__fd:-}" ]; then
  ok "a caller may name its out-vars '__cand'/'__fd' and still get values back"
else
  bad "naming the out-vars after internal locals lost the values (__cand='${__cand:-}' __fd='${__fd:-}')"
fi

rm -rf "$T" 2>/dev/null || true
echo
echo "pr-lock: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
