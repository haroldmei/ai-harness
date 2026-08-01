#!/usr/bin/env bash
# iteration-digest.sh — a rolling, bounded digest of the iteration history.
#
# Iterations are stored as per-issue files under docs/iterations/ (issue #2167).
# This maintains a compact, self-contained companion — docs/06-iteration-log.digest.md —
# that iterate / signal-iterate / agent-inbox read for prior-iteration context INSTEAD
# of reading every iteration file (issue #1698). It mirrors agent-scout's
# `${rejection_digest}` idiom: a bounded rolling window fed forward, never a verbatim
# replay of accreting history.
#
# The digest is DETERMINISTIC (bash/awk only — no LLM call): the caller passes a
# one-line headline already derived from the structured Phase-6 log section, and this
# script re-renders a fixed-size window. A haiku-class summarization call is only ever
# needed to CONDENSE free prose into that headline — which the caller does, not this.
#
# Source of truth is a machine block embedded in the committed digest file itself, so
# there is no separate (gitignored) state to lose across worktrees, and the window is
# bounded regardless of project age.
#
# Usage:
#   scripts/iteration-digest.sh --add --iter N --date YYYY-MM-DD --headline "one line"
#       Prepend iteration N to the digest and re-render the bounded window.
#   scripts/iteration-digest.sh --seed-from-log
#       One-time migration: build the initial digest from docs/iterations/ headers.
#       (Reads every iteration file ONCE — a migration, never part of a per-build path.)
#   scripts/iteration-digest.sh --show
#       Print the digest to stdout (creates an empty one if absent).
#
# Env knobs:
#   DIGEST_FILE            override the digest path (tests)
#   ITERATIONS_DIR          override the iterations directory (tests / --seed-from-log)
#   DIGEST_KEEP_VERBATIM   recent entries rendered with the full headline   (default 10)
#   DIGEST_KEEP_ONELINE    older entries rendered condensed, one line each   (default 30)
#
# Bounded: the machine block holds at most KEEP_VERBATIM+KEEP_ONELINE entries; older
# ones collapse into a single "+K earlier" rollup line. Target size ~2 KB.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIGEST_FILE="${DIGEST_FILE:-$ROOT/docs/06-iteration-log.digest.md}"
ITER_DIR="${ITERATIONS_DIR:-$ROOT/docs/iterations}"
KEEP_VERBATIM="${DIGEST_KEEP_VERBATIM:-8}"
KEEP_ONELINE="${DIGEST_KEEP_ONELINE:-20}"
CAP=$(( KEEP_VERBATIM + KEEP_ONELINE ))
# Cap the STORED headline (machine block + verbatim render) so the digest stays bounded
# regardless of how verbose a Phase-6 headline is — the whole point is a compact window.
STORE_HEADLINE_MAX="${DIGEST_HEADLINE_MAX:-110}"

# ── Parse the machine block: newest-first `N|date|headline` lines between the entries
# marker and its closing `-->`. Prints nothing if the file/marker is absent. ─
parse_entries() {
  [ -f "$DIGEST_FILE" ] || return 0
  awk '
    /<!-- digest:entries/ { f=1; next }
    f && /^-->/           { f=0 }
    f && /^[0-9]+\|/      { print }
  ' "$DIGEST_FILE"
}

# ── The running "elided older iterations" count, carried in the meta comment. ─
parse_earlier() {
  [ -f "$DIGEST_FILE" ] || { echo 0; return; }
  local k
  k="$(grep -oE 'earlier=[0-9]+' "$DIGEST_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
  echo "${k:-0}"
}

# ── Render the whole digest file from an entries list (newest first, on stdin) + the
# earlier-count + a "updated" date. Deterministic; no LLM. ─
render() { # <earlier> <updated_date>   (entries newest-first on stdin)
  local earlier="$1" updated="$2"
  local entries; entries="$(cat)"
  local total_retained latest
  total_retained="$(printf '%s\n' "$entries" | grep -c '^[0-9]' || true)"
  latest="$(printf '%s\n' "$entries" | head -1 | cut -d'|' -f1)"
  [ -n "$latest" ] || latest=0

  {
    printf '# Iteration Log — Rolling Digest\n\n'
    printf '_Compact rolling summary of `docs/iterations/` (per-iteration files; issue #2167).\n'
    printf 'Regenerated deterministically by `scripts/iteration-digest.sh` on every iteration — do NOT\n'
    printf 'hand-edit. `iterate` / `signal-iterate` / `agent-inbox` read THIS digest for prior-iteration\n'
    printf 'context, never every iteration file (issue #1698)._\n\n'
    printf '<!-- digest:meta latest=%s retained=%s earlier=%s updated=%s -->\n\n' \
      "$latest" "${total_retained:-0}" "$earlier" "$updated"

    printf '## Recent iterations\n\n'
    printf '%s\n' "$entries" | grep '^[0-9]' | head -n "$KEEP_VERBATIM" | while IFS='|' read -r n d h; do
      [ -n "$n" ] || continue
      printf -- '- **%s** (%s) — %s\n' "$n" "$d" "$h"
    done

    local condensed
    condensed="$(printf '%s\n' "$entries" | grep '^[0-9]' | tail -n +"$((KEEP_VERBATIM + 1))" | head -n "$KEEP_ONELINE")"
    if [ -n "$condensed" ]; then
      printf '\n## Earlier iterations (condensed)\n\n'
      printf '%s\n' "$condensed" | while IFS='|' read -r n d h; do
        [ -n "$n" ] || continue
        printf -- '- %s (%s) — %s\n' "$n" "$d" "$(printf '%s' "$h" | cut -c1-70)"
      done
    fi

    if [ "${earlier:-0}" -gt 0 ]; then
      printf '\n_+%s earlier iterations elided — see `docs/iterations/` for the full history._\n' "$earlier"
    fi

    printf '\n<!-- digest:entries (machine block, newest first: N|date|headline — do NOT edit)\n'
    printf '%s\n' "$entries" | grep '^[0-9]'
    printf -- '-->\n'
  } > "$DIGEST_FILE"
}

# ── Sanitize a headline into a single pipe-free line. ─
clean_headline() { # <text>
  printf '%s' "$1" | tr '\n\r|' '  /' | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g' | cut -c1-"$STORE_HEADLINE_MAX"
}

cmd_add() {
  local iter="" date="" headline=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --iter)     iter="$2"; shift 2;;
      --date)     date="$2"; shift 2;;
      --headline) headline="$2"; shift 2;;
      *) echo "add: unknown arg '$1'" >&2; exit 2;;
    esac
  done
  [ -n "$iter" ] || { echo "add: --iter required" >&2; exit 2; }
  case "$iter" in ''|*[!0-9]*) echo "add: --iter must be an integer" >&2; exit 2;; esac
  [ -n "$date" ] || date="unknown"
  headline="$(clean_headline "${headline:-（no headline）}")"

  local earlier existing new_line combined dropped kept
  earlier="$(parse_earlier)"
  existing="$(parse_entries)"
  # Dedup: drop any prior entry for THIS iteration (re-runs replace, never duplicate).
  existing="$(printf '%s\n' "$existing" | grep -vE "^${iter}\|" || true)"
  new_line="${iter}|${date}|${headline}"

  combined="$(printf '%s\n' "$new_line"; printf '%s\n' "$existing" | grep '^[0-9]' || true)"
  local n_combined; n_combined="$(printf '%s\n' "$combined" | grep -c '^[0-9]' || true)"
  dropped=0
  if [ "${n_combined:-0}" -gt "$CAP" ]; then
    dropped=$(( n_combined - CAP ))
    kept="$(printf '%s\n' "$combined" | grep '^[0-9]' | head -n "$CAP")"
  else
    kept="$(printf '%s\n' "$combined" | grep '^[0-9]')"
  fi
  earlier=$(( earlier + dropped ))

  printf '%s\n' "$kept" | render "$earlier" "$date"
  echo "iteration-digest: added #${iter} (retained $(printf '%s\n' "$kept" | grep -c '^[0-9]'), earlier ${earlier})"
}

# ── One-time migration: parse `## Iteration N — date` headers from every file under
# docs/iterations/ and take the first bullet under each as the headline. ─
cmd_seed_from_log() {
  [ -d "$ITER_DIR" ] || { echo "seed: $ITER_DIR not found" >&2; exit 1; }
  local entries file header_line
  entries=""
  for file in "$ITER_DIR"/*.md; do
    [ -f "$file" ] || continue
    header_line="$(head -1 "$file" 2>/dev/null || true)"
    # Parse "## Iteration N — date — description" or "## Iteration N — date"
    local n d h
    n="$(echo "$header_line" | sed -nE 's/^## Iteration ([0-9]+).*/\1/p')"
    [ -n "$n" ] || continue
    d="$(echo "$header_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' 2>/dev/null || true)"
    d="$(echo "$d" | head -1)"
    [ -n "$d" ] || d="unknown"
    # First non-empty bullet under the header (skipping blank lines after header)
    h="$(tail -n +2 "$file" 2>/dev/null | sed -n '/^- /{s/^- *//;p;q}' || true)"
    if [ -z "$h" ]; then h="(no headline)"; fi
    h="$(printf '%s' "$h" | tr '|' '/' | cut -c1-"$STORE_HEADLINE_MAX")"
    entries="${entries}${n}|${d}|${h}"$'\n'
  done

  entries="$(printf '%s' "$entries" | sort -t'|' -k1,1 -n -r | awk -F'|' '!seen[$1]++')"

  local n_total; n_total="$(printf '%s\n' "$entries" | grep -c '^[0-9]' || true)"
  local kept earlier
  kept="$(printf '%s\n' "$entries" | grep '^[0-9]' | head -n "$CAP")"
  earlier=$(( n_total > CAP ? n_total - CAP : 0 ))
  local updated; updated="$(printf '%s\n' "$kept" | head -1 | cut -d'|' -f2)"
  [ -n "$updated" ] || updated="unknown"
  printf '%s\n' "$kept" | render "$earlier" "$updated"
  echo "iteration-digest: seeded from iterations dir (${n_total} iterations, retained $(printf '%s\n' "$kept" | grep -c '^[0-9]'), earlier ${earlier})"
}

cmd_show() {
  [ -f "$DIGEST_FILE" ] || printf '' | render 0 "unknown"
  cat "$DIGEST_FILE"
}

mode="${1:-}"
case "$mode" in
  --add)           shift; cmd_add "$@";;
  --seed-from-log) cmd_seed_from_log;;
  --show)          cmd_show;;
  *) echo "Usage: $0 {--add --iter N --date D --headline H | --seed-from-log | --show}" >&2; exit 2;;
esac
