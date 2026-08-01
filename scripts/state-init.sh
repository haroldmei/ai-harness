#!/usr/bin/env bash
# state-init.sh — initialize the build-product-v2 blackboard.
#
# Usage:
#   scripts/state-init.sh "<product idea>"
#
# Idempotent: existing state.json is preserved; missing fields are added
# with null defaults so older runs upgrade cleanly.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/state-shard.sh
source "$ROOT/scripts/lib/state-shard.sh"
STATE_DIR="$ROOT/state"
STATE_FILE="$STATE_DIR/state.json"
DECISIONS_FILE="$STATE_DIR/decisions.md"
SIGNALS_FILE="$STATE_DIR/signals.json"

mkdir -p "$STATE_DIR"

PRODUCT_IDEA="${1:-${PRODUCT_IDEA:-SkillForge AI — adaptive corporate learning platform for tech teams}}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install with: sudo apt install jq  (or: brew install jq)" >&2
  exit 1
fi

# Build the canonical default state.
DEFAULT_STATE=$(jq -n \
  --arg now "$NOW" \
  --arg idea "$PRODUCT_IDEA" \
  '{
    schema_version: 1,
    started_at: $now,
    product_idea: $idea,
    wedge_sentence: null,
    icp: null,
    axis: null,
    anti_axis: null,
    scale_tier: "launch",
    current_phase: "iterate",
    phase_status: {},
    critic_verdicts: {},
    kill_switches: [],
    decisions: [],
    open_issues: [],
    kpi_targets: {},
    testing: {
      gate_attempts: {},
      open_issues_drained: false,
      adversarial_rounds: 0,
      last_mutation_score: null,
      last_verdict: null,
      last_run_at: null
    },
    signal_sources: {
      posthog:  { enabled: false, last_pull: null },
      sentry:   { enabled: false, last_pull: null },
      support:  { enabled: false, last_pull: null }
    },
    ml: {
      enabled: false,
      tier: "dashboard",
      task: null,
      relational: false,
      online: false,
      regulated: false,
      tracking: null,
      registry: null,
      serving: null,
      orchestrator: null,
      monitoring: null,
      decision: null,
      feasibility: { verdict: null, reasons: [], checked_at: null },
      baseline: { metric: null, value: null, higher_is_better: true },
      best_run: { id: null, metric: null, value: null, data_version: null, code_version: null },
      gate_metrics: {}
    }
  }')

if [[ -f "$STATE_FILE" ]]; then
  # Merge: existing state wins on overlapping keys, defaults fill missing.
  # Guarded (issue #2387): an unconditional `mv` after an unchecked jq moved a truncated
  # temp file over state.json whenever jq failed — destroying state rather than leaking a file.
  TMP=$(mktemp) || { echo "FATAL: mktemp failed" >&2; exit 1; }
  if jq -s '.[0] * .[1]' <(echo "$DEFAULT_STATE") "$STATE_FILE" > "$TMP"; then
    mv "$TMP" "$STATE_FILE"
    echo "✓ state.json upgraded in place (missing fields added)"
  else
    rm -f "$TMP"
    echo "FATAL: jq failed merging defaults into $STATE_FILE — left unchanged" >&2
    exit 1
  fi
else
  echo "$DEFAULT_STATE" > "$STATE_FILE"
  echo "✓ state.json initialized"
fi

# Decisions log: human-readable ADR stream.
if [[ ! -f "$DECISIONS_FILE" ]]; then
  cat > "$DECISIONS_FILE" <<EOF
# Decisions Log

> One-line ADRs. Format: \`- [YYYY-MM-DD] <phase>: <decision> — because <reason>\`

EOF
  echo "✓ decisions.md initialized"
fi

# Signals snapshot (separate file so signal-iterate can update freely).
if [[ ! -f "$SIGNALS_FILE" ]]; then
  jq -n --arg now "$NOW" '{
    initialized_at: $now,
    last_full_pull: null,
    behavior:  { funnel_conversion: null, activation_24h: null, retention_d7: null },
    failure:   { top_issues: [], crash_free_rate: null },
    voice:     { themes: [] }
  }' > "$SIGNALS_FILE"
  echo "✓ signals.json initialized"
fi

# Shard the blackboard into per-concern namespaces (idempotent, backward compatible, #1699).
state_migrate

echo
echo "State at: $STATE_FILE (sharded: product.json / testing.json / findings.json)"
jq -n \
  --argjson schema_version "$(jq '.schema_version' "$STATE_FILE")" \
  --argjson current_phase  "$(jq '.current_phase'  "$STATE_FILE")" \
  --argjson scale_tier     "$(jq '.scale_tier'     "$STATE_FILE")" \
  --argjson wedge_sentence "$(sget '.wedge_sentence')" \
  '{$schema_version, $current_phase, $scale_tier, $wedge_sentence}'
