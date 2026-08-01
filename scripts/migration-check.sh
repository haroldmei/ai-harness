#!/usr/bin/env bash
# migration-check.sh — model⇄migration drift gate (issue #194, root cause of #152).
#
# Spins up a SCRATCH Postgres, applies the full Alembic history
# (`alembic upgrade head`), then asks the autogenerate engine whether any model
# table/column exists with no migration (or vice-versa) — the exact drift that
# caused #152. See backend/scripts/check_migration_drift.py for why only
# STRUCTURAL drift (missing/extra tables & columns) is a hard failure while
# legacy cosmetic drift (nullability / index-naming / type-rendering) is
# reported but non-blocking.
#
# Scratch DB, in order of preference:
#   1. pg_virtualenv  — ephemeral, self-contained cluster (no daemon needed).
#   2. $DATABASE_URL / a Postgres already listening on localhost:5432, into a
#      throwaway database named drift_check_$$ (dropped on exit).
# If neither is available it exits 77 (SKIP) — the quality-gate spine promotes a
# 77 to FAIL only when the gate is tier-required.
#
# Exit: 0 no structural drift · 1 drift detected · 77 no Postgres available · 2 error.
#
# Flags:
#   --self-test   Prove the gate has teeth: after the clean check passes, inject
#                 a divergent (un-migrated) column into the model metadata and
#                 assert the checker reports structural drift. Used by
#                 scripts/migration-check.test.sh.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$ROOT/backend"
cd "$BACKEND" || { echo "FATAL: cannot cd to backend dir ${BACKEND}" >&2; exit 2; }

# Arg parse. `--_inner` is set when we re-exec ourselves INSIDE pg_virtualenv
# (DATABASE_URL already points at the ephemeral cluster) — it must short-circuit
# the provisioner block below so we don't try to nest a second cluster.
INNER=0
SELF_TEST=0
for a in "$@"; do
  case "$a" in
    --_inner)    INNER=1;;
    --self-test) SELF_TEST=1;;
  esac
done

# Use the interpreter that runs the app, not the `alembic` console-script shebang
# (which may point at a different Python without the app's deps — e.g. a system
# python3.10 missing datetime.UTC). `python -m alembic` always uses $PY.
PY="${PYTHON:-python}"

# The drift logic itself, run once Postgres is reachable via $DATABASE_URL.
# Kept as a function so both the real provisioners call the identical body.
run_drift_check() {
  export ENVIRONMENT="${ENVIRONMENT:-development}"
  # A real secret so the non-dev Settings validator never trips if ENVIRONMENT
  # is overridden in the caller's environment.
  export SECRET_KEY="${SECRET_KEY:-migration-drift-check-not-a-real-secret-000000000000}"

  echo "→ alembic upgrade head"
  if ! "$PY" -m alembic upgrade head; then
    echo "✗ alembic upgrade head FAILED — migrations do not apply cleanly"
    return 1
  fi

  echo "→ checking model⇄migration drift"
  "$PY" scripts/check_migration_drift.py
  local rc=$?

  if [[ "$SELF_TEST" -eq 1 && "$rc" -eq 0 ]]; then
    echo
    echo "→ self-test: injecting an un-migrated model column, expecting DRIFT"
    DRIFT_SELFTEST_INJECT=1 "$PY" scripts/check_migration_drift.py
    local inj=$?
    if [[ "$inj" -eq 1 ]]; then
      echo "✓ self-test passed — checker reports structural drift on a divergent model"
    else
      echo "✗ self-test FAILED — checker did not flag an un-migrated column (exit $inj)"
      return 1
    fi
  fi

  return "$rc"
}

# ── --_inner: body invoked INSIDE pg_virtualenv (DATABASE_URL already set) ─────
# Checked BEFORE the provisioners so the nested invocation never starts a second
# cluster (which would collide on port 5432). Writes its real exit code to
# $DRIFT_SENTINEL so the outer call can tell "the check ran and decided" apart
# from "pg_virtualenv could not even provision a cluster".
if [[ "$INNER" -eq 1 ]]; then
  run_drift_check
  rc=$?
  [[ -n "${DRIFT_SENTINEL:-}" ]] && echo "$rc" > "$DRIFT_SENTINEL"
  exit "$rc"
fi

# ── Provisioner 1: pg_virtualenv (preferred — ephemeral, no daemon) ───────────
# MIGRATION_DRIFT_NO_PGVENV=1 forces the docker fallback below (Provisioner 3) instead — for a
# host where pg_virtualenv is present but broken/slow, and to exercise the docker path in tests.
if [[ "${MIGRATION_DRIFT_NO_PGVENV:-0}" != "1" ]] && command -v pg_virtualenv >/dev/null 2>&1; then
  echo "migration-check: using pg_virtualenv (ephemeral cluster)"
  # pg_virtualenv runs the command with PG* env pointing at a fresh cluster it
  # tears down afterwards. Re-exec this script's body inside it. A sentinel file
  # disambiguates a real verdict from a provisioning failure (e.g. port 5432
  # already held by a dev/e2e Postgres) — the latter falls through below.
  DRIFT_SENTINEL="$(mktemp)"; rm -f "$DRIFT_SENTINEL"
  export PYTHON SELF_TEST DRIFT_SENTINEL
  pg_virtualenv bash -c '
    export DATABASE_URL="postgresql+asyncpg://$PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
    "'"$ROOT"'/scripts/migration-check.sh" --_inner '"$([[ $SELF_TEST -eq 1 ]] && echo --self-test)"'
  '
  if [[ -f "$DRIFT_SENTINEL" ]]; then
    rc="$(cat "$DRIFT_SENTINEL")"; rm -f "$DRIFT_SENTINEL"
    # Emit a clean final line AFTER pg_virtualenv's "Dropping cluster …" teardown
    # so the quality-gate scorecard's reason (tail -n1) is meaningful.
    case "$rc" in
      0) echo "migration-drift: PASS — no structural model⇄migration drift";;
      1) echo "migration-drift: FAIL — structural drift detected (see log above)";;
      *) echo "migration-drift: ERROR (exit $rc)";;
    esac
    exit "${rc:-2}"
  fi
  rm -f "$DRIFT_SENTINEL"
  echo "migration-check: pg_virtualenv could not provision a cluster (port in use?) — trying a reachable Postgres"
fi

# ── Provisioner 2: a reachable Postgres (DATABASE_URL or localhost:5432) ───────
db_host_reachable() { (exec 3<>/dev/tcp/127.0.0.1/5432) 2>/dev/null; }
if [[ -n "${DATABASE_URL:-}" ]] || db_host_reachable; then
  echo "migration-check: using a reachable Postgres (throwaway database)"
  # Carve a throwaway database so we never touch a real schema.
  ADMIN_URL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"
  SCRATCH_DB="drift_check_$$"
  PSQL_ADMIN="${ADMIN_URL/postgresql+asyncpg:/postgresql:}"
  if command -v psql >/dev/null 2>&1; then
    psql "$PSQL_ADMIN" -c "CREATE DATABASE $SCRATCH_DB" >/dev/null 2>&1 || true
    trap 'psql "$PSQL_ADMIN" -c "DROP DATABASE IF EXISTS '"$SCRATCH_DB"'" >/dev/null 2>&1 || true' EXIT
    # Point the app at the scratch DB (asyncpg driver).
    base="${PSQL_ADMIN%/*}"
    export DATABASE_URL="${base/postgresql:/postgresql+asyncpg:}/$SCRATCH_DB"
  fi
  run_drift_check
  exit $?
fi

# ── Provisioner 3: ephemeral docker Postgres (Docker hosts never silently skip) ───────────────
# pg_virtualenv is absent on most CI/dev hosts and no dev Postgres may be listening — yet a
# launch host HAS docker (it already boots the integration/e2e/lighthouse/visual stacks). Boot
# our OWN throwaway Postgres under a distinct compose project on a HIGH port band (never the dev
# DB), apply the schema, run the drift check, tear down. Mirrors scripts/integration.sh's
# isolation so migration-drift can be a REQUIRED launch gate (#1971) without silently skipping on
# hosts that have docker but no pg_virtualenv. Opt out with MIGRATION_DRIFT_NO_DOCKER=1.
if [[ "${MIGRATION_DRIFT_NO_DOCKER:-0}" != "1" ]] \
   && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
   && [[ -f "$ROOT/docker-compose.yml" && -f "$ROOT/docker-compose.e2e.yml" ]]; then
  echo "migration-check: booting an isolated ephemeral docker Postgres (no pg_virtualenv / reachable PG)…"
  # shellcheck source=scripts/lib/ephemeral-pg.sh
  source "$ROOT/scripts/lib/ephemeral-pg.sh"
  PROJECT="${MIGRATION_DRIFT_PROJECT:-skillforge-migdrift}"
  LOCK_FILE="${MIGRATION_DRIFT_LOCK_FILE:-${TMPDIR:-/tmp}/skillforge-migdrift-${PROJECT}.lock}"
  epg_acquire_lock "$LOCK_FILE" "${MIGRATION_DRIFT_LOCK_TIMEOUT:-2700}" || exit 2
  # High port band ABOVE integration (25432) and e2e (15432) so concurrent gates never contend.
  epg_pick_port SF_PG_PORT       "${SF_PG_PORT:-45432}"
  epg_pick_port SF_REDIS_PORT    "${SF_REDIS_PORT:-46379}"
  epg_pick_port SF_API_PORT      "${SF_API_PORT:-48000}"
  epg_pick_port SF_FRONTEND_PORT "${SF_FRONTEND_PORT:-43000}"
  export SF_PG_PORT SF_REDIS_PORT SF_API_PORT SF_FRONTEND_PORT
  # Absolute -f paths: cwd is $BACKEND (run_drift_check needs it for `alembic`), but the compose
  # files live at $ROOT. docker compose sets the project dir from the first -f file, so relative
  # build contexts still resolve.
  DC=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.e2e.yml")
  EPG_KEEP="${MIGRATION_DRIFT_KEEP:-0}"
  trap epg_teardown EXIT INT TERM HUP
  epg_reset_baseline "$PROJECT"
  epg_boot_db postgres || { echo "migration-check: ephemeral postgres did not come up"; exit 2; }
  export DATABASE_URL="postgresql+asyncpg://postgres:postgres@127.0.0.1:${SF_PG_PORT}/skillforge"
  run_drift_check
  exit $?
fi

echo "migration-check: no Postgres available (install postgresql-common for pg_virtualenv, set DATABASE_URL, start Postgres, or run on a docker host) — skipping"
exit 77
