#!/usr/bin/env bash
# iteration-immutable-check.sh — reject PRs that modify existing iteration files.
#
# Once written, an iteration file under docs/iterations/ is immutable. A PR must
# only ADD new iteration files, never modify or delete existing ones (issue #2167).
# This prevents the "two branches both editing the same line" conflict that the
# per-file split was designed to eliminate, and protects against corrupting other
# people's history.
#
# Usage:
#   scripts/iteration-immutable-check.sh               check vs origin/main
#   scripts/iteration-immutable-check.sh --base <ref>   check vs a different base
#
# Returns 0 if no existing iteration files are modified/deleted.
# Returns 1 if any are.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${1:-origin/main}"
if [ "$BASE" = "--base" ]; then
  BASE="${2:-origin/main}"
fi
ITER_DIR="${ITERATIONS_DIR:-$ROOT/docs/iterations}"

[ -d "$ITER_DIR" ] || { echo "iteration-immutable: no iterations dir — nothing to check"; exit 0; }

# Files that exist on the base branch but are modified or deleted on HEAD.
# We use git diff --name-status base...HEAD to see what changed.
# Status codes: M = modified, D = deleted, R = renamed.
VIOLATIONS="$(git diff --name-status --diff-filter=MD "$BASE"...HEAD -- "$ITER_DIR/" 2>/dev/null || true)"

if [ -z "$VIOLATIONS" ]; then
  echo "iteration-immutable: clean — no existing iteration files modified or deleted"
  exit 0
fi

echo "iteration-immutable: VIOLATION — these existing iteration files were modified or deleted:"
echo "$VIOLATIONS" | while IFS=$'\t' read -r status path; do
  echo "  $status  $path"
done
echo ""
echo "Iteration files are immutable after creation (issue #2167)."
echo "Create a NEW file under docs/iterations/ instead of modifying an existing one."
exit 1
