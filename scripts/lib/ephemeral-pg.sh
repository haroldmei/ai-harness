#!/usr/bin/env bash
# ephemeral-pg.sh — shared bring-up/teardown for an ISOLATED, ephemeral Postgres (and
# optionally the full stack) used by the integration / seed-integrity / lighthouse / a11y /
# visual quality gates. Extracted from scripts/run-e2e.sh so those gates reuse the same
# battle-tested isolation instead of copy-drifting it (issues #98/#140/#171).
#
# CONTRACT — source this, then set (before calling epg_* functions):
#   PROJECT   — a UNIQUE docker compose project name per purpose (skillforge-itest, …). MUST
#               carry a '-' infix distinct from the dev project 'skillforge' so the name-scoped
#               volume reaper can never reach the dev stack's skillforge_postgres_data.
#   DC        — the compose command array, e.g.
#               DC=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.e2e.yml)
#   SF_*_PORT — host ports (set via epg_pick_port). The dev stack defaults are 5432/6379/8000/3000;
#               each gate starts its own HIGH band (itest 25432, seedcheck 35432, …) and bumps on
#               conflict, so it never clashes with dev, e2e, or a concurrent gate.
#
# Every container/volume action here is scoped to $PROJECT (or a passed prefix) — never an
# unscoped docker prune that could reach the dev stack or another repo's volumes.
#
# NOTE ON `set -`: this file is a LIBRARY and deliberately sets NO shell options. A sourced lib
# runs in the CALLER's shell, so a `set -e` here would silently abort every "collector" script
# (the gate and agent stages) at its first *tolerated* failure — the ones that must survive a
# failing step in order to report, classify or clean up. Signal failure with return codes only.
# This is a deliberate design choice, not an oversight: do not "fix" it by adding `set -e`.
# See "Shell-option classes" in docs/AGENT-HARNESS.md (#2390).

# ── port selection (bump-on-conflict) ─────────────────────────────────────────────────────
EPG_CHOSEN_PORTS=""
epg_port_in_use() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$"; }
epg_pick_port() { # <varname> <start>
  local p="$2"
  while epg_port_in_use "$p" || [[ " $EPG_CHOSEN_PORTS " == *" $p "* ]]; do p=$((p + 1)); done
  EPG_CHOSEN_PORTS="$EPG_CHOSEN_PORTS $p"
  printf -v "$1" '%s' "$p"
}

# ── per-project serialization (so concurrent agent loops queue, not stomp the shared DB) ───
# Holds an flock on fd 9 for the life of the process (fd stays open until exit). No re-exec:
# the caller sources us early, so fd 9 is owned start-to-teardown. Distinct PROJECT → distinct
# lockfile → genuinely parallel across purposes.
epg_acquire_lock() { # <lockfile> [timeout_seconds]
  local lock="$1" timeout="${2:-2700}"
  command -v flock >/dev/null 2>&1 || { return 0; }   # no flock → best-effort, no serialization
  exec 9>"$lock"
  echo "ephemeral-pg: acquiring lock ($lock) so concurrent runs don't share the DB volume…"
  flock -w "$timeout" 9 || { echo "ephemeral-pg: timed out waiting for $lock"; return 1; }
}

# ── volume hygiene (name-scoped — never touches the dev stack) ──────────────────────────────
epg_scrub_project_volumes() {
  docker volume rm -f "${PROJECT}_postgres_data" "${PROJECT}_redis_data" >/dev/null 2>&1 || true
}
epg_reap_orphan_volumes() { # <name-prefix> — e.g. skillforge-itest
  local prefix="$1" v
  [[ -z "$prefix" ]] && return 0
  for v in $(docker volume ls -q 2>/dev/null | grep -E "^${prefix}[^[:space:]]*_(postgres|redis)_data$" || true); do
    docker volume rm -f "$v" >/dev/null 2>&1 || true
  done
}

# ── postgres bring-up with credential re-check + one in-run self-heal (issue #171) ──────────
epg_pg_auth_ok() {
  "${DC[@]}" exec -T postgres sh -c \
    'PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -d skillforge -c "SELECT 1" >/dev/null 2>&1'
}
epg_boot_db() { # services to bring up healthy, e.g. "postgres" or "postgres redis"
  local services="${*:-postgres}"
  local build_flag="--build"; [[ "${EPG_NO_BUILD:-0}" == 1 ]] && build_flag=""
  # shellcheck disable=SC2086
  _epg_up() { "${DC[@]}" up -d $build_flag --wait $services; }
  if ! { _epg_up && epg_pg_auth_ok; }; then
    echo "ephemeral-pg: postgres unhealthy or rejecting credentials — scrubbing + re-init once…"
    "${DC[@]}" logs --tail 20 postgres 2>&1 | sed 's/^/ephemeral-pg:   pg| /' || true
    "${DC[@]}" down -v >/dev/null 2>&1 || true
    epg_scrub_project_volumes
    if ! { _epg_up && epg_pg_auth_ok; }; then
      echo "ephemeral-pg: db still not healthy after recovery — failing"
      "${DC[@]}" logs --tail 40 postgres || true
      return 1
    fi
    echo "ephemeral-pg: DB recovered after scrub + re-init"
  fi
}

# ── clean baseline + teardown ───────────────────────────────────────────────────────────────
epg_reset_baseline() { # <reap-prefix>
  echo "ephemeral-pg: resetting ephemeral DB volume (clean baseline) [project ${PROJECT}]…"
  "${DC[@]}" down -v >/dev/null 2>&1 || true
  epg_scrub_project_volumes
  epg_reap_orphan_volumes "${1:-$PROJECT}"
}
EPG_CLEANED=0
epg_teardown() {
  [[ "$EPG_CLEANED" == 1 ]] && return; EPG_CLEANED=1
  if [[ "${EPG_KEEP:-0}" == 1 ]]; then
    echo "ephemeral-pg: leaving stack UP (EPG_KEEP=1) — tear down: ${DC[*]} down -v"
  else
    echo "ephemeral-pg: tearing down [project ${PROJECT}] (removing ephemeral volumes)…"
    "${DC[@]}" down -v >/dev/null 2>&1 || true
  fi
}

# ── HTTP readiness poll ─────────────────────────────────────────────────────────────────────
epg_poll() { # <url> <name> [tries]
  local tries="${3:-60}"
  for _ in $(seq 1 "$tries"); do
    curl -fsS "$1" >/dev/null 2>&1 && { echo "ephemeral-pg: $2 ready"; return 0; }
    sleep 2
  done
  echo "ephemeral-pg: $2 did not become ready ($1)"; return 1
}
