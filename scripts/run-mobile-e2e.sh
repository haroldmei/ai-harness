#!/usr/bin/env bash
# run-mobile-e2e.sh — run the Maestro mobile e2e suite (mobile/.maestro/*.yaml)
# against a build installed on a booted Android emulator / iOS simulator, driven
# against the hermetic mock server (mobile/e2e/mock-server.ts on :8099) that stubs
# every external service (AI provider, FCM push, store age signals, backend API).
#
# This is the RUNTIME sibling of the static mobile-e2e gate validation and mirrors
# scripts/run-e2e.sh (the web Playwright runner): the gate does cheap static
# validation first, then delegates the expensive emulator run here.
#
# HISTORY: the 26 Maestro flows used to run only in .github/workflows/mobile-e2e.yml,
# which was DELETED in 48992e99 — so before this runner they executed NOWHERE. This
# script restores a real execution path (issue #1970).
#
# Disabled by default (skip 77) so the unattended harness never boots an emulator
# unasked (same posture as run-e2e.sh's E2E_LOCAL_STACK). Opt in with
# MOBILE_E2E_LOCAL=1. When the runtime prerequisites are absent — no `maestro` CLI,
# no booted emulator/simulator, or (without MOBILE_E2E_BUILD=1) no installed build —
# the script exits 77 (SKIP) so infra-less hosts skip cleanly instead of false-failing.
# Promote with REQUIRED_GATES=mobile-e2e on an emulator host to make a skip fail.
#
#   MOBILE_E2E_LOCAL=1 scripts/run-mobile-e2e.sh                      # android (default)
#   MOBILE_E2E_LOCAL=1 MOBILE_E2E_PLATFORM=ios scripts/run-mobile-e2e.sh
#   MOBILE_E2E_LOCAL=1 MOBILE_E2E_BUILD=1 scripts/run-mobile-e2e.sh   # build+install first
#   MOBILE_E2E_LOCAL=1 MOBILE_E2E_FLOWS=".maestro/auth-flow.yaml" scripts/run-mobile-e2e.sh
#
# Exit: maestro's exit code (0 = pass) | 77 = skipped (disabled / no tooling / no device).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "mobile-e2e: cannot cd to repo root"; exit 1; }

APP_ID="com.skillforge.app"     # app.json android.package / ios.bundleIdentifier
MOCK_PORT="${MOBILE_E2E_MOCK_PORT:-8099}"
PLATFORM="${MOBILE_E2E_PLATFORM:-android}"

# ── Target gate: opt-in only, so the emulator never boots by surprise ──────────────
if [[ "${MOBILE_E2E_LOCAL:-0}" != "1" ]]; then
  echo "mobile-e2e: runtime disabled (set MOBILE_E2E_LOCAL=1 to boot the mock server + run Maestro on a device) — skipping"
  exit 77
fi

[[ -d mobile/.maestro ]] || { echo "mobile-e2e: no mobile/.maestro flows — skipping"; exit 77; }

# ── Prerequisite: the Maestro CLI ─────────────────────────────────────────────────
if ! command -v maestro >/dev/null 2>&1; then
  echo "mobile-e2e: maestro CLI not installed (curl -Ls https://get.maestro.mobile.dev | bash) — skipping"
  exit 77
fi

# ── Prerequisite: a booted emulator / simulator ───────────────────────────────────
# Absent device ⇒ SKIP (77), never FAIL — an infra-less host must not false-fail.
case "$PLATFORM" in
  android)
    command -v adb >/dev/null 2>&1 || { echo "mobile-e2e: adb not on PATH — skipping"; exit 77; }
    # A device line in state "device" (not "offline"/"unauthorized") means a live target.
    if ! adb devices | awk 'NR>1 && $2=="device"{found=1} END{exit found?0:1}'; then
      echo "mobile-e2e: no booted Android emulator/device (adb devices shows none ready) — skipping"
      exit 77
    fi
    ;;
  ios)
    command -v xcrun >/dev/null 2>&1 || { echo "mobile-e2e: xcrun not available (macOS only) — skipping"; exit 77; }
    if ! xcrun simctl list devices booted 2>/dev/null | grep -q "(Booted)"; then
      echo "mobile-e2e: no booted iOS simulator (xcrun simctl list devices booted) — skipping"
      exit 77
    fi
    ;;
  *)
    echo "mobile-e2e: unknown MOBILE_E2E_PLATFORM='$PLATFORM' (expected android|ios) — skipping"; exit 77;;
esac

# ── Prerequisite: an installed app build (or build it on request) ─────────────────
app_installed() {
  case "$PLATFORM" in
    android) adb shell pm list packages 2>/dev/null | grep -q "package:${APP_ID}$" ;;
    # No cheap portable "is it installed" probe for the simulator; assume the build
    # step (or a pre-provisioned simulator) put it there and let maestro report if not.
    ios)     return 0 ;;
  esac
}

if [[ "${MOBILE_E2E_BUILD:-0}" == "1" ]]; then
  # MOBILE_E2E_BUILD=1 always rebuilds+reinstalls the CURRENT source, even when a
  # (stale) build is already installed. `expo run:android` reinstalls over the
  # existing app. Gating the build on `! app_installed` silently tested a stale
  # APK — an app-source fix would never reach the device until a manual uninstall.
  echo "mobile-e2e: building + installing current source (MOBILE_E2E_BUILD=1)…"
  ( cd mobile
    [[ -d node_modules ]] || npm ci
    # Bake the hermetic mock server as the API origin so the release bundle
    # talks to it via `adb reverse tcp:${MOCK_PORT}` (baseUrl.ts passes a
    # localhost URL through untouched in a release build — no Metro hostUri).
    # Without this the app uses its default/.env backend, never contacts the
    # mock, and every authenticated screen renders blank.
    export EXPO_PUBLIC_API_URL="http://localhost:${MOCK_PORT}/api/v1"
    # E2E build flag (baked at bundle time): auto-unlocks the biometric lock
    # (BiometricLockScreen) since the OS biometric prompt can't be automated.
    export EXPO_PUBLIC_E2E_MODE=1
    case "$PLATFORM" in
      android) npx expo run:android --no-bundler --variant release ;;
      ios)     npx expo run:ios --no-bundler --configuration Release ;;
    esac
  ) || { echo "mobile-e2e: build/install failed"; exit 1; }
elif ! app_installed; then
  echo "mobile-e2e: app '${APP_ID}' not installed on the device (set MOBILE_E2E_BUILD=1 to build+install, or install a release build first) — skipping"
  exit 77
fi

# ── Hermetic mock server (mobile/e2e/mock-server.ts on :$MOCK_PORT) ───────────────
# Recursively signal a process AND its descendants. The mock server runs as
# `npx tsx …` inside a subshell, so $! is the subshell — a bare `kill $!` orphans
# the node/tsx child that actually holds :$MOCK_PORT, leaking it past teardown.
# Walk the tree (same approach as quality-gates.sh's _kill_tree; pgrep is present
# on Linux and macOS).
_kill_tree() {
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do _kill_tree "$c"; done
  kill "$p" 2>/dev/null
}
MOCK_PID=""
cleanup() {
  [[ -n "$MOCK_PID" ]] && _kill_tree "$MOCK_PID"
  [[ "$PLATFORM" == "android" ]] && adb reverse --remove "tcp:${MOCK_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

echo "mobile-e2e: starting hermetic mock server on :${MOCK_PORT}…"
( cd mobile/e2e && [[ -d node_modules ]] || npm ci ) || { echo "mobile-e2e: mock-server deps install failed"; exit 1; }
# mock-server.ts reads --port first, then $MOCK_PORT, then :8099. MOCK_PORT is
# already in this shell's environment (exported by the subshell inheritance), so
# --port alone is authoritative and unambiguous.
( cd mobile/e2e && npx tsx mock-server.ts --port="$MOCK_PORT" ) &
MOCK_PID=$!

# Wait for the mock server to answer /health (bounded — the gate's QG_GATE_TIMEOUT
# still caps the whole run, but a fast local wait keeps failures crisp).
ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://localhost:${MOCK_PORT}/health" 2>/dev/null | grep -q '"status":"ok"'; then
    ready=1; break
  fi
  # Bail early if the server process died on boot.
  kill -0 "$MOCK_PID" 2>/dev/null || break
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "mobile-e2e: mock server did not become ready on :${MOCK_PORT} — failing"
  exit 1
fi
echo "mobile-e2e: mock server ready on :${MOCK_PORT}"

# Android: forward the emulator's localhost:$MOCK_PORT to the host's mock server so
# E2E_API_URL=http://localhost:${MOCK_PORT} resolves from inside the device.
if [[ "$PLATFORM" == "android" ]]; then
  adb reverse "tcp:${MOCK_PORT}" "tcp:${MOCK_PORT}" || { echo "mobile-e2e: adb reverse failed"; exit 1; }
  echo "mobile-e2e: adb reverse tcp:${MOCK_PORT} → host :${MOCK_PORT} configured"
fi

# ── Run the Maestro suite ─────────────────────────────────────────────────────────
FLOWS="${MOBILE_E2E_FLOWS:-.maestro}"
echo "mobile-e2e: running Maestro (${PLATFORM}) → ${FLOWS}"

# Maestro 2.x does NOT read the workspace config.yaml `env:` block, so forward
# every entry as a --env flag (test-user creds, TOTP, etc.). Without this,
# `${E2E_USER_EMAIL}` stays a literal in inputText and login 401s.
MAESTRO_ENV=()
while IFS='=' read -r k v; do
  [[ -n "$k" ]] && MAESTRO_ENV+=(--env "${k}=${v}")
done < <(awk '
  /^env:/                 { f=1; next }
  f && /^[A-Za-z]/        { f=0 }
  f && /^[[:space:]]+[A-Za-z0-9_]+:/ {
    sub(/^[[:space:]]+/, ""); sub(/:[[:space:]]*/, "="); gsub(/"/, ""); print
  }' mobile/.maestro/config.yaml)

( cd mobile || exit 1
  # shellcheck disable=SC2086
  maestro test $FLOWS \
    "${MAESTRO_ENV[@]}" \
    --env E2E_API_URL="http://localhost:${MOCK_PORT}" \
    --env BIOMETRIC_BYPASS=true \
    --include-tags "${PLATFORM}" )
    # NB: Maestro --include-tags is OR, so a shared "e2e" tag would pull in
    # platform-exclusive flows (e.g. siwa-flow, iOS-only) on every platform.
    # Filtering on the platform tag alone is the intended discriminator: every
    # flow carries both "android" and "ios" EXCEPT genuinely single-platform
    # ones (Sign in with Apple is iOS-only — the button is hidden off-iOS).
rc=$?
echo "mobile-e2e: maestro exit=${rc}"
exit "$rc"
