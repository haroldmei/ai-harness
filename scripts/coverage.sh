#!/usr/bin/env bash
# coverage.sh — measure backend statement coverage and enforce the NFR-MAINT-001 floor (#2017).
#
# Background: NFR-MAINT-001 declared an 80% backend coverage floor that NOTHING computed.
# `scripts/unit.sh` runs pytest with `--no-cov` (deliberately — the unit gate must stay fast),
# backend/pyproject.toml declares no `--cov-fail-under`, and the GATES list had no coverage gate.
# The requirement was not merely unmet, it was UNMEASURED: nobody could tell whether coverage was
# drifting down as the agent pipeline landed PRs. This script is the measurement + the ratchet.
#
# Scope: the backend UNIT suite (`backend/tests/unit`) against `app/`. Unit-only on purpose —
# it is hermetic (no Postgres, no Docker, ~35s with xdist), so the gate can run on any host and
# produce a number that is comparable run-to-run. Integration/e2e coverage would raise the
# percentage but make it depend on which stacks happened to boot, which is exactly the kind of
# "green because nothing ran" hole the gate registry exists to close.
#
# The floor is a RATCHET, not the aspirational target. Measured coverage at the time this gate
# was wired was 65.2%; a gate hard-set to 80 would have been permanently red and therefore
# ignored. state/artifacts/coverage-floor.json holds the enforced floor plus the 80% target;
# `--ratchet` raises the floor as real coverage climbs, so the number can only go up.
#
# Usage:
#   scripts/coverage.sh                     # measure + enforce the committed floor
#   scripts/coverage.sh --floor 70          # enforce an explicit floor
#   scripts/coverage.sh --ratchet           # on pass, raise the committed floor to the new level
#   scripts/coverage.sh --from-json F       # skip pytest, read an existing coverage.py JSON report
#                                           # (the test seam — see scripts/coverage.test.sh)
#
# Env: COVERAGE_FLOOR (same as --floor), COVERAGE_PYTEST_ARGS (extra pytest args).
#
# Exit: 0 coverage ≥ floor | 1 coverage < floor | 77 cannot measure (no suite / no pytest-cov).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

# printf/awk must emit '65.22', never '65,22' — the percentages are fed to jq --argjson, which
# rejects a comma decimal separator outright. Pin the numeric locale rather than inherit it.
export LC_ALL=C LC_NUMERIC=C

FLOOR_FILE="state/artifacts/coverage-floor.json"
OUT_FILE="state/artifacts/coverage.json"
DEFAULT_FLOOR=80          # NFR-MAINT-001's stated target; used only when no floor file exists
RATCHET_SLACK=1.0         # headroom kept below the measured value so noise can't flap the gate

FLOOR=""
FROM_JSON=""
RATCHET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --floor)     FLOOR="$2"; shift 2;;
    --from-json) FROM_JSON="$2"; shift 2;;
    --ratchet)   RATCHET=1; shift;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v jq >/dev/null || { echo "coverage: jq required"; exit 77; }

# ---- resolve the floor: --floor > COVERAGE_FLOOR > committed floor file > DEFAULT_FLOOR ----
TARGET="$DEFAULT_FLOOR"
if [[ -z "$FLOOR" ]]; then FLOOR="${COVERAGE_FLOOR:-}"; fi
if [[ -f "$FLOOR_FILE" ]]; then
  TARGET="$(jq -r '.target // empty' "$FLOOR_FILE" 2>/dev/null)"; TARGET="${TARGET:-$DEFAULT_FLOOR}"
  if [[ -z "$FLOOR" ]]; then
    FLOOR="$(jq -r '.floor // empty' "$FLOOR_FILE" 2>/dev/null)"
  fi
fi
FLOOR="${FLOOR:-$DEFAULT_FLOOR}"
if ! [[ "$FLOOR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "coverage: floor '$FLOOR' is not a number"; exit 1
fi

# ---- measure ----
REPORT=""
if [[ -n "$FROM_JSON" ]]; then
  [[ -f "$FROM_JSON" ]] || { echo "coverage: --from-json '$FROM_JSON' not found"; exit 77; }
  REPORT="$FROM_JSON"
else
  [[ -d backend/tests/unit ]] || { echo "coverage: no backend/tests/unit — nothing to measure"; exit 77; }
  command -v python >/dev/null || { echo "coverage: python unavailable"; exit 77; }
  ( cd backend && python -c "import pytest_cov" ) 2>/dev/null \
    || { echo "coverage: pytest-cov not installed in the backend env"; exit 77; }

  # xdist keeps the measured run near the plain unit gate's wall clock; fall back when absent.
  XDIST=()
  ( cd backend && python -c "import xdist" ) 2>/dev/null && XDIST=(-n auto)

  REPORT="$(mktemp -t skillforge-cov-XXXXXX.json)"
  trap 'rm -f "$REPORT"' EXIT   # only the report WE generated; a --from-json report is the caller's
  echo "coverage: running backend unit suite with --cov=app …"
  # shellcheck disable=SC2086  # COVERAGE_PYTEST_ARGS is an intentional word-split escape hatch
  if ! ( cd backend && python -m pytest tests/unit/ -q -p no:cacheprovider \
           "${XDIST[@]}" --cov=app --cov-report= "--cov-report=json:$REPORT" \
           ${COVERAGE_PYTEST_ARGS:-} ); then
    echo "coverage: the backend unit suite FAILED — coverage is not meaningful until it is green"
    exit 1
  fi
fi

PCT="$(jq -r '.totals.percent_covered // empty' "$REPORT" 2>/dev/null)"
if [[ -z "$PCT" ]]; then
  echo "coverage: no .totals.percent_covered in $REPORT (not a coverage.py JSON report?)"; exit 77
fi
PCT="$(printf '%.2f' "$PCT")"
STMTS="$(jq -r '.totals.num_statements // 0' "$REPORT")"
MISSING="$(jq -r '.totals.missing_lines // 0' "$REPORT")"

# ---- record the number so drift is visible even on a pass ----
mkdir -p "$(dirname "$OUT_FILE")"
jq -n --argjson measured "$PCT" --argjson floor "$FLOOR" --argjson target "$TARGET" \
      --argjson statements "$STMTS" --argjson missing "$MISSING" \
      '{measured: $measured, floor: $floor, target: $target,
        statements: $statements, missing_statements: $missing,
        scope: "backend unit suite (backend/tests/unit) vs app/"}' > "$OUT_FILE"

echo "coverage: backend ${PCT}% of ${STMTS} statements (floor ${FLOOR}%, NFR-MAINT-001 target ${TARGET}%)"

if awk -v p="$PCT" -v f="$FLOOR" 'BEGIN{exit !(p+0 < f+0)}'; then
  echo "coverage: BELOW FLOOR — ${PCT}% < ${FLOOR}%"
  echo "  least-covered modules (missing statements):"
  jq -r '.files | to_entries
         | map(select(.value.summary.missing_lines > 0))
         | sort_by(-.value.summary.missing_lines)[:10][]
         | "    \(.value.summary.missing_lines) missing  \(.key) (\(.value.summary.percent_covered | floor)%)"' \
     "$REPORT" 2>/dev/null
  echo "  add tests for the modules above, or state a lower enforced floor in $FLOOR_FILE"
  echo "  (lowering the floor is a deliberate, reviewable act — NFR-MAINT-001 cites this gate)"
  exit 1
fi

if [[ "$RATCHET" -eq 1 ]]; then
  [[ -f "$FLOOR_FILE" ]] || jq -n --argjson target "$TARGET" '{floor: 0, target: $target}' > "$FLOOR_FILE"
  # Compare against the COMMITTED floor, not the effective one: a run that passed --floor/
  # COVERAGE_FLOOR lower than what is committed (a scoped local check, a bisect) must never
  # write that lower number back. The ratchet is one-way by construction.
  COMMITTED="$(jq -r '.floor // 0' "$FLOOR_FILE")"
  NEW="$(awk -v p="$PCT" -v s="$RATCHET_SLACK" -v t="$TARGET" \
         'BEGIN{n=p-s; if (n>t) n=t; printf "%.1f", (n<0?0:n)}')"
  if awk -v n="$NEW" -v c="$COMMITTED" 'BEGIN{exit !(n+0 > c+0)}'; then
    jq --argjson floor "$NEW" --argjson target "$TARGET" --argjson measured "$PCT" \
       '.floor=$floor | .target=$target | .measured_at_last_ratchet=$measured' \
       "$FLOOR_FILE" > "$FLOOR_FILE.tmp" && mv "$FLOOR_FILE.tmp" "$FLOOR_FILE"
    echo "coverage: ratcheted floor ${COMMITTED}% → ${NEW}%"
  else
    echo "coverage: committed floor unchanged (${COMMITTED}%) — measured ${PCT}% does not clear it by ${RATCHET_SLACK}pt"
  fi
fi

exit 0
