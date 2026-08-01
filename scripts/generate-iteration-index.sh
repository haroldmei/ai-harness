#!/usr/bin/env bash
# generate-iteration-index.sh — regenerate docs/06-iteration-log.md from docs/iterations/.
#
# This replaces the old append-at-EOF monolithic log with a file that is
# strictly generated from the per-iteration files in docs/iterations/.
# No one should ever hand-edit this file — to add an iteration, create a new
# file under docs/iterations/.
#
# Usage:
#   scripts/generate-iteration-index.sh
#
# Env knobs:
#   ITERATIONS_DIR   override the iterations directory (tests)
#   INDEX_FILE        override the output path (tests)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITER_DIR="${ITERATIONS_DIR:-$ROOT/docs/iterations}"
INDEX="${INDEX_FILE:-$ROOT/docs/06-iteration-log.md}"

[ -d "$ITER_DIR" ] || { echo "ERROR: $ITER_DIR not found" >&2; exit 1; }

# Collect iteration files, sorted by their NNN prefix (descending)
# Was `ls -1 … | sort -r`. Parsing `ls` output breaks on any filename containing a newline
# and hides a failing glob behind the pipe; a bare glob is both safer and simpler here
# (issue #2387, hygiene). nullglob so a no-match expands to nothing instead of the literal.
shopt -s nullglob
mapfile -t FILES < <(printf '%s\n' "$ITER_DIR"/*.md | sort -r)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
  echo "WARNING: no iteration files found in $ITER_DIR" >&2
fi

{
  echo "# Iteration Log"
  echo ""
  echo "> ⚠️ **This file is auto-generated** from \`docs/iterations/\` by"
  echo "> \`scripts/generate-iteration-index.sh\`. Do NOT hand-edit it."
  echo "> To add an iteration, create a new file under \`docs/iterations/\`"
  echo "> following the naming convention in \`CLAUDE.md\`."
  echo ""
  echo "**Total iterations:** ${#FILES[@]}"
  echo ""
  echo "---"
  echo ""

  latest_date=""
  for f in "${FILES[@]}"; do
    basename="${f##*/}"
    # Extract iteration number from filename (NNN at start)
    n="${basename:0:3}"
    # Strip leading zeros for display
    n_display=$((10#$n))

    # Extract the first header line for the date + title
    header="$(head -1 "$f" 2>/dev/null || true)"
    # "## Iteration N — date — description" or "## Iteration N — date"
    title="${header#\#\# Iteration }"
    # Remove the iteration number to get "date — description" or "date"
    title="${title#${n_display} }"
    title="${title#— }"
    title="${title#- }"

    # Track latest date
    if [ -z "$latest_date" ]; then
      # Extract date from header (first YYYY-MM-DD)
      d="$(echo "$header" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
      [ -n "$d" ] && latest_date="$d"
    fi

    # Link to the individual file, title is the full header line minus the "## "
    printf -- '- [Iteration %s](iterations/%s) — %s\n' "$n_display" "$basename" "${title:-$basename}"
  done

  echo ""
  echo "---"
  echo ""
  echo "*Generated $(date -u +%Y-%m-%dT%H:%M:%SZ). ${#FILES[@]} iterations.*"
} > "$INDEX"

echo "generate-iteration-index: wrote ${#FILES[@]} iterations to $INDEX (latest date: ${latest_date:-unknown})"
