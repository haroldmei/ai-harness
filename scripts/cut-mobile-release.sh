#!/usr/bin/env bash
# cut-mobile-release.sh — ship the mobile app for a commit already tagged by
# scripts/cut-release.sh. The mobile sibling of the web cut; it shares the
# staging-v* / v* tag line and never pushes a tag of its own.
#
#   scripts/cut-mobile-release.sh staging   → OTA the tagged commit to the `preview` channel
#   scripts/cut-mobile-release.sh prod       → OTA the tagged commit to the `prod` channel
#
# Full design + rationale: docs/53-mobile-release-cut.md. This implements PR 2:
# the preconditions (§4), the hard mobile-e2e gate spine (§5), the JS-only OTA
# path (§6.1/§6.2), and the ship record (§6.4). The native store-build path
# (§6.3) is stubbed to fail closed until store credentials land (#1924).
#
# ── The three binding decisions (docs/53 §1) ─────────────────────────────────
#   1. Local orchestration (this script; `eas build` still runs on Expo's cloud).
#   2. Shared tag line — the mobile artifact is pinned to the SAME commit the
#      backend deploy tagged. HEAD must already carry a staging-v* / v* tag.
#   3. mobile-e2e is a HARD gate — the 26 Maestro flows run on a booted emulator.
#      A host that cannot run them FAILS the cut (no device ⇒ no cut).
#
# Flags:
#   --platform ios|android|all   store-build target only; OTA is platform-agnostic (default: all)
#   --store                      force a store build + submit (TestFlight iOS / Play testing Android)
#                                even for a JS-only diff. Native diffs take this path regardless.
#                                Requires store creds EXPORTED (docs/49): iOS —
#                                EXPO_ASC_API_KEY_PATH, EXPO_ASC_KEY_ID, EXPO_ASC_ISSUER_ID,
#                                EXPO_APPLE_TEAM_ID; Android — GOOGLE_SERVICE_ACCOUNT_KEY_PATH.
#                                Builds with the store-distribution profile (staging → preview-store,
#                                prod → prod); submits with the submit profile (preview/prod).
#   --no-e2e                     skip the emulator Maestro gate; marks the run UNVERIFIED (emergencies)
#   --yes | -y                   skip the interactive confirmation (non-interactive use)
#   --dry-run                    run gates + classify + resolve the ship path, but do NOT ship
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die()  { printf '\033[31mcut-mobile: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }

# ── Parse args ────────────────────────────────────────────────────────────────
ENVNAME="" PLATFORM="all" RUN_E2E=1 ASSUME_YES=0 DRY_RUN=0 FORCE_STORE=0
for arg in "$@"; do
  case "$arg" in
    staging|prod)         ENVNAME="$arg" ;;
    --platform=*)         PLATFORM="${arg#--platform=}" ;;
    --platform)           die "use --platform=ios|android|all (got bare --platform)" ;;
    ios|android|all)      PLATFORM="$arg" ;;   # allow `--platform all` as two tokens
    --store)              FORCE_STORE=1 ;;
    --no-e2e)             RUN_E2E=0 ;;
    --yes|-y)             ASSUME_YES=1 ;;
    --dry-run)            DRY_RUN=1 ;;
    -h|--help)            sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg (expected staging|prod [--platform=ios|android|all] [--store] [--no-e2e] [--yes] [--dry-run])" ;;
  esac
done
[[ -n "$ENVNAME" ]] || die "first argument must be 'staging' or 'prod'"
case "$PLATFORM" in ios|android|all) ;; *) die "platform must be ios|android|all (got '$PLATFORM')" ;; esac

# staging → preview channel + preview submit profile + staging-v tag line;
# prod → prod + v tag line. STORE_BUILD_PROFILE is the store-DISTRIBUTION build
# profile used on the --store/native path (preview is internal ad-hoc/APK; its
# store-signed sibling is preview-store). The submit profile (PROFILE) is where
# the TestFlight/Play track + ascAppId live.
case "$ENVNAME" in
  staging) CHANNEL="preview"; PROFILE="preview"; STORE_BUILD_PROFILE="preview-store"; PREFIX="staging-v" ;;
  prod)    CHANNEL="prod";    PROFILE="prod";    STORE_BUILD_PROFILE="prod";          PREFIX="v" ;;
esac

# ── Precondition §4.2: revert the corepack `packageManager: yarn` artifact ────
# Gate/eas runs inside mobile/ make corepack inject a `"packageManager"` key into
# the ROOT package.json (docs/53 §4.2, MEMORY "Gate run dirties tree"). Revert it
# BEFORE the clean-tree check so it does not false-abort — but ONLY when that key
# is the sole change, so a real package.json edit is still caught below.
if ! git diff --quiet -- package.json 2>/dev/null; then
  if [[ -z "$(git diff -- package.json | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '"packageManager"|^[+-][[:space:]]*[}{,]?$')" ]]; then
    info "reverting corepack packageManager artifact in root package.json"
    git checkout -- package.json
  fi
fi

# ── Precondition §4.1: on main, clean tree, in sync with origin ───────────────
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "mobile releases must be cut from 'main' (on '$BRANCH')."
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty — commit or stash before releasing."
info "fetching origin…"
git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
  || die "local main is not in sync with origin/main — pull/push first."
ok "on main @ $(git rev-parse --short HEAD), clean, in sync with origin"

# ── Precondition §4.3: HEAD must already carry the release tag ────────────────
# This is the shared-tag guarantee: the mobile artifact ships the exact commit the
# backend deploy tagged. We never compute or push a tag here.
TAG="$(git describe --tags --match "${PREFIX}*" --exact-match HEAD 2>/dev/null || true)"
[[ -n "$TAG" ]] || die "HEAD is not a ${ENVNAME} release tag (${PREFIX}X.Y.Z) — run 'scripts/cut-release.sh ${ENVNAME}' first."
ok "HEAD is tagged ${TAG}"

# The mobile-e2e Maestro gate runs on whatever device THIS HOST can drive — it is
# cross-platform verification (flows are tagged android+ios), independent of the
# store-build --platform. iOS store builds happen on EAS's macOS cloud, so a Linux
# host still verifies via the Android emulator. Default to android; set
# MOBILE_E2E_PLATFORM=ios on a Mac with a booted simulator to gate on iOS instead.
E2E_PLATFORM="${MOBILE_E2E_PLATFORM:-android}"

# ── Precondition §4.4: emulator + Maestro (unless --no-e2e) ───────────────────
# Decision #3: no device ⇒ no cut. Fail with the exact remediation.
if [[ "$RUN_E2E" -eq 1 ]]; then
  command -v maestro >/dev/null 2>&1 \
    || die "maestro CLI not installed — 'curl -Ls https://get.maestro.mobile.dev | bash', or re-run with --no-e2e (UNVERIFIED)."
  case "$E2E_PLATFORM" in
    ios)
      command -v xcrun >/dev/null 2>&1 || die "xcrun not found for --platform=ios."
      xcrun simctl list devices booted 2>/dev/null | grep -q '(Booted)' \
        || die "no booted iOS simulator — 'xcrun simctl boot <udid>', or --no-e2e (UNVERIFIED)." ;;
    *)  # android is the default e2e platform (run-mobile-e2e.sh)
      command -v adb >/dev/null 2>&1 || die "adb not on PATH for the Android emulator gate."
      adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{f=1} END{exit f?0:1}' \
        || die "no booted Android emulator — 'emulator -avd <name> &', or --no-e2e (UNVERIFIED)." ;;
  esac
  ok "maestro + booted device present"
else
  warn "--no-e2e: the emulator Maestro gate is SKIPPED — this will NOT be a verified mobile release."
fi

# ── Precondition §4.5: authenticated to Expo ──────────────────────────────────
command -v eas >/dev/null 2>&1 || die "eas CLI not installed ('npm i -g eas-cli')."
if [[ -z "${EXPO_TOKEN:-}" ]] && ! eas whoami >/dev/null 2>&1; then
  die "not authenticated to Expo — set EXPO_TOKEN (docs/05-secrets-setup.md) or run 'eas login'."
fi
ok "authenticated to Expo as $(EXPO_TOKEN="${EXPO_TOKEN:-}" eas whoami 2>/dev/null || echo 'token')"

# ── Gate spine §5: mobile-scoped, with mobile-e2e as a HARD gate ──────────────
if [[ "$RUN_E2E" -eq 1 ]]; then
  info "running gates (typecheck/lint/unit + emulator Maestro e2e)…"
  GATE_ENV=(MOBILE_E2E_LOCAL=1 MOBILE_E2E_BUILD=1 MOBILE_E2E_PLATFORM="$E2E_PLATFORM"
            REQUIRED_GATES="typecheck lint unit mobile-e2e")
  GATE_ONLY="typecheck,lint,unit,mobile-e2e"
else
  info "running gates (typecheck/lint/unit only — NO emulator e2e)…"
  GATE_ENV=(REQUIRED_GATES="typecheck lint unit")
  GATE_ONLY="typecheck,lint,unit"
fi
if env "${GATE_ENV[@]}" scripts/quality-gates.sh --only "$GATE_ONLY" --tier launch; then
  ok "gates green on $(git rev-parse --short HEAD)"
else
  die "gates FAILED — nothing shipped. Fix the failures and re-run."
fi

# ── Classify change §6: JS-only (OTA) vs native (store build) ─────────────────
# Baseline = last mobile ship (mobile/.last-shipped), else the previous release tag.
LAST_SHIPPED_FILE="mobile/.last-shipped"
BASE=""
if [[ -f "$LAST_SHIPPED_FILE" ]]; then
  BASE="$(grep -oE '"commit"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' "$LAST_SHIPPED_FILE" | grep -oE '[0-9a-f]{7,40}' | head -1 || true)"
  [[ -n "$BASE" ]] && git cat-file -e "$BASE^{commit}" 2>/dev/null || BASE=""
fi
if [[ -z "$BASE" ]]; then
  BASE="$(git tag --list "${PREFIX}*" | grep -E "^${PREFIX}[0-9]+\.[0-9]+\.[0-9]+$" | sort -V \
          | awk -v t="$TAG" '$0==t{print prev} {prev=$0}')"
fi
if [[ -z "$BASE" ]]; then
  warn "no prior mobile ship or previous tag — classifying against HEAD~1 (limited)."
  BASE="HEAD~1"
fi
RANGE="${BASE}..HEAD"
info "classifying change over ${RANGE}…"
if bash mobile/scripts/check-change-type.sh "$RANGE" >/tmp/cmr-changetype.$$ 2>&1; then
  CHANGE_TYPE="js"
else
  CHANGE_TYPE="native"
fi
sed 's/^/    /' /tmp/cmr-changetype.$$ && rm -f /tmp/cmr-changetype.$$

# ── Confirm ───────────────────────────────────────────────────────────────────
MSG="${TAG} ($(git rev-parse --short HEAD))"
echo
printf '  Tag:      \033[1m%s\033[0m\n' "$TAG"
printf '  Commit:   %s  %s\n' "$(git rev-parse --short HEAD)" "$(git log -1 --pretty=%s)"
printf '  Channel:  %s   Change: %s\n' "$CHANNEL" "$([[ "$CHANGE_TYPE" == js ]] && echo 'JS-only → EAS Update (OTA)' || echo 'NATIVE → store build')"
[[ "$RUN_E2E" -eq 0 ]] && printf '  \033[33m%s\033[0m\n' "UNVERIFIED (--no-e2e)"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$CHANGE_TYPE" == "native" || "$FORCE_STORE" -eq 1 ]]; then
    ok "--dry-run: gates passed; WOULD store-build 'eas build --profile ${STORE_BUILD_PROFILE} --platform ${PLATFORM}' then 'eas submit --profile ${PROFILE} --platform ${PLATFORM} --latest'."
  else
    ok "--dry-run: gates passed; WOULD run 'eas update --branch ${CHANNEL} --message \"${MSG}\"'."
  fi
  exit 0
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  prompt="Ship ${TAG} to the ${CHANNEL} channel?"
  [[ "$ENVNAME" == "prod" ]] && prompt="⚠️  PRODUCTION OTA — deliver ${TAG} to prod users on the ${CHANNEL} channel?"
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by user — nothing shipped."
fi

# ── Ship §6 ───────────────────────────────────────────────────────────────────
if [[ "$CHANGE_TYPE" == "native" || "$FORCE_STORE" -eq 1 ]]; then
  # §6.3 — store build + submit (TestFlight iOS / Play testing tracks Android).
  # Native diffs are NOT OTA-eligible (the fingerprint runtimeVersion would reject
  # the update); --store forces this path for a signed store binary even on a
  # JS-only diff. Fail closed on missing credentials; never fall back to OTA.
  if [[ "$FORCE_STORE" -eq 1 && "$CHANGE_TYPE" != "native" ]]; then
    info "--store: forcing a store build+submit over a JS-only diff."
  else
    info "native change — routing to a store build+submit."
  fi
  info "preflighting store submit config for profile '${PROFILE}' (${PLATFORM})…"
  if ! bash mobile/scripts/check-submit-config.sh "$PROFILE" "$PLATFORM"; then
    die "store build/submit needs complete store credentials (docs/49)."
  fi
  # eas.json resolves the ASC key / Play key from $VARs, so verify they are
  # actually exported BEFORE the slow build — fail fast, not after building.
  if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "all" ]]; then
    [[ -n "${EXPO_ASC_API_KEY_PATH:-}" && -f "${EXPO_ASC_API_KEY_PATH:-/nonexistent}" ]] \
      || die "iOS store submit needs EXPO_ASC_API_KEY_PATH exported to the .p8 (+ EXPO_ASC_KEY_ID, EXPO_ASC_ISSUER_ID, EXPO_APPLE_TEAM_ID). See docs/49."
  fi
  if [[ "$PLATFORM" == "android" || "$PLATFORM" == "all" ]]; then
    [[ -n "${GOOGLE_SERVICE_ACCOUNT_KEY_PATH:-}" && -f "${GOOGLE_SERVICE_ACCOUNT_KEY_PATH:-/nonexistent}" ]] \
      || die "Android store submit needs GOOGLE_SERVICE_ACCOUNT_KEY_PATH exported to the Play service-account JSON. See docs/49."
  fi
  # Bump mobile/app.json version to match the release tag. The tag is the
  # source of truth for the mobile version (shared-tag design, docs/53 §1).
  # app.json is reverted after the ship so the working tree stays clean — the
  # tag is the permanent record; the app.json version is ephemeral for the build.
  MOBILE_VERSION="${TAG#$PREFIX}"
  info "bumping app.json version to ${MOBILE_VERSION} for the store build…"
  trap 'git checkout -- mobile/app.json 2>/dev/null; trap - EXIT' EXIT
  jq ".expo.version = \"$MOBILE_VERSION\"" mobile/app.json > mobile/app.json.tmp \
    && mv mobile/app.json.tmp mobile/app.json \
    || die "failed to bump app.json version."
  ok "app.json version → ${MOBILE_VERSION}"

  # Build with the STORE-distribution profile (App Store signing / Android AAB) —
  # NOT the internal 'preview' profile, whose iOS ad-hoc IPA cannot reach
  # TestFlight. EXPO_NO_CAPABILITY_SYNC works around an eas-cli bug that fails
  # patching iOS capabilities already enabled on the App ID. Signing credentials
  # live on EAS (created once, interactively), so this runs non-interactively.
  info "eas build --profile ${STORE_BUILD_PROFILE} --platform ${PLATFORM}…"
  ( cd mobile && EXPO_NO_CAPABILITY_SYNC=1 eas build --profile "$STORE_BUILD_PROFILE" --platform "$PLATFORM" --non-interactive ) \
    || die "eas build failed."
  info "eas submit --profile ${PROFILE} --platform ${PLATFORM} (latest build)…"
  ( cd mobile && eas submit --profile "$PROFILE" --platform "$PLATFORM" --latest --non-interactive ) \
    || die "eas submit failed."
  MECHANISM="build"
else
  # §6.1/§6.2 — JS-only OTA. Live to installed builds on this channel in minutes.
  info "eas update --branch ${CHANNEL}…"
  ( cd mobile && eas update --branch "$CHANNEL" --message "$MSG" --non-interactive ) \
    || die "eas update failed."
  MECHANISM="update"
fi
ok "shipped ${TAG} via ${MECHANISM} to the ${CHANNEL} channel"

# ── Record the ship §6.4 ──────────────────────────────────────────────────────
# Out-of-band (never rewrites the shared tag). The next cut reads .commit as the
# base of its change-type range. Git-ignored — this is local ship state.
cat > "$LAST_SHIPPED_FILE" <<EOF
{
  "tag": "${TAG}",
  "commit": "$(git rev-parse HEAD)",
  "channel": "${CHANNEL}",
  "mechanism": "${MECHANISM}",
  "verified": $([[ "$RUN_E2E" -eq 1 ]] && echo true || echo false)
}
EOF
ok "recorded ship in ${LAST_SHIPPED_FILE}"
echo "  EAS dashboard: https://expo.dev/accounts/haroldmei/projects/skillforge/updates"
