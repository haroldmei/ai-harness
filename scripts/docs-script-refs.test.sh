#!/usr/bin/env bash
# Hermetic test for scripts/docs-script-refs.sh (#1984).
#
# The gate's whole value is that it FAILS on the tree 7d418560 left behind. A gate that only ever
# passes proves nothing, so every scenario below builds a fake repo in a temp dir, breaks it in one
# specific way, and asserts the gate catches exactly that break. Nothing here touches the real repo.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/docs-script-refs.sh"

pass=0; fail=0
ok()  { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  ✗ %s\n' "$1"; fail=$((fail + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build a minimal repo that the gate considers clean: docs citing only scripts that exist, one
# well-formed script, and stubs for the two library suites check 4 runs.
new_repo() {
  local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/scripts/lib" "$d/docs"
  cp "$GATE" "$d/scripts/docs-script-refs.sh"; chmod +x "$d/scripts/docs-script-refs.sh"
  printf '#!/usr/bin/env bash\necho hi\n' >"$d/scripts/real.sh"
  printf '# lib\n' >"$d/scripts/lib/present.sh"
  # Stub every suite check 4 runs, so it is green unless a scenario says otherwise. Stubbing this
  # file's own suite is also what bounds the recursion: the inner gate run never re-enters here.
  printf '#!/usr/bin/env bash\necho "state-shard: 0 passed, 0 failed"\nexit 0\n' >"$d/scripts/state-shard.test.sh"
  printf '#!/usr/bin/env bash\necho "agent-trace: 0 passed, 0 failed"\nexit 0\n' >"$d/scripts/agent-trace.test.sh"
  printf '#!/usr/bin/env bash\necho "docs-script-refs: 0 passed, 0 failed"\nexit 0\n' >"$d/scripts/docs-script-refs.test.sh"
  printf 'Use `scripts/real.sh` for things.\n' >"$d/CLAUDE.md"
  printf 'Harness doc citing `scripts/real.sh`.\n' >"$d/docs/AGENT-HARNESS.md"
  printf '%s' "$d"
}
run_gate() { (cd "$1" && bash scripts/docs-script-refs.sh 2>&1); }

echo "Scenario 1 — a clean tree passes"
d="$(new_repo clean)"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -eq 0 ] && ok "clean tree exits 0" || bad "clean tree should exit 0, got $rc: $out"

echo "Scenario 2 — a doc citing a nonexistent script fails (the CLAUDE.md half of #1984)"
d="$(new_repo docref)"
printf 'Always use `scripts/lib/state-shard.sh` for state.\n' >>"$d/CLAUDE.md"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "missing doc-referenced script exits nonzero" || bad "should have failed"
grep -q 'scripts/lib/state-shard.sh' <<<"$out" && ok "names the missing path" || bad "must name the path"

echo "Scenario 3 — a script sourcing a missing library fails (the six-broken-scripts half)"
d="$(new_repo srcdep)"
printf '#!/usr/bin/env bash\nROOT=.\nsource "$ROOT/scripts/lib/gone.sh"\n' >"$d/scripts/broken.sh"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "missing sourced lib exits nonzero" || bad "should have failed"
grep -q 'sources a missing library' <<<"$out" && ok "reports it as a source-dep failure" || bad "wrong message: $out"

echo "Scenario 4 — the \$(dirname \${BASH_SOURCE[0]}) form is resolved, not skipped"
# verify-loop.sh and adversarial-loop.sh use exactly this form; if the gate can't resolve it, the
# two scripts #1984 is really about go unchecked while the gate still reports PASS.
d="$(new_repo dirname)"
printf '#!/usr/bin/env bash\nsource "$(dirname "${BASH_SOURCE[0]}")/lib/gone.sh"\n' >"$d/scripts/dyn.sh"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "dirname-form missing lib is caught" || bad "dirname form was not resolved: $out"
grep -q 'not statically checkable' <<<"$out" && bad "dirname form must resolve, not be skipped" \
  || ok "dirname form resolved rather than skipped"

echo "Scenario 5 — a present sourced library passes"
d="$(new_repo srcok)"
printf '#!/usr/bin/env bash\nsource "$(dirname "${BASH_SOURCE[0]}")/lib/present.sh"\n' >"$d/scripts/good.sh"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -eq 0 ] && ok "existing sourced lib passes" || bad "false positive: $out"

echo "Scenario 6 — a syntax error is caught"
d="$(new_repo syntax)"
printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n  echo unterminated\n' >"$d/scripts/bad.sh"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "syntax error exits nonzero" || bad "should have failed"
grep -q 'syntax error' <<<"$out" && ok "reports it as a syntax error" || bad "wrong message: $out"

echo "Scenario 7 — a bare path that only exists under backend/ is reported as a doc bug"
d="$(new_repo backendpath)"
mkdir -p "$d/backend/scripts"; printf 'x\n' >"$d/backend/scripts/seed.py"
printf 'Run `scripts/seed.py` to seed.\n' >>"$d/docs/AGENT-HARNESS.md"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "root-relative path that only exists under backend/ fails" || bad "should have failed"
grep -q 'write the full path' <<<"$out" && ok "tells the author to qualify the path" || bad "wrong message: $out"

echo "Scenario 8 — an allowlisted absent path does not fail the gate"
# scripts/deploy.sh is cited to say SkillForge deliberately does NOT have it.
d="$(new_repo allowlist)"
printf 'Not ported: `scripts/deploy.sh`.\n' >>"$d/docs/AGENT-HARNESS.md"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -eq 0 ] && ok "allowlisted absent path passes" || bad "allowlist not honoured: $out"
grep -q 'absent by design' <<<"$out" && ok "still surfaces it as allowlisted" || bad "should note the allowlist"

echo "Scenario 9 — a failing library suite fails the gate"
d="$(new_repo libtest)"
printf '#!/usr/bin/env bash\necho "  ✗ broke"\nexit 1\n' >"$d/scripts/state-shard.test.sh"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "red library suite exits nonzero" || bad "should have failed"
grep -q 'FAILED' <<<"$out" && ok "surfaces the failing suite" || bad "wrong message: $out"

echo "Scenario 10 — a deleted library suite fails the gate"
d="$(new_repo libgone)"
rm -f "$d/scripts/agent-trace.test.sh"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "missing library suite exits nonzero" || bad "should have failed"

echo "Scenario 11 — a pr-review-fix-loop.md with resolvable units + grep-able knobs passes (#2008)"
# The unit lives under deploy/systemd/ with the skillforge- prefix; the knob is read by a script.
d="$(new_repo prdoc_ok)"
mkdir -p "$d/deploy/systemd"
: >"$d/deploy/systemd/skillforge-agent-pr-reviewer.service"
: >"$d/deploy/systemd/skillforge-agent-pr-reviewer.timer"
printf '#!/usr/bin/env bash\n: "${PR_MAX_ROUNDS:=4}"\n' >"$d/scripts/agent-pr-reviewer.sh"
cat >"$d/docs/pr-review-fix-loop.md" <<'EOF'
Install `deploy/systemd/skillforge-agent-pr-reviewer.{service,timer}`.
<!-- pr-loop-knobs:start -->
| Var | Default |
|---|---|
| `PR_MAX_ROUNDS` | `4` |
<!-- pr-loop-knobs:end -->
EOF
out="$(run_gate "$d")"; rc=$?
[ "$rc" -eq 0 ] && ok "valid pr-doc passes" || bad "false positive: $out"

echo "Scenario 12 — a pr-doc naming a unit without the skillforge- prefix fails (#2008)"
d="$(new_repo prdoc_unit)"
mkdir -p "$d/deploy/systemd"
: >"$d/deploy/systemd/skillforge-agent-pr-reviewer.timer"   # real unit is prefixed
printf 'Enable `agent-pr-reviewer.timer` to start reviewing.\n' >"$d/docs/pr-review-fix-loop.md"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "unresolved unit name exits nonzero" || bad "should have failed: $out"
grep -q "names systemd unit 'agent-pr-reviewer.timer'" <<<"$out" && ok "names the bad unit" \
  || bad "must name the unresolved unit: $out"

echo "Scenario 13 — the NAME.{service,timer} brace shorthand is expanded, not skipped (#2008)"
# `foo.{service,timer}` must resolve to BOTH foo.service and foo.timer; here .timer is missing.
d="$(new_repo prdoc_brace)"
mkdir -p "$d/deploy/systemd"
: >"$d/deploy/systemd/skillforge-agent-pr-fixer.service"    # .service present, .timer absent
printf 'Install `deploy/systemd/skillforge-agent-pr-fixer.{service,timer}`.\n' >"$d/docs/pr-review-fix-loop.md"
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "brace form catches the missing half" || bad "brace form not expanded: $out"
grep -q 'skillforge-agent-pr-fixer.timer' <<<"$out" && ok "reports the missing .timer half" \
  || bad "must expand the brace and flag .timer: $out"

echo "Scenario 14 — a knob in the live-knob block that no code reads fails (the PR_FIXER_RESUME bug) (#2008)"
d="$(new_repo prdoc_knob)"
mkdir -p "$d/deploy/systemd"
cat >"$d/docs/pr-review-fix-loop.md" <<'EOF'
<!-- pr-loop-knobs:start -->
| Var | Default |
|---|---|
| `PR_FIXER_RESUME` | `0` |
<!-- pr-loop-knobs:end -->
EOF
out="$(run_gate "$d")"; rc=$?
[ "$rc" -ne 0 ] && ok "phantom live knob exits nonzero" || bad "should have failed: $out"
grep -q "env knob 'PR_FIXER_RESUME'" <<<"$out" && ok "names the phantom knob" \
  || bad "must name the unreadable knob: $out"

echo "Scenario 15 — a reverted knob mentioned OUTSIDE the marker block does not fail (#2008)"
# A var documented in prose as reverted is not a live knob; only the fenced table is enforced.
d="$(new_repo prdoc_prose)"
mkdir -p "$d/deploy/systemd"
cat >"$d/docs/pr-review-fix-loop.md" <<'EOF'
PR_FIXER_RESUME was reverted (7d418560) and is not implemented; no code reads it.
<!-- pr-loop-knobs:start -->
| Var | Default |
|---|---|
<!-- pr-loop-knobs:end -->
EOF
out="$(run_gate "$d")"; rc=$?
[ "$rc" -eq 0 ] && ok "reverted knob in prose is exempt" || bad "false positive on prose mention: $out"

echo
echo "docs-script-refs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
