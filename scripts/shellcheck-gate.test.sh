#!/usr/bin/env bash
# Hermetic tests for scripts/shellcheck-gate.sh (issue #2387).
#
# The gate exists because nothing linted scripts/. A gate nobody tests is the same
# failure one level up, so this suite drives it against throwaway script trees with a
# stubbed SHELLCHECK_BASELINE — no writes to the real baseline, no network.
#
#   Run: bash scripts/shellcheck-gate.test.sh   (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/shellcheck-gate.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v shellcheck >/dev/null 2>&1 || {
  echo "shellcheck not installed — skipping (the gate itself exits 77 in this case)"
  exit 0
}

# shellcheck source=scripts/lib/test-env.sh
source "$ROOT/scripts/lib/test-env.sh"
test_env_scrub

# Build a sandbox repo with its own scripts/ dir and run the REAL gate inside it.
# The gate cd's to its own parent, so it must be copied in rather than pointed at.
make_tree() { # <dir>
  local d="$1"
  mkdir -p "$d/scripts"
  cp "$GATE" "$d/scripts/shellcheck-gate.sh"
  chmod +x "$d/scripts/shellcheck-gate.sh"
}
run_gate() { # <dir> [args…]
  local d="$1"; shift
  ( cd "$d" && bash scripts/shellcheck-gate.sh "$@" 2>&1 )
}

# ── 1. A clean tree passes, and --update writes a baseline ───────────────────────
echo "Scenario 1 — clean tree: --update writes a baseline, check passes"
T1="$(mktemp -d)"; make_tree "$T1"
cat > "$T1/scripts/clean.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
main() { echo "hello"; }
main "$@"
EOF
run_gate "$T1" --update >/dev/null 2>&1
[ -f "$T1/scripts/shellcheck-baseline.txt" ] && ok "--update created the baseline" \
  || bad "--update created the baseline"
OUT="$(run_gate "$T1")"; RC=$?
[ "$RC" -eq 0 ] && ok "clean tree passes (exit 0)" || bad "clean tree passes (got $RC)"$'\n'"$OUT"

# ── 2. A NEW finding regresses the gate ──────────────────────────────────────────
# The whole point of the ratchet: pre-existing debt is tolerated, new debt is not.
echo "Scenario 2 — a newly-introduced warning fails the gate"
cat > "$T1/scripts/regress.sh" <<'EOF'
#!/usr/bin/env bash
# SC2164: cd without a guard — exactly the class that runs a gate in the wrong directory.
cd /tmp
echo done
EOF
OUT="$(run_gate "$T1")"; RC=$?
[ "$RC" -eq 1 ] && ok "new finding fails (exit 1)" || bad "new finding fails (got $RC)"$'\n'"$OUT"
grep -q 'SC2164' <<<"$OUT" && ok "the failure names the shellcheck code" \
  || bad "the failure names the shellcheck code"$'\n'"$OUT"
grep -q 'regress.sh' <<<"$OUT" && ok "the failure names the offending file" \
  || bad "the failure names the offending file"$'\n'"$OUT"

# ── 3. Budgeted debt is tolerated at its recorded count ──────────────────────────
echo "Scenario 3 — a finding at its budgeted count passes"
run_gate "$T1" --update >/dev/null 2>&1     # accept regress.sh's SC2164 as budget
OUT="$(run_gate "$T1")"; RC=$?
[ "$RC" -eq 0 ] && ok "budgeted finding passes after --update" \
  || bad "budgeted finding passes (got $RC)"$'\n'"$OUT"

# ── 4. MORE of the same code in the same file still fails ────────────────────────
# A per-file total, not a repo-wide one: the same defect spreading must not hide
# inside an existing budget line.
echo "Scenario 4 — the same code recurring beyond budget fails"
cat >> "$T1/scripts/regress.sh" <<'EOF'
cd /var
EOF
OUT="$(run_gate "$T1")"; RC=$?
[ "$RC" -eq 1 ] && ok "2 findings against a budget of 1 fails" \
  || bad "2 findings against a budget of 1 fails (got $RC)"$'\n'"$OUT"
grep -q 'budget 1' <<<"$OUT" && ok "the failure prints the budget it exceeded" \
  || bad "the failure prints the budget"$'\n'"$OUT"

# ── 5. Fixing a finding is a PASS, and is reported as ratchet-down slack ─────────
echo "Scenario 5 — fixing a finding passes and reports loose budget"
cat > "$T1/scripts/regress.sh" <<'EOF'
#!/usr/bin/env bash
cd /tmp || exit 1
echo done
EOF
OUT="$(run_gate "$T1")"; RC=$?
[ "$RC" -eq 0 ] && ok "an improvement passes by default" || bad "improvement passes (got $RC)"$'\n'"$OUT"
grep -qi 'ratchet it down' <<<"$OUT" && ok "slack budget prints the ratchet-down hint" \
  || bad "slack budget prints the hint"$'\n'"$OUT"
OUT="$(cd "$T1" && SHELLCHECK_STRICT_RATCHET=1 bash scripts/shellcheck-gate.sh 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "SHELLCHECK_STRICT_RATCHET=1 fails on a stale baseline" \
  || bad "STRICT_RATCHET fails on stale baseline (got $RC)"$'\n'"$OUT"

# ── 6. An UNPARSEABLE file is fatal and can never be baselined ───────────────────
# This is the regression that matters most: shellcheck reports nothing else about a
# file it cannot parse, so budgeting the parse error would silently exempt the whole
# script from linting. A comment line beginning "# shellcheck" does exactly this —
# it is read as a malformed directive (hit on this gate's own line 2 while writing it).
echo "Scenario 6 — a file shellcheck cannot parse is always fatal"
T6="$(mktemp -d)"; make_tree "$T6"
cat > "$T6/scripts/broken.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck-something not a real directive
cd /tmp || exit 1
EOF
run_gate "$T6" --update >/dev/null 2>&1        # try to bless it into the baseline
OUT="$(run_gate "$T6")"; RC=$?
[ "$RC" -eq 1 ] && ok "unparseable file fails even after --update" \
  || bad "unparseable file fails after --update (got $RC)"$'\n'"$OUT"
grep -qi 'could not PARSE' <<<"$OUT" && ok "the failure says the file is unlinted, not just noisy" \
  || bad "the failure explains the parse problem"$'\n'"$OUT"
grep -q 'broken.sh' <<<"$OUT" && ok "the parse failure names the file" \
  || bad "the parse failure names the file"$'\n'"$OUT"

# ── 7. A missing baseline is a failure with an actionable message, not a pass ────
echo "Scenario 7 — a missing baseline fails closed"
T7="$(mktemp -d)"; make_tree "$T7"
printf '#!/usr/bin/env bash\necho ok\n' > "$T7/scripts/x.sh"
OUT="$(run_gate "$T7")"; RC=$?
[ "$RC" -eq 1 ] && ok "no baseline → exit 1 (fails closed)" || bad "no baseline → exit 1 (got $RC)"$'\n'"$OUT"
grep -q -- '--update' <<<"$OUT" && ok "it tells you how to create one" \
  || bad "it tells you how to create one"$'\n'"$OUT"

rm -rf "$T1" "$T6" "$T7" 2>/dev/null || true
echo
echo "shellcheck-gate: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
