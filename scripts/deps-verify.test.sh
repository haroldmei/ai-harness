#!/usr/bin/env bash
# Unit suite for scripts/lib/deps-verify.sh — the one answer to "did the npm-workspaces install
# actually land?", shared by agent-inbox.sh (#2124), agent-pr-fixer.sh and agent-pr-merger.sh
# (#2438). Hermetic: builds throwaway trees under mktemp, touches no network and no real install.
#
# Why this is gated at all: the check is the ONLY thing standing between an incomplete `npm ci`
# (which exits 0) and a red `unit` gate that names no product code. Every consumer of that red has
# historically misread it — the inbox blamed the diff, the merger blamed `main` and wedged the
# whole merge queue. A false NEGATIVE here silently restores that; a false POSITIVE bricks every
# tick against a perfectly healthy tree. Both directions are asserted below.
#
# Cases:
#   D-1  a healthy hoisted install → nothing unresolved
#   D-2  the #2124/#2438 shape: mobile/ without expo → reported, named by workspace
#   D-3  expo resolved from the workspace's OWN node_modules (expo is NOT hoistable)
#   D-4  expo resolved by walking UP to the root node_modules (hoisted deps)
#   D-5  only DECLARED workspaces are scanned — never node_modules' own tsconfigs
#   D-6  relative `extends` ("./base.json") is not a package and is never reported
#   D-7  scoped specifiers keep both segments (@org/pkg), not just @org
#   D-8  JSONC with a `"@/*"` path does not break the extends reader
#   D-9  three unresolved deps join with a real "; ", not a cycling paste delimiter
#   D-10 a workspace GLOB (packages/*) expands; a glob matching nothing is not an error
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/test-env.sh
source "$ROOT/scripts/lib/test-env.sh"
test_env_scrub
# shellcheck source=scripts/lib/deps-verify.sh
source "$ROOT/scripts/lib/deps-verify.sh"

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

# mktree <dir> <workspaces-json>  — a repo root with a package.json declaring <workspaces-json>
mktree() {
  mkdir -p "$1"
  printf '{"name":"t","workspaces":%s}\n' "$2" > "$1/package.json"
}
# mkws <root> <dir> <extends>  — a workspace whose tsconfig extends <extends>, self-linked into
# the root node_modules by its own package name (npm workspaces always does this — verified
# against this repo's own node_modules: skillforge-frontend -> ../frontend, etc.) so a workspace
# is "healthy" (self-link present) by default; tests that model an EVICTED sibling remove it.
mkws() {
  mkdir -p "$1/$2"
  printf '{\n  "compilerOptions": { "paths": { "@/*": ["./src/*"] } },\n  "extends": "%s"\n}\n' "$3" \
    > "$1/$2/tsconfig.json"
  printf '{"name":"%s"}\n' "$(basename "$2")" > "$1/$2/package.json"
  mkdir -p "$1/node_modules/$(basename "$2")"
}
# mkpkg <dir> — an installed package at <dir> (…/node_modules/<name>)
mkpkg() { mkdir -p "$1"; printf '{"name":"x"}\n' > "$1/package.json"; }

T="$(mktemp -d)"
trap 'rm -rf "$T" 2>/dev/null || true' EXIT

echo "D-1 — a healthy hoisted install reports nothing"
A="$T/d1"; mktree "$A" '["frontend","mobile"]'
mkws "$A" frontend "@tsconfig/vite-react/tsconfig.json"
mkws "$A" mobile   "expo/tsconfig.base"
mkpkg "$A/node_modules/@tsconfig/vite-react"; mkpkg "$A/node_modules/expo"
eq "$(deps_unresolved_summary "$A")" "" "a complete install is silent"

echo "D-2 — mobile/ without expo is reported, named by workspace (#2124 / #2438)"
B="$T/d2"; mktree "$B" '["frontend","mobile"]'
mkws "$B" frontend "@tsconfig/vite-react/tsconfig.json"
mkws "$B" mobile   "expo/tsconfig.base"
mkpkg "$B/node_modules/@tsconfig/vite-react"
eq "$(deps_unresolved_summary "$B")" "expo (mobile)" "the missing package and its workspace are both named"

echo "D-3 — expo resolves from the workspace's OWN node_modules (it is not hoistable)"
C="$T/d3"; mktree "$C" '["mobile"]'
mkws "$C" mobile "expo/tsconfig.base"
mkpkg "$C/mobile/node_modules/expo"
eq "$(deps_unresolved_summary "$C")" "" "a nested (non-hoisted) install counts as resolved"

echo "D-4 — a hoisted dep resolves by walking UP to the root node_modules"
D="$T/d4"; mktree "$D" '["packages/api-client"]'
mkws "$D" packages/api-client "some-base/tsconfig"
mkpkg "$D/node_modules/some-base"
eq "$(deps_unresolved_summary "$D")" "" "the walk-up finds a hoisted package"

echo "D-5 — only DECLARED workspaces are scanned, never node_modules' own tsconfigs"
# ~50 hoisted packages ship a root tsconfig.json and ~20 of those extend a bare specifier that is
# THEIR OWN devDependency, never installed here. A depth glob reported them as missing deps on
# every healthy tree, which would brick every tick with a list no `npm install` can fix.
E="$T/d5"; mktree "$E" '["mobile"]'
mkws "$E" mobile "expo/tsconfig.base"; mkpkg "$E/mobile/node_modules/expo"
mkdir -p "$E/node_modules/call-bind-apply-helpers"
printf '{ "extends": "@ljharb/tsconfig" }\n' > "$E/node_modules/call-bind-apply-helpers/tsconfig.json"
eq "$(deps_unresolved_summary "$E")" "" "a third-party package's own tsconfig is never scanned"

echo "D-6 — a relative extends is not a package and is never reported"
F="$T/d6"; mktree "$F" '["mobile"]'
mkws "$F" mobile "./tsconfig.base.json"
eq "$(deps_unresolved_summary "$F")" "" "./relative extends is ignored"
mkws "$F" mobile "../shared/tsconfig.json"
eq "$(deps_unresolved_summary "$F")" "" "../relative extends is ignored"

echo "D-7 — a scoped specifier keeps BOTH segments"
G="$T/d7"; mktree "$G" '["frontend"]'
mkws "$G" frontend "@tsconfig/node18/tsconfig.json"
eq "$(deps_unresolved_summary "$G")" "@tsconfig/node18 (frontend)" "@org/pkg is not truncated to @org"
# …and it resolves against the full scoped path, not the scope directory.
mkdir -p "$G/node_modules/@tsconfig"
eq "$(deps_unresolved_summary "$G")" "@tsconfig/node18 (frontend)" "an empty scope directory does not count as installed"
mkpkg "$G/node_modules/@tsconfig/node18"
eq "$(deps_unresolved_summary "$G")" "" "the scoped package itself does"

echo "D-8 — JSONC with a \"@/*\" path does not break the extends reader"
# `"@/*"` contains a literal /*, which is what makes comment-stripping regex parsers unsafe here —
# hence the grep-based reader. mkws writes that path into every fixture; assert it explicitly.
H="$T/d8"; mktree "$H" '["mobile"]'
mkws "$H" mobile "expo/tsconfig.base"
grep -qF '"@/*"' "$H/mobile/tsconfig.json" && ok "the fixture really contains the /* trap" || bad "fixture lost its /* path"
eq "$(deps_tsconfig_bare_extends "$H/mobile/tsconfig.json")" "expo/tsconfig.base" "the specifier is read correctly anyway"

echo "D-9 — three unresolved deps join with a real '; ' (not a cycling paste delimiter)"
# `paste -sd'; '` takes a delimiter LIST that CYCLES, so three items joined as "a;b c" — the
# second separator a bare space. Two workspaces cannot catch it; the bug starts at separator two.
I="$T/d9"; mktree "$I" '["desktop","mobile","tablet"]'
mkws "$I" mobile  "expo/tsconfig.base"
mkws "$I" tablet  "react-native-tv/tsconfig"
mkws "$I" desktop "electron-tsconfig/base"
line="$(deps_unresolved_summary "$I")"
eq "$(printf '%s' "$line" | grep -o '; ' | wc -l | tr -d ' ')" "2" "three items → exactly two '; ' separators"
case "$line" in *"electron-tsconfig (desktop); expo (mobile); react-native-tv (tablet)"*) ok "joined in full" ;;
  *) bad "unexpected join: $line" ;; esac

echo "D-10 — a workspace GLOB expands, and one matching nothing is not an error"
J="$T/d10"; mktree "$J" '["packages/*"]'
mkws "$J" packages/api-client "some-base/tsconfig"
mkws "$J" packages/ui         "other-base/tsconfig"
line="$(deps_unresolved_summary "$J")"
case "$line" in *"some-base (packages/api-client)"*) ok "glob reached the first package" ;; *) bad "glob missed packages/api-client: $line" ;; esac
case "$line" in *"other-base (packages/ui)"*)        ok "glob reached the second package" ;; *) bad "glob missed packages/ui: $line" ;; esac
K="$T/d10b"; mktree "$K" '["packages/*","extensions/*"]'
eq "$(deps_unresolved_summary "$K")" "" "a glob matching nothing yields no findings and no error"
L="$T/d10c"; mktree "$L" 'null'
eq "$(deps_unresolved_summary "$L")" "" "a package.json with no workspaces key is handled"

echo "D-11 — a declared-but-absent dependency is 'all declared' (a genuine install gap)"
M="$T/d11"; mktree "$M" '["mobile"]'
mkws "$M" mobile "expo/tsconfig.base"
ws_json="$(jq -c '.dependencies = {"expo":"*"}' "$M/mobile/package.json")"; printf '%s\n' "$ws_json" > "$M/mobile/package.json"
eq "$(deps_unresolved_summary "$M")" "expo (mobile)" "still reported as unresolved (nothing installed)"
deps_unresolved_all_declared "$M" && ok "declared-but-absent counts as 'all declared'" || bad "a declared dependency was not recognized"

echo "D-12 — a dependency declared NOWHERE is NOT 'all declared' (a code defect, not an install gap)"
N="$T/d12"; mktree "$N" '["mobile"]'
mkws "$N" mobile "expo/tsconfig.base"
eq "$(deps_unresolved_summary "$N")" "expo (mobile)" "still reported as unresolved"
deps_unresolved_all_declared "$N" && bad "an undeclared dependency was wrongly excused as 'all declared'" \
  || ok "an undeclared dependency is correctly NOT 'all declared'"

echo "D-13 — declaration at the ROOT package.json also counts (not just the workspace's own)"
O="$T/d13"; mktree "$O" '["mobile"]'
mkws "$O" mobile "expo/tsconfig.base"
ws_json="$(jq -c '.dependencies = {"expo":"*"}' "$O/package.json")"; printf '%s\n' "$ws_json" > "$O/package.json"
deps_unresolved_all_declared "$O" && ok "a root-level declaration is honored" || bad "root package.json declaration was not checked"

echo "D-14 — a resolved dependency needs no declaration check at all"
P="$T/d14"; mktree "$P" '["mobile"]'
mkws "$P" mobile "expo/tsconfig.base"; mkpkg "$P/mobile/node_modules/expo"
eq "$(deps_unresolved_summary "$P")" "" "nothing unresolved"
deps_unresolved_all_declared "$P" && ok "a fully-resolved tree is vacuously 'all declared'" || bad "a healthy tree should never fail this check"

echo "D-15 — a workspace with NO bare 'extends' (frontend/packages/api-client/extensions/vscode in this repo have none) is still caught when EVICTED, closing the blind spot the extends-only check has"
# This is #2438's other half: `agent-pr-merger.sh` says a per-package `npm ci` in a concurrent
# stage "installs only its own subtree and evicts its siblings mid-run". If the evicted sibling
# has no bare `extends`, the extends-only check (deps_unresolved's first loop) never looks at it.
Q="$T/d15"; mktree "$Q" '["frontend","mobile"]'
mkws "$Q" frontend "./tsconfig.base.json"   # relative extends — invisible to the extends-only check
mkws "$Q" mobile   "expo/tsconfig.base"; mkpkg "$Q/mobile/node_modules/expo"
eq "$(deps_unresolved_summary "$Q")" "" "a healthy tree (both workspaces self-linked) reports nothing"
rm -rf "$Q/node_modules/frontend"   # simulate mobile/'s npm ci evicting frontend's root symlink
eq "$(deps_unresolved_summary "$Q")" "frontend (frontend)" "the evicted sibling is reported by its own package name, even though it has no 'extends' for the old check to catch"
deps_unresolved_all_declared "$Q" && ok "an evicted workspace is treated as environmental (it is declared by definition — it's a member of the workspaces array)" \
  || bad "an evicted workspace's own symlink must never fail the 'declared' check"

echo "D-16 — the ROOT workspace itself is never checked for a self-link (it has no entry under its own node_modules)"
R="$T/d16"; mktree "$R" '["mobile"]'
mkws "$R" mobile "expo/tsconfig.base"; mkpkg "$R/mobile/node_modules/expo"
eq "$(deps_unresolved_summary "$R")" "" "root's own package.json name ('t') is correctly never looked up in its own node_modules"

echo; echo "deps-verify: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
