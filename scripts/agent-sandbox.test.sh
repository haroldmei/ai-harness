#!/usr/bin/env bash
# Hermetic tests for scripts/lib/agent-sandbox.sh — temp dirs only, no network, no DB.
#
#   Run: bash scripts/agent-sandbox.test.sh    (exit 0 = all pass, 77 = skipped)
#
# These assert the PROPERTY, not the implementation: after sandbox_clone + sandbox_run, a command
# behaving exactly like the runaway reviewer model (cd to the primary checkout, git checkout a PR
# branch there) must fail to affect the primary. A test that merely greps for "bwrap" in the
# source would have passed on the broken version too.
set -uo pipefail

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/agent-sandbox.sh
source "$ROOT/scripts/lib/agent-sandbox.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# A stand-in "primary checkout": main plus a PR branch, exactly the shape the reviewer sees.
PRIMARY="$TMP/primary"
git init -q -b main "$PRIMARY"
( cd "$PRIMARY"
  echo base > file.txt; git add -A; git commit -qm base
  git checkout -q -b agent/issue-9; echo pr > file.txt; git add -A; git commit -qm pr
  git checkout -q main
  # A remote-tracking ref is what the reviewer resolves; clone does NOT copy it as a branch.
  git update-ref refs/remotes/origin/agent/issue-9 refs/heads/agent/issue-9 ) >/dev/null 2>&1

CLONE="$TMP/clone"

# ── sandbox_clone ────────────────────────────────────────────────────────────────
if sandbox_clone "$PRIMARY" "$CLONE" "origin/agent/issue-9"; then
  ok "sandbox_clone succeeds against a remote-tracking ref"
else
  bad "sandbox_clone succeeds against a remote-tracking ref" "returned non-zero"
fi

[ "$(cat "$CLONE/file.txt" 2>/dev/null)" = "pr" ] \
  && ok "clone has the PR head checked out" \
  || bad "clone has the PR head checked out" "file.txt=$(cat "$CLONE/file.txt" 2>/dev/null)"

# The whole reason a clone replaced the worktree: no pointer back into the primary.
[ -d "$CLONE/.git" ] \
  && ok "clone has a real .git directory (not a worktree pointer file)" \
  || bad "clone has a real .git directory" ".git is a file — a linked worktree cannot be isolated"

[ ! -e "$CLONE/.git/objects/info/alternates" ] \
  && ok "clone writes no objects/info/alternates" \
  || bad "clone writes no alternates" "alternates would reach back into the hidden primary"

# ── the property: the primary is unreachable ─────────────────────────────────────
if ! sandbox_available; then
  printf '  SKIP bwrap unavailable — isolation assertions cannot run here\n'
  printf '%s passed, %s failed (isolation skipped)\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && exit 77 || exit 1
fi

before="$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)"

# Behave exactly like the runaway model: cd into the primary and switch branches there.
sandbox_run "$PRIMARY" bash -c "cd '$PRIMARY' 2>/dev/null && git checkout -q agent/issue-9" >/dev/null 2>&1

after="$(git -C "$PRIMARY" rev-parse --abbrev-ref HEAD)"
[ "$before" = "$after" ] \
  && ok "a git checkout inside the sandbox cannot move the primary's HEAD (still $after)" \
  || bad "sandbox must not let the primary's HEAD move" "was $before, now $after"

seen="$(sandbox_run "$PRIMARY" bash -c "ls -A '$PRIMARY' 2>/dev/null | wc -l")"
[ "$seen" = "0" ] \
  && ok "the primary checkout is empty inside the sandbox" \
  || bad "the primary checkout must be empty inside the sandbox" "saw $seen entries"

# Hiding the primary must not cost the model its own repo — that would trade one break for another.
inside="$(sandbox_run "$PRIMARY" bash -c "cd '$CLONE' && git log --oneline -1 2>/dev/null | wc -l")"
[ "$inside" = "1" ] \
  && ok "the clone still works with the primary hidden (hardlinked objects survive)" \
  || bad "the clone must still work with the primary hidden" "git log returned $inside lines"

# Writes into the overlay must evaporate rather than reach disk.
sandbox_run "$PRIMARY" bash -c "touch '$PRIMARY/leaked.txt'" >/dev/null 2>&1
[ ! -e "$PRIMARY/leaked.txt" ] \
  && ok "writes into the hidden path do not reach the real directory" \
  || bad "writes into the hidden path leaked to disk" "$PRIMARY/leaked.txt exists"

# ── --expose regression: the shape that shipped broken ───────────────────────────
# `command -v claude` yields ~/.local/bin/claude, a SYMLINK to ~/.local/share/claude/versions/X.
# bwrap cannot mount over a symlink and aborts the entire sandbox, so the model never launched
# and PRs #2173/#2194 went review-stuck with "could not produce a verdict". An --expose target
# OUTSIDE the hidden path must therefore be ignored, not bound.
mkdir -p "$TMP/opt/real" "$TMP/bin"
printf '#!/usr/bin/env bash\necho ran\n' > "$TMP/opt/real/tool"; chmod +x "$TMP/opt/real/tool"
ln -s "$TMP/opt/real/tool" "$TMP/bin/tool"

out="$(sandbox_run "$PRIMARY" --expose "$TMP/bin/tool" -- "$TMP/bin/tool" 2>&1)"
[ "$out" = "ran" ] \
  && ok "--expose on a symlink OUTSIDE the hidden path does not break the sandbox" \
  || bad "--expose on an outside symlink must be ignored" "got: $out"

# The inside case must still work — that is the whole reason --expose exists.
mkdir -p "$PRIMARY/tools"
printf '#!/usr/bin/env bash\necho inside\n' > "$PRIMARY/tools/t"; chmod +x "$PRIMARY/tools/t"
out="$(sandbox_run "$PRIMARY" --expose "$PRIMARY/tools/t" -- "$PRIMARY/tools/t" 2>&1)"
[ "$out" = "inside" ] \
  && ok "--expose still re-binds a path INSIDE the hidden path" \
  || bad "--expose must re-bind a path inside the hidden path" "got: $out"

# ...and exposing one path must not un-hide the rest of the directory.
seen="$(sandbox_run "$PRIMARY" --expose "$PRIMARY/tools/t" -- bash -c "ls -A '$PRIMARY' | wc -l")"
[ "$seen" = "1" ] \
  && ok "--expose re-binds only what was asked for (primary still otherwise hidden)" \
  || bad "--expose must not un-hide the whole directory" "saw $seen entries, expected 1"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
