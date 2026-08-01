#!/usr/bin/env bash
# Hermetic test for scripts/ingest-help.sh — the repo-root wrapper around the help
# corpus ingester (#2126, S1-2). Exercises only the wrapper's own job: resolve the
# backend, pass arguments through, and propagate the exit code from any cwd.
#
# The parser, the upsert and the CLI have real pytest suites
# (backend/tests/unit/test_ingest_help*.py, backend/tests/integration/…); this file
# exists so a broken wrapper — the thing CI actually invokes — cannot be green
# just because the Python underneath it is fine.
#
#   Run: bash scripts/ingest-help.test.sh    (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/ingest-help.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# The wrapper needs the backend importable (app.models.help_corpus + rag_service).
# Where it isn't, skip loudly rather than reporting a green run that tested nothing.
if ! ( cd "$ROOT/backend" && python -c 'import app.models.help_corpus' ) >/dev/null 2>&1; then
  echo "ingest-help.test: SKIP — backend deps not importable (pip install -e backend)"
  exit 0
fi

article() { # <slug>
  printf -- '---\nslug: %s\ntitle: %s\naudience: [org_admin]\ntopic: subscriptions\nvisibility: public\nowner: content-team\nupdated: 2026-07-25\n---\n\nBody for %s.\n' "$1" "$1" "$1"
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/help"
article seats > "$T/help/seats.mdx"

echo "Scenario 1 — a valid corpus validates and exits 0"
out="$(bash "$WRAPPER" --check --root "$T/help" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 on a valid corpus" || bad "expected exit 0, got $rc ($out)"
case "$out" in *"1 article(s) valid"*) ok "reports the article count";; *) bad "unexpected output: $out";; esac

echo "Scenario 2 — a malformed article fails loudly and names the path"
printf '# no frontmatter\n' > "$T/help/broken.mdx"
out="$(bash "$WRAPPER" --check --root "$T/help" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on an invalid corpus" || bad "expected exit 1, got $rc"
case "$out" in *"broken.mdx"*) ok "names the offending file";; *) bad "did not name the file: $out";; esac
rm -f "$T/help/broken.mdx"

echo "Scenario 3 — cwd-independent (the wrapper's entire reason to exist)"
out="$( cd / && bash "$WRAPPER" --check --root "$T/help" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "runs from / as well as from the repo root" || bad "cwd-dependent: $rc ($out)"

echo "Scenario 4 — a missing corpus root is an error, never an empty corpus"
out="$(bash "$WRAPPER" --check --root "$T/nope" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on a missing root" || bad "expected exit 1, got $rc"
case "$out" in *"does not exist"*) ok "says the root is missing";; *) bad "unclear error: $out";; esac

printf '\ningest-help.test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
