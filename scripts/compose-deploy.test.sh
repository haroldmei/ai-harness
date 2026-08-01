#!/usr/bin/env bash
# compose-deploy.test.sh — validate the layered compose topology that deploy-on-merge depends on.
#
# These are STATIC assertions against `docker compose config` (the renderer normalises + merges
# the files but builds/boots NOTHING), so they're cheap and hermetic — no daemon, no images, no
# network. They lock in the contract issue #24 established:
#
#   • dev    (bare `docker compose up`, auto-loads docker-compose.override.yml)
#            → api bind-mounts ./backend:/app AND runs uvicorn --reload   (hot-reload preserved)
#   • deploy (-f docker-compose.yml -f docker-compose.deploy.yml, what local-deploy.sh runs)
#            → NO host source mount, NO --reload, restart: unless-stopped + container_name on
#              every service, healthchecks on api(/health)+frontend, redis appendonly
#   • e2e    (-f docker-compose.yml -f docker-compose.e2e.yml)
#            → still builds the image (no ./backend:/app mount), config is valid
#
#   Run: bash scripts/compose-deploy.test.sh     (exit 0 = all pass, 77 = skipped)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v docker >/dev/null 2>&1 || { echo "compose-deploy: docker CLI absent — skipping"; exit 77; }
docker compose version >/dev/null 2>&1 || { echo "compose-deploy: docker compose plugin absent — skipping"; exit 77; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
# count <file> <regex>  → number of matching lines. `--` so a regex starting with `-` (e.g.
# --reload) isn't parsed by grep as an option.
count() { grep -cE -- "$2" "$1" 2>/dev/null || true; }
has()   { grep -qE -- "$2" "$1" 2>/dev/null; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DEV="$TMP/dev.yml"; DEPLOY="$TMP/deploy.yml"; E2E="$TMP/e2e.yml"

# Render each topology. config merges + normalises only — it does not build or pull anything.
docker compose config                                                   >"$DEV"    2>/dev/null || { echo "compose-deploy: dev config failed to render"; exit 1; }
docker compose -f docker-compose.yml -f docker-compose.deploy.yml config >"$DEPLOY" 2>/dev/null || { echo "compose-deploy: deploy config failed to render"; exit 1; }
docker compose -f docker-compose.yml -f docker-compose.e2e.yml config    >"$E2E"    2>/dev/null || { echo "compose-deploy: e2e config failed to render"; exit 1; }

# ── DEV (base + auto override) — the hot-reload loop must survive ────────────────────────────
echo "Dev topology (bare docker compose up → auto-loads docker-compose.override.yml)"
if has "$DEV" 'target: /app$' && has "$DEV" 'source: .*/backend$'; then ok "api bind-mounts ./backend:/app (hot reload)"; else bad "dev lost the ./backend:/app bind mount"; fi
has "$DEV" '--reload' && ok "api runs uvicorn --reload" || bad "dev api missing --reload"
# Issue #26: a bare `docker compose up` must end FULLY SEEDED, not migrated-but-empty. The dev
# override adds a one-shot `seed` service that seeds + verifies after the api is healthy.
DEV_SVCS="$(docker compose config --services 2>/dev/null)"
echo "$DEV_SVCS" | grep -qx 'seed'                     && ok "dev has the auto-seed service" || bad "dev missing the seed service (would come up empty)"
has "$DEV" 'scripts/seed_courses.py'                   && ok "seed service runs seed_courses.py" || bad "seed service does not run seed_courses.py"
has "$DEV" 'scripts/verify_seed.py'                    && ok "seed service verifies completeness" || bad "seed service does not run verify_seed.py"

# ── DEPLOY (base + deploy overlay) — the self-contained artifact ─────────────────────────────
echo "Deploy topology (-f docker-compose.yml -f docker-compose.deploy.yml)"
if has "$DEPLOY" 'target: /app$'; then bad "deploy still has a host source mount at /app"; else ok "NO host source mount (runs the built image)"; fi
if has "$DEPLOY" '--reload'; then bad "deploy api still runs --reload"; else ok "api runs WITHOUT --reload"; fi
has "$DEPLOY" '--workers 2'                          && ok "api serves with a fixed worker count" || bad "deploy api missing --workers"
[ "$(count "$DEPLOY" 'restart: unless-stopped')" -ge 4 ] && ok "restart: unless-stopped on every service (>=4)" || bad "deploy missing restart on some service ($(count "$DEPLOY" 'restart: unless-stopped')/4)"
[ "$(count "$DEPLOY" 'container_name: skillforge_')" -ge 4 ] && ok "container_name: skillforge_* on every service (>=4)" || bad "deploy missing container_name on some service"
has "$DEPLOY" 'localhost:8080/health'                  && ok "api healthcheck hits /health (gates --wait)" || bad "deploy api missing /health healthcheck"
# Must hit 127.0.0.1, not localhost: busybox wget resolves localhost to ::1 first but nginx is
# IPv4-only, so `localhost` wrongly marks the container unhealthy and breaks `up --wait`.
has "$DEPLOY" 'wget .*127\.0\.0\.1:8080'               && ok "frontend healthcheck present on 127.0.0.1 (gates --wait)" || bad "deploy frontend healthcheck missing / not on 127.0.0.1"
has "$DEPLOY" '--appendonly'                        && ok "redis persists with appendonly" || bad "deploy redis missing appendonly"
has "$DEPLOY" 'redis_data'                             && ok "redis has a named persistence volume" || bad "deploy redis missing named volume"
# The seed service is a DEV-override one-shot; deploy seeds via scripts/local-deploy.sh, so the
# explicit `-f` set must NOT pick up the seed service (it would double-run under `up --wait`).
if docker compose -f docker-compose.yml -f docker-compose.deploy.yml config --services 2>/dev/null | grep -qx 'seed'; then bad "deploy unexpectedly includes the dev seed service"; else ok "deploy excludes the dev seed service (seeds via local-deploy.sh)"; fi

# ── E2E (base + e2e overlay) — still builds the image, no host mount ─────────────────────────
echo "E2E topology (-f docker-compose.yml -f docker-compose.e2e.yml)"
if has "$E2E" 'target: /app$'; then bad "e2e unexpectedly mounts host source at /app"; else ok "e2e runs the built image (no ./backend:/app mount)"; fi
has "$E2E" 'target: /app/.env$' && ok "e2e keeps the empty .env shadow" || bad "e2e lost the /app/.env shadow"
if docker compose -f docker-compose.yml -f docker-compose.e2e.yml config --services 2>/dev/null | grep -qx 'seed'; then bad "e2e unexpectedly includes the dev seed service"; else ok "e2e excludes the dev seed service (seeds via run-e2e.sh)"; fi
# Issue #140: the e2e postgres healthcheck must gate on a real TCP + password-authenticated
# query (psql), NOT the base `pg_isready` socket probe. The official image's first-init temp
# server is socket-only, so pg_isready reports healthy (and `up --wait` returns) before TCP/auth
# is ready; the api then races into "connection refused" / "password authentication failed".
if has "$E2E" "psql -h 127\.0\.0\.1 -U postgres" && has "$E2E" 'PGPASSWORD'; then
  ok "e2e postgres healthcheck gates on a TCP + authenticated query (no socket-only false-ready)"
else
  bad "e2e postgres healthcheck is not a TCP+auth psql probe — first-init race can mark it healthy early"
fi
# Blast radius: the TCP+auth override is e2e-only. Dev/deploy must keep the cheap pg_isready probe.
if has "$DEV" 'pg_isready -U postgres' && ! has "$DEV" "psql -h 127\.0\.0\.1 -U postgres"; then
  ok "dev/base postgres healthcheck unchanged (still pg_isready — override is e2e-scoped)"
else
  bad "the e2e healthcheck override leaked into the base/dev topology"
fi
# Issue #140: the e2e postgres data dir must be EPHEMERAL (tmpfs), not a persistent named volume.
# POSTGRES_PASSWORD is only applied when PGDATA is empty; a tmpfs is recreated empty on every
# container start, so a prior run killed mid-initdb (which leaves a half-init data dir with no
# password) can never survive into the next run as "password authentication failed".
e2e_pg="$(docker compose -f docker-compose.yml -f docker-compose.e2e.yml config 2>/dev/null | sed -n '/^  postgres:/,/^  redis:/p')"
if grep -qE 'type: tmpfs' <<<"$e2e_pg" && grep -qE 'target: /var/lib/postgresql/data' <<<"$e2e_pg"; then
  ok "e2e postgres data dir is tmpfs (initdb + password always re-run — no poisoned-volume carryover)"
else
  bad "e2e postgres still uses a persistent data dir — a half-init volume can poison later runs (issue #140)"
fi
if grep -qE 'source: postgres_data' <<<"$e2e_pg"; then
  bad "e2e postgres still mounts the persistent postgres_data volume (tmpfs override didn't replace it)"
else
  ok "e2e postgres no longer mounts the persistent named volume (tmpfs replaced it by target path)"
fi
# Blast radius: dev/deploy keep the PERSISTENT named volume (data must survive restarts there).
if has "$DEPLOY" 'source: postgres_data'; then
  ok "deploy/base postgres keeps its persistent named volume (ephemeral override is e2e-scoped)"
else
  bad "the e2e tmpfs override leaked into the deploy/base topology — deploy data would not persist"
fi

	# ── SECURITY: port binding to 127.0.0.1 (issue #1603) ────────────────────────────
	echo "Security: port bindings (issue #1603 — CVE-2025-29927 class)"
	# All published ports must be bound to 127.0.0.1 (localhost-only) — never 0.0.0.0 on the host.
	# Inside the container uvicorn/nginx still bind 0.0.0.0 (correct for Docker port mapping); the
	# host_ip: 127.0.0.1 constrains Docker's port publishing to the loopback interface.
	if has "$DEPLOY" 'host_ip: 127.0.0.1'; then
	  ok "deploy publishes all ports to host 127.0.0.1 only (not network-reachable)"
	else
	  bad "deploy publishes ports on 0.0.0.0 (host_ip:127.0.0.1 missing)"
	fi
	if has "$E2E" 'host_ip: 127.0.0.1'; then
	  ok "e2e publishes all ports to host 127.0.0.1 only"
	else
	  bad "e2e publishes ports on 0.0.0.0 (host_ip:127.0.0.1 missing)"
	fi
	# Dev override inherits the base's 127.0.0.1 port bindings + adds --reload.
	# The bare `docker compose config` at line 36 renders ALL three files merged (base + override).
	# It should still show 127.0.0.1 on published ports from the base.
	if has "$DEV" 'host_ip: 127.0.0.1'; then
	  ok "dev also binds published ports to 127.0.0.1 (inherited from base)"
	else
	  bad "dev does NOT bind ports to 127.0.0.1"
	fi

	# ── SECURITY: read-only filesystem on deploy api container (issue #1603) ────────
	if has "$DEPLOY" "read_only: true"; then
	  ok "deploy api container has read-only root filesystem"
	else
	  bad "deploy api container missing read_only: true"
	fi
	# Must have a writable /tmp for runtime temp files when root is read-only.
	if has "$DEPLOY" "tmpfs" || has "$DEPLOY" "/tmp"; then
	  ok "deploy api container has writable /tmp"
	else
	  bad "deploy api container missing writable /tmp (read-only would break temp files)"
	fi

	# ── SECURITY: dev override carries the security warning banner (issue #1603) ────
	if grep -q 'SECURITY WARNING' docker-compose.override.yml; then
	  ok "docker-compose.override.yml carries prominent security warning"
	else
	  bad "docker-compose.override.yml missing SECURITY WARNING banner"
	fi
	if grep -q 'CVE-2025-29927' docker-compose.override.yml; then
	  ok "override security warning references CVE-2025-29927 class"
	else
	  bad "override security warning missing CVE reference"
	fi
	if grep -q 'NEVER run' docker-compose.override.yml && grep -q 'network-reachable host' docker-compose.override.yml; then
	  ok "override warns against network-reachable deployment"
	else
	  bad "override missing 'never on network-reachable host' warning"
	fi

echo
echo "compose-deploy config: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
