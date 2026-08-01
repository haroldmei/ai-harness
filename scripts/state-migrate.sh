#!/usr/bin/env bash
# state-migrate.sh — shard state/state.json into per-concern namespaces (issue #1699).
#
# Idempotent + backward compatible: splits the monolith into product.json /
# testing.json / findings.json and rewrites state.json as a thin index
# {schema_version, pointers, …index fields}. Safe to run repeatedly; an
# already-sharded value is authoritative and never clobbered. state-init.sh runs
# this automatically, but you can run it by hand after pulling a legacy state.json.
#
# Usage: scripts/state-migrate.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/state-shard.sh
source "$ROOT/scripts/lib/state-shard.sh"

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 2; }

state_migrate

DIR="$(state_shard_dir)"
echo "✓ blackboard sharded under $DIR"
echo "  index    : $(jq -c '{schema_version, pointers}' "$DIR/state.json")"
echo "  product  : $(jq -c 'keys' "$DIR/product.json")"
echo "  testing  : $(jq -c '.testing | keys' "$DIR/testing.json")"
echo "  findings : $(jq -c '{open_issues: (.open_issues | length)}' "$DIR/findings.json")"
