#!/usr/bin/env bash
# Hermetic test for scripts/lib/state-shard.sh + state-set.sh + sget.sh + state-migrate.sh —
# the per-concern sharding of the blackboard that split the 83 KB state.json monolith
# into product/testing/findings + a thin index (#1699).
#
#   Run: bash scripts/state-shard.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/state-shard.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# A representative legacy monolith: one key from every namespace.
seed_monolith() { # <dir>
  cat > "$1/state.json" <<'JSON'
{
  "schema_version": 1,
  "iteration_count": 204,
  "scale_tier": "launch",
  "current_phase": "iterate",
  "axis": "adaptivity",
  "anti_axis": "content-breadth",
  "icp": "eng teams",
  "wedge_sentence": "Adaptive learning for tech teams.",
  "product_idea": "SkillForge",
  "kpi_targets": {"activation": 0.4},
  "testing": {"gate_attempts": {"e2e": 2}, "last_mutation_score": 63, "adversarial_rounds": 1,
              "last_verdict": "PASS", "last_run_at": null, "open_issues_drained": true},
  "open_issues": [
    {"id": "AT-001", "status": "open", "repro_test": "tests/adversarial/at_001.py"},
    {"id": "AT-002", "status": "closed"}
  ],
  "ml": {"enabled": false}
}
JSON
}

# ── Scenario 1: routing table ────────────────────────────────────────────────────
echo "Scenario 1 — state_shard_file routes each namespace to its own file"
T1="$(mktemp -d)"; export STATE_DIR="$T1"
source "$LIB"
eq "testing → testing.json"        "$(basename "$(state_shard_file '.testing.gate_attempts."e2e"')")" "testing.json"
eq "open_issues → findings.json"   "$(basename "$(state_shard_file '.open_issues[0].id')")"           "findings.json"
eq "axis → product.json"           "$(basename "$(state_shard_file '.axis')")"                        "product.json"
eq "wedge_sentence → product.json" "$(basename "$(state_shard_file '.wedge_sentence')")"              "product.json"
eq "kpi_targets → product.json"    "$(basename "$(state_shard_file '.kpi_targets')")"                 "product.json"
eq "scale_tier → state.json"       "$(basename "$(state_shard_file '.scale_tier')")"                  "state.json"
eq "iteration_count → state.json"  "$(basename "$(state_shard_file '.iteration_count')")"             "state.json"
eq "kill_switches[0] → state.json" "$(basename "$(state_shard_file '.kill_switches[0]')")"            "state.json"

# ── Scenario 2: migration splits the monolith, data lands in the right shard ──────
echo "Scenario 2 — state_migrate shards data into the owning files"
seed_monolith "$T1"
state_migrate
eq "testing lifted to testing.json"   "$(jq -r '.testing.last_mutation_score' "$T1/testing.json")"   "63"
eq "open_issues lifted to findings"   "$(jq -r '.open_issues[0].id' "$T1/findings.json")"             "AT-001"
eq "axis lifted to product.json"      "$(jq -r '.axis' "$T1/product.json")"                           "adaptivity"
eq "wedge lifted to product.json"     "$(jq -r '.wedge_sentence' "$T1/product.json")"                 "Adaptive learning for tech teams."
eq "index keeps scale_tier"           "$(jq -r '.scale_tier' "$T1/state.json")"                       "launch"
eq "index keeps iteration_count"      "$(jq -r '.iteration_count' "$T1/state.json")"                  "204"
eq "index keeps ml (non-sharded)"     "$(jq -r '.ml.enabled' "$T1/state.json")"                       "false"
eq "index bumped to schema_version 2" "$(jq -r '.schema_version' "$T1/state.json")"                   "2"
eq "index has product pointer"        "$(jq -r '.pointers.product' "$T1/state.json")"                 "state/product.json"

# The index must NO LONGER carry the sharded namespaces (that's the whole point).
eq "index dropped .testing"     "$(jq -r 'has("testing")' "$T1/state.json")"     "false"
eq "index dropped .open_issues" "$(jq -r 'has("open_issues")' "$T1/state.json")" "false"
eq "index dropped .axis"        "$(jq -r 'has("axis")' "$T1/state.json")"        "false"
eq "index dropped .wedge"       "$(jq -r 'has("wedge_sentence")' "$T1/state.json")" "false"

# ── Scenario 3: idempotency — a second migrate preserves post-migration writes ────
echo "Scenario 3 — migration is idempotent and never clobbers a sharded write"
# A stage writes a fresh value into the testing shard AFTER migration…
jq '.testing.last_mutation_score = 91' "$T1/testing.json" > "$T1/t.tmp" && mv "$T1/t.tmp" "$T1/testing.json"
state_migrate   # …re-running migrate must NOT reset it to the monolith's 63
eq "re-migrate preserves shard write" "$(jq -r '.testing.last_mutation_score' "$T1/testing.json")" "91"
eq "re-migrate keeps findings"        "$(jq -r '.open_issues[0].id' "$T1/findings.json")"          "AT-001"
eq "re-migrate index still v2"        "$(jq -r '.schema_version' "$T1/state.json")"                "2"

# ── Scenario 4: sset routes writes to the owning shard, not the index ─────────────
echo "Scenario 4 — sset (via state-set.sh) routes writes by prefix"
"$ROOT/scripts/state-set.sh" '.testing.gate_attempts."unit"' '3' >/dev/null
eq "testing write lands in testing.json" "$(jq -r '.testing.gate_attempts.unit' "$T1/testing.json")" "3"
eq "testing write does NOT touch index"  "$(jq -r 'has("testing")' "$T1/state.json")"                "false"
"$ROOT/scripts/state-set.sh" '.open_issues' '[{"id":"AT-009","status":"open"}]' >/dev/null
eq "findings write lands in findings.json" "$(jq -r '.open_issues[0].id' "$T1/findings.json")" "AT-009"
"$ROOT/scripts/state-set.sh" '.scale_tier' '"preview"' >/dev/null
eq "index write lands in state.json"       "$(jq -r '.scale_tier' "$T1/state.json")"          "preview"

# ── Scenario 5: sget reads from the owning shard (routed reads) ───────────────────
echo "Scenario 5 — sget reads route to the owning shard"
eq "sget testing"    "$("$ROOT/scripts/sget.sh" '.testing.gate_attempts.unit')"    "3"
eq "sget findings"   "$("$ROOT/scripts/sget.sh" '.open_issues[0].id' --raw)"       "AT-009"
eq "sget product"    "$("$ROOT/scripts/sget.sh" '.axis' --raw)"                    "adaptivity"
eq "sget index raw"  "$("$ROOT/scripts/sget.sh" '.scale_tier' --raw)"             "preview"
eq "sget missing → null" "$("$ROOT/scripts/sget.sh" '.testing.nope')"            "null"

# Regression (adversary #1699): a legit boolean `false` must read back as false,
# NOT null — jq's `//` treats false as absent, which silently corrupted the value
# and let a stale monolith value shadow it. Cover both the shard read and the
# monolith fallback with a real `false`.
"$ROOT/scripts/state-set.sh" '.testing.open_issues_drained' 'false' >/dev/null
eq "sget false stays false (shard)"       "$("$ROOT/scripts/sget.sh" '.testing.open_issues_drained')" "false"
eq "sget false stays false (raw)"         "$("$ROOT/scripts/sget.sh" '.testing.open_issues_drained' --raw)" "false"
# And a false value living ONLY in a not-yet-migrated monolith must survive the fallback.
T1b="$(mktemp -d)"; STATE_DIR="$T1b" bash -c '
  echo "{\"testing\":{\"open_issues_drained\":false}}" > "'"$T1b"'/state.json"
  STATE_DIR="'"$T1b"'" '"$ROOT"'/scripts/sget.sh ".testing.open_issues_drained" --raw
' > "$T1b/out" 2>/dev/null
eq "sget false via monolith fallback" "$(cat "$T1b/out")" "false"
rm -rf "$T1b" 2>/dev/null || true

# ── Scenario 6: backward compat — sget finds a value in a NOT-YET-migrated monolith ─
echo "Scenario 6 — old key paths keep working before migration (monolith fallback)"
T2="$(mktemp -d)"; export STATE_DIR="$T2"
seed_monolith "$T2"   # only state.json exists; no shards yet
eq "sget testing falls back to monolith" "$("$ROOT/scripts/sget.sh" '.testing.last_mutation_score' --raw)" "63"
eq "sget findings falls back to monolith" "$("$ROOT/scripts/sget.sh" '.open_issues[0].id' --raw)"          "AT-001"
eq "sget product falls back to monolith"  "$("$ROOT/scripts/sget.sh" '.axis' --raw)"                       "adaptivity"

# ── Scenario 7: migrate on an empty/fresh dir yields well-formed shards ────────────
echo "Scenario 7 — migrate bootstraps clean defaults on a fresh dir"
T3="$(mktemp -d)"; export STATE_DIR="$T3"
state_migrate
eq "fresh testing shape"  "$(jq -r '.testing.adversarial_rounds' "$T3/testing.json")" "0"
eq "fresh findings shape" "$(jq -r '.open_issues | length' "$T3/findings.json")"      "0"
eq "fresh product shape"  "$(jq -r '.axis' "$T3/product.json")"                       "null"
eq "fresh index v2"       "$(jq -r '.schema_version' "$T3/state.json")"               "2"

# ── Scenario 8: a jq failure must NOT truncate the target shard (regression, #2387) ─
# _shard_write used to be `jq … | _shard_write "$target"`, reading jq's stdout through a
# pipe — that hides jq's exit status behind `cat`'s, so a jq parse failure still looked
# like success and the unconditional `mv` clobbered the target with an empty file.
echo "Scenario 8 — state_migrate leaves a malformed state.json intact and reports failure"
T4="$(mktemp -d)"; export STATE_DIR="$T4"
printf '{"schema_version": 1, "iteration_count": 12' > "$T4/state.json"   # truncated JSON
before_size="$(wc -c < "$T4/state.json" | tr -d ' ')"
if state_migrate 2>/dev/null; then bad "state_migrate returns non-zero on jq failure (returned 0)"
else ok "state_migrate returns non-zero on jq failure"; fi
after_size="$(wc -c < "$T4/state.json" | tr -d ' ')"
eq "malformed state.json is left byte-for-byte intact" "$after_size" "$before_size"

unset STATE_DIR
rm -rf "$T1" "$T2" "$T3" "$T4" 2>/dev/null || true
echo
echo "state-shard: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
