#!/usr/bin/env bash
# cut-release.sh — gate, tag, and push a release tag that triggers the GitHub Actions deploy.
#
#   scripts/cut-release.sh staging [X.Y.Z]   → tags  staging-vX.Y.Z  → .github/workflows/deploy-staging.yml
#   scripts/cut-release.sh prod    [X.Y.Z]   → tags  vX.Y.Z          → .github/workflows/deploy-prod.yml
#
# If X.Y.Z is omitted, the next PATCH after the latest matching tag is used
# (staging and prod version lines are tracked independently).
#
# It is the TAG push — not a push to main — that triggers the deploy workflow.
# This script never pushes commits to main; main must already be in sync with origin.
#
# ── The pre-tag gate ──────────────────────────────────────────────────────────
# Before tagging, the project gates run on THIS checkout (the commit being
# released) and the release ABORTS on any failure — nothing is tagged or pushed
# unless green.
#
# Honest note on "full end-to-end": `quality-gates.sh --tier launch` only REQUIRES
# typecheck/lint/unit; its e2e gate skips-as-pass unless the real stack is booted.
# So by default this script makes the check a TRUE browser-journey run by booting
# the local e2e stack and promoting e2e to a required gate:
#     E2E_LOCAL_STACK=1 REQUIRED_GATES="typecheck lint unit e2e" \
#         scripts/quality-gates.sh --tier launch
# That needs the Docker daemon running. Pass --no-e2e to fall back to the literal
# unit-tier gate (faster, but NOT a full end-to-end test).
#
# Flags:
#   --no-e2e        run only `quality-gates.sh --tier launch` (typecheck/lint/unit; no browser e2e)
#   --skip=A,B      forward `--skip A,B` to the gate, dropping NON-required gates from the run.
#                   (Required gates [typecheck lint unit e2e] still FAIL if named — fail-closed.)
#                   Used for staging cuts to scope out pre-existing cosmetic debt (e.g. a11y,visual).
#   --yes           skip the interactive confirmation (for non-interactive use)
#   --dry-run       do everything (incl. the gate) EXCEPT the final `git tag` + `git push`
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { printf '\033[31mcut-release: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok() { printf '\033[32m✓ %s\033[0m\n' "$*"; }

# ── Parse args ────────────────────────────────────────────────────────────────
ENVNAME="" VERSION="" RUN_E2E=1 ASSUME_YES=0 DRY_RUN=0 SKIP_GATES=""
for arg in "$@"; do
  case "$arg" in
    staging|prod) ENVNAME="$arg" ;;
    --no-e2e)     RUN_E2E=0 ;;
    --skip=*)     SKIP_GATES="${arg#--skip=}" ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    [0-9]*.[0-9]*.[0-9]*) VERSION="$arg" ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg (expected staging|prod [X.Y.Z] [--no-e2e] [--skip=A,B] [--yes] [--dry-run])" ;;
  esac
done
[[ -n "$ENVNAME" ]] || die "first argument must be 'staging' or 'prod'"

case "$ENVNAME" in
  staging) PREFIX="staging-v" ;;
  prod)    PREFIX="v" ;;
esac

# ── Repo safety: on main, clean, in sync with origin ─────────────────────────
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "releases must be cut from 'main' (on '$BRANCH'). Checkout main first."
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty — commit or stash before releasing."
info "fetching origin…"
git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
  || die "local main is not in sync with origin/main — pull/push so the tagged commit is the published HEAD."
ok "on main @ $(git rev-parse --short HEAD), clean, in sync with origin"

# ── Resolve the version / tag ────────────────────────────────────────────────
# strict X.Y.Z matcher; ignores malformed legacy tags like 'staging-v0.01'
strict_re="^${PREFIX//./\\.}[0-9]+\.[0-9]+\.[0-9]+$"
latest="$(git tag --list "${PREFIX}*" | grep -E "$strict_re" | sed "s/^${PREFIX}//" | sort -V | tail -1 || true)"

if [[ -z "$VERSION" ]]; then
  if [[ -z "$latest" ]]; then
    VERSION="0.1.0"
    info "no existing ${PREFIX}X.Y.Z tag — starting at $VERSION"
  else
    IFS='.' read -r MA MI PA <<<"$latest"
    VERSION="${MA}.${MI}.$((PA + 1))"
    info "latest ${ENVNAME} tag is ${PREFIX}${latest} → next patch ${PREFIX}${VERSION}"
  fi
else
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got '$VERSION')"
fi

TAG="${PREFIX}${VERSION}"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && die "tag ${TAG} already exists locally."
# Was: `git ls-remote … | grep -q . && die "…"`. Two problems, both of which made an EXISTING
# tag read as free — the fail-open direction on the one check standing between a re-cut and a
# clobbered release (issue #2387, M2):
#   1. `&&` fires only on a zero pipeline status. If ls-remote failed (network, auth, remote
#      gone) the status was non-zero, `die` did not run, and the script proceeded as though
#      the tag were available.
#   2. Under this file's `set -o pipefail`, `grep -q` exits on its first match and SIGPIPEs
#      ls-remote, so even the SUCCESS path could report 141 and skip the `die`.
# Capture status and output separately, and fail closed when the remote cannot be consulted.
remote_tag_out="$(git ls-remote --tags --quiet origin "refs/tags/${TAG}" 2>&1)"; remote_tag_rc=$?
[[ "$remote_tag_rc" -ne 0 ]] && die "cannot reach origin to check whether tag ${TAG} exists (git ls-remote exit ${remote_tag_rc}): ${remote_tag_out}"
[[ -n "${remote_tag_out//[[:space:]]/}" ]] && die "tag ${TAG} already exists on origin."

# prod tags must be plain semver so deploy-prod's 'v[0-9]+.[0-9]+.[0-9]+' filter matches
if [[ "$ENVNAME" == "prod" && ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "computed prod tag '${TAG}' would NOT match the deploy-prod trigger — aborting."
fi

# ── Pre-tag gate ──────────────────────────────────────────────────────────────
if [[ "$RUN_E2E" -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
    || die "e2e requested but the Docker daemon is unreachable. Start Docker, or re-run with --no-e2e (NOT a full e2e)."
  info "running FULL gate (typecheck/lint/unit + browser e2e on the local stack)…"
  GATE_ENV=(E2E_LOCAL_STACK=1 REQUIRED_GATES="typecheck lint unit e2e")
else
  info "running unit-tier gate only (--no-e2e: typecheck/lint/unit, NO browser e2e)…"
  GATE_ENV=()
fi

GATE_ARGS=(--keep-going --tier launch)
if [[ -n "$SKIP_GATES" ]]; then
  GATE_ARGS+=(--skip "$SKIP_GATES")
  info "scoping out non-required gates: ${SKIP_GATES} (required gates still fail-closed if named)"
fi
if env "${GATE_ENV[@]}" scripts/quality-gates.sh "${GATE_ARGS[@]}"; then
  ok "gates green on $(git rev-parse --short HEAD)"
else
  die "gates FAILED — not tagging. Fix the failures and re-run."
fi

# ── Confirm ──────────────────────────────────────────────────────────────────
WF=$([[ "$ENVNAME" == "prod" ]] && echo "deploy-prod.yml (GCP PRODUCTION)" || echo "deploy-staging.yml (GCP staging)")
echo
printf '  Tag:     \033[1m%s\033[0m\n' "$TAG"
printf '  Commit:  %s  %s\n' "$(git rev-parse --short HEAD)" "$(git log -1 --pretty=%s)"
printf '  Deploys: %s\n' "$WF"
echo
if [[ "$DRY_RUN" -eq 1 ]]; then ok "--dry-run: gate passed; NOT tagging or pushing."; exit 0; fi
if [[ "$ASSUME_YES" -ne 1 ]]; then
  prompt="Tag and push ${TAG}?"
  [[ "$ENVNAME" == "prod" ]] && prompt="⚠️  PRODUCTION release — tag and push ${TAG}?"
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by user — nothing tagged."
fi

# ── Tag + push (the tag push is what triggers the workflow) ───────────────────
info "tagging ${TAG}…"
git tag -a "$TAG" -m "release: ${TAG}"
info "pushing ${TAG} to origin…"
git push origin "$TAG"
ok "pushed ${TAG} — deploy triggered."
echo "  Watch: https://github.com/haroldmei/skillforge-ai/actions"
[[ "$ENVNAME" == "prod" ]] && echo "  (prod waits for required-reviewer approval in the 'production' GitHub Environment before any step runs.)"
