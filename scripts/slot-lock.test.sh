#!/usr/bin/env bash
# Hermetic test for scripts/lib/slot-lock.sh — the counting semaphore behind parallel gate runs.
#
# The properties that matter are the ones a mutex does NOT give you: N concurrent holders, distinct
# indices (they name compose projects and port bands, so a duplicate index means container
# cross-talk), release on crash, and refusal to over-admit.
#
#   Run: bash scripts/slot-lock.test.sh     (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/slot-lock.sh
source "$ROOT/scripts/lib/slot-lock.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; P="$T/slot"

# ── 1: a single acquire takes slot 0 ─────────────────────────────────────────────
echo "1 — first acquirer gets slot 0"
slot_acquire s "$P" 3 8
held_after="$(slot_free_count "$P" 3)"
[ "$s" = "0" ] && ok "first acquire → slot 0" || bad "first acquire → slot 0 (got '$s')"
# THE regression that matters: the lock must still be held after slot_acquire RETURNS. The original
# API printed the index, so the natural `slot=$(slot_acquire …)` took the lock in a subshell that
# exited immediately — two concurrent gate runs both reported slot 0 and neither held anything.
# With 3 slots and 1 genuinely held, exactly 2 must remain free.
[ "$held_after" = "2" ] && ok "lock is still held after the call returns (2/3 free)" \
  || bad "slot not actually held after acquire — got $held_after/3 free, expected 2"

# Release it before the next case: this shell really IS holding slot 0 now (that is the point of the
# assertion above), so leaving fd 8 open would leave only 2 slots for the 3 holders below.
exec 8>&-

# ── 2: N concurrent holders get N DISTINCT slots ─────────────────────────────────
# Each child holds its slot until it is told to exit, so the parent observes them simultaneously.
echo "2 — three concurrent holders get three distinct slots"
for i in 0 1 2; do
  ( slot_acquire got "$P" 3 8; printf '%s\n' "$got" > "$T/got.$i"; while [ ! -f "$T/release" ]; do sleep 0.05; done ) &
done
for _ in $(seq 1 100); do
  [ "$(ls "$T"/got.* 2>/dev/null | wc -l)" = "3" ] && break
  sleep 0.1
done
got="$(cat "$T"/got.* 2>/dev/null | sort | tr '\n' ' ')"
uniq_n="$(cat "$T"/got.* 2>/dev/null | sort -u | wc -l)"
[ "$uniq_n" = "3" ] && ok "three holders → three distinct slots ($got)" \
  || bad "expected 3 distinct slots, got '$got'"

# ── 3: the 4th waits while all 3 are held ────────────────────────────────────────
echo "3 — a 4th acquirer is refused while all slots are held"
if SLOT_LOCK_POLL=0.1 slot_acquire s4 "$P" 3 9 1 2>/dev/null; then
  bad "4th acquirer must not be admitted while 3/3 are held"
else
  ok "4th acquirer blocked (timed out) rather than over-admitting"
fi

# ── 4: releasing frees a slot for the waiter ──────────────────────────────────────
echo "4 — a slot freed by an exiting holder is reusable"
touch "$T/release"; wait
s2=""; SLOT_LOCK_POLL=0.1 slot_acquire s2 "$P" 3 8 1 2>/dev/null || true
[ -n "$s2" ] && ok "slot reacquired after the holders exited (slot $s2)" \
  || bad "slot should be reacquirable once holders exit"

# ── 5: the lock dies with the process — no stale-lock reaper needed ───────────────
# A holder that is SIGKILLed (never runs cleanup) must not wedge the semaphore.
echo "5 — SIGKILLed holder releases its slot (kernel-backed, no reaper)"
P2="$T/kill"
# `exec` so the holder IS the sleep: a forked child would INHERIT fd 8 and keep the lock alive
# after the parent dies, which is a real property of flock (see the note in slot-lock.sh), not a
# bug — but it would make this test assert the wrong thing.
( slot_acquire _s "$P2" 1 8; exec sleep 30 ) &
victim=$!
for _ in $(seq 1 50); do [ -e "${P2}-0.lock" ] && break; sleep 0.1; done
sleep 0.3
kill -9 "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
if SLOT_LOCK_POLL=0.1 slot_acquire _s2 "$P2" 1 9 2 2>/dev/null; then
  ok "slot recovered after SIGKILL without any cleanup step"
else
  bad "a SIGKILLed holder wedged the semaphore"
fi

# ── 6: a bad slot count is refused, not silently treated as 1 ─────────────────────
echo "6 — invalid slot counts are refused"
for badn in 0 -1 abc ""; do
  if slot_acquire _b "$T/bad" "$badn" 8 2>/dev/null; then
    bad "slots='$badn' must be refused"
  else
    ok "slots='$badn' refused"
  fi
done

rm -rf "$T" 2>/dev/null || true
echo
echo "slot-lock: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
