#!/usr/bin/env bash
# run-e2e.sh — run skillforge's Playwright e2e (frontend/tests/e2e/*.spec.ts) against a
# REAL running stack and drive the browser user journeys.
#
# Two targets:
#   1) LOCAL FULL STACK (E2E_LOCAL_STACK=1) — boot docker compose (postgres+redis+api+
#      frontend), wait healthy, seed idempotently (test-admin/test-learner), then run the
#      browser suite against http://localhost:3000. The frontend is rebuilt to talk to the
#      LOCAL api (docker-compose.e2e.yml), so nothing touches production/staging.
#   2) REMOTE (E2E_LIVE=1 or FRONTEND_URL=…) — run against an already-running URL (e.g.
#      staging); no stack boot, no seed.
#
# Disabled by default (skip 77) so the unattended harness never boots a stack or hits a
# live URL unasked. Data safety: the e2e stack runs under its OWN compose project (a DIFFERENT
# project from the dev stack, whose skillforge_postgres_data volume is never touched). Its DB is
# VOLUME-LESS (tmpfs — see docker-compose.e2e.yml + issue #171), and every named-volume removal
# here is scoped to this gate's project / the skillforge-e2e prefix, so dev data stays safe.
#
# EPHEMERAL DB (issues #98/#140/#171): the e2e gate uses a FIXED compose project, so any named
# postgres volume would persist across runs and branches. A volume left behind by a prior or
# concurrent branch — a stale alembic revision, a half-applied migration, or mismatched DB
# creds — makes `alembic upgrade head` (and thus the api) fail on boot, which docker reports as
# "dependency failed to start". Defence in depth: (1) the DB has NO named volume at all — postgres
# runs on a tmpfs via `!override` (docker-compose.e2e.yml), so initdb + the password ALWAYS run on
# a fresh data dir; (2) `down -v` + a project-scoped scrub + an orphan reaper run before boot, so a
# survivor/orphan from a killed run can't poison this one; (3) if postgres still comes up unhealthy
# or rejecting creds, the run scrubs + re-inits ONCE in-line and self-heals instead of failing.
#
#   E2E_LOCAL_STACK=1 scripts/run-e2e.sh                 # boot+seed+run locally, then tear down
#   E2E_LOCAL_STACK=1 E2E_KEEP=1 scripts/run-e2e.sh      # leave the stack UP for debugging
#   E2E_LOCAL_STACK=1 E2E_NO_BUILD=1 scripts/run-e2e.sh  # reuse images (skip rebuild)
#   E2E_SPECS="tests/e2e/learner.spec.ts" E2E_LOCAL_STACK=1 scripts/run-e2e.sh
#   E2E_LIVE=1 scripts/run-e2e.sh                         # run against staging (remote)
#
# Exit: Playwright's exit code (0 = pass) | 77 = skipped (disabled / no config).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/run-e2e.sh"   # absolute self-path, stable across the cd + lock re-exec below
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

[[ -f frontend/playwright.config.ts ]] || { echo "e2e: no playwright config — skipping"; exit 77; }

run_playwright() { # <frontend_url> <api_url>
  ( cd frontend || { echo "FATAL: no frontend/ directory under $PWD" >&2; exit 2; }
    [[ -d node_modules ]] || npm ci
    npx --no-install playwright install chromium >/dev/null 2>&1 || true
    local skip_msg=""; local skip_flags=""
    if [[ -n "${E2E_SKIP:-}" ]]; then
      # E2E_SKIP=basename1,basename2 → --grep-invert 'basename1|basename2'
      # Playwright's --grep-invert matches against the full test title (which includes
      # the spec file name), so skipping by basename quarantines the whole spec file.
      skip_flags="--grep-invert $(echo "$E2E_SKIP" | tr ',' '|')"
      skip_msg=" (quarantined: ${E2E_SKIP})"
    fi
    echo "e2e: running Playwright against $1 → ${E2E_SPECS:-all specs}${skip_msg}"
    # Force CI mode so playwright.config pins workers=2 (+ retries=1). Without it,
    # Playwright defaults to ~half the host's cores (16 on a 32-core box) — far more
    # than the 2-account admin pool (fixtures.ts SEED_ADMIN_EMAILS), so workers
    # collide modulo-2 onto the same admin and livelock on its single-column MFA
    # challenge token → the floating "MFA challenge never completed" flake.
    # --project=chromium prevents the `visual` project (*.visual.spec.ts) from running
    # here: those specs compare pixels against pinned-container Linux baselines and will
    # produce spurious diffs when executed on a host chromium outside the container.
    # shellcheck disable=SC2086
    CI=1 FRONTEND_URL="$1" API_URL="$2" npx --no-install playwright test --project=chromium ${E2E_SPECS:-} $skip_flags --reporter=line )
}

# ── Target 2: remote URL (no stack management) ───────────────────────────────────────────
if [[ "${E2E_LOCAL_STACK:-0}" != "1" ]]; then
  if [[ "${E2E_LIVE:-0}" != "1" && -z "${FRONTEND_URL:-}" ]]; then
    echo "e2e: disabled (set E2E_LOCAL_STACK=1 for a local stack, or E2E_LIVE=1/FRONTEND_URL for a remote target) — skipping"
    exit 77
  fi
  run_playwright "${FRONTEND_URL:-}" "${API_URL:-}"
  exit $?
fi

# ── Target 1: local full stack ───────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "e2e: docker daemon unreachable — skipping"; exit 77; }
[[ -f docker-compose.yml && -f docker-compose.e2e.yml ]] || { echo "e2e: missing compose files — skipping"; exit 77; }

PROJECT="${E2E_PROJECT:-skillforge-e2e}"

# ── Serialize concurrent e2e runs that share this compose project (issue #140) ─────────────
# E2E_LOCAL_STACK=1 is baked into FOUR systemd agents (pr-merger, pr-fixer, inbox, pipeline),
# so several e2e runs hit the SAME docker daemon and the SAME fixed compose project at once.
# Host PORTS are deconflicted per run (pick_port below), but the compose PROJECT — and thus its
# postgres CONTAINER and named volume — are shared. Without a lock, run B's `down -v` (the
# clean-baseline reset / teardown) tears the volume out from under run A's live postgres,
# leaving a half-initialized data dir whose superuser password was never set by initdb. The
# next TCP connection then fails with `password authentication failed for user "postgres"`,
# which docker surfaces as the api crashing on boot — blocking EVERY branch's e2e gate, not
# just the one that happened to collide. A per-project file lock makes runs QUEUE instead of
# stomp, so each owns the shared project start-to-teardown. flock releases automatically if the
# holder dies (fd closes on exit), so a crashed run can never deadlock the gate. Distinct
# E2E_PROJECTs get distinct lockfiles, so they still run in parallel. E2E_NO_LOCK=1 opts out.
LOCK_FILE="${E2E_LOCK_FILE:-${TMPDIR:-/tmp}/skillforge-e2e-${PROJECT}.lock}"
if [[ "${E2E_NO_LOCK:-0}" != "1" && -z "${_E2E_LOCKED:-}" ]] && command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  echo "e2e: acquiring the e2e lock (${LOCK_FILE}) so concurrent agent runs don't share the DB volume…"
  if ! flock -w "${E2E_LOCK_TIMEOUT:-2700}" 9; then
    echo "e2e: timed out after ${E2E_LOCK_TIMEOUT:-2700}s waiting for the e2e lock — another e2e run still holds it"
    exit 1
  fi
  # Re-exec under the held lock; fd 9 survives exec (not close-on-exec), so the lock is owned for
  # the WHOLE run incl. teardown. _E2E_LOCKED stops the re-exec'd instance from locking again.
  _E2E_LOCKED=1 exec bash "$SELF" "$@"
fi

# Distinct HIGH host ports by default so the e2e stack never clashes with a dev stack on
# 3000/8000/5432/6379. The configured value is a STARTING point: if it (or a port chosen for
# another service) is already bound — e.g. you have a local stack up, or two loops run at once
# — bump upward to the next free one. So the e2e gate is collision-proof against ANY running
# stack. The base compose reads SF_*_PORT; the overlay bakes VITE_API_URL from SF_API_PORT, so
# ports must be resolved BEFORE the build/up below.
port_in_use() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$"; }
CHOSEN_PORTS=""
pick_port() { # <varname> <start>
  local p="$2"
  while port_in_use "$p" || [[ " $CHOSEN_PORTS " == *" $p "* ]]; do p=$((p + 1)); done
  CHOSEN_PORTS="$CHOSEN_PORTS $p"
  printf -v "$1" '%s' "$p"
}
pick_port SF_FRONTEND_PORT "${SF_FRONTEND_PORT:-13000}"
pick_port SF_API_PORT      "${SF_API_PORT:-18000}"
pick_port SF_PG_PORT       "${SF_PG_PORT:-15432}"
pick_port SF_REDIS_PORT    "${SF_REDIS_PORT:-16379}"
export SF_FRONTEND_PORT SF_API_PORT SF_PG_PORT SF_REDIS_PORT
DC=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.e2e.yml)
FE_URL="http://localhost:${SF_FRONTEND_PORT}"; API_URL_LOCAL="http://localhost:${SF_API_PORT}"
echo "e2e: host ports → frontend=${SF_FRONTEND_PORT} api=${SF_API_PORT} pg=${SF_PG_PORT} redis=${SF_REDIS_PORT}"

CLEANED=0
cleanup() {
  [[ "$CLEANED" == 1 ]] && return; CLEANED=1
  if [[ "${E2E_KEEP:-0}" == 1 ]]; then
    echo "e2e: leaving the stack UP (E2E_KEEP=1) — tear down with: ${DC[*]} down -v"
  else
    echo "e2e: tearing down the e2e stack (removing the ephemeral DB volume)…"
    "${DC[@]}" down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM HUP

# ── Volume hygiene (issue #171) ────────────────────────────────────────────────────────────
# The e2e DB is volume-less BY CONSTRUCTION: docker-compose.e2e.yml pins postgres to a tmpfs
# mount with `!override`, so no ${PROJECT}_postgres_data named volume is ever provisioned or
# mounted (verify: `docker volume ls` shows none during/after a run). The scrubs below are
# belt-and-suspenders for two failure modes the tmpfs alone cannot cover:
#   • a SURVIVOR named volume from a run on an older/quirky compose that DID mount one and left
#     it half-initialized (unset superuser password → `password authentication failed`), which
#     a best-effort `down -v` can't reclaim while a leftover container still holds it; and
#   • ORPHANS from custom-E2E_PROJECT runs killed before teardown, which nothing else reaps.
# Every removal here is NAME-SCOPED to this gate (the fixed project name, or the `skillforge-e2e`
# prefix) — never an unscoped `docker volume rm` that could reach the dev stack's
# skillforge_postgres_data or another repo's modelforge-e2e_* volumes.
scrub_project_volumes() { # drop THIS project's leftover named volumes (no-op if absent or in-use)
  docker volume rm -f "${PROJECT}_postgres_data" "${PROJECT}_redis_data" >/dev/null 2>&1 || true
}
reap_orphan_volumes() {
  # Prune stray skillforge-e2e*_{postgres,redis}_data volumes orphaned by killed runs. `docker
  # volume rm` REFUSES a volume that's in use, so volumes held by a live concurrent run are
  # skipped automatically (|| true). The `^skillforge-e2e` anchor is the safety boundary: it
  # matches this gate's fixed project AND custom runs (skillforge-e2e-<tag>_…) but NEVER another
  # repo's modelforge-e2e_* nor the dev stack's skillforge_postgres_data (no `-e2e` infix).
  local v
  for v in $(docker volume ls -q 2>/dev/null | grep -E '^skillforge-e2e[^[:space:]]*_(postgres|redis)_data$' || true); do
    docker volume rm -f "$v" >/dev/null 2>&1 || true
  done
}

# Start from a CLEAN DB every run (issue #98). The fixed compose project means a poisoned
# postgres volume left by a prior/concurrent run (crashed before teardown, or a different
# branch's alembic head) would make the api fail to migrate on boot. `down -v` removes ONLY
# this project's named volumes (skillforge-e2e*_postgres_data / _redis_data); the dev stack's
# skillforge_postgres_data is a separate compose project and is untouched.
echo "e2e: resetting the ephemeral DB volume (clean migration baseline)…"
"${DC[@]}" down -v >/dev/null 2>&1 || true
# Belt-and-suspenders (issue #171): scrub a survivor this project's down -v couldn't reclaim, and
# reap orphans from killed custom-project runs, BEFORE booting — so neither can poison this run.
scrub_project_volumes
reap_orphan_volumes

echo "e2e: booting local stack [project ${PROJECT}] (api migrates on boot)…"
build_flag="--build"; [[ "${E2E_NO_BUILD:-0}" == 1 ]] && build_flag=""

# Bring postgres+redis up healthy. The e2e overlay's healthcheck gates on a REAL TCP + password-
# authenticated query, so `--wait` succeeding already means the credentials the api uses work.
# pg_auth_ok re-checks that explicitly (issue #171) — independent of which healthcheck is active —
# so a poisoned/half-initialized data dir is caught even if the base socket-only check were in use.
# shellcheck disable=SC2086
boot_db()    { "${DC[@]}" up -d $build_flag --wait postgres redis; }
pg_auth_ok() { "${DC[@]}" exec -T postgres sh -c 'PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -d skillforge -c "SELECT 1" >/dev/null 2>&1'; }

# IN-RUN RECOVERY (issue #171): if postgres doesn't come up healthy OR rejects the credentials —
# the poisoned-volume signature — tear the volume out, scrub, and re-up ONCE so the gate self-heals
# within the run instead of dead-ending an issue on needs-human. A second failure is a real fault.
if ! { boot_db && pg_auth_ok; }; then
  echo "e2e: postgres unhealthy or rejecting credentials (poisoned DB volume?) — scrubbing and re-initializing once…"
  "${DC[@]}" logs --tail 20 postgres 2>&1 | sed 's/^/e2e:   pg| /' || true
  "${DC[@]}" down -v >/dev/null 2>&1 || true
  scrub_project_volumes
  if ! { boot_db && pg_auth_ok; }; then
    echo "e2e: db/redis still not healthy after recovery — failing"
    "${DC[@]}" logs --tail 40 postgres || true
    exit 1
  fi
  echo "e2e: DB recovered after scrub + re-init"
fi
# shellcheck disable=SC2086
# On boot failure DUMP the api/frontend container logs — a container that exits during
# `alembic upgrade head` carries the real cause ("migrate: non-transient failure …",
# DatatypeMismatchError, DuplicateTable, etc.) in ITS logs, not in this compose-level
# "dependency failed to start" line. Without this dump the triage classifier (#172) never
# sees the migrate marker and misfingerprints a branch-introduced migration bug as infra
# `dependency-failed-to-start`, dead-ending the issue on needs-human (see #152, #210).
"${DC[@]}" up -d $build_flag api frontend || {
  echo "e2e: api/frontend failed to start"
  "${DC[@]}" logs --tail 80 api frontend 2>&1 || true
  exit 1
}

# api/frontend now carry compose healthchecks (used by the deploy stack's --wait); here we still
# poll their HTTP surfaces directly as the readiness gate before seeding + the browser run.
poll() { # <url> <name>
  for _ in $(seq 1 60); do curl -fsS "$1" >/dev/null 2>&1 && { echo "e2e: $2 ready"; return 0; }; sleep 2; done
  echo "e2e: $2 did not become ready ($1)"; return 1
}
poll "$API_URL_LOCAL/health" api || { "${DC[@]}" logs --tail 40 api; exit 1; }
poll "$FE_URL" frontend       || { "${DC[@]}" logs --tail 40 frontend; exit 1; }

echo "e2e: seeding (idempotent: test-admin/test-learner + demo content)…"
"${DC[@]}" exec -T api python scripts/seed_courses.py || { echo "e2e: seed failed"; "${DC[@]}" logs --tail 40 api; exit 1; }

echo "e2e: verifying seed completeness (issue #26)…"
"${DC[@]}" exec -T api python scripts/verify_seed.py || { echo "e2e: seed verify failed — DB is missing seed data"; "${DC[@]}" logs --tail 40 api; exit 1; }

run_playwright "$FE_URL" "$API_URL_LOCAL"
rc=$?
echo "e2e: playwright exit=${rc}"
exit "$rc"
