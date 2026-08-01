#!/usr/bin/env bash
# Hermetic test for scripts/iteration-digest.sh — the rolling, bounded digest that lets
# iterate / signal-iterate / agent-inbox read a compact companion instead of the 700 KB+
# docs/06-iteration-log.md (issue #1698).
#
#   Run: bash scripts/iteration-digest.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/iteration-digest.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
hasnt(){ if grep -qF -- "$2" "$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

add() { # <digest> <iter> <date> <headline> [extra env...]
  local df="$1" it="$2" dt="$3" hl="$4"; shift 4
  DIGEST_FILE="$df" DIGEST_KEEP_VERBATIM=3 DIGEST_KEEP_ONELINE=2 "$@" \
    bash "$HELPER" --add --iter "$it" --date "$dt" --headline "$hl" >/dev/null
}

# ── Scenario 1: --add creates the digest with a machine block + rendered sections ─
echo "Scenario 1 — --add builds the digest deterministically"
T1="$(mktemp -d)"; D1="$T1/digest.md"
add "$D1" 1 2026-01-01 "first iteration did a thing"
has "$D1" "# Iteration Log — Rolling Digest" "renders the header"
has "$D1" "<!-- digest:entries" "carries the machine block (source of truth)"
has "$D1" "1|2026-01-01|first iteration did a thing" "machine block records the entry"
has "$D1" "**1** (2026-01-01) — first iteration did a thing" "recent section renders the entry"
eq  "meta latest=1" "$(grep -oE 'latest=[0-9]+' "$D1" | head -1)" "latest=1"

# ── Scenario 2: bounded window — older entries collapse into an "earlier" rollup ──
echo "Scenario 2 — window is bounded (CAP=5); older iterations elide into a rollup"
for i in 2 3 4 5 6 7; do add "$D1" "$i" "2026-01-0$i" "iteration $i headline"; done
retained="$(grep -cE '^[0-9]+\|' "$D1" || true)"
eq  "machine block holds at most CAP=5 entries" "$retained" "5"
has "$D1" "earlier=2" "the 2 evicted iterations are counted in the earlier rollup"
has "$D1" "elided" "a human-readable rollup line is rendered"
hasnt "$D1" "1|2026-01-01|first iteration" "the oldest evicted entry is gone from the block"
has "$D1" "7|2026-01-07|iteration 7 headline" "the newest entry is retained (newest-first)"
# newest-first ordering: iter 7 appears before iter 6 in the block
eq  "newest entry is first in the block" "$(grep -oE '^[0-9]+' "$D1" | head -1)" "7"

# ── Scenario 3: re-adding the same iteration replaces, never duplicates ───────────
echo "Scenario 3 — re-add is idempotent per iteration number (dedup)"
add "$D1" 7 2026-01-09 "REVISED iteration 7 headline"
eq  "still exactly one entry for iter 7" "$(grep -cE '^7\|' "$D1" || true)" "1"
has "$D1" "REVISED iteration 7 headline" "the entry was replaced with the new headline"
eq  "block still capped at 5 after re-add" "$(grep -cE '^[0-9]+\|' "$D1" || true)" "5"

# ── Scenario 4: pipes/newlines in a headline can't corrupt the block format ───────
echo "Scenario 4 — headline is sanitized (no pipe/newline injection)"
T4="$(mktemp -d)"; D4="$T4/digest.md"
printf -v NASTY 'has a | pipe\nand a newline'
add "$D4" 10 2026-02-02 "$NASTY"
eq  "exactly one machine-block line for iter 10" "$(grep -cE '^10\|' "$D4" || true)" "1"
hasnt "$D4" "10|2026-02-02|has a | pipe" "the embedded pipe was neutralized"

# ── Scenario 5: --seed-from-log migrates from docs/iterations/ files, deduped ─
echo "Scenario 5 — --seed-from-log bootstraps from iterations dir (one-time migration)"
T5="$(mktemp -d)"; D5="$T5/digest.md"; I5="$T5/iterations"; mkdir -p "$I5"
# Create per-iteration files with the NNN-issue-NNNN-slug.md pattern
cat > "$I5/001-issue-100-oldest-thing.md" <<'F1'
## Iteration 1 — 2026-01-01
### Gaps Addressed
- did the oldest thing
F1
cat > "$I5/003-issue-101-newer-thing.md" <<'F3'
## Iteration 3 — 2026-03-04
- newer thing three revised
F3
cat > "$I5/003-issue-102-dup-header.md" <<'F3DUP'
## Iteration 3 — 2026-03-03
- newer thing three
F3DUP
cat > "$I5/002-issue-103-middle-thing.md" <<'F2'
## Iteration 2 — 2026-02-02
- middle thing two
F2
DIGEST_FILE="$D5" ITERATIONS_DIR="$I5" DIGEST_KEEP_VERBATIM=3 DIGEST_KEEP_ONELINE=2 \
  bash "$HELPER" --seed-from-log >/dev/null
has "$D5" "3|" "seeded the highest iteration"
eq  "duplicate iteration-3 entries collapse to one" "$(grep -cE '^3\|' "$D5" || true)" "1"
eq  "newest iteration is first (3)" "$(grep -oE '^[0-9]+' "$D5" | head -1)" "3"
has "$D5" "did the oldest thing" "took the first bullet under a header as the headline"

# ── Scenario 6: the rendered digest stays small (compact companion, not a replay) ─
echo "Scenario 6 — digest stays bounded in size regardless of headline verbosity"
T6="$(mktemp -d)"; D6="$T6/digest.md"
big="$(head -c 5000 /dev/zero | tr '\0' 'X')"
for i in 1 2 3 4 5 6 7 8; do add "$D6" "$i" "2026-01-0$i" "$big"; done
sz="$(wc -c < "$D6")"
[ "$sz" -lt 8000 ] && ok "digest bounded well under 8 KB even with 5 KB headlines (got ${sz}B)" \
  || bad "digest not bounded (got ${sz}B)"

rm -rf "$T1" "$T4" "$T5" "$T6" 2>/dev/null || true
echo
echo "iteration-digest: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
