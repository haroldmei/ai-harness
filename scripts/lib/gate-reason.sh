#!/usr/bin/env bash
# gate-reason.sh — pull the line(s) that actually DIAGNOSE a gate failure out of its log.
#
# Why this is shared (issue #2387, H4)
# -----------------------------------
# Three places need "why did this gate fail", and there were three answers:
#
#   verify-loop.sh    SPAWN_DIAG_RE  + dedup + head -40   (correct)
#   release-train.sh  FAILURE_LINE_RE + dedup + head -N   (correct, plus infra patterns)
#   quality-gates.sh  tail -n1                            (wrong)
#
# `tail -n1` is wrong for every runner this repo owns. pytest prints the failure body FIRST
# and a warnings summary LAST; a gate script's own last line is usually its success banner.
# Observed on a real run:
#
#     unit  fail  see …/unit.log —  ✓ release-train guards
#
# — a PASS line reported as the reason a gate FAILED. That string is not cosmetic: it lands
# in escalation issue bodies, in PR comments, and in the brief handed to the auto-fixer, so
# the fixer was being told to fix a passing check.
#
# One extractor, used by all three, so fixing the excerpt fixes every consumer at once.
#
# NOTE ON `set -`: this file is a LIBRARY and deliberately sets NO shell options. A sourced lib
# runs in the CALLER's shell, so a `set -e` here would silently abort every "collector" script
# (the gate and agent stages) at its first *tolerated* failure — the ones that must survive a
# failing step in order to report, classify or clean up. Signal failure with return codes only.
# This is a deliberate design choice, not an oversight: do not "fix" it by adding `set -e`.
# See "Shell-option classes" in docs/AGENT-HARNESS.md (#2390).

# Lines that carry an actual diagnosis. Union of the two prior regexes: the test-runner
# patterns both had, plus release-train's infra patterns (it also excerpts for escalate(),
# where the failure is Docker/OOM/disk rather than an assertion — without them the excerpt
# falls back to a blind tail exactly when the cause is most opaque).
GATE_FAILURE_LINE_RE='^E[[:space:]]+|^(FAILED|ERROR)[[:space:]]|^[[:space:]]*(FAILED|ERROR)[[:space:]]|error(\[[A-Za-z0-9-]+\])?:|Error:|Traceback \(most recent call last\)|AssertionError|^\s*✗|^[^:]+:[0-9]+:[0-9]+: [a-zA-Z]+[0-9]+|^[^:]+:[0-9]+: error:|genuine Docker starvation|never became usable after|Cannot connect to the Docker daemon|no space left on device|Connection refused.*5432|ReaperException|Resource temporarily unavailable|Cannot allocate memory'

# STRONG patterns: lines only a FAILING check emits. The broad set above is deliberately
# generous — `Error:`, `Traceback`, `AssertionError` — which is right for an excerpt but wrong
# for picking the single headline line, because passing tests print those too and the first
# match in the file wins. Observed 2026-08-01: the `unit` gate's reported reason was
#
#   {"event": "Sentry initialisation failed; continuing without it", "level": "warning",
#    … "exception": "Traceback (most recent call last): … AttributeError: …"}
#
# — one line of structured stderr from a backend test that PASSED, matched via `Traceback`
# thousands of lines before the real failure (4 assertions in scripts/quality-gates.test.sh).
# That string is what reaches escalation issues, PR comments and the auto-fixer's brief, so the
# operator was sent after a sentry_sdk packaging bug that had nothing to do with the failure.
# Same defect class the `tail -n1` note above describes; this is the other half of it.
GATE_FAILURE_STRONG_RE='^[[:space:]]*✗|^E[[:space:]]+|^[[:space:]]*(FAILED|ERROR)[[:space:]]|AssertionError|^[^:]+:[0-9]+:[0-9]+: [a-zA-Z]+[0-9]+|^[^:]+:[0-9]+: error:|genuine Docker starvation|never became usable after|Cannot connect to the Docker daemon|no space left on device|Connection refused.*5432|ReaperException|Resource temporarily unavailable|Cannot allocate memory'

# Structured log records a PASSING test emitted. A runner that logs JSON puts its severity in
# the record, so anything at warning/info/debug is by definition not the reason a gate failed.
# Only these levels are dropped: an `"level": "error"` record may well BE the failure.
GATE_REASON_NOISE_RE='"level"[[:space:]]*:[[:space:]]*"(warning|info|debug)"'

# gate_reason_lines <logfile> [max-lines] — the diagnostic excerpt, deduplicated.
# Strong matches first (so the headline line is a real failure), then the broad set, then a
# blind tail. Noise-filtered at every tier — a passing test's warning record is never a reason.
gate_reason_lines() {
  local src="$1" n="${2:-40}" diag clean
  [ -f "$src" ] || return 0
  clean="$(grep -vE "$GATE_REASON_NOISE_RE" "$src" 2>/dev/null)"
  diag="$(printf '%s\n' "$clean" | grep -E "$GATE_FAILURE_STRONG_RE" 2>/dev/null | awk '!seen[$0]++' | head -n "$n")"
  if [ -z "${diag// }" ]; then
    diag="$(printf '%s\n' "$clean" | grep -E "$GATE_FAILURE_LINE_RE" 2>/dev/null | awk '!seen[$0]++' | head -n "$n")"
  fi
  if [ -z "${diag// }" ]; then
    diag="$(tail -n "$n" "$src" 2>/dev/null)"
  fi
  printf '%s' "$diag"
}

# gate_reason_summary <logfile> — ONE line, for a summary table or a `<gate>:<status>:<reason>`
# record. Colons are stripped: quality-gates.sh packs results into a colon-delimited string
# and splits with `IFS=':' read -r name status reason`, so a colon in the reason would shift
# the fields. Newlines and CR likewise.
gate_reason_summary() {
  local src="$1" line
  [ -f "$src" ] || { printf 'no log at %s' "$src"; return 0; }
  line="$(gate_reason_lines "$src" 1)"
  line="${line%%$'\n'*}"
  line="${line//:/ }"
  line="${line//$'\r'/}"
  # collapse runs of whitespace so the summary table stays aligned
  line="$(printf '%s' "$line" | tr -s '[:space:]' ' ')"
  line="${line# }"; line="${line% }"
  printf '%s' "${line:-no diagnostic line in log}"
}
