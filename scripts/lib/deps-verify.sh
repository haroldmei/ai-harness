#!/usr/bin/env bash
# deps-verify.sh — did the npm-workspaces install actually LAND?
#
# `npm ci` can exit 0 and still leave a workspace unresolvable. When that workspace is
# `mobile/`, `mobile/tsconfig.json`'s `extends: expo/tsconfig.base` fails to resolve and ALL
# ~154 mobile test files die at TRANSFORM time — before a single assertion runs. The `unit`
# gate goes red with a stack trace that names no product code, and every consumer of that
# result misreads it:
#   #2124  agent-inbox blamed the diff, burning three auto-fix rounds on an innocent test.
#   #2438  agent-pr-merger re-ran the gates on the bare base in the SAME unprovisioned
#          worktree, got the SAME red (a missing package is perfectly deterministic, so the
#          anti-flake confirmation re-run confirms it), concluded `main` itself was red, and
#          parked the whole merge queue at `merge-stuck` + a p0 issue. `main` was green.
#
# #2124 fixed this for agent-inbox.sh alone, inline. agent-pr-merger.sh and agent-pr-fixer.sh
# carry the same bare `npm ci` and the same trust in its exit code, which is how the class came
# back. This file is the ONE implementation all three share — same reasoning as
# lib/gate-reason.sh being the one gate-failure-reason extractor.
#
# Usage:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deps-verify.sh"
#   missing="$(deps_unresolved_summary "$wt")"     # "" when healthy
#
# Dependency-free by design (grep + sed + jq), so it can run before/without an install.

# The bare package specifier a tsconfig `extends`, if any.
# grep, not a JSON parser: these files are JSONC, and `"@/*"` paths break naive
# comment-stripping regexes (they contain a literal `/*`).
deps_tsconfig_bare_extends() { # <tsconfig> → bare specifier, or nothing
  grep -oE '"extends"[[:space:]]*:[[:space:]]*"[^"]+"' "$1" 2>/dev/null | head -1 \
    | sed -E 's/.*"([^"]+)"$/\1/' | grep -vE '^[./]' || true
}

# Walk up for node_modules/<pkg>, exactly as node resolution does. Not `ls node_modules/<pkg>`
# in the workspace: npm workspaces HOIST, so a healthy `mobile` dep usually lives in the root
# node_modules — while `expo` specifically is NOT hoistable and lives in mobile/node_modules.
# Only the walk-up answers both cases.
deps_pkg_installed() { # <startdir> <pkg>
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -d "$d/node_modules/$2" ] && return 0
    d="$(dirname "$d")"
  done
  return 1
}

# Only THIS repo's own workspaces — the root plus the entries of the root package.json
# `workspaces` array. A depth glob (`$root/*/*/tsconfig.json`) reaches straight into
# `node_modules/<pkg>/`, and ~50 hoisted packages ship a root tsconfig.json of which ~20
# `extends` a bare specifier that is THEIR OWN devDependency and is never installed here
# (`@ljharb/tsconfig`, `expo-module-scripts/tsconfig.base`, `@tsconfig/node18`, `tsex`, …).
# Scanning those would report a nonsense missing-dep list that no `npm install` can fix.
deps_workspace_dirs() { # <root> → one directory per line
  local root="$1" globs g d
  printf '%s\n' "$root"
  globs="$(jq -r 'if (.workspaces|type) == "array" then .workspaces[] elif (.workspaces|type) == "object" then (.workspaces.packages // [])[] else empty end' \
            "$root/package.json" 2>/dev/null || true)"
  [ -n "$globs" ] || return 0
  while read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2086  # $g is a workspace GLOB (packages/*) — must expand
    for d in "$root"/$g; do [ -d "$d" ] && printf '%s\n' "$d"; done
  done <<<"$globs"
}

# "<pkg> (<workspace>)" for every workspace whose tsconfig extends a package that cannot be
# resolved from it. Empty output = the install landed.
deps_unresolved() { # <root>
  local root="$1" d f spec pkg
  while read -r d; do
    [ -n "$d" ] || continue
    case "$d" in */node_modules|*/node_modules/*) continue;; esac   # belt and braces
    f="$d/tsconfig.json"; [ -f "$f" ] || continue
    spec="$(deps_tsconfig_bare_extends "$f")"; [ -n "$spec" ] || continue
    pkg="$(printf '%s\n' "$spec" | sed -E 's#^(@[^/]+/[^/]+|[^/]+).*#\1#')"
    deps_pkg_installed "$d" "$pkg" || printf '%s (%s)\n' "$pkg" "${d#"$root"/}"
  done <<<"$(deps_workspace_dirs "$root")"
  deps_workspace_unlinked "$root"
}

# The `extends` check above only catches a workspace whose OWN tsconfig points outside itself
# (mobile → expo) — it is blind when the workspace evicted mid-run is a SIBLING with no bare
# `extends` at all (frontend, packages/api-client, extensions/vscode all have none in this repo).
# npm workspaces always symlinks every member into the root node_modules by its own package.json
# `name` (verified against this repo's own node_modules: node_modules/skillforge-frontend →
# ../frontend, node_modules/@skillforge/api-client → ../../packages/api-client); a per-package
# `npm ci` in a concurrent stage resolves the root lockfile but rewrites only its own subtree,
# deleting that symlink for every sibling it didn't touch. This is the other half of the
# eviction class deps_unresolved() exists to catch (agent-pr-merger.sh's "installs only its own
# subtree and evicts its siblings mid-run", #2395/#2438). A workspace member is declared by
# definition — it came from deps_workspace_dirs(), i.e. the root package.json `workspaces` array
# — so unlike deps_unresolved() this needs no separate deps_pkg_declared() gate.
deps_workspace_unlinked() { # <root> → "<pkg> (<workspace>)" per evicted workspace
  local root="$1" d f name
  while read -r d; do
    [ -n "$d" ] || continue
    [ "$d" != "$root" ] || continue
    case "$d" in */node_modules|*/node_modules/*) continue;; esac
    f="$d/package.json"; [ -f "$f" ] || continue
    name="$(jq -r '.name // empty' "$f" 2>/dev/null)"
    [ -n "$name" ] || continue
    [ -d "$root/node_modules/$name" ] && continue
    printf '%s (%s)\n' "$name" "${d#"$root"/}"
  done <<<"$(deps_workspace_dirs "$root")"
}

# `; ` cannot be a `paste -d` separator: -d takes a delimiter LIST that CYCLES, so three items
# would join as "a;b c" — `;` then a bare space. Join on `;` alone, then space it out.
deps_join() { paste -sd';' - | sed 's/;/; /g'; }

# The one call most callers want: a single `; `-joined line, empty when the tree is healthy.
deps_unresolved_summary() { # <root>
  deps_unresolved "$1" | deps_join
}

# Is <pkg> DECLARED as a dependency of <workspace-dir> (or the repo root)? An unresolved import
# whose package is declared nowhere was never going to be there — a PR that deleted it from
# package.json (or added a consumer without declaring it) broke the tree itself; that is a code
# defect, not an install gap, no matter how deterministically it reproduces (#2438's classifier
# must not excuse it).
deps_pkg_declared() { # <root> <workspace-dir> <pkg>
  local root="$1" wsdir="$2" pkg="$3" f
  for f in "$wsdir/package.json" "$root/package.json"; do
    [ -f "$f" ] || continue
    jq -e --arg p "$pkg" \
      '((.dependencies // {}) + (.devDependencies // {}) + (.peerDependencies // {})) | has($p)' \
      "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

# 0 (true) only when EVERY unresolved workspace/package pair under <root> is a DECLARED
# dependency that simply failed to install — the genuinely environmental shape (#2438). A missing
# package that is declared nowhere means the tree itself is broken by the code, not the install,
# and callers must not wave that off as environmental.
#
# Deliberately does not re-walk deps_workspace_unlinked(): an evicted WORKSPACE (as opposed to a
# missing third-party package) is declared by construction — it is a member of the root
# package.json `workspaces` array, which is how deps_workspace_dirs() found it in the first
# place — so it can never fail the "declared nowhere" check and needs no separate gate here.
deps_unresolved_all_declared() { # <root>
  local root="$1" d f spec pkg
  while read -r d; do
    [ -n "$d" ] || continue
    case "$d" in */node_modules|*/node_modules/*) continue;; esac
    f="$d/tsconfig.json"; [ -f "$f" ] || continue
    spec="$(deps_tsconfig_bare_extends "$f")"; [ -n "$spec" ] || continue
    pkg="$(printf '%s\n' "$spec" | sed -E 's#^(@[^/]+/[^/]+|[^/]+).*#\1#')"
    deps_pkg_installed "$d" "$pkg" && continue
    deps_pkg_declared "$root" "$d" "$pkg" || return 1
  done <<<"$(deps_workspace_dirs "$root")"
  return 0
}
