#!/usr/bin/env bash
# seed-integrity.sh — full RUNTIME seed-integrity check against an ISOLATED ephemeral
# Postgres (own compose project + high port band; never touches the dev DB). Boots the DB,
# runs the manifest's boot_command (migrate + seed + verify), asserts each table meets its
# min_rows, and re-runs seed_command to assert idempotency (row counts unchanged). Row
# counts go through `docker compose exec postgres psql` so no host psql client is needed.
#
# gate_seed_integrity (scripts/quality-gates.sh) delegates here when docker is available and
# no DATABASE_URL is preset; otherwise it runs its static (file-existence) checks inline.
#
# Exit: 0 pass | 1 fail | 77 docker/compose/manifest unavailable.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

MANIFEST="state/artifacts/db-migrator.json"
[[ -f "$MANIFEST" ]] || { echo "no $MANIFEST"; exit 77; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || { echo "seed-integrity: docker unreachable — skipping"; exit 77; }
[[ -f docker-compose.yml && -f docker-compose.e2e.yml ]] \
  || { echo "seed-integrity: missing compose files — skipping"; exit 77; }

# shellcheck source=scripts/lib/ephemeral-pg.sh
source "$ROOT/scripts/lib/ephemeral-pg.sh"

PROJECT="${SEEDCHECK_PROJECT:-skillforge-seedcheck}"
LOCK_FILE="${SEEDCHECK_LOCK_FILE:-${TMPDIR:-/tmp}/skillforge-seedcheck-${PROJECT}.lock}"
epg_acquire_lock "$LOCK_FILE" "${SEEDCHECK_LOCK_TIMEOUT:-1800}" || exit 1

# High port band ABOVE integration (25432) so seed-check never contends with dev/e2e/itest.
epg_pick_port SF_PG_PORT       "${SF_PG_PORT:-35432}"
epg_pick_port SF_REDIS_PORT    "${SF_REDIS_PORT:-36379}"
epg_pick_port SF_API_PORT      "${SF_API_PORT:-38000}"
epg_pick_port SF_FRONTEND_PORT "${SF_FRONTEND_PORT:-33000}"
export SF_PG_PORT SF_REDIS_PORT SF_API_PORT SF_FRONTEND_PORT

DC=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.e2e.yml)
EPG_KEEP="${SEEDCHECK_KEEP:-0}"
trap epg_teardown EXIT INT TERM HUP

echo "seed-integrity: host pg port = ${SF_PG_PORT} [project ${PROJECT}]"
epg_reset_baseline "skillforge-seedcheck"
epg_boot_db postgres || { echo "seed-integrity: postgres did not come up"; exit 1; }

export DATABASE_URL="postgresql+asyncpg://postgres:postgres@127.0.0.1:${SF_PG_PORT}/skillforge"
export ENVIRONMENT=development BETA_MODE=false AUTH_BLACKLIST_FAIL_OPEN=true CONTENT_EVAL_ON_GENERATE=false
export SECRET_KEY="${SECRET_KEY:-seed-integrity-not-a-real-secret-000000000000}"

psql_count() { # <name> <count_query|null>
  local name="$1" q="$2"
  [[ "$q" == "null" || -z "$q" ]] && q="SELECT COUNT(*) FROM \"$name\""
  "${DC[@]}" exec -T postgres psql -U postgres -d skillforge -tAc "$q" 2>/dev/null | tr -d '[:space:]'
}

# 1. boot_command: migrate + seed + verify
boot_cmd="$(jq -r '.boot_command // empty' "$MANIFEST")"
if [[ -n "$boot_cmd" ]]; then
  echo "seed-integrity: running boot_command (migrate + seed + verify)…"
  bash -c "$boot_cmd" || { echo "seed-integrity: boot_command failed"; exit 1; }
fi

# 2. row-count assertions
row_fail=""
while IFS=$'\t' read -r name minrows query; do
  [[ -z "$name" ]] && continue
  c="$(psql_count "$name" "$query")"; [[ -z "$c" ]] && c=0
  if [[ "$c" -lt "$minrows" ]]; then
    row_fail+="  - $name: $c rows < manifest min_rows=$minrows"$'\n'
  else
    echo "seed-integrity: $name = $c rows (>= $minrows) ✓"
  fi
done < <(jq -r '(.seed_expectations.tables // [])[] | [.name, (.min_rows|tostring), (.count_query // "null")] | @tsv' "$MANIFEST")
if [[ -n "$row_fail" ]]; then
  echo "seed-integrity: seed produced fewer rows than the manifest promises:"; printf '%s' "$row_fail"; exit 1
fi

# 3. idempotency: re-run seed_command, assert counts unchanged
seed_cmd="$(jq -r '.seed_command // empty' "$MANIFEST")"
if [[ -n "$seed_cmd" ]] && jq -e '.seed_expectations.idempotent == true' "$MANIFEST" >/dev/null; then
  snapshot() { jq -r '(.seed_expectations.tables // [])[] | [.name, (.count_query // "null")] | @tsv' "$MANIFEST" \
      | while IFS=$'\t' read -r n q; do printf '%s:%s\n' "$n" "$(psql_count "$n" "$q")"; done; }
  pre="$(snapshot)"
  echo "seed-integrity: re-running seed_command to verify idempotency…"
  bash -c "$seed_cmd" || { echo "seed-integrity: second seed run failed"; exit 1; }
  post="$(snapshot)"
  if [[ "$pre" != "$post" ]]; then
    echo "seed-integrity: seed is NOT idempotent — row counts changed on second run:"
    diff <(echo "$pre") <(echo "$post") || true
    exit 1
  fi
  echo "seed-integrity: seed is idempotent (counts unchanged on re-run) ✓"
fi

echo "seed-integrity: runtime checks passed (rows + idempotency) against isolated ephemeral DB"
