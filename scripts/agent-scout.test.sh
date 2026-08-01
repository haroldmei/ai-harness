#!/usr/bin/env bash
# Hermetic end-to-end test for the agent-scout journey (scripts/agent-scout.sh).
#
# Drives the REAL producer journey with the agent (`claude`) and GitHub (`gh`) STUBBED:
# zero real GitHub side-effects, zero LLM cost, deterministic. Verifies the original five
# disciplines AND the 2026 best-practice learning/prioritisation backlog (docs/33 §learning):
#   • produce → critic → file · CRITIC drop · DEDUP · RATE-LIMIT · ISOLATION (originals)
#   1. outcome ledger + rolling accept-rate (persists across runs)
#   2. rejection digest fed into the producer prompt (no re-proposing a rejected class)
#   3. cross-batch impact ranking (top-ranked = highest impact×confidence)
#   4. proposed-speculative tier for low-confidence survivors (downgrade, not drop)
#   5. double-pass confirmation for p0 (single-pass flagged, agreed promoted)
#   6. JSONL decision audit log (every candidate's verdict + file/skip queryable)
#   7. critic re-verifies cited file:line (a nonexistent line → evidence-not-found drop)
#   8. compose_body contract lint (run fails loudly on missing fingerprint/acceptance)
#   9. semantic near-duplicate clustering pre-file (one defect → at most one issue)
#  10. staleness nudge for an untriaged p0 `proposed`
#  11. regression-origin commit link for SINCE runs
#  12. dynamic per-engine budget from accept-rate
#
#   Run: bash scripts/agent-scout.test.sh     (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/agent-scout.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_grep()   { if grep -qF "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected: $2)"; fi; }
assert_nogrep() { if grep -qF "$2" "$1" 2>/dev/null; then bad "$3 (unexpectedly found: $2)"; else ok "$3"; fi; }
assert_eq()     { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }

# ════════════════════════════════════════════════════════════════════════════════
# ORIGINAL discipline harness (kept; fixtures now cite REAL files so the new file:line
# re-verification gate (#7) passes for genuine candidates).
# ════════════════════════════════════════════════════════════════════════════════
make_env() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/logs"

  git init -q --bare "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
  ( cd "$tmp/clone"
    git config user.email t@t; git config user.name tester
    echo base > base.txt
    echo '{"name":"t"}' > package.json
    mkdir -p node_modules; echo x > node_modules/.keep
    # Files the candidates cite — needed so the file:line re-verification gate passes.
    printf 'l1\n'                                     > a.ts
    printf 'l1\nl2\nl3\nl4\n'                         > c.ts
    printf 'l1\nl2\nl3\nl4\nl5\n'                     > d.ts
    printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n'           > page.tsx
    git add -A; git commit -qm init; git branch -M main; git push -q origin main ) 2>/dev/null

  # The user's live state: uncommitted WIP that the scan must never touch.
  echo "user work in progress" > "$tmp/clone/USER_WIP.txt"

  # An EXISTING issue (could be closed/rejected) carrying a scout fingerprint — the dedup
  # source of truth. The candidate "dup-existing" must NOT be re-filed because of this.
  cat > "$tmp/issues.json" <<'JSON'
[ { "number": 1, "title": "old", "state": "OPEN", "stateReason": null, "labels": [], "createdAt": "2020-01-01T00:00:00Z", "body": "old proposal\n<!-- scout-fp: dup-existing -->" } ]
JSON

  cat > "$tmp/bin/gh" <<GH
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then cat "$tmp/issues.json"; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "create" ]; then
  title=""; labels=""; body=""
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --title) title="\$2"; shift 2;;
      --label) labels="\${labels} \$2"; shift 2;;
      --body)  body="\$2"; shift 2;;
      *) shift;;
    esac
  done
  echo "create | title=\${title} | labels=\${labels}" >> "$tmp/logs/created.log"
  printf '%s\n' "\$body" >> "$tmp/logs/bodies.log"
  echo "https://github.com/test/repo/issues/777"; exit 0
fi
if [ "\$1" = "issue" ] && { [ "\$2" = "edit" ] || [ "\$2" = "comment" ]; }; then
  echo "\$2 #\$3 :: \$*" >> "$tmp/logs/gh.log"; exit 0
fi
exit 0
GH
  chmod +x "$tmp/bin/gh"

  cat > "$tmp/bin/claude" <<CL
#!/usr/bin/env bash
if [ -n "\${SCOUT_VERDICTS_OUT:-}" ]; then
  cat > "\$SCOUT_VERDICTS_OUT" <<'JSON'
{ "verdicts": [
  { "fingerprint": "fresh-1", "keep": true,  "reason": "real" },
  { "fingerprint": "fresh-2", "keep": true,  "reason": "real" },
  { "fingerprint": "fresh-3", "keep": true,  "reason": "real" },
  { "fingerprint": "dup-existing", "keep": true, "reason": "real but already filed" },
  { "fingerprint": "dropme", "keep": false, "reason": "imagined / stale-spec" }
] }
JSON
  echo '{"result":"ok"}'; exit 0
fi
if [ -n "\${SCOUT_CANDIDATES_OUT:-}" ]; then
  cat > "\$SCOUT_CANDIDATES_OUT" <<'JSON'
{ "candidates": [
  { "fingerprint": "fresh-1", "engine": "bug", "title": "Bug one ALPHA", "severity": "p1", "confidence": "high", "rationale": "r", "evidence": "a.ts:1", "repro": "x", "proposed_fix": "f", "acceptance": "test" },
  { "fingerprint": "fresh-2", "engine": "ux-business", "title": "UX two BETA", "severity": "p2", "confidence": "medium", "rationale": "r", "evidence": "page.tsx:9", "repro": "x", "proposed_fix": "f", "acceptance": "journey" },
  { "fingerprint": "fresh-3", "engine": "bug", "title": "Bug three GAMMA", "severity": "p0", "confidence": "high", "rationale": "r", "evidence": "c.ts:3", "repro": "x", "proposed_fix": "f", "acceptance": "test" },
  { "fingerprint": "dup-existing", "engine": "bug", "title": "Dup DELTA", "severity": "p1", "confidence": "high", "rationale": "r", "evidence": "d.ts:4", "repro": "x", "proposed_fix": "f", "acceptance": "test" },
  { "fingerprint": "dropme", "engine": "bug", "title": "Imagined EPSILON", "severity": "p2", "confidence": "low", "rationale": "r", "evidence": "a.ts:1", "repro": "?", "proposed_fix": "?", "acceptance": "?" }
] }
JSON
  echo '{"result":"ok"}'; exit 0
fi
echo '{"result":"ok"}'; exit 0
CL
  chmod +x "$tmp/bin/claude"
}

run_runner() {
  local tmp="$1"
  SCOUT_ROOT="$tmp/clone" \
  SCOUT_GH="$tmp/bin/gh" SCOUT_CLAUDE="$tmp/bin/claude" \
  SCOUT_REMOTE="origin" SCOUT_BASE="main" \
  SCOUT_ENGINES="bug" \
  SCOUT_MAX_ISSUES="2" SCOUT_MAX_PER_ENGINE="5" \
  SCOUT_LOCK="$tmp/scout.lock" SCOUT_LOGDIR="$tmp/logs" \
  SCOUT_WORKTREE_BASE="$tmp/worktrees" \
  SCOUT_LEDGER="$tmp/ledger.jsonl" \
  SCOUT_PREFLIGHT_TOOLS="git jq node npx" \
  SCOUT_DEPS="symlink" \
    bash "$RUNNER" > "$tmp/logs/runner.out" 2>&1
}

echo "Scenario — produce → critic → dedup → rate-limited file (originals)"
T1="$(mktemp -d)"; make_env "$T1"; run_runner "$T1"
created="$T1/logs/created.log"; touch "$created"

n="$(grep -c '^create ' "$created" 2>/dev/null || echo 0)"
[ "$n" -eq 2 ] && ok "rate-limit honored — exactly 2 issues filed (cap)" || bad "rate-limit: expected 2 filed, got $n"
assert_grep "$created" "proposed" "filed issues carry the 'proposed' review label"
assert_grep "$created" "ALPHA" "first survivor (fresh-1) was filed"
assert_nogrep "$created" "EPSILON" "critic-refuted candidate (dropme) was NOT filed"
assert_nogrep "$created" "DELTA" "already-filed fingerprint (dup-existing) was NOT re-filed"
[ "$(git -C "$T1/clone" branch --show-current)" = "main" ] \
  && ok "primary working copy stayed on main" || bad "primary copy branch changed"
git -C "$T1/clone" status --porcelain | grep -qF "USER_WIP.txt" \
  && ok "user's uncommitted WIP left untouched" || bad "user's WIP was disturbed"
[ -z "$(git -C "$T1/clone" worktree list 2>/dev/null | grep -F "$T1/worktrees")" ] \
  && ok "scan worktree cleaned up" || bad "scan worktree leaked"

echo "Scenario — DRY_RUN files nothing"
T2="$(mktemp -d)"; make_env "$T2"
SCOUT_DRY_RUN=1 SCOUT_ROOT="$T2/clone" SCOUT_GH="$T2/bin/gh" SCOUT_CLAUDE="$T2/bin/claude" \
  SCOUT_REMOTE="origin" SCOUT_BASE="main" SCOUT_ENGINES="bug" SCOUT_MAX_ISSUES="2" \
  SCOUT_LOCK="$T2/scout.lock" SCOUT_LOGDIR="$T2/logs" SCOUT_WORKTREE_BASE="$T2/worktrees" \
  SCOUT_LEDGER="$T2/ledger.jsonl" \
  SCOUT_PREFLIGHT_TOOLS="git jq node npx" SCOUT_DEPS="symlink" \
  bash "$RUNNER" > "$T2/logs/runner.out" 2>&1
[ ! -s "$T2/logs/created.log" ] && ok "DRY_RUN filed zero issues" || bad "DRY_RUN should file nothing"
assert_grep "$T2/logs/runner.out" "DRY-RUN would file" "DRY_RUN reported what it would file"

# ════════════════════════════════════════════════════════════════════════════════
# GENERIC harness for the learning/prioritisation backlog: candidate + verdict + pass2
# JSON are injected per-scenario; gh records create/edit/comment.
# ════════════════════════════════════════════════════════════════════════════════
mkg() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/logs"
  git init -q --bare "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
  ( cd "$tmp/clone"
    git config user.email t@t; git config user.name tester
    echo base > base.txt
    echo '{"name":"t"}' > package.json
    mkdir -p node_modules; echo x > node_modules/.keep
    printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n' > src.ts
    printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n' > page.tsx
    printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n' > gateway.ts
    git add -A; git commit -qm init; git branch -M main; git push -q origin main ) 2>/dev/null
  echo '[]'                  > "$tmp/issues.json"
  echo '{"candidates":[]}'   > "$tmp/candidates.json"
  echo '{"verdicts":[]}'     > "$tmp/verdicts.json"

  cat > "$tmp/bin/gh" <<GH
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then cat "$tmp/issues.json"; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "create" ]; then
  title=""; labels=""; body=""
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --title) title="\$2"; shift 2;;
      --label) labels="\${labels} \$2"; shift 2;;
      --body)  body="\$2"; shift 2;;
      *) shift;;
    esac
  done
  echo "create | title=\${title} | labels=\${labels}" >> "$tmp/logs/created.log"
  printf -- '--- %s\n%s\n' "\${title}" "\$body" >> "$tmp/logs/bodies.log"
  echo "https://github.com/test/repo/issues/777"; exit 0
fi
if [ "\$1" = "issue" ] && { [ "\$2" = "edit" ] || [ "\$2" = "comment" ]; }; then
  echo "\$2 #\$3 :: \$*" >> "$tmp/logs/gh.log"; exit 0
fi
exit 0
GH
  chmod +x "$tmp/bin/gh"

  cat > "$tmp/bin/claude" <<CL
#!/usr/bin/env bash
ALLARGS="\$*"
if [ -n "\${SCOUT_VERDICTS_OUT:-}" ]; then
  cp "$tmp/verdicts.json" "\$SCOUT_VERDICTS_OUT"; echo '{"result":"ok"}'; exit 0
fi
if [ -n "\${SCOUT_CANDIDATES_OUT:-}" ]; then
  src="$tmp/candidates.json"
  if [ "\${SCOUT_PASS:-1}" = "2" ] && [ -f "$tmp/candidates-pass2.json" ]; then src="$tmp/candidates-pass2.json"; fi
  cp "\$src" "\$SCOUT_CANDIDATES_OUT"
  # Coverage engines (req/journey) write a matrix in the SAME producer call.
  if [ -n "\${SCOUT_MATRIX_OUT:-}" ] && [ -f "$tmp/matrix.json" ]; then cp "$tmp/matrix.json" "\$SCOUT_MATRIX_OUT"; fi
  # Honour the rejection digest: a producer that sees "RECENTLY REJECTED" drops cousins.
  if [ -s "$tmp/banned-keywords.txt" ] && grep -qi "RECENTLY REJECTED" <<<"\$ALLARGS"; then
    kw="\$(paste -sd'|' "$tmp/banned-keywords.txt")"
    jq --arg kw "\$kw" '.candidates |= map(select((.title|ascii_downcase|test(\$kw))|not))' \
      "\$SCOUT_CANDIDATES_OUT" > "\$SCOUT_CANDIDATES_OUT.tmp" && mv "\$SCOUT_CANDIDATES_OUT.tmp" "\$SCOUT_CANDIDATES_OUT"
  fi
  echo '{"result":"ok"}'; exit 0
fi
echo '{"result":"ok"}'; exit 0
CL
  chmod +x "$tmp/bin/claude"
}

# run_g <tmp> [VAR=val ...]
run_g() {
  local tmp="$1"; shift
  env "$@" \
    SCOUT_ROOT="$tmp/clone" SCOUT_GH="$tmp/bin/gh" SCOUT_CLAUDE="$tmp/bin/claude" \
    SCOUT_REMOTE="origin" SCOUT_BASE="main" \
    SCOUT_LOCK="$tmp/scout.lock" SCOUT_LOGDIR="$tmp/logs" SCOUT_WORKTREE_BASE="$tmp/worktrees" \
    SCOUT_LEDGER="$tmp/ledger.jsonl" \
    SCOUT_PREFLIGHT_TOOLS="git jq node npx" SCOUT_DEPS="symlink" \
    bash "$RUNNER" > "$tmp/logs/runner.out" 2>&1
}

# run scout with the script's DEFAULT (per-repo) lock/logdir/worktree paths — i.e. WITHOUT the
# SCOUT_LOCK/LOGDIR/WORKTREE_BASE overrides — to exercise the per-repo namespacing (issue #55).
# Captures stdout (which carries the resolved "single-instance lock:" line) to $2.
run_default() {
  local tmp="$1" out="$2"
  env SCOUT_ROOT="$tmp/clone" SCOUT_GH="$tmp/bin/gh" SCOUT_CLAUDE="$tmp/bin/claude" \
    SCOUT_REMOTE="origin" SCOUT_BASE="main" SCOUT_ENGINES="bug" SCOUT_MAX_ISSUES="2" \
    SCOUT_PREFLIGHT_TOOLS="git jq node npx" SCOUT_DEPS="symlink" \
    bash "$RUNNER" > "$out" 2>&1
}

# ── #1 outcome ledger + rolling accept-rate, persisted across runs ────────────────
echo "Scenario 1 — outcome ledger + rolling accept-rate (persists)"
L1="$(mktemp -d)"; mkg "$L1"
cat > "$L1/issues.json" <<'JSON'
[
 {"number":1,"title":"accepted item","state":"OPEN","stateReason":null,
  "labels":[{"name":"agent"},{"name":"bug"},{"name":"p0"}],"createdAt":"2030-01-01T00:00:00Z",
  "body":"x · confidence high\n<!-- scout-fp: acc-1 -->"},
 {"number":2,"title":"rejected item","state":"CLOSED","stateReason":"NOT_PLANNED",
  "labels":[{"name":"bug"},{"name":"p1"}],"createdAt":"2020-01-01T00:00:00Z",
  "body":"y · confidence medium\n<!-- scout-fp: rej-1 -->"}
]
JSON
run_g "$L1" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=3
assert_grep "$L1/logs/runner.out" "accept-rate (rolling): bug=50% (1/2)" "rolling accept-rate printed by engine"
[ -s "$L1/ledger.jsonl" ] && ok "ledger persisted to disk" || bad "ledger not written"
run_g "$L1" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=3   # second run: outcomes are idempotent
lc="$(grep -c . "$L1/ledger.jsonl" 2>/dev/null || echo 0)"
assert_eq "$lc" "2" "ledger is idempotent across runs (no duplicate outcomes)"

# ── #2 rejection digest fed into the producer prompt (no re-proposing the class) ──
echo "Scenario 2 — rejection digest suppresses a rejected class under a new fingerprint"
L2="$(mktemp -d)"; mkg "$L2"
cat > "$L2/issues.json" <<'JSON'
[ {"number":7,"title":"Add dark mode toggle nobody asked for","state":"CLOSED","stateReason":"NOT_PLANNED",
   "labels":[{"name":"ux-customer"},{"name":"wontfix"}],"createdAt":"2024-01-01T00:00:00Z",
   "body":"rejected · confidence low\n<!-- scout-fp: darkmode-old -->"} ]
JSON
# A cousin of the rejected finding, with a BRAND-NEW fingerprint (exact dedup can't catch it).
cat > "$L2/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "darkmode-new-2", "engine": "ux-customer", "title": "Add a dark mode toggle to settings",
    "severity": "p2", "confidence": "medium", "rationale": "r", "evidence": "page.tsx:2", "repro": "x",
    "proposed_fix": "f", "acceptance": "journey" } ] }
JSON
cat > "$L2/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "darkmode-new-2", "keep": true, "reason": "plausible" } ] }
JSON
printf 'dark mode\n' > "$L2/banned-keywords.txt"
run_g "$L2" SCOUT_ENGINES=ux SCOUT_MAX_ISSUES=3
assert_grep "$L2/logs/prompt-ux.txt" "Add dark mode toggle nobody asked for" "rejection digest injected into producer prompt"
touch "$L2/logs/created.log"
assert_nogrep "$L2/logs/created.log" "dark mode toggle" "rejected class not re-proposed under a new fingerprint"

# ── #3 cross-batch impact ranking + #6 audit log ─────────────────────────────────
echo "Scenario 3 — cross-batch impact ranking; top-ranked = highest impact×confidence (+ audit log)"
L3="$(mktemp -d)"; mkg "$L3"
cat > "$L3/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "rk-low",  "engine": "bug", "title": "Minor cosmetic typo somewhere", "severity": "p2", "confidence": "low",    "business_impact": "low",
    "rationale": "r", "evidence": "src.ts:2", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" },
  { "fingerprint": "rk-high", "engine": "bug", "title": "Cross tenant data leak in gateway", "severity": "p0", "confidence": "high", "business_impact": "high",
    "rationale": "r", "evidence": "gateway.ts:3", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" },
  { "fingerprint": "rk-mid",  "engine": "bug", "title": "Budget math off by rounding error", "severity": "p1", "confidence": "medium", "business_impact": "medium",
    "rationale": "r", "evidence": "src.ts:4", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" } ] }
JSON
cat > "$L3/candidates-pass2.json" <<'JSON'
{ "candidates": [ { "fingerprint": "rk-high", "engine": "bug", "title": "x", "severity": "p0", "confidence": "high", "evidence": "gateway.ts:3", "acceptance": "t" } ] }
JSON
cat > "$L3/verdicts.json" <<'JSON'
{ "verdicts": [
  { "fingerprint": "rk-low",  "keep": true, "reason": "ok" },
  { "fingerprint": "rk-high", "keep": true, "reason": "ok" },
  { "fingerprint": "rk-mid",  "keep": true, "reason": "ok" } ] }
JSON
run_g "$L3" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=5
first="$(grep '^create ' "$L3/logs/created.log" 2>/dev/null | head -1)"
case "$first" in *"Cross tenant data leak"*) ok "highest impact×confidence item filed first (rank 1)";; *) bad "ranking: expected the cross-tenant leak first, got: $first";; esac
assert_grep "$L3/logs/bodies.log" "Queue rank 1" "filed issue carries its queue rank"
[ -s "$L3/logs/audit.jsonl" ] && ok "audit log written (JSONL)" || bad "audit log missing"
af="$(jq -r 'select(.decision=="filed") | .fingerprint' "$L3/logs/audit.jsonl" 2>/dev/null | sort | tr '\n' ' ')"
case "$af" in *rk-high*rk-mid*|*rk-mid*rk-high*) ok "audit log is queryable (filed decisions recoverable)";; *) bad "audit query failed, got: $af";; esac

# ── #4 proposed-speculative tier for low-confidence survivors ─────────────────────
echo "Scenario 4 — low-confidence survivor filed proposed-speculative (downgraded, not dropped)"
L4="$(mktemp -d)"; mkg "$L4"
cat > "$L4/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "spec-1", "engine": "bug", "title": "Possible race in token refresh", "severity": "p1", "confidence": "low",
    "rationale": "r", "evidence": "src.ts:5", "repro": "hard to repro", "proposed_fix": "f", "acceptance": "test passes" } ] }
JSON
cat > "$L4/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "spec-1", "keep": true, "reason": "plausible but uncertain" } ] }
JSON
run_g "$L4" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=3
assert_grep "$L4/logs/created.log" "proposed-speculative" "low-confidence survivor filed under the speculative tier"

# ── #5 double-pass confirmation for p0 ───────────────────────────────────────────
echo "Scenario 5 — double-pass: agreed p0 promoted, single-pass p0 flagged"
L5="$(mktemp -d)"; mkg "$L5"
cat > "$L5/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "p0-both", "engine": "bug", "title": "Auth bypass on admin route", "severity": "p0", "confidence": "high",
    "rationale": "r", "evidence": "gateway.ts:1", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" },
  { "fingerprint": "p0-solo", "engine": "bug", "title": "Possible IDOR on export endpoint", "severity": "p0", "confidence": "high",
    "rationale": "r", "evidence": "src.ts:1", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" } ] }
JSON
# Second pass only re-derives p0-both → p0-solo is single-pass.
cat > "$L5/candidates-pass2.json" <<'JSON'
{ "candidates": [ { "fingerprint": "p0-both", "engine": "bug", "title": "Auth bypass on admin route", "severity": "p0", "confidence": "high", "evidence": "gateway.ts:1", "acceptance": "t" } ] }
JSON
cat > "$L5/verdicts.json" <<'JSON'
{ "verdicts": [
  { "fingerprint": "p0-both", "keep": true, "reason": "ok" },
  { "fingerprint": "p0-solo", "keep": true, "reason": "ok" } ] }
JSON
run_g "$L5" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=5 AGENT_TRACE_DIR="$L5/traces"
solo_line="$(grep 'IDOR on export' "$L5/logs/created.log" 2>/dev/null)"
case "$solo_line" in *single-pass*) ok "single-pass p0 flagged with the single-pass label";; *) bad "single-pass p0 not flagged: $solo_line";; esac
both_line="$(grep 'Auth bypass' "$L5/logs/created.log" 2>/dev/null)"
case "$both_line" in *single-pass*) bad "double-pass-agreed p0 wrongly flagged single-pass";; *) ok "double-pass-agreed p0 promoted (no single-pass label)";; esac
assert_grep "$L5/logs/bodies.log" "Confirmed by a second producer pass" "agreed p0 body notes double-pass confirmation"

# The scout-pass2 span must fingerprint the ACTUAL second-pass prompt (producer prompt + "SECOND
# PASS" suffix, sent at agent-scout.sh's SCOUT_CANDIDATES_OUT/SCOUT_PASS=2 call), not the producer's
# archived prompt-<engine>.txt — hashing the latter made every pass-2 span misread as a verbatim
# re-send of the producer turn (they'd carry an IDENTICAL prompt_sha256).
l5_spans="$(ls "$L5"/traces/spans-*.jsonl 2>/dev/null | head -1)"
if [ -n "$l5_spans" ]; then
  l5_prod_hash="$(jq -rs '[.[] | select(.stage=="scout-producer")][0].prompt_sha256 // empty' "$l5_spans")"
  l5_pass2_hash="$(jq -rs '[.[] | select(.stage=="scout-pass2")][0].prompt_sha256 // empty' "$l5_spans")"
  if [ -n "$l5_prod_hash" ] && [ -n "$l5_pass2_hash" ] && [ "$l5_prod_hash" != "$l5_pass2_hash" ]; then
    ok "scout-pass2 span hashes the actual second-pass prompt (differs from the producer's)"
  else
    bad "scout-pass2 span's prompt_sha256 ($l5_pass2_hash) matches the producer's ($l5_prod_hash) — hashing the wrong prompt"
  fi
else
  bad "no trace spans file written for the double-pass scenario"
fi

# The scout-producer span must hash the RAW prompt string sent to claude, not the archived
# prompt-<engine>.txt — that file is written via `printf '%s\n' "$prompt"`, one trailing byte
# larger, which put the producer's digest on a different base than every other call site.
if [ -n "$l5_spans" ]; then
  l5_prompt_file="$(ls "$L5"/logs/prompt-bug.txt 2>/dev/null | head -1)"
  l5_prod_bytes="$(jq -rs '[.[] | select(.stage=="scout-producer")][0].prompt_bytes // empty' "$l5_spans")"
  if [ -n "$l5_prompt_file" ] && [ -n "$l5_prod_bytes" ]; then
    l5_file_bytes="$(wc -c < "$l5_prompt_file" | tr -d ' ')"
    if [ "$l5_prod_bytes" -eq "$((l5_file_bytes - 1))" ]; then
      ok "scout-producer span hashes the raw prompt (bytes = archived file - 1 trailing newline)"
    else
      bad "scout-producer prompt_bytes ($l5_prod_bytes) should be archived-file bytes ($l5_file_bytes) - 1"
    fi
  else
    bad "missing prompt-bug.txt or scout-producer prompt_bytes to compare"
  fi
fi

# ── #7 critic re-verifies cited file:line (evidence-not-found) ────────────────────
echo "Scenario 7 — a candidate citing a nonexistent line is dropped (evidence-not-found)"
L7="$(mktemp -d)"; mkg "$L7"
cat > "$L7/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "ghost-1", "engine": "bug", "title": "Null deref in nonexistent file", "severity": "p1", "confidence": "high",
    "rationale": "r", "evidence": "ghost.ts:42", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" } ] }
JSON
cat > "$L7/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "ghost-1", "keep": true, "reason": "looks plausible" } ] }
JSON
run_g "$L7" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=3
touch "$L7/logs/created.log"
assert_nogrep "$L7/logs/created.log" "nonexistent file" "candidate with absent file:line was NOT filed"
ev="$(jq -r 'select(.fingerprint=="ghost-1") | .decision' "$L7/logs/audit.jsonl" 2>/dev/null)"
assert_eq "$ev" "evidence-not-found" "drop reason recorded as evidence-not-found"

# ── #8 compose_body contract lint (fail loudly on missing acceptance) ────────────
echo "Scenario 8 — contract lint: run fails loudly when a body lacks an acceptance criterion"
L8="$(mktemp -d)"; mkg "$L8"
cat > "$L8/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "noacc-1", "engine": "bug", "title": "Defect with no acceptance bar", "severity": "p1", "confidence": "high",
    "rationale": "r", "evidence": "src.ts:1", "repro": "x", "proposed_fix": "f" } ] }
JSON
cat > "$L8/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "noacc-1", "keep": true, "reason": "ok" } ] }
JSON
run_g "$L8" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=3; rc8=$?
[ "$rc8" -ne 0 ] && ok "run exits non-zero on a contract violation" || bad "run should fail loudly (got exit 0)"
assert_grep "$L8/logs/runner.out" "CONTRACT VIOLATION" "contract violation logged loudly"
touch "$L8/logs/created.log"
assert_nogrep "$L8/logs/created.log" "no acceptance bar" "contract-violating issue was NOT filed"

# ── #9 semantic near-duplicate clustering pre-file ───────────────────────────────
echo "Scenario 9 — two differently-worded reports of one defect file at most one issue"
L9="$(mktemp -d)"; mkg "$L9"
cat > "$L9/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "dup-a", "engine": "bug", "title": "Score route missing tenant isolation", "severity": "p1", "confidence": "high",
    "rationale": "r", "evidence": "gateway.ts:1", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" },
  { "fingerprint": "dup-b", "engine": "bug", "title": "Score route missing tenant isolation guard", "severity": "p2", "confidence": "high",
    "rationale": "r", "evidence": "gateway.ts:2", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" } ] }
JSON
cat > "$L9/verdicts.json" <<'JSON'
{ "verdicts": [
  { "fingerprint": "dup-a", "keep": true, "reason": "ok" },
  { "fingerprint": "dup-b", "keep": true, "reason": "ok" } ] }
JSON
run_g "$L9" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=5
nd="$(grep -c '^create ' "$L9/logs/created.log" 2>/dev/null || echo 0)"
assert_eq "$nd" "1" "near-duplicate clustering filed exactly one of the two reports"
assert_grep "$L9/logs/audit.jsonl" "near-duplicate" "the merged report is audited as a near-duplicate"

# ── #10 staleness nudge for an untriaged p0 `proposed` ───────────────────────────
echo "Scenario 10 — untriaged stale p0 proposal is nudged"
L10="$(mktemp -d)"; mkg "$L10"
cat > "$L10/issues.json" <<'JSON'
[ {"number":42,"title":"old p0 proposal","state":"OPEN","stateReason":null,
   "labels":[{"name":"proposed"},{"name":"bug"},{"name":"p0"}],"createdAt":"2020-01-01T00:00:00Z",
   "body":"stale · confidence high\n<!-- scout-fp: stale-1 -->"} ]
JSON
run_g "$L10" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=3 SCOUT_STALE_DAYS=3 SCOUT_NOW=4102444800
assert_grep "$L10/logs/runner.out" "nudged #42" "stale p0 proposal was nudged"
assert_grep "$L10/logs/gh.log" "edit #42" "nudge applied a label / comment via gh"

# ── #11 regression-origin commit link for SINCE runs ─────────────────────────────
echo "Scenario 11 — diff-scoped (SINCE) finding links its introducing commit"
L11="$(mktemp -d)"; mkg "$L11"
SINCE_REF="$(git -C "$L11/clone" rev-parse HEAD)"
( cd "$L11/clone"
  printf 'regression line one\nregression line two\n' > feat.ts
  git add -A; git commit -qm "introduce feat.ts regression"; git push -q origin main ) 2>/dev/null
INTRO_SHA="$(git -C "$L11/clone" rev-parse --short=12 HEAD)"
cat > "$L11/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "reg-1", "engine": "bug", "title": "Regression in feat path", "severity": "p1", "confidence": "high",
    "rationale": "r", "evidence": "feat.ts:1", "repro": "x", "proposed_fix": "f", "acceptance": "test passes" } ] }
JSON
cat > "$L11/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "reg-1", "keep": true, "reason": "ok" } ] }
JSON
run_g "$L11" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=3 SCOUT_SINCE="$SINCE_REF"
assert_grep "$L11/logs/bodies.log" "Regression origin" "SINCE finding carries a regression-origin section"
assert_grep "$L11/logs/bodies.log" "$INTRO_SHA" "regression-origin links the introducing commit"

# ── #12 dynamic per-engine budget from accept-rate ───────────────────────────────
echo "Scenario 12 — per-engine budget shifts toward the higher-yield engine"
L12="$(mktemp -d)"; mkg "$L12"
cat > "$L12/ledger.jsonl" <<'JSON'
{"engine":"bug","outcome":"accepted","severity":"p1","confidence":"high","fingerprint":"h1"}
{"engine":"bug","outcome":"accepted","severity":"p1","confidence":"high","fingerprint":"h2"}
{"engine":"bug","outcome":"accepted","severity":"p1","confidence":"high","fingerprint":"h3"}
{"engine":"ux-customer","outcome":"rejected","severity":"p2","confidence":"low","fingerprint":"l1"}
{"engine":"ux-customer","outcome":"rejected","severity":"p2","confidence":"low","fingerprint":"l2"}
{"engine":"ux-business","outcome":"rejected","severity":"p2","confidence":"low","fingerprint":"l3"}
JSON
run_g "$L12" "SCOUT_ENGINES=bug ux" SCOUT_MAX_ISSUES=6 SCOUT_MAX_PER_ENGINE=3 SCOUT_DYNAMIC_BUDGET=1
bline="$(grep 'engine budgets:' "$L12/logs/runner.out" 2>/dev/null)"
bug_cap="$(sed -n 's/.*bug=\([0-9]\+\).*/\1/p' <<<"$bline")"
ux_cap="$(sed -n 's/.*ux=\([0-9]\+\).*/\1/p' <<<"$bline")"
if [ -n "$bug_cap" ] && [ -n "$ux_cap" ] && [ "$bug_cap" -gt "$ux_cap" ]; then
  ok "higher-yield engine got a larger budget (bug=$bug_cap > ux=$ux_cap)"
else
  bad "dynamic budget did not favor the higher-yield engine: '$bline'"
fi

# ════════════════════════════════════════════════════════════════════════════════
# doc-34 ITERATION (issue #55): three new engines (req/journey/docs), the ux Nielsen
# fold-in, the bug lint-ingestion fold-in, and the journey regression mode under SINCE.
# Same hermetic harness — stubbed gh/claude, zero GitHub side-effects, zero LLM cost.
# ════════════════════════════════════════════════════════════════════════════════

# ── req: a MISSING-FR candidate (no file:line) is filed (not evidence-dropped) + matrix ──
echo "Scenario 13 — req engine: missing-FR candidate filed (no file:line) + compliance matrix"
R1="$(mktemp -d)"; mkg "$R1"
cat > "$R1/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "fr-012-no-export-throttle", "engine": "req", "title": "FR-012 export throttle is unimplemented",
    "severity": "p1", "confidence": "high", "business_impact": "high", "rationale": "no module enforces it",
    "evidence": "FR-012 / docs/03-system-design.md gateway module", "repro": "FR-012 has no implementing route",
    "proposed_fix": "add the throttle middleware", "acceptance": "FR-012: exports are rate-limited per tenant" } ] }
JSON
cat > "$R1/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "fr-012-no-export-throttle", "keep": true, "reason": "genuinely missing" } ] }
JSON
cat > "$R1/matrix.json" <<'JSON'
[ {"fr":"FR-001","status":"implemented","evidence":"gateway.ts","missing_part":"","severity":"p2"},
  {"fr":"FR-012","status":"missing","evidence":"docs/03-system-design.md","missing_part":"throttle","severity":"p1"} ]
JSON
run_g "$R1" SCOUT_ENGINES=req SCOUT_MAX_ISSUES=3 SCOUT_ARTIFACT_DIR="$R1/artifacts"
assert_grep "$R1/logs/created.log" "FR-012 export throttle" "missing-FR req item was filed"
assert_grep "$R1/logs/created.log" "req" "req item carries the 'req' engine label"
rdec="$(jq -r 'select(.fingerprint=="fr-012-no-export-throttle") | .decision' "$R1/logs/audit.jsonl" 2>/dev/null)"
assert_eq "$rdec" "filed" "missing-FR (no file:line) is NOT dropped by verify_evidence (req exempt from bug gate)"
[ -s "$R1/artifacts/scout-compliance.json" ] && jq -e 'type=="array"' "$R1/artifacts/scout-compliance.json" >/dev/null 2>&1 \
  && ok "req wrote a well-formed compliance matrix artifact" || bad "req compliance matrix missing/malformed"
assert_grep "$R1/logs/prompt-req.txt" "compliance matrix" "req producer prompt asks for the compliance matrix"

# ── req: matrix is regenerated even when ZERO issues are filed ────────────────────
echo "Scenario 14 — req matrix written even when zero issues are filed"
R2="$(mktemp -d)"; mkg "$R2"
echo '{"candidates":[]}' > "$R2/candidates.json"
cat > "$R2/matrix.json" <<'JSON'
[ {"fr":"FR-001","status":"implemented","evidence":"gateway.ts","missing_part":"","severity":"p2"} ]
JSON
run_g "$R2" SCOUT_ENGINES=req SCOUT_MAX_ISSUES=3 SCOUT_ARTIFACT_DIR="$R2/artifacts"
touch "$R2/logs/created.log"
[ ! -s "$R2/logs/created.log" ] && ok "req filed zero issues (nothing partial/missing/contradicted)" || bad "req should file nothing here"
[ -s "$R2/artifacts/scout-compliance.json" ] && ok "compliance matrix still regenerated with zero filed issues" || bad "matrix not written on a zero-issue run"

# ── journey: a BLOCKED journey is filed + coverage matrix artifact ───────────────
echo "Scenario 15 — journey engine: blocked journey filed + coverage matrix"
J1="$(mktemp -d)"; mkg "$J1"
cat > "$J1/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "s007-deadend-step4", "engine": "journey", "title": "Journey S-007 dead-ends at the deploy step",
    "severity": "p0", "confidence": "high", "business_impact": "high", "rationale": "deploy button has no handler",
    "evidence": "S-007 / services/app-shell deploy screen", "repro": "follow S-007 to step 4",
    "proposed_fix": "wire the deploy handler", "acceptance": "S-007 completes end-to-end in an e2e spec" } ] }
JSON
cat > "$J1/candidates-pass2.json" <<'JSON'
{ "candidates": [ { "fingerprint": "s007-deadend-step4", "engine": "journey", "title": "x", "severity": "p0", "confidence": "high", "evidence": "S-007", "acceptance": "t" } ] }
JSON
cat > "$J1/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "s007-deadend-step4", "keep": true, "reason": "real dead-end" } ] }
JSON
cat > "$J1/matrix.json" <<'JSON'
[ {"id":"S-007","status":"blocked","evidence":"deploy screen","broken_hop":"deploy button","severity":"p0"} ]
JSON
run_g "$J1" SCOUT_ENGINES=journey SCOUT_MAX_ISSUES=3 SCOUT_ARTIFACT_DIR="$J1/artifacts"
assert_grep "$J1/logs/created.log" "Journey S-007 dead-ends" "blocked journey item was filed"
assert_grep "$J1/logs/created.log" "journey" "journey item carries the 'journey' engine label"
[ -s "$J1/artifacts/scout-journeys-coverage.json" ] && jq -e 'type=="array"' "$J1/artifacts/scout-journeys-coverage.json" >/dev/null 2>&1 \
  && ok "journey wrote a well-formed coverage matrix artifact" || bad "journey coverage matrix missing/malformed"

# ── docs: a missing-doc candidate is filed under the docs label ──────────────────
echo "Scenario 16 — docs engine: missing-doc candidate filed under the docs label"
D1="$(mktemp -d)"; mkg "$D1"
cat > "$D1/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "gateway-score-route-undocumented", "engine": "docs", "title": "Public /score route has no doc comment",
    "severity": "p2", "confidence": "high", "business_impact": "medium", "rationale": "a public route with no docs",
    "evidence": "gateway.ts:1", "repro": "open gateway.ts — no docstring above the handler",
    "proposed_fix": "add a one-line docstring: POST /score → tenant-scoped scoring",
    "acceptance": "the /score handler carries a doc comment describing inputs/outputs" } ] }
JSON
cat > "$D1/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "gateway-score-route-undocumented", "keep": true, "reason": "real doc gap" } ] }
JSON
run_g "$D1" SCOUT_ENGINES=docs SCOUT_MAX_ISSUES=3
assert_grep "$D1/logs/created.log" "no doc comment" "docs item was filed"
assert_grep "$D1/logs/created.log" "docs" "docs item carries the 'docs' engine label"
assert_grep "$D1/logs/prompt-docs.txt" "comment:code ratio exceeds 2.0" "docs prompt carries the verbosity ratio knob"

# ── ux fold-in: a Nielsen heuristic rides through end-to-end into the issue body ──
echo "Scenario 17 — ux Nielsen heuristic carried end-to-end into the filed body"
U1="$(mktemp -d)"; mkg "$U1"
cat > "$U1/candidates.json" <<'JSON'
{ "candidates": [
  { "fingerprint": "profiler-no-progress", "engine": "ux-customer", "title": "Profiler gives no progress feedback",
    "severity": "p2", "confidence": "high", "business_impact": "medium", "rationale": "user can't tell it's working",
    "evidence": "page.tsx:1 profiler screen", "repro": "run a profile — the screen just hangs",
    "proposed_fix": "add a progress indicator", "acceptance": "the profiler shows live status",
    "heuristic": "visibility-of-system-status" } ] }
JSON
cat > "$U1/verdicts.json" <<'JSON'
{ "verdicts": [ { "fingerprint": "profiler-no-progress", "keep": true, "reason": "real friction" } ] }
JSON
run_g "$U1" SCOUT_ENGINES=ux SCOUT_MAX_ISSUES=3
assert_grep "$U1/logs/bodies.log" "visibility-of-system-status" "ux heuristic field surfaced in the filed body"
assert_grep "$U1/logs/prompt-ux.txt" "Nielsen" "ux prompt injects the Nielsen heuristics rubric"

# ── bug fold-in: a SCOUT_LINT_REPORT seeds the bug producer prompt ───────────────
echo "Scenario 18 — bug lint ingestion: SCOUT_LINT_REPORT seeds the bug prompt"
B1="$(mktemp -d)"; mkg "$B1"
echo '{"candidates":[]}' > "$B1/candidates.json"
echo '{"verdicts":[]}'   > "$B1/verdicts.json"
printf 'gateway.ts(7,3): error TS2532: ZZLINTSEED object is possibly undefined.\n' > "$B1/lint.txt"
run_g "$B1" SCOUT_ENGINES=bug SCOUT_MAX_ISSUES=3 SCOUT_LINT_REPORT="$B1/lint.txt"
assert_grep "$B1/logs/prompt-bug.txt" "ZZLINTSEED" "lint-report entries are seeded into the bug producer prompt"
assert_grep "$B1/logs/prompt-bug.txt" "STATIC SIGNAL TO TRIAGE" "bug prompt frames lint entries as signal to triage"

# ── journey regression mode: SCOUT_SINCE scopes the journey prompt to changed files ──
echo "Scenario 19 — journey regression mode: SINCE injects the changed files into the prompt"
J2="$(mktemp -d)"; mkg "$J2"
SINCE_REF2="$(git -C "$J2/clone" rev-parse HEAD)"
( cd "$J2/clone"
  printf 'changed handler line\n' > deploy-route.ts
  git add -A; git commit -qm "touch deploy-route.ts"; git push -q origin main ) 2>/dev/null
echo '{"candidates":[]}' > "$J2/candidates.json"
echo '{"verdicts":[]}'   > "$J2/verdicts.json"
run_g "$J2" SCOUT_ENGINES=journey SCOUT_MAX_ISSUES=3 SCOUT_SINCE="$SINCE_REF2" SCOUT_ARTIFACT_DIR="$J2/artifacts"
assert_grep "$J2/logs/prompt-journey.txt" "REGRESSION MODE" "journey prompt enters regression mode under SINCE"
assert_grep "$J2/logs/prompt-journey.txt" "deploy-route.ts" "regression mode scopes the journey scan to the changed file"

# ── dispatch isolation: SCOUT_ENGINES=req runs ONLY the req engine ───────────────
echo "Scenario 20 — dispatch: SCOUT_ENGINES=req runs only the req engine"
DI="$(mktemp -d)"; mkg "$DI"
echo '{"candidates":[]}' > "$DI/candidates.json"
echo '{"verdicts":[]}'   > "$DI/verdicts.json"
run_g "$DI" SCOUT_ENGINES=req SCOUT_MAX_ISSUES=3 SCOUT_ARTIFACT_DIR="$DI/artifacts"
[ -f "$DI/logs/prompt-req.txt" ] && ok "req engine dispatched (prompt-req.txt written)" || bad "req engine did not run"
[ ! -f "$DI/logs/prompt-bug.txt" ] && ok "no other engine ran (prompt-bug.txt absent)" || bad "an unexpected engine ran"

# ── ledger/bucket wiring: an accepted req issue updates the req accept-rate ───────
echo "Scenario 21 — ledger/bucket: an accepted req issue feeds the req accept-rate"
R3="$(mktemp -d)"; mkg "$R3"
cat > "$R3/issues.json" <<'JSON'
[ {"number":9,"title":"accepted req gap","state":"OPEN","stateReason":null,
   "labels":[{"name":"agent"},{"name":"req"},{"name":"p1"}],"createdAt":"2030-01-01T00:00:00Z",
   "body":"x · confidence high\n<!-- scout-fp: req-acc-1 -->"} ]
JSON
echo '{"candidates":[]}' > "$R3/candidates.json"
echo '{"verdicts":[]}'   > "$R3/verdicts.json"
run_g "$R3" SCOUT_ENGINES=req SCOUT_MAX_ISSUES=3 SCOUT_ARTIFACT_DIR="$R3/artifacts"
assert_grep "$R3/logs/runner.out" "req=100% (1/1)" "req bucket accept-rate computed from the ledger"
assert_grep "$R3/ledger.jsonl" "\"engine\":\"req\"" "accepted req outcome recorded against the req bucket"

# ════════════════════════════════════════════════════════════════════════════════
# issue #55 — PER-REPO LOCK NAMESPACING. The lock/logdir/worktree base must default to
# per-repo paths derived from the git common dir, so two scouts in DIFFERENT repos run
# concurrently WITHOUT relying on systemd's SCOUT_* env overrides, while two scouts of the
# SAME repo still serialize. These scenarios run with the DEFAULT paths (no SCOUT_LOCK etc.).
# ════════════════════════════════════════════════════════════════════════════════
echo "Scenario 22 — default lock/logdir/worktree are per-repo (two repos → distinct paths)"
N1="$(mktemp -d)"; mkg "$N1"
N2="$(mktemp -d)"; mkg "$N2"
run_default "$N1" "$N1/out.txt"
run_default "$N2" "$N2/out.txt"
lockA="$(sed -n 's/.*single-instance lock: //p' "$N1/out.txt" | head -1)"
lockB="$(sed -n 's/.*single-instance lock: //p' "$N2/out.txt" | head -1)"
case "$lockA" in /tmp/agent-scout-*.lock) ok "default lock path is per-repo namespaced under /tmp ($lockA)";; *) bad "default lock path not namespaced: '$lockA'";; esac
if [ -n "$lockA" ] && [ -n "$lockB" ] && [ "$lockA" != "$lockB" ]; then
  ok "two DIFFERENT repos derive DISTINCT default lock paths (cross-repo independence)"
else
  bad "cross-repo lock paths not distinct: A='$lockA' B='$lockB'"
fi
assert_nogrep "$N1/out.txt" "another scan in progress" "repo A ran without being blocked by repo B"
assert_nogrep "$N2/out.txt" "another scan in progress" "repo B ran without being blocked by repo A"
# logdir/worktree are namespaced under the same key (no cross-project clobbering).
case "$lockA" in /tmp/agent-scout-*.lock)
  keyA="${lockA#/tmp/agent-scout-}"; keyA="${keyA%.lock}"
  [ -d "/tmp/agent-scout-$keyA/worktrees" ] && ok "logdir+worktrees co-namespaced under the repo key" \
    || bad "expected per-repo logdir /tmp/agent-scout-$keyA";; esac

echo "Scenario 23 — same repo: a second scout serializes (exits 0 with 'another scan in progress')"
# Hold repo A's DERIVED lock in the test process; a second scout of repo A must then bail.
if exec 9>"$lockA" && flock -n 9; then
  run_default "$N1" "$N1/out2.txt"
  assert_grep "$N1/out2.txt" "another scan in progress" "second scout of the SAME repo exits 0 (serialized)"
  flock -u 9; exec 9>&-
else
  bad "could not acquire repo A's derived lock to simulate an in-progress same-repo scan"
fi

echo "Scenario 24 — cross-repo: repo B still runs while repo A's lock is HELD"
if exec 9>"$lockA" && flock -n 9; then
  run_default "$N2" "$N2/out2.txt"
  assert_nogrep "$N2/out2.txt" "another scan in progress" "repo B acquired its OWN lock while repo A's was held"
  assert_grep "$N2/out2.txt" "scan complete" "repo B completed despite repo A holding its lock"
  flock -u 9; exec 9>&-
else
  bad "could not acquire repo A's lock for the cross-repo contention check"
fi

# clean the per-repo /tmp dirs these default-path runs created (unique mktemp-derived keys).
rm -rf "$lockA" "$lockB" "${lockA%.lock}" "${lockB%.lock}" 2>/dev/null || true

rm -rf "$T1" "$T2" "$L1" "$L2" "$L3" "$L4" "$L5" "$L7" "$L8" "$L9" "$L10" "$L11" "$L12" \
       "$R1" "$R2" "$J1" "$D1" "$U1" "$B1" "$J2" "$DI" "$R3" "$N1" "$N2" 2>/dev/null || true
echo
echo "agent-scout e2e: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
