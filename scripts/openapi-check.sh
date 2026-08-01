#!/usr/bin/env bash
# openapi-check.sh — fail if the committed openapi.yaml has drifted from the app's
# generated schema. The API-surface analogue of scripts/migration-check.sh: a route,
# request, or response-model change that isn't reflected in the committed spec fails CI,
# so the contract gate can never lint a stale spec.
#
# Regenerate after an intentional API change:  cd backend && python scripts/dump_openapi.py
#
# Exit: 0 in sync | 1 drift (prints the diff) | 77 cannot generate (no python/app).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

COMMITTED="$ROOT/openapi.yaml"
[[ -f "$COMMITTED" ]] || { echo "no committed openapi.yaml (run: cd backend && python scripts/dump_openapi.py)"; return 77 2>/dev/null || exit 77; }
command -v python >/dev/null || { echo "python unavailable"; exit 77; }

TMP="$(mktemp -t openapi-XXXXXX.yaml)"
trap 'rm -f "$TMP"' EXIT

if ! ( cd backend && python scripts/dump_openapi.py "$TMP" ) >/dev/null 2>&1; then
  echo "could not generate OpenAPI schema from the app"; exit 77
fi

# PID-namespaced: three agent lanes run concurrently on this host and a fixed
# /tmp/openapi-drift.diff meant lane 1's drift report overwrote lane 0's mid-read, so a gate
# could print another lane's diff as its own (issue #2387, M3 — same class as #2211).
DRIFT_DIFF="${OPENAPI_DRIFT_DIFF:-/tmp/openapi-drift-$$.diff}"
trap 'rm -f "$TMP" "$DRIFT_DIFF"' EXIT
if ! diff -u "$COMMITTED" "$TMP" >"$DRIFT_DIFF" 2>&1; then
  echo "openapi.yaml is STALE — regenerate with: cd backend && python scripts/dump_openapi.py"
  sed -n '1,40p' "$DRIFT_DIFF"
  exit 1
fi
echo "openapi.yaml in sync with the app schema"
