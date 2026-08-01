#!/usr/bin/env bash
# agent-sandbox.sh — keep a `--permission-mode bypassPermissions` model OUT of the primary checkout.
#
# The problem this solves (2026-07-26): the reviewer handed the model a linked `git worktree` and
# `cd`'d into it, then trusted it to stay there. A model that runs with bypassPermissions has no
# reason to: it `cd`s to the primary repo it can see in its context and runs `git checkout <pr>`
# there. That switched the primary checkout off `main` mid-review and left a conflicted merge in
# it — while the systemd timers were executing harness scripts out of that same checkout.
# `agent-pr-reviewer.sh` had warned about exactly this in a comment for months; a comment is not
# an enforcement mechanism.
#
# Two pieces, and BOTH are needed:
#
#   sandbox_clone   A linked worktree cannot be isolated. Its `.git` is a POINTER FILE
#                   (`gitdir: <primary>/.git/worktrees/<name>`), so hiding the primary breaks git
#                   inside the worktree. A local `git clone` is self-contained instead: on one
#                   filesystem git hardlinks the objects, which measured 0.11s for this repo's
#                   83M of history, and writes NO `objects/info/alternates` — so nothing reaches
#                   back into the source once it is created.
#
#   sandbox_run     Hides a path from the command with a bubblewrap tmpfs overlay. Everything
#                   else — $HOME/.claude credentials, node, the network, /tmp logs — stays bound
#                   read-write, so only the one directory disappears. The overlay is per-process:
#                   writes into it land in the tmpfs and evaporate on exit, they never touch disk.
#
# The clone alone is not enough (the model can still `cd` to the primary); the overlay alone is
# not enough (it would break a linked worktree's git). Together the model cannot see, let alone
# mutate, the checkout the timers run from.
#
# Availability: bubblewrap needs unprivileged user namespaces. `sandbox_available` probes for
# real rather than assuming, because a kernel that refuses userns must degrade loudly, not
# silently drop the isolation and look like it worked.
#
# NOTE ON `set -`: this file is a LIBRARY and deliberately sets NO shell options. A sourced lib
# runs in the CALLER's shell, so a `set -e` here would silently abort every "collector" script
# (the gate and agent stages) at its first *tolerated* failure — the ones that must survive a
# failing step in order to report, classify or clean up. Signal failure with return codes only.
# This is a deliberate design choice, not an oversight: do not "fix" it by adding `set -e`.
# See "Shell-option classes" in docs/AGENT-HARNESS.md (#2390).

# Guard against double-sourcing (the caller may source this via more than one path).
[ -n "${_AGENT_SANDBOX_SH:-}" ] && return 0
_AGENT_SANDBOX_SH=1

# sandbox_available — 0 when bwrap can actually create a namespace here, 1 otherwise.
# Probes once and memoises: this runs per review and the probe costs a fork.
sandbox_available() {
  if [ -z "${_SANDBOX_OK:-}" ]; then
    if command -v bwrap >/dev/null 2>&1 \
       && bwrap --dev-bind / / --tmpfs /tmp --die-with-parent true >/dev/null 2>&1; then
      _SANDBOX_OK=0
    else
      _SANDBOX_OK=1
    fi
  fi
  return "$_SANDBOX_OK"
}

# sandbox_clone <src_repo> <dest> <ref>
# Self-contained clone of <src_repo> with <ref> checked out. <ref> is resolved in the SOURCE and
# fetched by SHA, so a stale local branch in the source cannot be picked up by accident — that
# staleness is what turned an ordinary sync into a conflicted merge on 2026-07-26.
# Leaves `origin` pointing at the source's own remote URL, not at the source path: inside the
# sandbox that path is empty, and a remote that silently resolves to nothing invites confusion.
sandbox_clone() {
  local src="$1" dest="$2" ref="$3" sha url
  sha="$(git -C "$src" rev-parse --verify -q "${ref}^{commit}")" || return 1
  rm -rf "$dest" 2>/dev/null || true
  git clone --quiet --no-checkout "$src" "$dest" 2>/dev/null || return 1
  # The SHA may live only in a remote-tracking ref, which `git clone` does not copy as a branch.
  git -C "$dest" fetch --quiet "$src" "$sha" 2>/dev/null || return 1
  git -C "$dest" checkout --quiet --detach "$sha" 2>/dev/null || return 1
  url="$(git -C "$src" remote get-url origin 2>/dev/null)"
  [ -n "$url" ] && git -C "$dest" remote set-url origin "$url" 2>/dev/null
  return 0
}

# sandbox_run <hidden_path> [--expose <path>]... -- <cmd...>
# Runs <cmd...> with <hidden_path> replaced by an empty tmpfs.
#
# --expose re-binds a path back on top of that tmpfs. It is required because hiding a directory
# hides EVERYTHING under it, including things the run legitimately owns: the model binary itself
# when $CLAUDE resolves inside the repo, and the log/verdict directory whenever a caller points
# it there. Without this the model silently never runs — which is worse than the bug being fixed,
# because the reviewer would still report a verdict-less failure rather than an obvious crash.
#
# A path is bound ONLY when it genuinely resolves under <hidden_path>. Binding an unrelated path
# is NOT harmless, which is how this first shipped broken: `command -v claude` yields
# `~/.local/bin/claude`, a SYMLINK into ~/.local/share/claude/versions/. bwrap cannot create a
# mountpoint over a symlink and aborts the whole sandbox —
#   bwrap: Can't create file at /home/hmei/.local/bin/claude: No such file or directory
# — so the model never launched and two PRs were labelled review-stuck with "could not produce a
# verdict". Paths outside <hidden_path> are already visible through --dev-bind and need nothing.
#
# Comparison and binding both use the RESOLVED path, so a symlink is never a mountpoint. A path
# that does not exist is skipped: bwrap refuses to bind a missing source and would take the whole
# review down with it.
#
# Falls through to running the command unchanged when bwrap is unavailable, so a box without user
# namespaces still reviews — the CALLER logs that the isolation was not applied.
# --die-with-parent: a killed reviewer must not leave the model running against a stale namespace.
sandbox_run() {
  local hidden="$1"; shift
  local hidden_real; hidden_real="$(readlink -f "$hidden" 2>/dev/null || printf '%s' "$hidden")"
  local -a expose=()
  local real
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expose)
        if [ -e "${2:-}" ]; then
          real="$(readlink -f "$2" 2>/dev/null || printf '%s' "$2")"
          # Only what the tmpfs actually hides. Anything else stays visible via --dev-bind, and
          # binding it is what broke the sandbox outright the first time round.
          case "$real" in "$hidden_real"/*) expose+=("$real") ;; esac
        fi
        shift 2 ;;
      --)       shift; break ;;
      *)        break ;;
    esac
  done

  if ! sandbox_available; then
    "$@"
    return $?
  fi

  local -a args=(--dev-bind / / --tmpfs "$hidden")
  local p
  for p in "${expose[@]}"; do
    # Order matters: every --expose is applied AFTER the tmpfs, so it layers on top of it.
    args+=(--bind "$p" "$p")
  done
  args+=(--die-with-parent)
  bwrap "${args[@]}" "$@"
}
