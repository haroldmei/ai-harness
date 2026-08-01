#!/usr/bin/env bash
# Tests for scripts/lib/gate-reason.sh — the ONE gate-failure-reason extractor.
#
# Why this suite exists
# ---------------------
# The string this lib returns is not cosmetic. It lands in escalation issue bodies, in PR
# comments, and in the brief handed to the auto-fixer, so a wrong headline sends both the
# human and the model after the wrong defect. The lib was created (#2387, H4) because
# quality-gates.sh used `tail -n1` and reported a PASS banner as the reason a gate FAILED.
#
# It had the same defect from the other end. `gate_reason_lines <log> 1` took the FIRST line
# matching a deliberately-generous regex — one that includes `Error:`, `Traceback` and
# `AssertionError` because an EXCERPT wants them. Passing tests print those too. Observed on
# the 2026-08-01 mobile cut: the `unit` gate's reason was a single line of structured stderr
# from a backend test that passed —
#
#   {"event": "Sentry initialisation failed; …", "level": "warning", … "Traceback …"}
#
# — matched thousands of lines before the real failure (4 assertions in quality-gates.test.sh),
# so the release-train output blamed a sentry_sdk packaging bug for a harness hermeticity bug.
#
# The fix is tiered: strong patterns (lines only a FAILING check emits) pick the headline,
# the broad set stays for the excerpt, and structured records at warning/info/debug are
# dropped as noise at every tier. These cases pin all three properties.
#
#   Run: bash scripts/gate-reason.test.sh    (exit 0 = all pass)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/test-env.sh
source "$SCRIPT_DIR/lib/test-env.sh"
test_env_scrub
# shellcheck source=scripts/lib/gate-reason.sh
source "$SCRIPT_DIR/lib/gate-reason.sh"

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; printf '      %s\n' "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d -t gate-reason-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "gate-reason.sh"

# ── 1) The regression: a PASSING test's warning record must never become the reason. ──
# This is the real 2026-08-01 shape — Sentry noise early, the true failure much later.
cat > "$TMP/unit.log" <<'EOF'
unit: backend (pytest tests/unit)
{"event": "Sentry initialisation failed; continuing without it", "level": "warning", "exception": "Traceback (most recent call last):\n  File \"observability.py\", line 244\nAttributeError: 'NoneType' object has no attribute 'get'"}
4518 passed, 18 skipped, 623 warnings in 19.97s
unit: frontend (vitest)
Error: Not implemented: navigation (except hash changes)
 Test Files  341 passed (341)
unit: harness shell suites (scripts/*.test.sh)
  ✓ agent-inbox.test.sh — passed: 87  failed: 0
  ✗ quality-gates.test.sh — failed (exit 1):
      ✗ --skip contract at launch → expected nonzero exit, got 0 (contract not required?)
  harness shell suites: 37 passed, 1 failed
EOF
_r="$(gate_reason_summary "$TMP/unit.log")"
if [[ "$_r" != *Sentry* && "$_r" != *AttributeError* ]]; then
  ok "a passing test's Sentry warning record is not the reason"
else bad "a passing test's Sentry warning record is not the reason" "got: $_r"; fi
if [[ "$_r" == *"quality-gates.test.sh"* ]]; then
  ok "the failing shell suite IS the reason"
else bad "the failing shell suite IS the reason" "got: $_r"; fi

# ── 2) jsdom/global-error stderr from passing frontend tests must not win either. ──
cat > "$TMP/fe.log" <<'EOF'
stderr | src/x.test.tsx > renders
Error: Not implemented: navigation (except hash changes)
[skillforge:global-error:unhandled-rejection] async exploded Error: async exploded
 FAIL  src/broken.test.tsx > Suite > explodes on load
AssertionError: expected 1 to be 2
EOF
_r="$(gate_reason_summary "$TMP/fe.log")"
if [[ "$_r" != *"Not implemented"* && "$_r" != *"async exploded"* ]]; then
  ok "jsdom / global-error noise from passing tests is not the reason"
else bad "jsdom / global-error noise from passing tests is not the reason" "got: $_r"; fi

# ── 3) A log whose ONLY diagnosis is broad-tier still yields it (no regression in reach). ──
# `Error:` is not a strong pattern; with no strong match anywhere the broad tier must answer,
# or a whole class of failures would fall through to a blind tail.
printf 'building…\nError: could not resolve module foo\ndone\n' > "$TMP/broad.log"
_r="$(gate_reason_summary "$TMP/broad.log")"
if [[ "$_r" == *"could not resolve module foo"* ]]; then
  ok "broad-tier diagnosis still reported when no strong match exists"
else bad "broad-tier diagnosis still reported when no strong match exists" "got: $_r"; fi

# ── 4) An `"level": "error"` record is NOT noise — only warning/info/debug are dropped. ──
printf '{"event": "boom", "level": "error", "detail": "AssertionError: nope"}\n' > "$TMP/err.log"
_r="$(gate_reason_summary "$TMP/err.log")"
if [[ "$_r" == *boom* || "$_r" == *AssertionError* ]]; then
  ok "an error-level structured record is still eligible as the reason"
else bad "an error-level structured record is still eligible as the reason" "got: $_r"; fi

# ── 5) Nothing diagnostic at all ⇒ the blind-tail fallback still fires. ──
printf 'line one\nline two\nline three\n' > "$TMP/quiet.log"
_r="$(gate_reason_summary "$TMP/quiet.log")"
if [[ -n "$_r" && "$_r" != "no diagnostic line in log" ]]; then
  ok "falls back to the tail when the log carries no diagnosis"
else bad "falls back to the tail when the log carries no diagnosis" "got: $_r"; fi

# ── 6) The summary stays single-line and colon-free (quality-gates.sh packs it colon-delimited
#       and splits with IFS=':', so a stray colon shifts every field after it). ──
_r="$(gate_reason_summary "$TMP/unit.log")"
if [[ "$_r" != *:* && "$_r" != *$'\n'* ]]; then
  ok "summary is one line with no colons (safe for the colon-packed results record)"
else bad "summary is one line with no colons" "got: $_r"; fi

# ── 7) A missing log is reported, not silently empty. ──
if [[ "$(gate_reason_summary "$TMP/nope.log")" == *"no log at"* ]]; then
  ok "a missing log file is reported explicitly"
else bad "a missing log file is reported explicitly" "got: $(gate_reason_summary "$TMP/nope.log")"; fi

# ── 8) The excerpt (multi-line) still surfaces the real failure, not just the headline. ──
_e="$(gate_reason_lines "$TMP/unit.log" 40)"
if [[ "$_e" == *"--skip contract at launch"* ]]; then
  ok "the multi-line excerpt reaches the individual failing assertions"
else bad "the multi-line excerpt reaches the individual failing assertions" "got: $_e"; fi

echo
echo "  passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
