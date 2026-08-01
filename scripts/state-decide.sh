#!/usr/bin/env bash
# state-decide.sh — append a one-line ADR to state/decisions.md AND state.decisions[]
#
# Usage:
#   scripts/state-decide.sh <phase> "<decision>" "<reason>"
#
# Example:
#   scripts/state-decide.sh designer "monolith over microservices" "preview tier; 1 dev, 0 users"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT/state/state.json"
DECISIONS_MD="$ROOT/state/decisions.md"

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <phase> <decision> <reason>" >&2
  exit 2
fi

PHASE="$1"
DECISION="$2"
REASON="$3"
DATE="$(date -u +%Y-%m-%d)"

LINE="- [$DATE] $PHASE: $DECISION — because $REASON"

# Append to human-readable log.
echo "$LINE" >> "$DECISIONS_MD"

# Mirror into JSON state.
# Guarded (issue #2387): an unconditional `mv` after an unchecked jq moved a truncated temp
# file over state.json whenever jq failed, destroying state rather than leaking a temp file.
TMP=$(mktemp) || { echo "FATAL: mktemp failed" >&2; exit 1; }
if jq --arg date "$DATE" \
   --arg phase "$PHASE" \
   --arg decision "$DECISION" \
   --arg reason "$REASON" \
   '.decisions += [{date:$date, phase:$phase, decision:$decision, reason:$reason}]' \
   "$STATE_FILE" > "$TMP"; then
  mv "$TMP" "$STATE_FILE"
else
  rm -f "$TMP"
  echo "FATAL: jq failed appending the decision to $STATE_FILE — left unchanged" >&2
  exit 1
fi

echo "✓ recorded: $LINE"
