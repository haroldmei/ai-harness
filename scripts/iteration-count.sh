#!/usr/bin/env bash
# iteration-count.sh — the iteration number, read from state instead of scanning files.
#
# `iterate`/`signal-iterate` need "which iteration is this" every run. The old way
# (docs/06-iteration-log.md:count-the-headers) means reading a 700 KB+ append-only log
# on EVERY inbox build just to learn a single integer — the single largest avoidable
# token sink in the single-issue fast path (issue #1696). This makes the counter a
# cheap O(1) field, `.iteration_count`, in state/state.json.
#
# Usage:
#   scripts/iteration-count.sh          → print the current (highest completed) iteration number
#   scripts/iteration-count.sh --next   → reserve the next number: increment, persist, print it
#   scripts/iteration-count.sh --peek-next → print current+1 WITHOUT persisting
#
# Migration: if `.iteration_count` is absent/null, it is seeded ONCE from the highest
# NNN prefix in docs/iterations/ (0 if no files exist), then persisted — so an existing
# project keeps its numbering without a manual backfill.
#
# Atomic: writes to a temp file then renames. Safe under concurrent reads.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${ITERATION_STATE_FILE:-$ROOT/state/state.json}"
ITER_DIR="${ITERATIONS_DIR:-$ROOT/docs/iterations}"

mode="${1:-current}"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: $STATE_FILE not found. Run scripts/state-init.sh first." >&2
  exit 1
fi

# ── Highest iteration number recorded in docs/iterations/ (migration seed only) ──
# Filename format: NNN-issue-NNNN-slug.md. Numbers can appear out of order and some
# NNN prefixes can be duplicated, so take the MAX, not the count.
log_max() {
  [[ -d "$ITER_DIR" ]] || { echo 0; return; }
  local m
  # Extract NNN prefix, strip leading zeros, take max
  # Bare glob rather than parsing `ls` (issue #2387, hygiene) — same reasons as
  # generate-iteration-index.sh.
  shopt -s nullglob
  m="$(printf '%s\n' "$ITER_DIR"/*.md | sed -E 's|.*/([0-9]+)-.*|\1|' | sed 's/^0*//' | sort -n | tail -1)"
  shopt -u nullglob
  # If all were stripped (e.g., "000"), output 0
  echo "${m:-0}"
}

# ── Current count: the state field, seeded from the log on first read ────────────
current() {
  local c
  c="$(jq -r '.iteration_count // empty' "$STATE_FILE")"
  if [[ -z "$c" ]]; then
    c="$(log_max)"
    persist "$c"            # one-time migration so the next read is O(1)
  fi
  echo "$c"
}

persist() { # <value>
  # Guarded (issue #2387): this was `jq … > "$tmp"` followed by an UNCONDITIONAL `mv`. A jq
  # failure (malformed input, disk full, OOM) left $tmp empty or truncated and then moved it
  # over the real state file — silently destroying it rather than leaking a temp file. Check
  # jq's status before the mv, and clean up the temp file on the failure path.
  local tmp
  tmp="$(mktemp)" || { echo "FATAL: mktemp failed — not persisting the iteration count" >&2; return 1; }
  if jq --argjson v "$1" '.iteration_count = $v' "$STATE_FILE" > "$tmp"; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
    echo "FATAL: jq failed updating $STATE_FILE — left unchanged" >&2
    return 1
  fi
}

case "$mode" in
  current)     current ;;
  --peek-next) echo $(( $(current) + 1 )) ;;
  --next)
    n=$(( $(current) + 1 ))
    persist "$n"
    echo "$n" ;;
  *)
    echo "Usage: $0 [--next|--peek-next]" >&2
    exit 2 ;;
esac
