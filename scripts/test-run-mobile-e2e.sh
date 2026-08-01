#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Tests for run-mobile-e2e.sh (issue #1970 — runtime mobile Maestro e2e gate).
#
# run-mobile-e2e.sh is the RUNTIME half of the mobile-e2e gate (the sibling of
# scripts/run-e2e.sh). These tests lock in its two load-bearing contracts:
#
#   1) SKIP SEMANTICS — it must exit 77 (SKIP), never 1 (FAIL), when a runtime
#      prerequisite is absent (opt-in flag unset, no maestro CLI, no booted
#      device, app not installed, unknown platform). This is what lets an
#      infra-less host record SKIP instead of false-failing the gate. A
#      regression here would either wedge the pipeline (77→FAIL promotion on a
#      required run) or, worse, dead-end a real infra problem as a spurious FAIL.
#   2) EXIT-CODE PASSTHROUGH — when every prerequisite is present it runs Maestro
#      and returns maestro's own exit code (0 pass / non-zero fail), so a failing
#      flow actually fails the gate.
#
# The real emulator/maestro toolchain isn't available in unit CI, so each test
# shadows maestro/adb/xcrun/curl/npx/npm with configurable PATH stubs and asserts
# the resulting exit code + a marker in the output.
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-mobile-e2e.sh"
PASS=0
FAIL=0

[[ -x "$RUNNER" ]] || { echo "FATAL: $RUNNER not found or not executable"; exit 1; }

# Build a stub bin dir whose maestro/adb/xcrun/curl/npx/npm shadow the real tools.
# The stubs are driven by STUB_* env vars so each test picks the scenario it wants.
# Stub dirs are registered for removal at exit (issue #2387): each call used to leak a
# mktemp -d, so a full run of this suite left one directory per scenario behind in $TMPDIR.
STUB_DIRS=()
cleanup_stub_dirs() { local d; for d in "${STUB_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup_stub_dirs EXIT

make_stub_bin() {
  local d; d="$(mktemp -d)"
  STUB_DIRS+=("$d")

  cat > "$d/maestro" <<'EOF'
#!/usr/bin/env bash
exit "${STUB_MAESTRO_EXIT:-0}"
EOF

  cat > "$d/adb" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  devices)
    echo "List of devices attached"
    [[ "${STUB_ADB_DEVICE:-0}" == "1" ]] && echo "emulator-5554 device"
    ;;
  shell)  # `adb shell pm list packages`
    [[ "${STUB_APP_INSTALLED:-0}" == "1" ]] && echo "package:com.skillforge.app"
    ;;
  reverse) : ;;   # forward / --remove — always succeed
  *) : ;;
esac
exit 0
EOF

  cat > "$d/xcrun" <<'EOF'
#!/usr/bin/env bash
# `xcrun simctl list devices booted`
if [[ "$*" == *"list devices booted"* && "${STUB_IOS_BOOTED:-0}" == "1" ]]; then
  echo "    iPhone 15 (ABC-123) (Booted)"
fi
exit 0
EOF

  cat > "$d/curl" <<'EOF'
#!/usr/bin/env bash
# Health probe — report the mock server ready.
echo '{"status":"ok"}'
exit 0
EOF

  cat > "$d/npx" <<'EOF'
#!/usr/bin/env bash
# Stand in for `npx tsx mock-server.ts` — stay alive briefly so the runner's
# liveness check (kill -0) sees a running mock server, then let cleanup kill us.
# Kept short so a missed cleanup can't block the capturing $() for long.
sleep 5
EOF

  cat > "$d/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$d"/*
  printf '%s' "$d"
}

# run_case <label> <expected_exit> <expected_marker> [env assignments...]
run_case() {
  local label="$1" expected="$2" marker="$3"; shift 3
  local bin; bin="$(make_stub_bin)"
  local out actual
  # Stubs first on PATH so they shadow any real tool; keep the rest for coreutils.
  # Clear ambient MOBILE_E2E_* first so each case fully controls the runner's
  # inputs — otherwise a caller that exports these (e.g. cut-mobile-release.sh
  # runs this suite with MOBILE_E2E_BUILD=1 for the real run) leaks into the
  # "app not installed → 77" case and flips it to a build+install (exit 0).
  out="$(env -u MOBILE_E2E_LOCAL -u MOBILE_E2E_BUILD -u MOBILE_E2E_PLATFORM \
             -u MOBILE_E2E_FLOWS -u MOBILE_E2E_MOCK_PORT \
             "$@" PATH="$bin:$PATH" bash "$RUNNER" 2>&1)"; actual=$?
  rm -rf "$bin"

  local ok=1
  [[ "$actual" -eq "$expected" ]] || ok=0
  [[ -z "$marker" || "$out" == *"$marker"* ]] || ok=0
  if [[ "$ok" == 1 ]]; then
    echo "  ✓ $label"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $label (expected exit $expected, got $actual)"
    echo "    Output: $(echo "$out" | tail -1)"
    FAIL=$((FAIL + 1))
  fi
}

echo "── run-mobile-e2e.sh skip/run semantics ──"

# Opt-in gate: without MOBILE_E2E_LOCAL the emulator path never boots.
run_case "disabled by default → 77" 77 "runtime disabled" \
  MOBILE_E2E_LOCAL=

# Unknown platform is a config error, but still a SKIP (never a false FAIL).
run_case "unknown platform → 77" 77 "unknown MOBILE_E2E_PLATFORM" \
  MOBILE_E2E_LOCAL=1 MOBILE_E2E_PLATFORM=windows

# Android with no booted device → SKIP.
run_case "android, no device → 77" 77 "no booted Android" \
  MOBILE_E2E_LOCAL=1 MOBILE_E2E_PLATFORM=android STUB_ADB_DEVICE=0

# Android with a device but no installed build and no build flag → SKIP.
run_case "android, app not installed → 77" 77 "not installed on the device" \
  MOBILE_E2E_LOCAL=1 MOBILE_E2E_PLATFORM=android STUB_ADB_DEVICE=1 STUB_APP_INSTALLED=0

# iOS with no booted simulator → SKIP.
run_case "ios, no booted simulator → 77" 77 "no booted iOS simulator" \
  MOBILE_E2E_LOCAL=1 MOBILE_E2E_PLATFORM=ios STUB_IOS_BOOTED=0

# Happy path (android): device booted, app installed, mock server healthy,
# maestro passes → the runner returns maestro's 0.
run_case "android, all present, maestro passes → 0" 0 "maestro exit=0" \
  MOBILE_E2E_LOCAL=1 MOBILE_E2E_PLATFORM=android \
  STUB_ADB_DEVICE=1 STUB_APP_INSTALLED=1 STUB_MAESTRO_EXIT=0

# Failing flow must propagate: maestro exits 1 → the runner exits 1 (the gate fails).
run_case "android, maestro fails → 1" 1 "maestro exit=1" \
  MOBILE_E2E_LOCAL=1 MOBILE_E2E_PLATFORM=android \
  STUB_ADB_DEVICE=1 STUB_APP_INSTALLED=1 STUB_MAESTRO_EXIT=1

echo "═══════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
