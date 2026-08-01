#!/usr/bin/env bash
# Hermetic test for the Cloud Run canary + auto-rollback engine (issue #204).
#
# There is no cloud surface to drive, so this exercises the REAL script
# (scripts/canary-deploy.sh) with gcloud + curl + jq STUBBED: zero real GCP
# calls, deterministic. It proves the deploy-safety contract:
#
#   1. canary deploy   → new revision is created with --no-traffic --tag=canary,
#                        so the PRIOR revision keeps serving 100%.
#   2. passing smoke   → traffic is shifted to the new revision (promote).
#   3. failing smoke   → traffic is pinned BACK to the recorded last-healthy
#                        revision and the command exits non-zero (rollback).
#   4. first deploy    → no last-healthy target; rollback fails loudly but never
#                        shifts traffic to the broken revision.
#   5. smoke targets the CANARY url, never the live service url.
#   6. the staging workflow + Makefile actually wire these verbs (pin → deploy
#      no-traffic → smoke canary → promote, with rollback on failure).
#
#   Run: bash scripts/canary-deploy.test.sh     (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/canary-deploy.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
# `--` before the pattern so leading-dash needles (e.g. --no-traffic) aren't parsed as grep flags.
assert_grep()   { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected to find: $2)"; fi; }
assert_nogrep() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (unexpectedly found: $2)"; else ok "$3"; fi; }

SVC="skillforge-api-staging"

# ── Hermetic env: a stub gcloud whose service state is a JSON file on disk, and
# a stub curl whose status code is read from a file (so a test can flip smoke
# pass→fail). Every gcloud invocation is appended to gcloud-calls.log. ──────────
make_env() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/state"

  # The service's traffic state. Two revisions exist; rev-old serves 100%, and a
  # canary-tagged rev-new serves 0% (what `deploy --no-traffic --tag=canary`
  # produces). Its canary URL is distinct from the live URL.
  cat > "$tmp/service.json" <<'JSON'
{
  "status": {
    "url": "https://skillforge-api-staging-live.a.run.app",
    "traffic": [
      { "revisionName": "rev-old", "percent": 100, "tag": "" },
      { "revisionName": "rev-new", "percent": 0, "tag": "canary",
        "url": "https://canary---skillforge-api-staging-xyz.a.run.app" }
    ]
  }
}
JSON

  echo "200" > "$tmp/smoke-status"   # curl stub returns this; flip to 500 to fail smoke

  # gcloud stub: logs the call; answers `services describe ... --format=json`
  # from service.json; accepts deploy / update-traffic as no-ops (exit 0).
  cat > "$tmp/bin/gcloud" <<GC
#!/usr/bin/env bash
echo "gcloud \$*" >> "$tmp/state/gcloud-calls.log"
for a in "\$@"; do [ "\$a" = "describe" ] && { cat "$tmp/service.json"; exit 0; }; done
exit 0
GC
  chmod +x "$tmp/bin/gcloud"

  # curl stub: echoes the status code from smoke-status (canary-deploy.sh uses
  # -w '%{http_code}' -o /dev/null, so its stdout IS the status).
  cat > "$tmp/bin/curl" <<CU
#!/usr/bin/env bash
echo "curl \$*" >> "$tmp/state/curl-calls.log"
cat "$tmp/smoke-status"
CU
  chmod +x "$tmp/bin/curl"
}

run() {  # run the script verb against the stubs; extra env as KEY=VAL args
  local tmp="$1"; shift
  local verb_and_args=()
  while [ $# -gt 0 ] && [[ "$1" != *=* || "$1" == *://* ]]; do verb_and_args+=("$1"); shift; done
  env "$@" \
    CANARY_GCLOUD="$tmp/bin/gcloud" \
    CANARY_CURL="$tmp/bin/curl" \
    CANARY_JQ="jq" \
    CANARY_PROJECT="test-proj" CANARY_REGION="us-central1" \
    CANARY_STATE_DIR="$tmp/state" \
    CANARY_SMOKE_RETRIES=1 CANARY_SMOKE_DELAY=0 \
    bash "$SCRIPT" "${verb_and_args[@]}" > "$tmp/last.out" 2>&1
  echo $? > "$tmp/last.rc"
}
rc() { cat "$1/last.rc"; }

# ── Scenario 1: canary deploy takes NO traffic + tags the revision ────────────
echo "Scenario 1 — deploy creates the revision with --no-traffic --tag=canary (prior keeps serving)"
T1="$(mktemp -d)"; make_env "$T1"
run "$T1" deploy "$SVC" "us-docker.pkg.dev/p/api:abc123"
[ "$(rc "$T1")" = "0" ] && ok "deploy exits 0" || bad "deploy should exit 0"
assert_grep "$T1/state/gcloud-calls.log" "run deploy $SVC" "invoked gcloud run deploy"
assert_grep "$T1/state/gcloud-calls.log" "--no-traffic" "deployed with --no-traffic (prior revision keeps 100%)"
assert_grep "$T1/state/gcloud-calls.log" "--tag=canary" "tagged the new revision canary"

# ── Scenario 2: passing smoke → promote shifts traffic to the new revision ────
echo "Scenario 2 — passing smoke → promote shifts 100% traffic to the new revision"
T2="$(mktemp -d)"; make_env "$T2"
run "$T2" pin-healthy "$SVC"
[ "$(cat "$T2/state/$SVC.last-healthy")" = "rev-old" ] && ok "pin-healthy recorded the serving revision (rev-old)" || bad "pin-healthy did not record rev-old"
echo "200" > "$T2/smoke-status"
run "$T2" smoke "$SVC" /health
[ "$(rc "$T2")" = "0" ] && ok "smoke passes on HTTP 200" || bad "smoke should pass on 200"
# smoke must hit the CANARY url, not the live url
assert_grep "$T2/state/curl-calls.log" "canary---skillforge-api-staging-xyz" "smoke targeted the canary URL"
assert_nogrep "$T2/state/curl-calls.log" "skillforge-api-staging-live" "smoke did NOT target the live URL"
: > "$T2/state/gcloud-calls.log"
run "$T2" promote "$SVC"
[ "$(rc "$T2")" = "0" ] && ok "promote exits 0" || bad "promote should exit 0"
assert_grep "$T2/state/gcloud-calls.log" "update-traffic $SVC" "promote called update-traffic"
assert_grep "$T2/state/gcloud-calls.log" "--to-latest" "promote shifted traffic to the new (latest) revision"

# ── Scenario 3: failing smoke → rollback pins traffic to last-healthy + fails ─
echo "Scenario 3 — failing smoke → rollback restores traffic to last-healthy and fails loudly"
T3="$(mktemp -d)"; make_env "$T3"
run "$T3" pin-healthy "$SVC"
echo "500" > "$T3/smoke-status"
run "$T3" smoke "$SVC" /health
[ "$(rc "$T3")" != "0" ] && ok "smoke exits non-zero on HTTP 500" || bad "smoke must fail on 500"
assert_grep "$T3/last.out" "canary smoke failed" "smoke failure is reported loudly"
: > "$T3/state/gcloud-calls.log"
run "$T3" rollback "$SVC"
[ "$(rc "$T3")" != "0" ] && ok "rollback exits non-zero (workflow goes red)" || bad "rollback must exit non-zero"
assert_grep "$T3/state/gcloud-calls.log" "update-traffic $SVC" "rollback called update-traffic"
assert_grep "$T3/state/gcloud-calls.log" "--to-revisions=rev-old=100" "rollback pinned 100% traffic to last-healthy rev-old"
assert_nogrep "$T3/state/gcloud-calls.log" "--to-latest" "rollback did NOT shift traffic to the broken new revision"
assert_grep "$T3/last.out" "traffic restored to last-healthy" "rollback confirms traffic was restored"

# ── Scenario 4: first deploy (no last-healthy target) → rollback fails safe ───
echo "Scenario 4 — first deploy: no last-healthy revision → rollback fails loudly, never serves the broken build"
T4="$(mktemp -d)"; make_env "$T4"
# Simulate a brand-new service: no traffic entries at all.
echo '{ "status": { "url": "https://x", "traffic": [] } }' > "$T4/service.json"
run "$T4" pin-healthy "$SVC"
[ ! -s "$T4/state/$SVC.last-healthy" ] && ok "pin-healthy records empty target on a first deploy" || bad "first deploy should record no healthy revision"
: > "$T4/state/gcloud-calls.log"
run "$T4" rollback "$SVC"
[ "$(rc "$T4")" != "0" ] && ok "rollback on a first deploy still exits non-zero" || bad "rollback must fail loudly even with no target"
assert_nogrep "$T4/state/gcloud-calls.log" "--to-latest" "first-deploy rollback never promotes the broken revision"
assert_nogrep "$T4/state/gcloud-calls.log" "--to-revisions" "first-deploy rollback has no revision to pin to"

# ── Scenario 5: the workflow + Makefile actually wire the safe sequence ───────
echo "Scenario 5 — deploy-staging.yml + Makefile wire pin → no-traffic deploy → smoke canary → promote/rollback"
WF="$ROOT/.github/workflows/deploy-staging.yml"
MK="$ROOT/Makefile"
assert_grep "$MK" "--no-traffic" "Makefile deploy targets pin new revisions to --no-traffic"
assert_grep "$MK" "canary-deploy.sh" "Makefile delegates canary verbs to scripts/canary-deploy.sh"
assert_grep "$WF" "pin-healthy" "workflow records the last-healthy revision before deploying"
assert_grep "$WF" "smoke-canary" "workflow smokes the canary, not the live service"
assert_grep "$WF" "make promote" "workflow promotes traffic after a passing smoke"
assert_grep "$WF" "make rollback" "workflow has a rollback step"
assert_grep "$WF" "if: failure()" "rollback runs on failure (auto-rollback)"

rm -rf "$T1" "$T2" "$T3" "$T4" 2>/dev/null || true
echo
echo "canary-deploy: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
