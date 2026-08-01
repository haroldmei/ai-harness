#!/usr/bin/env bash
# sget.sh — routed READ from the sharded blackboard (issue #1699).
#
# Usage:
#   scripts/sget.sh <jq_path> [--raw]
#
# Examples:
#   scripts/sget.sh '.scale_tier' --raw           # → launch          (index shard)
#   scripts/sget.sh '.testing.last_mutation_score' # → 63             (testing shard)
#   scripts/sget.sh '.open_issues'                 # → [ … ]          (findings shard)
#
# Routes by the jq path's top-level key to the owning shard file, with a
# transition fallback to the old monolith state.json when a shard has no value
# yet — so old key paths keep working during migration. --raw unwraps strings.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/state-shard.sh
source "$ROOT/scripts/lib/state-shard.sh"

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <jq_path> [--raw]" >&2
  exit 2
fi

sget "$1" "${2:-}"
