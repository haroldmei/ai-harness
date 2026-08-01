#!/usr/bin/env bash
# slot-lock.sh — a counting semaphore over flock, for "N of these may run at once".
#
# The harness has several places that need "one at a time" relaxed to "at most N at a time":
# quality-gates runs that boot an ephemeral stack, and (later) the inbox / reviewer / fixer stages.
# A plain mutex is one lockfile; a semaphore of N is N lockfiles and a scan for a free one. The
# INDEX matters as much as the exclusion: the holder uses it to derive a private compose project
# name and port band, which is what actually makes concurrent runs safe.
#
#   source scripts/lib/slot-lock.sh
#   slot_acquire QG_SLOT /tmp/qg-slot-abc123 3 8 || exit 1   # blocks until a slot frees
#   # ... fd 8 now holds slot $QG_SLOT for the lifetime of this shell ...
#
# It ASSIGNS the index to a caller-named variable and prints nothing, which is deliberate. An
# earlier version printed the index, and the obvious call — `slot=$(slot_acquire …)` — is silently
# broken: command substitution runs in a SUBSHELL, so the fd opens and the flock is taken there and
# released the instant the subshell exits. Every caller then "acquires" slot 0 and none of them
# holds anything. Printing nothing makes that mistake unwritable.
#
# The fd is held OPEN deliberately: the kernel drops the lock when the last fd referencing it
# closes, so a crashed or SIGKILLed holder can never wedge the semaphore (no stale-lock reaper
# needed — the same property the existing single-mutex callers already rely on).
#
# Caveat worth knowing, since it bit this file's own test: forked children INHERIT the fd, so the
# slot stays held until every descendant holding it exits, not just the acquirer. That is normally
# what you want (a gate's spawned pytest/compose tree should keep the slot), but it means killing
# only the parent of a process tree does not release the slot. `_kill_tree` in quality-gates.sh
# already kills whole trees for exactly this class of reason.
#
# Fairness: barging, not FIFO. A waiter scans 0..N-1 and retries after SLOT_LOCK_POLL seconds, so a
# steady stream of arrivals can in principle delay one waiter. That is acceptable here — every
# caller is a background pipeline stage with no latency SLA, and the alternative (a ticket queue in
# the filesystem) needs its own crash recovery, which is exactly the complexity flock avoids.
#
# NOTE ON `set -`: this file is a LIBRARY and deliberately sets NO shell options. A sourced lib
# runs in the CALLER's shell, so a `set -e` here would silently abort every "collector" script
# (the gate and agent stages) at its first *tolerated* failure — the ones that must survive a
# failing step in order to report, classify or clean up. Signal failure with return codes only.
# This is a deliberate design choice, not an oversight: do not "fix" it by adding `set -e`.
# See "Shell-option classes" in docs/AGENT-HARNESS.md (#2390).

# slot_acquire <out-var> <lock-prefix> <slots> <fd> [timeout-seconds]
# Assigns the acquired slot index (0-based) to <out-var>. Prints NOTHING — see the header note on
# why returning it via stdout is a footgun. Returns 1 if <timeout-seconds> elapses, 2 on bad input.
slot_acquire() {
  local __outvar="$1" prefix="$2" slots="$3" fd="$4" timeout="${5:-0}"
  local k start=$SECONDS

  if ! [[ "$slots" =~ ^[0-9]+$ ]] || [ "$slots" -lt 1 ]; then
    echo "slot_acquire: slots must be a positive integer (got '$slots')" >&2
    return 2
  fi

  while :; do
    for (( k = 0; k < slots; k++ )); do
      # Open then try to take it. On failure the fd MUST be closed again, or the next sweep
      # would re-test a descriptor that is already ours and report success spuriously.
      eval "exec ${fd}>\"${prefix}-${k}.lock\"" 2>/dev/null || continue
      if flock -n "$fd" 2>/dev/null; then
        printf -v "$__outvar" '%s' "$k"
        return 0
      fi
      eval "exec ${fd}>&-" 2>/dev/null || true
    done
    if [ "$timeout" -gt 0 ] && [ $(( SECONDS - start )) -ge "$timeout" ]; then
      echo "slot_acquire: no free slot in ${prefix} after ${timeout}s (${slots} slots)" >&2
      return 1
    fi
    sleep "${SLOT_LOCK_POLL:-2}"
  done
}

# slot_free_count <lock-prefix> <slots> — how many slots are currently unheld. Diagnostics only:
# the answer is stale the moment it returns, so never gate a decision on it.
slot_free_count() {
  local prefix="$1" slots="$2" k free=0
  for (( k = 0; k < slots; k++ )); do
    if ( exec 199>"${prefix}-${k}.lock" && flock -n 199 ) 2>/dev/null; then
      free=$(( free + 1 ))
    fi
  done
  printf '%s\n' "$free"
}
