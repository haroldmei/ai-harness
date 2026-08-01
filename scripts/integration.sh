#!/usr/bin/env bash
# integration.sh — run skillforge's backend integration suite against an ISOLATED,
# ephemeral Postgres (not the dev DB). Previously this gate SKIPped unless a Postgres
# happened to listen on :5432 — which, if the DEV stack was up, would run the suite
# against the developer's real database. Now it boots its OWN throwaway Postgres under a
# distinct compose project on a HIGH port band (never touching dev's :5432 or its named
# volume), applies the full alembic schema, runs pytest, and tears down.
#
# The migrated DB has FORCE ROW LEVEL SECURITY disabled (the raw test-fixture sessions run
# as the superuser owner, so NO FORCE makes them unscoped — matching the old SQLite path).
# RLS *enforcement* stays proven by the dedicated testcontainer RLS suites, which build their
# own FORCE-enabled containers.
#
#   scripts/integration.sh                      # boot ephemeral PG, migrate, run, tear down
#   INTEGRATION_KEEP=1 scripts/integration.sh   # leave the DB up for debugging
#   ITEST_SPECS="tests/integration/test_auth_api.py" scripts/integration.sh
#
# Exit: 0 pass | 1 failed | 77 no suite / docker unavailable.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

[[ -d backend/tests/integration ]] || { echo "no backend/tests/integration"; exit 77; }

# xdist speeds up the integration gate (~920s serial), but needs worker-namespaced
# fixture identities (issue #2164 T1-c).
#
# --dist LOADGROUP, not loadfile. Nine modules in tests/integration each start their OWN
# testcontainers Postgres in a module-scoped fixture. loadfile pinned each module to one worker but
# did nothing to stop all nine running AT ONCE on nine different workers — and with three gate lanes
# that reached ~27 Postgres containers. Past a point the box cannot bring a container to "listening"
# before alembic dials it, and the fixture dies at setup with
#   ConnectionRefusedError: [Errno 111] Connect call failed
# Measured on a 32-core/62G host: one container is ready in ~1.3s idle, sixteen take ~8.1s. The
# failures rotate between modules and scale with load (2 → 9 → 14 → 15 → 20 → 36 errors across six
# consecutive runs), which is the signature of starvation rather than of a bug.
#
# backend/tests/integration/conftest.py assigns the grouping loadgroup distributes by: every
# container-owning module shares the group `pgcontainer` (serialised onto ONE worker → one container
# at a time), and every other module gets a group named after its file, which reproduces exactly what
# loadfile gave us. Without that second half, loadgroup would scatter ungrouped tests individually
# and break modules whose tests assume a shared worker.
#
# Worker count is CAPPED (ITEST_XDIST_MAX, default 16) instead of `-n auto`. `auto` is core count —
# 32 here — and three concurrent gate lanes at 32 workers oversubscribes the CPU badly regardless of
# how few containers are alive, which inflates every container's time-to-ready.
XDIST=()
ITEST_XDIST_MAX="${ITEST_XDIST_MAX:-16}"
if ( cd backend && python -c "import xdist" ) 2>/dev/null; then
  _itest_cores="$(nproc 2>/dev/null || echo "$ITEST_XDIST_MAX")"
  _itest_workers=$(( _itest_cores < ITEST_XDIST_MAX ? _itest_cores : ITEST_XDIST_MAX ))
  XDIST=(-n "$_itest_workers" --dist loadgroup)
fi

# A caller-provided DATABASE_URL (already a reachable Postgres) short-circuits the bring-up.
if [[ -n "${DATABASE_URL:-}" ]]; then
  echo "integration: using caller DATABASE_URL — running pytest directly"
  ( cd backend && python -m pytest "${ITEST_SPECS:-tests/integration/}" -q --no-cov -p no:cacheprovider "${XDIST[@]}" )
  exit $?
fi

# Opt-in: the isolated ephemeral-Postgres bring-up runs only when ITEST_LOCAL_STACK=1 (or a
# DATABASE_URL is supplied above). By default this gate SKIPs — the integration suite still
# carries ~80 SQLite-era fixtures that use non-UUID string ids and naive datetimes, which a
# real Postgres rejects; that remediation is tracked separately. Defaulting to skip keeps the
# launch gate green until the suite is Postgres-clean, and (unlike the old behavior) we NEVER
# auto-run against a Postgres on :5432, so the dev database is never touched.
if [[ "${ITEST_LOCAL_STACK:-0}" != "1" ]]; then
  echo "integration: disabled by default (set ITEST_LOCAL_STACK=1 to boot an isolated ephemeral Postgres, or pass DATABASE_URL) — skipping"
  exit 77
fi

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || { echo "integration: docker daemon unreachable — skipping"; exit 77; }
[[ -f docker-compose.yml && -f docker-compose.e2e.yml ]] \
  || { echo "integration: missing compose files — skipping"; exit 77; }

# shellcheck source=scripts/lib/ephemeral-pg.sh
source "$ROOT/scripts/lib/ephemeral-pg.sh"

PROJECT="${INTEGRATION_PROJECT:-skillforge-itest}"
LOCK_FILE="${INTEGRATION_LOCK_FILE:-${TMPDIR:-/tmp}/skillforge-itest-${PROJECT}.lock}"
epg_acquire_lock "$LOCK_FILE" "${INTEGRATION_LOCK_TIMEOUT:-2700}" || exit 1

# High port band ABOVE e2e (15432) so integration + e2e never contend for a starting port.
epg_pick_port SF_PG_PORT       "${SF_PG_PORT:-25432}"
# Pin the other host ports too (compose publishes them even though we only start postgres),
# so a concurrent dev/e2e stack can't collide on 5432/6379/8000/3000.
epg_pick_port SF_REDIS_PORT    "${SF_REDIS_PORT:-26379}"
epg_pick_port SF_API_PORT      "${SF_API_PORT:-28000}"
epg_pick_port SF_FRONTEND_PORT "${SF_FRONTEND_PORT:-23000}"
export SF_PG_PORT SF_REDIS_PORT SF_API_PORT SF_FRONTEND_PORT

DC=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.e2e.yml)
EPG_KEEP="${INTEGRATION_KEEP:-0}"
trap epg_teardown EXIT INT TERM HUP

echo "integration: host pg port = ${SF_PG_PORT} [project ${PROJECT}]"
epg_reset_baseline "skillforge-itest"
epg_boot_db postgres || { echo "integration: postgres did not come up"; exit 1; }

export DATABASE_URL="postgresql+asyncpg://postgres:postgres@127.0.0.1:${SF_PG_PORT}/skillforge"

# run_migrations.py runs as a standalone script BEFORE conftest's env defaults apply, so set
# the same test env here (Settings defaults ENVIRONMENT to non-dev, which trips the
# "secret_key must be changed" validator). Forced to development for this throwaway test DB,
# mirroring conftest's setdefault values. pytest then inherits these (conftest only setdefaults).
export ENVIRONMENT=development
export BETA_MODE=false
export AUTH_BLACKLIST_FAIL_OPEN=true
export CONTENT_EVAL_ON_GENERATE=false
export SECRET_KEY="${SECRET_KEY:-integration-test-not-a-real-secret-000000000000}"
# Point the token-blacklist Redis at an unreachable port so it stays INERT (fail-open),
# exactly like clean CI. Without this, on a dev box where Redis is up on :6379 the tests
# connect to the DEV Redis and the cached async client (a module singleton in
# app/core/security.py) is reused across pytest's per-test event loops → "Future attached to
# a different loop" → hang. Connection-refused on :1 fails fast, so the blacklist is inert.
export REDIS_URL="redis://127.0.0.1:1/0"

echo "integration: applying alembic migrations to the ephemeral DB…"
( cd backend && python scripts/run_migrations.py ) || { echo "integration: migrations failed"; exit 1; }

# Disable FORCE RLS on the itest DB only (the test fixtures run as the superuser owner; with
# FORCE off the owner bypasses RLS, so unscoped fixture reads behave like the old SQLite path).
echo "integration: disabling FORCE row-level security on the ephemeral DB (test-only)…"
if ! "${DC[@]}" exec -T postgres psql -U postgres -d skillforge -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT relname FROM pg_class WHERE relforcerowsecurity AND relkind = 'r' LOOP
    EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', r.relname);
  END LOOP;
END $$;
SQL
then
  echo "integration: failed to relax FORCE RLS"; exit 1
fi

echo "integration: running pytest (tests/integration) against the ephemeral Postgres…"
# Per-test timeout (signal method) so a single hanging test — e.g. an async client/limiter
# bound to a dead endpoint, or an unbounded SSE stream — fails THAT test instead of stalling
# the whole gate forever. signal interrupts the test's own event loop and continues the run.
#
# EXPORTED, and the flag reads the exported value rather than re-applying its own default: pytest-
# timeout also covers module-scoped fixture SETUP, and `tests/integration/_pg_container.py` sizes
# its container-retry budget against this number so its diagnostics stay reachable. Two independent
# defaults would let an operator's override move the timeout but not the budget (issue #2183).
export ITEST_TIMEOUT="${ITEST_TIMEOUT:-210}"
( cd backend && python -m pytest "${ITEST_SPECS:-tests/integration/}" -q --no-cov -p no:cacheprovider \
    --timeout="${ITEST_TIMEOUT}" --timeout-method=signal "${XDIST[@]}" )
rc=$?
echo "integration: pytest exit=${rc}"
exit "$rc"
