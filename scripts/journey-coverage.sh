#!/usr/bin/env bash
# journey-coverage.sh — every catalogued USER JOURNEY must have a real e2e spec.
#   Reads state/artifacts/journeys.json (.journeys[] = {id,name,spec,priority?}).
#   For each REQUIRED journey, the .spec file must exist on disk AND contain a real
#   Playwright test (a `test(`/`test.describe(` call) — a placeholder/empty file does
#   not satisfy the gate. This is journey→test (vs wedge-coverage's file→test).
#
# Priority/tier: if a journey carries .priority (P0/P1/…), P0 is required at every tier
# and P1 becomes required at launch+ (scale). Journeys with NO .priority are treated as
# required at every tier (the current data has no priority field, so all are required).
# TIER is read from the environment (gate_journey_coverage passes it through; default launch).
#
# Exit: 0 all required journeys covered | 1 a required journey lacks a real spec
#       | 77 no journeys.json (nothing to enforce).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

MANIFEST="state/artifacts/journeys.json"
[[ -f "$MANIFEST" ]] || { echo "no $MANIFEST (emit it to enforce journey coverage)"; exit 77; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

TIER="${TIER:-launch}"

# Is a journey of the given priority required at the current tier?
#   P0 → always required. P1 → required at launch+ (launch, scale). empty → always required.
required_at_tier() {
  local prio="$1"
  case "$prio" in
    ""|-|null|P0) return 0;;
    P1) [[ "$TIER" == "launch" || "$TIER" == "scale" ]] && return 0 || return 1;;
    *)  [[ "$TIER" == "scale" ]] && return 0 || return 1;;   # P2+ only at scale
  esac
}

missing=""
checked=0
while IFS=$'\t' read -r id prio spec; do
  [[ -z "$id" ]] && continue
  if ! required_at_tier "$prio"; then
    continue   # not required at this tier
  fi
  checked=$((checked + 1))
  if [[ -z "$spec" || "$spec" == "null" ]]; then
    missing+="  - ${id}: no spec recorded"$'\n'
  elif [[ ! -f "$spec" ]]; then
    missing+="  - ${id}: spec '${spec}' missing on disk"$'\n'
  elif ! grep -qE '\b(test|test\.describe)\s*\(' "$spec"; then
    missing+="  - ${id}: spec '${spec}' has no test()/test.describe() — placeholder?"$'\n'
  fi
# NB: `read` with whitespace IFS coalesces consecutive tabs, so an empty middle field
# (no .priority) would shift columns. Emit "-" for a missing priority to keep 3 fields.
done < <(jq -r '.journeys[]? | [(.id // "?"), (.priority // "-"), (.spec // "null")] | @tsv' "$MANIFEST")

if [[ -n "$missing" ]]; then
  echo "user journeys (required at tier '$TIER') lack a real e2e spec:"
  printf '%s' "$missing"
  exit 1
fi
echo "all $checked journey(s) required at tier '$TIER' have a real e2e spec"
