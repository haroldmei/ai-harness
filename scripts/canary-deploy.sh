#!/usr/bin/env bash
# Cloud Run canary + auto-rollback engine (issue #204).
#
# WHY: `gcloud run deploy` routes 100% of traffic to the new revision the moment
# it goes Ready — so a revision that boots but fails its smoke check serves the
# broken build to every user. Cloud Run keeps the old revision around, but the
# old deploy-staging.yml only `exit 1`d on smoke failure; it never moved traffic
# back. This script makes the deploy SAFE:
#
#   1. deploy   — create the new revision with --no-traffic --tag=canary. The
#                 PRIOR revision keeps serving 100% of production traffic; the
#                 new one is reachable ONLY at its private canary URL.
#   2. smoke    — health-check the canary URL (the new code), never the live URL.
#   3. promote  — smoke passed: shift 100% traffic to the new revision.
#      rollback — smoke failed: traffic was never shifted, so the prior revision
#                 is still serving; we additionally PIN traffic explicitly to the
#                 recorded last-healthy revision (belt-and-suspenders) and fail
#                 the workflow loudly.
#
# The verbs are split so a CI workflow can wire promote on success and rollback
# in an `if: failure()` step. All gcloud/curl/jq calls go through overridable
# vars (CANARY_GCLOUD/CANARY_CURL/CANARY_JQ) so the logic is hermetically
# testable with stubs — see scripts/canary-deploy.test.sh.
#
# Usage:
#   canary-deploy.sh pin-healthy <service>     # record the revision serving now
#   canary-deploy.sh deploy      <service> <image> [-- <extra gcloud run deploy args>]
#   canary-deploy.sh smoke       <service> [path]   # smoke the canary URL (default /)
#   canary-deploy.sh promote     <service>     # shift 100% traffic to the new revision
#   canary-deploy.sh rollback    <service>     # restore traffic to last-healthy + exit 1
#
# State (the recorded last-healthy revision per service) lives under
# CANARY_STATE_DIR so `pin-healthy` (pre-deploy) and `rollback` (post-failure)
# can run in separate workflow steps / processes.
set -uo pipefail

# Arrays, not strings (issue #2387, hygiene). These were expanded unquoted — `"${GCLOUD[@]}" run …`,
# `$JQ -r …` — which relies on word splitting to let an override like
# CANARY_GCLOUD="docker run --rm gcloud-sdk gcloud" become multiple argv entries. That works,
# but it also splits a path containing a space and re-globs every word, and it means shellcheck
# flags six real-looking SC2046s that a reader has to individually dismiss. An explicit array
# expresses the same intent, keeps the multi-word override working, and is safe.
read -r -a GCLOUD <<< "${CANARY_GCLOUD:-gcloud}"
read -r -a CURL   <<< "${CANARY_CURL:-curl}"
read -r -a JQ     <<< "${CANARY_JQ:-jq}"
REGION="${CANARY_REGION:-${GCP_REGION:-us-central1}}"
PROJECT="${CANARY_PROJECT:-${GCP_PROJECT_ID:-}}"
CANARY_TAG="${CANARY_TAG:-canary}"
STATE_DIR="${CANARY_STATE_DIR:-${TMPDIR:-/tmp}/skillforge-canary}"
# Smoke retry budget — generous defaults for a cold Cloud Run revision; the test
# overrides these to 1 attempt / 0 delay so the suite stays fast.
SMOKE_RETRIES="${CANARY_SMOKE_RETRIES:-6}"
SMOKE_DELAY="${CANARY_SMOKE_DELAY:-10}"
SMOKE_TIMEOUT="${CANARY_SMOKE_TIMEOUT:-15}"

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { printf '%s\n' "$*" >&2; }
die() { log "❌ $*"; exit 1; }

# Common locator args for every gcloud run call.
# The location flags as an ARRAY. `_loc()` used to print a string that every call site then
# splat unquoted via `$(_loc)`; building it once as an array removes the splitting entirely. PROJECT and
# REGION are read-only after argument parsing, so one construction is enough.
LOC_ARGS=( "--region=$REGION" )
[ -n "$PROJECT" ] && LOC_ARGS+=( "--project=$PROJECT" )

# The file where pin-healthy records the revision that was serving before our deploy.
_healthy_file() { printf '%s/%s.last-healthy' "$STATE_DIR" "$1"; }

# Describe the service as JSON (single source of truth for traffic parsing).
_describe_json() {
  "${GCLOUD[@]}" run services describe "$1" "${LOC_ARGS[@]}" --format=json 2>/dev/null
}

# The revision currently receiving the most production traffic — i.e. the one
# that was healthy before we started. All historical deploys were all-at-once,
# so the top-percent entry is the single live revision.
_current_serving_revision() {
  _describe_json "$1" | "${JQ[@]}" -r '
    [ .status.traffic[]? | select((.tag // "") == "") ]
    | sort_by(.percent // 0) | reverse | (.[0].revisionName // "")'
}

# The private URL of the canary-tagged revision (the new code, 0% prod traffic).
_canary_url() {
  _describe_json "$1" | "${JQ[@]}" -r --arg t "$CANARY_TAG" '
    (.status.traffic[]? | select(.tag == $t) | .url) // ""' | head -1
}

# ── pin-healthy ──────────────────────────────────────────────────────────────
# Record the revision serving production NOW, before the canary deploy creates a
# new one. rollback reads this file to know where to send traffic back to.
cmd_pin_healthy() {
  local service="${1:?service required}"
  local rev; rev="$(_current_serving_revision "$service")"
  printf '%s' "$rev" > "$(_healthy_file "$service")"
  if [ -n "$rev" ]; then
    log "📌 last-healthy revision for $service: $rev"
  else
    # First-ever deploy: there is no prior revision to fall back to. That is
    # safe — a --no-traffic deploy means the (possibly broken) new revision
    # never serves — but rollback cannot restore anything, so flag it.
    log "📌 no prior serving revision for $service (first deploy — no rollback target)"
  fi
}

# ── deploy ───────────────────────────────────────────────────────────────────
# Deploy the new revision WITHOUT taking traffic. The prior revision keeps
# serving 100%; the new one is reachable only at its canary tag URL.
cmd_deploy() {
  local service="${1:?service required}"; local image="${2:?image required}"
  shift 2
  [ "${1:-}" = "--" ] && shift
  log "🚀 deploying $service (canary, --no-traffic) image=$image"
  "${GCLOUD[@]}" run deploy "$service" \
    --image="$image" \
    "${LOC_ARGS[@]}" \
    --no-traffic \
    --tag="$CANARY_TAG" \
    "$@"
}

# ── smoke ────────────────────────────────────────────────────────────────────
# Health-check the CANARY url (the new code) — never the live service URL, which
# is still serving the old healthy revision.
cmd_smoke() {
  local service="${1:?service required}"; local path="${2:-/}"
  local url; url="$(_canary_url "$service")"
  [ -n "$url" ] || die "could not resolve canary URL for $service (deploy step did not run?)"
  local target="${url%/}$path"
  log "🩺 smoking canary $target"
  local i status
  for ((i=1; i<=SMOKE_RETRIES; i++)); do
    status="$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time "$SMOKE_TIMEOUT" "$target" 2>/dev/null)"
    log "  attempt $i: HTTP $status"
    [ "$status" = "200" ] && { log "✅ canary healthy"; return 0; }
    [ "$i" -lt "$SMOKE_RETRIES" ] && sleep "$SMOKE_DELAY"
  done
  die "canary smoke failed for $service (last HTTP $status)"
}

# ── promote ──────────────────────────────────────────────────────────────────
# Smoke passed: shift 100% of traffic to the new (latest) revision and drop the
# canary tag so its private URL is freed.
cmd_promote() {
  local service="${1:?service required}"
  log "🟢 promoting $service — shifting 100% traffic to the new revision"
  "${GCLOUD[@]}" run services update-traffic "$service" "${LOC_ARGS[@]}" --to-latest \
    || die "failed to shift traffic to the new revision for $service"
  "${GCLOUD[@]}" run services update-traffic "$service" "${LOC_ARGS[@]}" --remove-tags="$CANARY_TAG" \
    || log "⚠️  could not remove canary tag (traffic already shifted; non-fatal)"
  log "✅ $service promoted"
}

# ── rollback ─────────────────────────────────────────────────────────────────
# Smoke/health failed: restore traffic to the recorded last-healthy revision and
# fail loudly. Because the deploy used --no-traffic the prior revision was never
# displaced, so this is a guaranteed-safe explicit re-pin, not a scramble.
cmd_rollback() {
  local service="${1:?service required}"
  local healthy; healthy="$(cat "$(_healthy_file "$service")" 2>/dev/null || true)"
  # Drop the canary tag regardless so the failed revision is not reachable.
  "${GCLOUD[@]}" run services update-traffic "$service" "${LOC_ARGS[@]}" --remove-tags="$CANARY_TAG" 2>/dev/null \
    || log "⚠️  could not remove canary tag during rollback (non-fatal)"
  if [ -z "$healthy" ]; then
    log "🛑 ROLLBACK: no last-healthy revision recorded for $service."
    log "   (first deploy, or pin-healthy never ran). The --no-traffic deploy"
    log "   means the broken revision never served traffic — nothing to undo —"
    log "   but there is also no prior revision to promote. Failing loudly."
    return 1
  fi
  log "↩️  ROLLBACK: pinning 100% traffic for $service back to $healthy"
  "${GCLOUD[@]}" run services update-traffic "$service" "${LOC_ARGS[@]}" --to-revisions="${healthy}=100" \
    || die "ROLLBACK FAILED for $service — manual intervention required (see runbook)"
  log "✅ $service traffic restored to last-healthy revision $healthy"
  # The deploy is a failure even though traffic is safe — the workflow must go red.
  return 1
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    pin-healthy) cmd_pin_healthy "$@" ;;
    deploy)      cmd_deploy "$@" ;;
    smoke)       cmd_smoke "$@" ;;
    promote)     cmd_promote "$@" ;;
    rollback)    cmd_rollback "$@" ;;
    canary-url)  _canary_url "${1:?service required}" ;;   # exposed for debugging
    *) die "usage: canary-deploy.sh {pin-healthy|deploy|smoke|promote|rollback|canary-url} <service> [...]" ;;
  esac
}

main "$@"
