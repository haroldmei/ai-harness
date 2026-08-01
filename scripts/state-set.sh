#!/usr/bin/env bash
# state-set.sh — write a field into the sharded blackboard, ROUTING by key prefix.
#
# Usage:
#   scripts/state-set.sh <jq_path> <json_value>
#
# Examples:
#   scripts/state-set.sh '.wedge_sentence' '"Two-click bookkeeping for Shopify DTC."'
#   scripts/state-set.sh '.scale_tier'     '"launch"'
#   scripts/state-set.sh '.phase_status.differentiation' '"done"'
#   scripts/state-set.sh '.kill_switches'  '["demand: <30 yes after 50 outreach"]'
#
# Since issue #1699 the blackboard is sharded per concern (product / testing /
# findings / index). This script routes the write to the owning shard by the jq
# path's top-level key (see scripts/lib/state-shard.sh) — so every existing caller
# (`state-set.sh '.testing.x' …`) keeps working unchanged and now lands in the
# right file. Atomic: writes to a temp file then renames. Safe under concurrent reads.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/state-shard.sh
source "$ROOT/scripts/lib/state-shard.sh"
STATE_DIR_RESOLVED="$(state_shard_dir)"
INDEX_FILE="$STATE_DIR_RESOLVED/state.json"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <jq_path> <json_value>" >&2
  exit 2
fi

if [[ ! -f "$INDEX_FILE" ]]; then
  echo "ERROR: $INDEX_FILE not found. Run scripts/state-init.sh first." >&2
  exit 1
fi

JQ_PATH="$1"
JSON_VAL="$2"

# ── Guard against jq-path injection ──────────────────────────────────────────────
# $JQ_PATH is interpolated UNQUOTED into the jq program ("$JQ_PATH = \$v"), so a crafted
# first arg is effectively arbitrary jq — e.g. `. = {}` (with a `{}` value) silently wipes
# the whole blackboard "successfully", and `.x) | (.y` would splice in extra filters. A
# less-capable driver model is exactly the caller that fat-fingers this. Restrict the path to
# a plain field/index selector: it must begin with `.<field>` / `."quoted"` / `[N]` and contain
# NONE of the jq operators/metacharacters needed to escape the assignment. Fail closed.
case "$JQ_PATH" in
  *[\ =\|\;\(\)\{\}\$\`\<\>\&\!]* | *$'\n'* | *$'\t'* )
    echo "ERROR: refusing unsafe jq path '$JQ_PATH' — contains an operator/whitespace. Only plain field/index paths are allowed (e.g. .scale_tier, .testing.gate_attempts.\"e2e\", .kill_switches[0])." >&2
    exit 2;;
esac
if [[ ! "$JQ_PATH" =~ ^\.([A-Za-z_][A-Za-z0-9_-]*|\"[^\"]+\"|\[[0-9]+\]) ]]; then
  echo "ERROR: refusing jq path '$JQ_PATH' — must start with a concrete field or index (.foo, .\"foo-bar\", or [0]); a bare '.' (whole-document) write is not allowed." >&2
  exit 2
fi

# Route to the shard that owns this key. On the first sharded write the target may
# not exist yet — bootstrap all shards from the monolith (idempotent) so no value
# is stranded in the old state.json during the transition.
STATE_FILE="$(state_shard_file "$JQ_PATH")"
[[ -f "$STATE_FILE" ]] || state_migrate

# READ-MODIFY-WRITE, so it needs a lock — `mv` makes the replacement atomic but does nothing about
# two writers that both read the pre-change file. The loser's edit is silently dropped: whoever
# calls `mv` last wins the whole document, not just its own key. Harmless while every writer was
# serialised behind one gate lock; a lost-update bug the moment builds run in parallel (two
# `iteration-count.sh --next` calls returning the same number, a digest entry vanishing).
#
# The lock is per SHARD FILE, so writes to different shards still proceed concurrently. flock is
# released when the fd closes, including on crash, so a killed writer cannot wedge the blackboard.
# STATE_SET_NO_LOCK=1 opts out for environments without flock.
_state_write() {
  local tmp; tmp="$(mktemp)"
  if jq --argjson v "$JSON_VAL" "$JQ_PATH = \$v" "$STATE_FILE" > "$tmp"; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
    echo "ERROR: jq failed writing $JQ_PATH to $STATE_FILE — state left unchanged" >&2
    return 1
  fi
}

if [[ "${STATE_SET_NO_LOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
  exec 8>"${STATE_FILE}.lock"
  flock 8
  _state_write || exit 1
  exec 8>&-
else
  _state_write || exit 1
fi

echo "✓ set $JQ_PATH"
jq "$JQ_PATH" "$STATE_FILE"
