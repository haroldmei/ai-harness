#!/usr/bin/env bash
# run-visual.sh — boot an ISOLATED, ephemeral full stack (postgres+redis+api+frontend),
# seed it, and run the Playwright visual-regression suite (frontend/tests/e2e/*.visual.spec.ts,
# the `visual` project — toHaveScreenshot) INSIDE A PINNED container so the screenshots are
# HOST-INDEPENDENT.
#
# WHY A PINNED CONTAINER: toHaveScreenshot compares pixels against committed baselines. Font
# hinting, antialiasing and the device-pixel-ratio differ host-to-host, so a baseline taken on
# one machine fails on another. We render inside mcr.microsoft.com/playwright:v1.49.1-jammy —
# the image matching the pinned @playwright/test 1.49.1 — so every run (baseline-gen, CI, a
# teammate's box) renders identically. The committed PNGs carry a -linux platform suffix.
#
# Modeled on scripts/run-lighthouse.sh's isolated bring-up (reusing scripts/lib/ephemeral-pg.sh
# for the per-project flock, tmpfs ephemeral DB, name-scoped volume hygiene and one-shot pg
# self-heal) and scripts/run-e2e.sh's seed step (the visual specs log in as the seeded
# learner/admin via the auth fixtures, so the stack must carry the same seed content).
#
# DATA SAFETY: runs under its OWN compose project (skillforge-visual) on its OWN high port band,
# distinct from dev (skillforge / 5432·6379·8000·3000), e2e (skillforge-e2e / 13000·18000·15432·
# 16379), lighthouse (skillforge-lh / 14000·19000·16432·17379) and integration (skillforge-itest /
# 25432…). The DB is volume-less (tmpfs via docker-compose.e2e.yml); every volume removal is
# name-scoped to skillforge-visual*, so the dev stack's skillforge_postgres_data is never touched.
#
#   scripts/run-visual.sh                       # boot+seed, run visual project in container, tear down
#   VISUAL_UPDATE=1 scripts/run-visual.sh       # (re)generate the committed Linux baselines
#   VISUAL_KEEP=1 scripts/run-visual.sh         # leave the stack UP for debugging / re-runs
#   VISUAL_NO_BUILD=1 scripts/run-visual.sh     # reuse images (skip the frontend rebuild)
#
# Exit: Playwright's exit code (0 = no visual diffs) | 77 = docker/compose absent (skip).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

PW_IMAGE="${VISUAL_PW_IMAGE:-mcr.microsoft.com/playwright:v1.49.1-jammy}"

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || { echo "visual: docker daemon unreachable — skipping"; exit 77; }
[[ -f docker-compose.yml && -f docker-compose.e2e.yml ]] \
  || { echo "visual: missing compose files — skipping"; exit 77; }
[[ -f frontend/playwright.config.ts ]] || { echo "visual: no playwright config — skipping"; exit 77; }

# shellcheck source=scripts/lib/ephemeral-pg.sh
source "$ROOT/scripts/lib/ephemeral-pg.sh"

PROJECT="${VISUAL_PROJECT:-skillforge-visual}"
LOCK_FILE="${VISUAL_LOCK_FILE:-${TMPDIR:-/tmp}/skillforge-visual-${PROJECT}.lock}"
epg_acquire_lock "$LOCK_FILE" "${VISUAL_LOCK_TIMEOUT:-2700}" || exit 1

# High port band distinct from dev (3000/8000/5432/6379), e2e (13000/18000/15432/16379),
# lighthouse (14000/19000/16432/17379) and integration (25432…). Bump-on-conflict so a
# concurrent stack can never collide. Ports must be resolved BEFORE the build/up — the overlay
# bakes VITE_API_URL from SF_API_PORT at build time.
epg_pick_port SF_FRONTEND_PORT "${SF_FRONTEND_PORT:-14500}"
epg_pick_port SF_API_PORT      "${SF_API_PORT:-19500}"
epg_pick_port SF_PG_PORT       "${SF_PG_PORT:-16532}"
epg_pick_port SF_REDIS_PORT    "${SF_REDIS_PORT:-17479}"
export SF_FRONTEND_PORT SF_API_PORT SF_PG_PORT SF_REDIS_PORT

DC=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.e2e.yml)
FE_URL="http://localhost:${SF_FRONTEND_PORT}"
API_URL_LOCAL="http://localhost:${SF_API_PORT}"
EPG_KEEP="${VISUAL_KEEP:-0}"
EPG_NO_BUILD="${VISUAL_NO_BUILD:-0}"
trap epg_teardown EXIT INT TERM HUP

echo "visual: host ports → frontend=${SF_FRONTEND_PORT} api=${SF_API_PORT} pg=${SF_PG_PORT} redis=${SF_REDIS_PORT} [project ${PROJECT}]"

# Clean baseline, then bring postgres+redis up healthy (shared one-shot self-heal).
epg_reset_baseline "skillforge-visual"
epg_boot_db postgres redis || { echo "visual: postgres/redis did not come up"; exit 1; }

# Bring up api+frontend (api migrates on boot). On failure DUMP container logs — a container that
# exits during `alembic upgrade head` carries the real cause in ITS logs, not the compose-level
# "dependency failed to start" line.
build_flag="--build"; [[ "${EPG_NO_BUILD:-0}" == 1 ]] && build_flag=""
# shellcheck disable=SC2086
"${DC[@]}" up -d $build_flag api frontend || {
  echo "visual: api/frontend failed to start"
  "${DC[@]}" logs --tail 80 api frontend 2>&1 || true
  exit 1
}

epg_poll "$API_URL_LOCAL/health" api || { "${DC[@]}" logs --tail 40 api; exit 1; }
epg_poll "$FE_URL" frontend          || { "${DC[@]}" logs --tail 40 frontend; exit 1; }

# Seed idempotently (test-admin/test-learner + demo content) — the visual specs log in as these
# seeded accounts via the auth fixtures, exactly like run-e2e.sh.
echo "visual: seeding (idempotent: test-admin/test-learner + demo content)…"
"${DC[@]}" exec -T api python scripts/seed_courses.py || { echo "visual: seed failed"; "${DC[@]}" logs --tail 40 api; exit 1; }
"${DC[@]}" exec -T api python scripts/verify_seed.py  || { echo "visual: seed verify failed"; "${DC[@]}" logs --tail 40 api; exit 1; }

# ── Run the visual project INSIDE the pinned container ───────────────────────────────────────
# --network host so the container reaches the frontend/api on localhost:$SF_*_PORT. The frontend
# repo is mounted at /work; node_modules are installed inside the container the first run (a host
# node_modules can carry host-arch binaries that won't run in the image). FRONTEND_URL/API_URL are
# passed the same way run-e2e.sh passes them. CI=1 pins workers/retries from playwright.config.
UPDATE_FLAG=""; [[ "${VISUAL_UPDATE:-0}" == 1 ]] && UPDATE_FLAG="--update-snapshots"
echo "visual: running Playwright [visual project] in ${PW_IMAGE} against ${FE_URL} ${UPDATE_FLAG:+(updating baselines)}…"

# Inside-container command: ensure deps, then run only the visual project. We `npm ci` if the
# mounted node_modules is missing OR was built for a different platform (the .package-lock.json
# sentinel check is cheap; a failed require at test time is not). Use --no-install for the test
# run so it never tries to reach the network mid-suite.
# Run as the HOST user (not the image's default root): the container mounts the host's
# frontend/ and Playwright writes test-results/ there. As root it leaves root-owned files the
# host user can't unlink, which then breaks every subsequent host-run Playwright (the e2e gate
# fails with EACCES on test-results/.last-run.json). HOME=/tmp gives the non-root user a
# writable home for npm/npx/playwright caches.
# The repo is an npm-WORKSPACES monorepo with ONE root package-lock.json —
# frontend/package-lock.json no longer exists (removed in 90198ba2) and frontend's deps
# hoist to the root node_modules. Mount the REPO ROOT and `npm ci` there; playwright/esbuild
# binaries resolve from /work/node_modules/.bin via npx's upward search from /work/frontend.
docker run --rm --network host \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD":/work -w /work/frontend \
  -e CI=1 \
  -e FRONTEND_URL="$FE_URL" \
  -e API_URL="$API_URL_LOCAL" \
  "$PW_IMAGE" \
  bash -lc '
    set -euo pipefail
    # Reinstall if: (a) the playwright binary is absent from the hoisted root (or local)
    # node_modules, OR (b) esbuild (a native binary that vite/Playwright use to transpile TS
    # config+specs) cannot execute — this catches a host-arch node_modules (e.g. macOS
    # arm64/x64) mounted into the Linux amd64 container. Checking esbuild is more reliable
    # than checking the playwright JS shim, which is architecture-agnostic but delegates to
    # a platform binary at runtime.
    ok=1
    pw=""; esbuild_bin=""
    for d in /work/node_modules /work/frontend/node_modules; do
      [ -z "$pw" ] && [ -x "$d/.bin/playwright" ] && pw="$d/.bin/playwright"
      [ -z "$esbuild_bin" ] && [ -x "$d/.bin/esbuild" ] && esbuild_bin="$d/.bin/esbuild"
    done
    [ -n "$pw" ] || ok=0
    { [ -n "$esbuild_bin" ] && "$esbuild_bin" --version >/dev/null 2>&1; } || ok=0
    if [ "$ok" != 1 ]; then
      echo "visual: installing workspace deps inside the container (npm ci at the repo root)…"
      (cd /work && npm ci --no-audit --no-fund)
    fi
    npx --no-install playwright test --project=visual --reporter=line '"$UPDATE_FLAG"'
  '
rc=$?
echo "visual: playwright exit=${rc}"
exit "$rc"
