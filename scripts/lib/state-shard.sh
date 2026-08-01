#!/usr/bin/env bash
# state-shard.sh — namespace routing for the sharded blackboard (issue #1699).
#
# state/state.json used to be an 83 KB monolith mixing four unrelated concerns:
# product strategy, pipeline-testing state, adversarial findings, and phase/ML
# bookkeeping. Every stage that loaded state for ONE field paid (in tokens when a
# model reads it, in fragility always) for ALL of it, and concurrent writers from
# different stages contended on one file.
#
# This library shards by consumer and routes reads/writes by the jq path's
# top-level key prefix, so call sites migrate incrementally without a big-bang
# rewrite:
#
#   .testing.*                          → state/testing.json   (verify-loop, quality-gates)
#   .open_issues[...]                   → state/findings.json  (adversarial-loop, triage, repro-tests)
#   .release_train.*                    → state/release-train.json  (release-train.sh; HOST-LOCAL,
#                                         git-ignored — a weekly cut must not dirty the tree it is
#                                         about to tag, and its run log is machine-local like
#                                         mobile/.last-shipped and state/traces/)
#   .axis .anti_axis .icp               → state/product.json   (iterate cold-start ONLY)
#   .wedge_sentence .product_idea .kpi_targets
#   everything else (schema_version,    → state/state.json     (thin index + pointers)
#     iteration_count, scale_tier, …)
#
# CRUCIAL invariant: each shard keeps the namespace at its ORIGINAL key path, so a
# jq path like `.testing.gate_attempts."e2e"` is unchanged — only the FILE it reads
# from changes. That is what lets call sites migrate one at a time.
#
# Source it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/state-shard.sh"
# Provides: state_shard_dir, state_shard_file, state_migrate, sget, sset
#
# Honors STATE_DIR (default <repo>/state) so the helpers are hermetically testable.
#
# NOTE ON `set -`: this file is a LIBRARY and deliberately sets NO shell options. A sourced lib
# runs in the CALLER's shell, so a `set -e` here would silently abort every "collector" script
# (the gate and agent stages) at its first *tolerated* failure — the ones that must survive a
# failing step in order to report, classify or clean up. Signal failure with return codes only.
# This is a deliberate design choice, not an oversight: do not "fix" it by adding `set -e`.
# See "Shell-option classes" in docs/AGENT-HARNESS.md (#2390).

# Resolve the repo root from THIS file's location (…/scripts/lib/state-shard.sh).
_STATE_SHARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The six product-namespace keys (issue #1699). Space-padded for word-boundary match.
_STATE_PRODUCT_KEYS=" axis anti_axis icp wedge_sentence product_idea kpi_targets "

state_shard_dir() { printf '%s' "${STATE_DIR:-$_STATE_SHARD_ROOT/state}"; }

# _state_top_key <jq_path> → the top-level field name.
#   .foo.bar     → foo
#   .foo[0]      → foo
#   ."foo-bar".x → foo-bar
_state_top_key() {
  local p="${1#.}"
  case "$p" in
    '"'*) p="${p#\"}"; p="${p%%\"*}" ;;   # ."quoted-key"…
    *)    p="${p%%.*}"; p="${p%%\[*}" ;;   # .foo.bar or .foo[0]
  esac
  printf '%s' "$p"
}

# state_shard_file <jq_path> → absolute path of the shard that owns this key.
state_shard_file() {
  local dir; dir="$(state_shard_dir)"
  local top; top="$(_state_top_key "$1")"
  case "$top" in
    testing)       printf '%s/testing.json'       "$dir" ;;
    open_issues)   printf '%s/findings.json'      "$dir" ;;
    release_train) printf '%s/release-train.json' "$dir" ;;
    *)
      if [[ "$_STATE_PRODUCT_KEYS" == *" $top "* ]]; then
        printf '%s/product.json' "$dir"
      else
        printf '%s/state.json' "$dir"
      fi ;;
  esac
}

# _shard_write <target-file> <jq-args…> — run jq itself (never through a pipe: piping jq's
# stdout into a helper hides jq's exit status behind the downstream command's, so a jq failure
# still reads as success) into a temp file and atomically move it into place, removing the temp
# file if jq fails.
#
# The four call sites below were `tmp="$(mktemp)"; jq … > "$tmp" && mv "$tmp" "$target"`. On a jq
# failure the `&&` short-circuits and the temp file is LEAKED into $TMPDIR — every failed
# migration, forever, on a host that runs this on a timer (issue #2387, hygiene).
#
# Deliberately NOT a `trap … EXIT`: this is a LIBRARY. Installing an EXIT trap here would
# silently replace the trap of whichever script sourced it, and several of them rely on theirs
# to remove worktrees and release locks.
_shard_write() { # <target-file> <jq-args…>
  local target="$1"; shift
  local tmp
  tmp="$(mktemp)" || return 1
  if jq "$@" > "$tmp"; then
    mv "$tmp" "$target"
  else
    rm -f "$tmp"
    return 1
  fi
}

# state_migrate — idempotently shard state/state.json into the per-concern files
# and rewrite state.json as a thin index. Safe to run repeatedly and concurrently
# (every write is temp-file + atomic rename). An already-sharded shard is treated
# as authoritative, so a re-run never clobbers a value a stage wrote post-migration.
state_migrate() {
  local dir; dir="$(state_shard_dir)"
  mkdir -p "$dir"
  local sf="$dir/state.json"
  local pf="$dir/product.json" tf="$dir/testing.json" ff="$dir/findings.json"
  local rt="$dir/release-train.json"
  [[ -f "$sf" ]] || echo '{}' > "$sf"
  # release-train.json is host-local and git-ignored, so there is nothing to lift out
  # of the monolith — it only needs to EXIST before state-set.sh's first jq write.
  [[ -f "$rt" ]] || echo '{}' > "$rt"

  local default_testing='{"gate_attempts":{},"open_issues_drained":false,"adversarial_rounds":0,"last_mutation_score":null,"last_verdict":null,"last_run_at":null}'
  local rc=0

  # testing.json — existing shard wins; else lift from the monolith; else default.
  local testing_obj
  if [[ -f "$tf" ]]; then
    testing_obj="$(jq -c '.testing // {}' "$tf")"
  else
    testing_obj="$(jq -c --argjson d "$default_testing" '.testing // $d' "$sf")"
  fi
  _shard_write "$tf" -n --argjson t "$testing_obj" '{testing:$t}' || rc=1

  # findings.json — the adversarial open_issues list.
  local oi
  if [[ -f "$ff" ]]; then oi="$(jq -c '.open_issues // []' "$ff")"
  else                    oi="$(jq -c '.open_issues // []' "$sf")"; fi
  _shard_write "$ff" -n --argjson o "$oi" '{open_issues:$o}' || rc=1

  # product.json — strategy/wedge/ICP.
  if [[ -f "$pf" ]]; then
    _shard_write "$pf" '.' "$pf" || rc=1
  else
    _shard_write "$pf" '{
      axis:(.axis//null), anti_axis:(.anti_axis//null), icp:(.icp//null),
      wedge_sentence:(.wedge_sentence//null), product_idea:(.product_idea//null),
      kpi_targets:(.kpi_targets//{})
    }' "$sf" || rc=1
  fi

  # state.json — strip the sharded namespaces, stamp schema_version + pointers.
  _shard_write "$sf" '
    del(.testing, .open_issues, .axis, .anti_axis, .icp, .wedge_sentence, .product_idea, .kpi_targets)
    | .schema_version = 2
    | .pointers = {product:"state/product.json", testing:"state/testing.json", findings:"state/findings.json"}
  ' "$sf" || rc=1

  return "$rc"
}

# sget <jq_path> [--raw] — routed read. Reads the owning shard; during the
# transition, falls back to the monolith so an old key path keeps working even
# before state_migrate has run (backward-compat requirement, issue #1699).
#
# NB: read the value with a bare `jq -c "$path"`, NOT `"$path // null"`. jq's `//`
# treats BOTH null and `false` as absent, so `// null` silently converts a legit
# `false` (e.g. .testing.open_issues_drained) into null — and then shadows it with
# any stale monolith value. A missing OR jq-errored path already yields "null"
# here, which is the only thing that should trigger the monolith fallback.
sget() {
  local path="$1"; local mode="${2:-}"
  local file; file="$(state_shard_file "$path")"
  local sf; sf="$(state_shard_dir)/state.json"
  local val="null"
  [[ -f "$file" ]] && val="$(jq -c "$path" "$file" 2>/dev/null || echo null)"
  if [[ "$val" == "null" && "$file" != "$sf" && -f "$sf" ]]; then
    local mono; mono="$(jq -c "$path" "$sf" 2>/dev/null || echo null)"
    [[ -n "$mono" && "$mono" != "null" ]] && val="$mono"
  fi
  if [[ "$mode" == "--raw" ]]; then printf '%s' "$val" | jq -r '.'; else printf '%s' "$val"; fi
}

# sset <jq_path> <json_value> — routed write. Delegates to state-set.sh (which
# owns the jq-path injection guard + atomic write and itself routes by prefix).
sset() {
  "$_STATE_SHARD_ROOT/scripts/state-set.sh" "$1" "$2"
}
