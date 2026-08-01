#!/usr/bin/env bash
# local-deploy.sh — the unattended "main advanced → rebuild my local stack" runner.
#
# The deploy half of the agent loop: a PR is merged into `main` (by the agent-pr-merger, or
# by you from the GitHub mobile app), `main` advances on GitHub, and within a couple of minutes
# this rebuilds and redeploys your LOCAL docker-compose stack. No webhook / tunnel needed — this
# box is WSL behind NAT (no inbound endpoint), so we POLL `origin/main` on a systemd user timer,
# exactly like the agent-inbox poller. Cheap on every tick; real work only when main moved:
#
#   1. fetch origin/main; compare its SHA to the recorded "last-deployed" SHA.
#   2. unchanged → exit 0 (cheap, like the inbox timer doing nothing when no issue is open).
#   3. advanced  → deploy: fast-forward a PINNED checkout to the new SHA, then bring up the
#      PRODUCTION-STYLE stack (`-f docker-compose.yml -f docker-compose.deploy.yml`) with
#      `up -d --build --force-recreate --wait` — whose api/frontend healthchecks make --wait
#      alone gate readiness — run the idempotent seed (the build+seed half of
#      scripts/run-e2e.sh), optional smoke e2e, record the new SHA, and notify.
#
# This is SkillForge's local CD (Buildkite retired): GCP staging deploys stay manual via
# `make deploy-staging`; THIS keeps your local stack continuously up to date with main.
#
# ISOLATION (mirrors the inbox/merger hardening):
#   • Deploy from a PINNED CHECKOUT ($DEPLOY_DIR), never your live working copy — so a deploy
#     never fights your WIP / branch. The checkout is its own clone of origin.
#   • Fixed COMPOSE_PROJECT_NAME=skillforge — always the SAME stack regardless of which
#     directory built it (so a deploy and a hand-run `docker compose up` in the repo, whose
#     default project is also `skillforge`, share ONE stack instead of forking two).
#   • SHARE the agent-inbox flock ($DEPLOY_LOCK, default = inbox's per-repo lock
#     /tmp/agent-inbox-<repo-key>.lock) so a deploy and an inbox build never run two
#     `docker compose up --build`s at once.
#   • Trigger = a PR MERGE, not any push (DEPLOY_TRIGGER, default `pr-merge`): a PR merge on
#     main triggers a deploy of main's TIP, so a bare `git push` to main is ignored. (We deploy
#     the tip, NOT the merged PR's own commit — see issue #48: in a batched/out-of-order merge
#     the latest-merged PR's commit can sit behind the tip and wedge the poller on stale code.)
#     Set DEPLOY_TRIGGER=any-push to deploy on every advance of main instead.
#   • Only-on-change (recorded SHA) — otherwise every tick rebuilds. DEPLOY_FORCE=1 redeploys
#     regardless (a manual "redeploy now").
#
# Single-pass by design (the timer re-invokes it). Every external command + path is overridable
# via env so the journey is testable hermetically (scripts/local-deploy.test.sh) with NO real
# GitHub side-effects and NO real docker.
#
#   Setup: scripts/local-deploy-setup.sh  ·  Docs: docs/AGENT-HARNESS.md
set -uo pipefail

# ── Injectable dependencies (defaults = production; tests override) ──────────────
ROOT="${DEPLOY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GIT="${DEPLOY_GIT:-git}"                    # git (real even in tests — uses a local bare origin)
DOCKER="${DEPLOY_DOCKER:-docker}"           # docker CLI (stubbed in tests)
GH="${DEPLOY_GH:-gh}"                       # GitHub CLI for the default notify + pr-merge trigger
REMOTE="${DEPLOY_REMOTE:-origin}"           # git remote to poll
BASE="${DEPLOY_BASE:-main}"                 # branch whose advance triggers a deploy
# SHARED with agent-inbox on purpose (one deploy XOR one build). agent-inbox now namespaces its
# lock PER REPO (a key derived from the git common dir, to stop colliding with another repo's
# inbox), so we derive the SAME key from the SAME repo root to keep sharing its lock. Resolve to
# an ABSOLUTE path because `--git-common-dir` returns a bare ".git" at a repo root.
deploy_repo_ns() {
  local d
  d="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  d="$(cd "$ROOT" 2>/dev/null && cd "$d" 2>/dev/null && pwd)" || return 1
  printf '%s' "$d" | sha1sum | cut -c1-12
}
NS="$(deploy_repo_ns || true)"; [ -n "$NS" ] || NS="nogit"
LOCK="${DEPLOY_LOCK:-/tmp/agent-inbox-$NS.lock}"   # SHARED with agent-inbox's per-repo lock
STATE_DIR="${DEPLOY_STATE_DIR:-$HOME/.cache/skillforge-deploy}"
DEPLOY_DIR="${DEPLOY_DIR:-$STATE_DIR/checkout}"        # the pinned checkout (NOT your live copy)
SHA_FILE="${DEPLOY_SHA_FILE:-$STATE_DIR/last-deployed-sha}"
LOGDIR="${DEPLOY_LOGDIR:-$STATE_DIR/logs}"
PROJECT="${COMPOSE_PROJECT_NAME:-skillforge}"          # fixed stack name
# Deploy the PRODUCTION-STYLE stack: base compose + the deploy overlay (container_name + restart
# + no host source mount). The explicit `-f` set also disables the auto-loaded
# docker-compose.override.yml, so the deploy never picks up the dev bind mount / --reload.
read -r -a COMPOSE_FILES <<< "${DEPLOY_COMPOSE_FILES:--f docker-compose.yml -f docker-compose.deploy.yml}"

mkdir -p "$STATE_DIR" "$LOGDIR"
export COMPOSE_PROJECT_NAME="$PROJECT"
# Deploy-stack host ports. The base compose reads SF_*_PORT (default 3000/8000/5432/6379); the
# default frontend port 3000 collides with a sibling stack (ml-builder's app-shell holds :3000),
# so pin the always-on deploy stack to its own non-colliding range. Override via env.
export SF_FRONTEND_PORT="${SF_FRONTEND_PORT:-3002}"
export SF_API_PORT="${SF_API_PORT:-8000}"
export SF_PG_PORT="${SF_PG_PORT:-5532}"
export SF_REDIS_PORT="${SF_REDIS_PORT:-6380}"
log() { printf '[local-deploy] %s\n' "$*"; }

# ── Notify — a deploy result you can see on your phone. Default: a GitHub commit comment on
# the deployed SHA (lands as a GitHub-app push). Override with DEPLOY_NOTIFY_CMD, which is run
# with $DEPLOY_STATUS / $DEPLOY_SHA / $DEPLOY_MSG in the env (e.g. an ntfy curl). ─
notify() {  # $1=status(deploying|deployed|failed)  $2=sha  $3=message
  local status="$1" sha="$2" msg="$3"
  log "NOTIFY [$status] ${sha:0:12} — $msg"
  if [ -n "${DEPLOY_NOTIFY_CMD:-}" ]; then
    DEPLOY_STATUS="$status" DEPLOY_SHA="$sha" DEPLOY_MSG="$msg" \
      bash -c "$DEPLOY_NOTIFY_CMD" >>"$LOGDIR/notify.log" 2>&1 || log "notify cmd failed (non-fatal)"
    return
  fi
  [ "$status" = "deploying" ] && return 0   # don't spam a comment for the "starting" tick
  command -v "$GH" >/dev/null 2>&1 || return 0
  ( cd "$DEPLOY_DIR" 2>/dev/null && "$GH" api -X POST \
      "repos/{owner}/{repo}/commits/${sha}/comments" -f body="🚀 local-deploy: $msg" \
      >/dev/null 2>&1 ) || log "gh commit comment failed (non-fatal)"
}

# ── Toolchain bootstrap — systemd/cron start from a BARE environment (no ~/.bashrc). The
# build + seed run INSIDE docker, so host node/python aren't needed; but source nvm/conda
# anyway so an optional smoke e2e (host Playwright) and gh resolve. ─
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
[ -s "$HOME/miniconda3/etc/profile.d/conda.sh" ] && . "$HOME/miniconda3/etc/profile.d/conda.sh" >/dev/null 2>&1 || true

# ── Preflight — fail LOUD + early on a missing/unhealthy dependency (the deploy needs the
# docker DAEMON, not just the CLI on PATH). DEPLOY_PREFLIGHT_TOOLS is overridable for tests. ─
PREFLIGHT_TOOLS="${DEPLOY_PREFLIGHT_TOOLS:-git docker curl}"
missing=""
for t in $PREFLIGHT_TOOLS; do command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"; done
if [ -n "$missing" ]; then
  log "PREFLIGHT FAILED — not on PATH:${missing}"
  log "  systemd/cron use a bare env; ensure git/docker/curl resolve (see docs/AGENT-HARNESS.md)."
  exit 1
fi
case " $PREFLIGHT_TOOLS " in *" docker "*)
  if ! "$DOCKER" info >/dev/null 2>&1; then
    log "PREFLIGHT FAILED — docker CLI present but the daemon is unreachable"
    log "  start Docker Desktop / check the socket (the deploy boots the stack)."
    exit 1
  fi ;;
esac

# ── Single-instance lock — SHARED with agent-inbox so a deploy and an inbox build never run
# two `docker compose up --build`s at once. Non-blocking: if either holds it, defer to the
# next tick (exit 0 — a non-zero would mark the systemd unit failed). ──────────────────────
exec 9>"$LOCK"
if ! flock -n 9; then log "agent-inbox or another deploy in progress — deferring to next tick"; exit 0; fi

# ── Ensure the pinned checkout exists (its OWN clone of origin — never your live copy) ────
if [ ! -d "$DEPLOY_DIR/.git" ]; then
  origin_url="${DEPLOY_ORIGIN_URL:-$("$GIT" -C "$ROOT" remote get-url "$REMOTE" 2>/dev/null || true)}"
  if [ -z "$origin_url" ]; then log "cannot resolve $REMOTE url from $ROOT — aborting"; exit 1; fi
  log "first run — cloning pinned checkout: $origin_url → $DEPLOY_DIR"
  rm -rf "$DEPLOY_DIR"
  if ! "$GIT" clone -q "$origin_url" "$DEPLOY_DIR" >>"$LOGDIR/deploy.log" 2>&1; then
    log "clone failed (see $LOGDIR/deploy.log)"; exit 1
  fi
fi

# ── What should be deployed this tick? ALWAYS the TIP of $REMOTE/$BASE — never a specific PR's
# merge commit. When the agent-pr-merger lands several PRs in one batch, the most-recently-MERGED
# PR (by GitHub's merge-recency order) can be a merge commit that sits BEHIND main's actual tip;
# deploying that stale commit anchors the poller to it and wedges it on old code forever (issue
# #48). So we fetch, take the tip as the target, and let the TRIGGER only GATE whether to deploy —
# not WHAT to deploy:
#   • pr-merge — deploy the tip only when a real PR merge sits in the just-arrived range
#     (last..tip). A bare `git push` to $BASE lands a commit but opens no PR → IGNORED.
#   • any-push — deploy whenever $REMOTE/$BASE advances, however it got there. ─────────────
"$GIT" -C "$DEPLOY_DIR" fetch -q "$REMOTE" "$BASE" >>"$LOGDIR/deploy.log" 2>&1 || { log "fetch failed — skipping this tick"; exit 0; }
TRIGGER="${DEPLOY_TRIGGER:-pr-merge}"
FORCE="${DEPLOY_FORCE:-0}"

# Target = the tip (the only commit a deploy should ever land on), for BOTH triggers.
new="$("$GIT" -C "$DEPLOY_DIR" rev-parse "${REMOTE}/${BASE}" 2>/dev/null || true)"
[ -z "$new" ] && { log "could not resolve ${REMOTE}/${BASE} — skipping"; exit 0; }
last="$(cat "$SHA_FILE" 2>/dev/null || true)"

# Unchanged tip → cheap no-op (checked BEFORE any gh query so an idle tick costs no API call).
if [ "$FORCE" != "1" ] && [ "$new" = "$last" ]; then
  log "${REMOTE}/${BASE} unchanged (${new:0:12}) — nothing to deploy"; exit 0
fi

# ── pr-merge GATE — deploy the tip only when a PR actually merged into the new range. The
# merged-PR query is the GATE, NEVER the target: we check the latest merged PR's commit is
# reachable from the tip AND is not already deployed (in $last). A bare `git push` (no PR)
# advances the tip but adds no merged-PR commit beyond $last → IGNORED. DEPLOY_FORCE bypasses. ─
if [ "$TRIGGER" = "pr-merge" ] && [ "$FORCE" != "1" ]; then
  command -v "$GH" >/dev/null 2>&1 || { log "DEPLOY_TRIGGER=pr-merge needs gh on PATH — aborting"; exit 1; }
  pr="$( ( cd "$DEPLOY_DIR" && "$GH" pr list --base "$BASE" --state merged --limit 1 \
            --json mergeCommit --jq '.[0].mergeCommit.oid' ) 2>>"$LOGDIR/deploy.log" || true )"
  if [ -z "$pr" ] || [ "$pr" = "null" ]; then log "no merged PR on ${BASE} yet — nothing to deploy"; exit 0; fi
  if ! "$GIT" -C "$DEPLOY_DIR" merge-base --is-ancestor "$pr" "$new" 2>/dev/null; then
    log "latest merged PR ${pr:0:12} not contained in ${REMOTE}/${BASE} tip ${new:0:12} — skipping"; exit 0
  fi
  if [ -n "$last" ] && "$GIT" -C "$DEPLOY_DIR" merge-base --is-ancestor "$pr" "$last" 2>/dev/null; then
    log "no new PR merge since ${last:0:12} (latest merged PR ${pr:0:12} already deployed) — nothing to deploy"; exit 0
  fi
fi

if [ "$FORCE" = "1" ]; then
  log "DEPLOY_FORCE=1 — redeploying ${new:0:12} regardless of the recorded SHA"
# ── Forward-only: never roll the stack BACK to a commit already contained in what we last
# deployed (e.g. a force-push that moved the tip backward). Deploying it would be a silent
# rollback — skip. DEPLOY_FORCE overrides. With the tip as the target, this prevents rollback
# WITHOUT wedging the poller (issue #48). ─────────────────────────────────────────────────────
elif [ -n "$last" ] && "$GIT" -C "$DEPLOY_DIR" merge-base --is-ancestor "$new" "$last" 2>/dev/null; then
  log "target ${new:0:12} already contained in deployed ${last:0:12} — not rolling back"; exit 0
fi

log "deploy: ${REMOTE}/${BASE} advanced ${last:0:12} → ${new:0:12}"
notify deploying "$new" "building ${new:0:12}…"

# ── Pin the checkout to the new SHA (hard reset — the checkout has no WIP of its own) ─────
"$GIT" -C "$DEPLOY_DIR" reset --hard -q "$new" >>"$LOGDIR/deploy.log" 2>&1 || { log "reset --hard failed"; notify failed "$new" "git reset failed"; exit 1; }

# ── Provision local, git-IGNORED files the stack needs (same gap node_modules has): root +
# per-service .env files and the .gcp cred dir. Symlinked from your live copy so they're
# present without ever being committed. Override the set with DEPLOY_LOCAL_PATHS. ──────────
shopt -s nullglob
LOCAL_GLOBS=( "$ROOT"/.env "$ROOT"/.env.local "$ROOT"/.gcp "$ROOT"/backend/.env "$ROOT"/backend/.env.local "$ROOT"/frontend/.env "$ROOT"/frontend/.env.local )
for extra in ${DEPLOY_LOCAL_PATHS:-}; do LOCAL_GLOBS+=( "$ROOT/$extra" ); done
for src in "${LOCAL_GLOBS[@]}"; do
  [ -e "$src" ] || continue
  rel="${src#"$ROOT"/}"; dst="$DEPLOY_DIR/$rel"
  [ -e "$dst" ] || { mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" 2>/dev/null; } || true
done
shopt -u nullglob

# ── Take over any containers pinned by a fixed container_name BEFORE `up` (such names are
# GLOBAL, not project-scoped, so a stack started under another project would block
# --force-recreate). The deploy overlay pins skillforge_* names, so this stops/removes any
# stale ones first. Named VOLUMES are untouched, so the DB survives. ────────────────────────
names="$(grep -hE '^[[:space:]]*container_name:[[:space:]]*' \
           "$DEPLOY_DIR/docker-compose.deploy.yml" "$DEPLOY_DIR/docker-compose.yml" 2>/dev/null \
         | awk '{print $2}' | tr -d '\r' | sort -u)"
if [ -n "$names" ]; then
  log "taking over the stack — stopping any existing containers (volumes preserved): $(echo $names | tr '\n' ' ')"
  "$DOCKER" stop $names  >>"$LOGDIR/deploy.log" 2>&1 || true
  "$DOCKER" rm -f $names >>"$LOGDIR/deploy.log" 2>&1 || true
fi

# ── Build + redeploy — the build half of run-e2e.sh, in the pinned checkout. --force-recreate
# is REQUIRED: on a cache-hit `up --build` leaves the OLD container running, silently serving
# stale code; force-recreate from the freshly built images. The api migrates on boot
# (`alembic upgrade head` in its compose command). --wait gates on the compose healthchecks:
# the deploy stack has healthchecks on api (/health) AND frontend, so a successful `up --wait`
# already means both are READY — no separate host-side /health poll needed. ─────────────────
log "docker compose ${COMPOSE_FILES[*]} up --build --force-recreate --wait (project ${PROJECT})…"
if ! ( cd "$DEPLOY_DIR" && "$DOCKER" compose "${COMPOSE_FILES[@]}" up -d --build --force-recreate --wait ) >>"$LOGDIR/deploy.log" 2>&1; then
  log "compose up FAILED (see $LOGDIR/deploy.log) — NOT recording SHA (will retry next tick)"
  notify failed "$new" "compose up failed — see logs ($(tail -1 "$LOGDIR/deploy.log" 2>/dev/null))"
  exit 1
fi

# ── Reseed (idempotent: re-running skips anything already present). Runs INSIDE the api
# container, which already has DATABASE_URL set — same call scripts/run-e2e.sh makes. The api
# healthcheck above already guarantees migrations are done (the boot command runs `alembic
# upgrade head` before uvicorn binds the port /health answers on). ──────────────────────────
log "reseeding (idempotent — test-admin/test-learner + demo content)…"
if ! ( cd "$DEPLOY_DIR" && "$DOCKER" compose "${COMPOSE_FILES[@]}" exec -T api python scripts/seed_courses.py ) >>"$LOGDIR/deploy.log" 2>&1; then
  log "seed FAILED (see $LOGDIR/deploy.log) — NOT recording SHA (will retry next tick)"
  notify failed "$new" "reseed failed — see logs"
  exit 1
fi

# ── Verify the seed is COMPLETE (issue #26). The seed above is idempotent, but a partial/empty
# DB is exactly the failure we must never silently ship: assert org + demo/test users + ~50
# skills + 10 courses (lessons & quizzes) + learning path + live session + invitation are all
# present. Fail loudly (don't record the SHA) so the next tick retries. ──────────────────────
log "verifying seed completeness (org/users/skills/courses/lessons/quizzes/path/session/invite)…"
if ! ( cd "$DEPLOY_DIR" && "$DOCKER" compose "${COMPOSE_FILES[@]}" exec -T api python scripts/verify_seed.py ) >>"$LOGDIR/deploy.log" 2>&1; then
  log "seed VERIFY FAILED (see $LOGDIR/deploy.log) — NOT recording SHA (will retry next tick)"
  notify failed "$new" "seed verify failed — see logs"
  exit 1
fi

# ── Optional smoke e2e against the freshly deployed stack (DEPLOY_SMOKE=1) — run-e2e's REMOTE
# target mode against the deployed URLs (no stack boot/rebuild). Off by default. ────────────
if [ "${DEPLOY_SMOKE:-0}" = "1" ]; then
  log "running smoke e2e against the deployed stack…"
  if ! ( cd "$DEPLOY_DIR" && FRONTEND_URL="http://localhost:${SF_FRONTEND_PORT:-3000}" \
         API_URL="http://localhost:${SF_API_PORT:-8000}" bash scripts/run-e2e.sh ) >>"$LOGDIR/deploy.log" 2>&1; then
    log "smoke e2e FAILED — NOT recording SHA (will retry next tick)"
    notify failed "$new" "smoke e2e failed on ${new:0:12}"
    exit 1
  fi
fi

# ── Success — record the SHA so the next tick is a cheap no-op, and notify ────────────────
printf '%s\n' "$new" > "$SHA_FILE"
log "DEPLOYED ${new:0:12}"
notify deployed "$new" "deployed ${new:0:12} ✓"
