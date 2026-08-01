#!/usr/bin/env bash
# Tests for cut-mobile-release.sh — exercises argument validation, the §4
# preconditions, and both §6 dry-run ship paths against a real sandbox git repo
# with PATH-stubbed externals (eas / maestro / adb / quality-gates / the mobile
# sub-scripts). No emulator, Expo account, or network is touched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUT_SCRIPT="$SCRIPT_DIR/cut-mobile-release.sh"
# shellcheck source=scripts/lib/test-env.sh
source "$SCRIPT_DIR/lib/test-env.sh"
test_env_scrub
# The stub dir SUBSTITUTES for PATH rather than being prepended to it (issue #2387, M7).
# Prepending left the host's real binaries reachable on the tail, so "no maestro → abort"
# passed or failed on whether the developer had ~/.maestro/bin on PATH — measured 12/12
# without it, 11/12 with it. Only these real tools stay reachable; eas / maestro / adb
# deliberately do NOT, so removing a stub genuinely removes the tool.
STUB_KEEP_TOOLS=(bash sh env git jq node npx python3 sed awk grep cat mktemp date dirname basename tr head tail sort uniq wc find xargs rm mkdir cp mv chmod ln printf ls touch tee diff realpath readlink)
PASS=0 FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; echo "      $2"; FAIL=$((FAIL+1)); }

# assert that running the sandboxed cut with $1=args produces exit $2 and output matching regex $3
assert_run() {
  local args="$1" want_rc="$2" want_re="$3" label="$4"
  local out rc
  out="$( cd "$REPO" && PATH="$(test_env_stub_path "$STUB" "${STUB_KEEP_TOOLS[@]}")" bash scripts/cut-mobile-release.sh $args </dev/null 2>&1 )"; rc=$?
  if [[ "$rc" -ne "$want_rc" ]]; then
    fail "$label" "exit $rc≠$want_rc; out: $(echo "$out" | tail -1)"; return
  fi
  if [[ -n "$want_re" ]] && ! grep -qE "$want_re" <<<"$out"; then
    fail "$label" "missing /$want_re/; out: $(echo "$out" | tail -2 | tr '\n' '|')"; return
  fi
  pass "$label"
}

# ── Sandbox: a real repo on main, clean, in sync with a bare origin, HEAD tagged.
make_sandbox() {
  ROOTDIR="$(mktemp -d)"
  REPO="$ROOTDIR/repo"; ORIGIN="$ROOTDIR/origin.git"; STUB="$ROOTDIR/stub"
  mkdir -p "$STUB"
  git init --bare --quiet "$ORIGIN"
  git init -b main --quiet "$REPO"
  ( cd "$REPO" || exit 1
    git config user.email t@t.co; git config user.name t
    mkdir -p scripts mobile/scripts
    cp "$CUT_SCRIPT" scripts/cut-mobile-release.sh
    # Controllable fakes for the orchestrated sub-scripts (exit via env in the stub PATH).
    printf '#!/usr/bin/env bash\nexit ${GATE_RC:-0}\n'      > scripts/quality-gates.sh
    printf '#!/usr/bin/env bash\necho classified\nexit ${CHANGETYPE_RC:-0}\n' > mobile/scripts/check-change-type.sh
    printf '#!/usr/bin/env bash\nexit ${SUBMIT_RC:-0}\n'    > mobile/scripts/check-submit-config.sh
    chmod +x scripts/quality-gates.sh mobile/scripts/*.sh
    echo '{"name":"root"}' > package.json
    git add -A; git commit --quiet -m init
    git tag staging-v1.0.0
    git remote add origin "$ORIGIN"
    git push --quiet origin main --tags )
  # PATH stubs: eas (whoami ok, update/build/submit ok), maestro present, adb booted.
  printf '#!/usr/bin/env bash\ncase "$1" in whoami) echo tester;; *) : ;; esac\nexit 0\n' > "$STUB/eas"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/maestro"
  printf '#!/usr/bin/env bash\nif [ "$1" = devices ]; then printf "List\\nemulator-5554\\tdevice\\n"; fi\nexit 0\n' > "$STUB/adb"
  chmod +x "$STUB"/*
  export GATE_RC=0 CHANGETYPE_RC=0 SUBMIT_RC=0
}
cleanup() { [[ -n "${ROOTDIR:-}" ]] && rm -rf "$ROOTDIR"; }
trap cleanup EXIT

echo "cut-mobile-release.sh tests"
make_sandbox

# ── Argument validation (no repo state needed) ────────────────────────────────
assert_run ""                     1 "must be 'staging' or 'prod'"          "no env arg → error"
assert_run "staging --platform=x" 1 "platform must be"                      "bad platform → error"
assert_run "--help"               0 "cut-mobile-release"                    "--help prints header"
assert_run "bogus"                1 "unknown argument"                      "unknown arg → error"

# ── §4 preconditions ──────────────────────────────────────────────────────────
assert_run "staging --yes --dry-run"          0 "WOULD run 'eas update"     "clean+tagged+green → dry-run OTA plan"
assert_run "staging --no-e2e --yes --dry-run" 0 "UNVERIFIED"                "--no-e2e marks run unverified"

# native change → store-build plan (dormant)
CHANGETYPE_RC=1 assert_run "staging --yes --dry-run" 0 "store build"        "native change → store-build plan"
CHANGETYPE_RC=0

# gate failure aborts before shipping
GATE_RC=1 assert_run "staging --yes --dry-run" 1 "gates FAILED"            "red gates → abort"
GATE_RC=0

# no maestro on PATH (and not --no-e2e) → emulator precondition fails.
# NB: assert_run must run in THIS shell (not a subshell) or its PASS/FAIL
# increments are lost — an earlier version hid a test result this way.
rm -f "$STUB/maestro"
assert_run "staging --yes --dry-run" 1 "maestro CLI not installed"         "no maestro → abort"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/maestro"; chmod +x "$STUB/maestro"

# HEAD not tagged → abort
( cd "$REPO" && git tag -d staging-v1.0.0 >/dev/null && git push --quiet origin :refs/tags/staging-v1.0.0 )
assert_run "staging --yes --dry-run" 1 "not a staging release tag"          "untagged HEAD → abort"
( cd "$REPO" && git tag staging-v1.0.0 && git push --quiet origin --tags )

# prod on a staging-only tag line → abort (no v* tag present)
assert_run "prod --yes --dry-run" 1 "not a prod release tag"               "prod without v* tag → abort"

# dirty tree → abort
( cd "$REPO" && echo x > dirty.txt )
assert_run "staging --yes --dry-run" 1 "working tree is dirty"             "dirty tree → abort"
( cd "$REPO" && rm -f dirty.txt )

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
