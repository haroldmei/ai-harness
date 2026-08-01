#!/usr/bin/env bash
# Ratcheted shellcheck over scripts/ (file: shellcheck-gate.sh).
#
# Why (issue #2387)
# ----------------
# `scripts/` is ~20k lines of shell that gates every other change in this repo and
# pushes to `main` unattended. `lint.sh` linted backend (ruff), frontend, mobile and
# the vscode extension — and lint NOTHING in `scripts/`. The code that judges all the
# other code was the only code with no linter.
#
# This is not theoretical. On the commit that introduced this gate, a plain
# `shellcheck -S warning` over scripts/ flagged both of the review's most severe
# findings, in seconds, by exact line:
#
#   agent-pipeline.sh:228,241,262  SC2106  "This only exits the subshell caused by (..)"
#       → the `continue` that was supposed to stop a conflicted PR being re-armed.
#         It never did; conflicted PRs re-entered the merge loop carrying needs-human.
#   agent-pr-merger.sh:974         SC1012  "\n is just literal 'n' here"
#       → mangled quoting that posted an EMPTY PR comment, silently dropping the
#         "here are the failed gates" context the fixer needs.
#
# The ratchet, and why it is per (file, code)
# -------------------------------------------
# A repo-wide total is a bad ratchet: it lets you add a bug to auth.sh as long as you
# delete a nit from a test, and it churns on every file move. This keys the budget to
# (file, code) pairs, so:
#   * a NEW code in a file            → fail (a novel class of defect)
#   * MORE hits of a known code       → fail (the same defect, spreading)
#   * fewer hits                      → pass, and print the ratchet-down hint
#
# Severity floor is `warning`, not the default `style`. At `style` this reports ~548
# findings, dominated by SC2015 (A && B || C), SC2016 (single-quoted $) and SC1091
# (can't follow source) — house idiom and false positives that would bury the two real
# bugs above. `warning` is where shellcheck stops guessing at intent.
#
# Usage:
#   scripts/shellcheck-gate.sh            # check against the baseline
#   scripts/shellcheck-gate.sh --update   # rewrite the baseline (review the diff!)
#   scripts/shellcheck-gate.sh --list     # print current findings, grouped
#
# Exit: 0 clean or within budget | 1 regression | 77 shellcheck not installed.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

BASELINE="${SHELLCHECK_BASELINE:-scripts/shellcheck-baseline.txt}"
SEVERITY="${SHELLCHECK_SEVERITY:-warning}"
MODE="check"
case "${1:-}" in
  --update) MODE="update";;
  --list)   MODE="list";;
  "")       ;;
  *) echo "usage: $0 [--update|--list]" >&2; exit 2;;
esac

command -v shellcheck >/dev/null 2>&1 || {
  echo "shellcheck not installed (apt-get install shellcheck) — gate unavailable"
  exit 77
}

mapfile -t FILES < <(find scripts -type f -name '*.sh' | sort)
[ "${#FILES[@]}" -gt 0 ] || { echo "no shell scripts under scripts/"; exit 77; }

# `file<TAB>code<TAB>count`, sorted — the on-disk baseline format.
current_counts() {
  shellcheck -f gcc -S "$SEVERITY" "${FILES[@]}" 2>/dev/null \
    | sed -nE 's|^([^:]+):[0-9]+:[0-9]+: [a-z]+: .*\[(SC[0-9]+)\]$|\1\t\2|p' \
    | sort | uniq -c \
    | awk '{ printf "%s\t%s\t%s\n", $2, $3, $1 }' \
    | sort
}

CUR="$(current_counts)"

# ── Unparseable files are NEVER baselined ────────────────────────────────────────
# SC1072/SC1073/SC1017 mean shellcheck gave up on the file. It then reports nothing
# else about it, so a baselined parse error would silently exempt an entire script
# from linting — the precise failure this gate exists to end. (Found immediately: this
# file's own line 2 began "# shellcheck-gate.sh …", which shellcheck read as a broken
# directive and skipped the whole file for.) Always fatal, never budgeted.
UNPARSEABLE="$(shellcheck -f gcc -S error "${FILES[@]}" 2>/dev/null | grep -E '\[SC(1072|1073|1017)\]' || true)"
if [ -n "$UNPARSEABLE" ]; then
  echo "  ✗ shellcheck could not PARSE these files — they are effectively unlinted:"
  printf '%s\n' "$UNPARSEABLE" | sed 's/^/      /'
  echo "    (a comment line starting with '# shellcheck' is read as a directive — reword it)"
  exit 1
fi

if [[ "$MODE" == "list" ]]; then
  shellcheck -f gcc -S "$SEVERITY" "${FILES[@]}" 2>/dev/null
  printf '\n── totals by code ──\n'
  printf '%s\n' "$CUR" | awk -F'\t' '{ t[$2] += $3 } END { for (c in t) printf "%6d  %s\n", t[c], c }' | sort -rn
  exit 0
fi

if [[ "$MODE" == "update" ]]; then
  {
    echo "# shellcheck ratchet baseline — scripts/ (severity: $SEVERITY)"
    echo "# Regenerate with: scripts/shellcheck-gate.sh --update"
    echo "# Format: <file>\t<SC code>\t<allowed count>.  Lower is better; never raise a"
    echo "# number to make a gate pass — fix the finding or justify it in the PR."
    printf '%s\n' "$CUR"
  } > "$BASELINE"
  echo "baseline written: $BASELINE ($(printf '%s\n' "$CUR" | grep -c . ) file/code pairs, $(printf '%s\n' "$CUR" | awk -F'\t' '{s+=$3} END{print s+0}') findings)"
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "no baseline at $BASELINE — run: scripts/shellcheck-gate.sh --update"
  exit 1
fi

BASE="$(grep -v '^#' "$BASELINE" | grep . | sort)"

regressions=""; improvements=""
while IFS=$'\t' read -r f code n; do
  [ -n "$f" ] || continue
  b="$(printf '%s\n' "$BASE" | awk -F'\t' -v f="$f" -v c="$code" '$1==f && $2==c { print $3 }')"
  b="${b:-0}"
  if [ "$n" -gt "$b" ]; then
    regressions+="  ${f}: ${code} × ${n} (budget ${b})"$'\n'
  elif [ "$n" -lt "$b" ]; then
    improvements+="  ${f}: ${code} × ${n} (budget ${b})"$'\n'
  fi
done <<< "$CUR"

# A pair that vanished entirely is an improvement too — and leaving it in the baseline
# lets the finding come back for free later, so name it.
while IFS=$'\t' read -r f code n; do
  [ -n "$f" ] || continue
  if ! printf '%s\n' "$CUR" | awk -F'\t' -v f="$f" -v c="$code" '$1==f && $2==c { found=1 } END { exit !found }'; then
    improvements+="  ${f}: ${code} × 0 (budget ${n}) — resolved"$'\n'
  fi
done <<< "$BASE"

total_now="$(printf '%s\n' "$CUR" | awk -F'\t' '{s+=$3} END{print s+0}')"
total_base="$(printf '%s\n' "$BASE" | awk -F'\t' '{s+=$3} END{print s+0}')"
echo "shellcheck (severity ${SEVERITY}, ${#FILES[@]} files): ${total_now} findings, budget ${total_base}"

if [ -n "$regressions" ]; then
  echo "  ✗ new or increased shellcheck findings:"
  printf '%s' "$regressions"
  echo "    Fix them, or (only with a reason in the PR) re-baseline:"
  echo "      scripts/shellcheck-gate.sh --update"
  exit 1
fi

if [ -n "$improvements" ]; then
  echo "  ✓ no regressions — and the budget is now loose:"
  printf '%s' "$improvements"
  echo "    Ratchet it down: scripts/shellcheck-gate.sh --update"
  # Loose budget is a PASS by default so an unrelated PR that happens to delete a
  # flagged line is never punished. Set SHELLCHECK_STRICT_RATCHET=1 (CI-only) to make
  # a stale baseline fail instead, which stops the budget quietly staying slack.
  [ "${SHELLCHECK_STRICT_RATCHET:-0}" = 1 ] && exit 1
fi

echo "  ✓ scripts/ within shellcheck budget"
exit 0
