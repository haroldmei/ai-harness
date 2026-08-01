#!/usr/bin/env bash
# Hermetic e2e for the PR reviewer (scripts/agent-pr-reviewer.sh). gh + claude STUBBED:
# zero real GitHub I/O, zero LLM cost, deterministic.
# Scenarios: J-PR-1 (request-changes), J-PR-2 (approve, no merge), J-PR-6 (R==F → refuse),
#            J-PR-7 (transient 429/session-limit → retry, NOT review-stuck),
#            J-PR-8 (genuine no-verdict, model ran clean → review-stuck),
#            J-PR-13/14 (verdict shape: pretty-printed multi-line, ```json-fenced).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/agent-pr-reviewer.sh"
# Keep per-PR claim locks inside the suite's own tree. lib/pr-lock.sh defaults
# PR_LOCK_DIR to /tmp and names the file after the PR NUMBER alone, so this suite and
# its two siblings (reviewer/fixer/merger all drive PR #42) shared one lockfile the
# moment they ran concurrently — each stole the others' claim and the runs skipped the
# PR they were asserting on. It also raced any REAL lane's claim on the same number.
# Same fix agent-inbox.test.sh already carries (issues #2387 M4, #2412).
_SUITE_LOCKS="$(mktemp -d)"; export PR_LOCK_DIR="$_SUITE_LOCKS"
trap 'rm -rf "$_SUITE_LOCKS" 2>/dev/null || true' EXIT
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_grep()   { if grep -qF "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_nogrep() { if grep -qF "$2" "$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

make_env() {
  local tmp="$1" verdict="$2"
  mkdir -p "$tmp/bin" "$tmp/logs"; : > "$tmp/logs/gh.log"
  mkdir -p "$tmp/scripts/lib" && cp "$ROOT/scripts/lib/agent-model-call.sh" "$ROOT/scripts/lib/agent-sandbox.sh" "$ROOT/scripts/lib/pr-lock.sh" "$tmp/scripts/lib/"
  # gh stub: serves one review-needed PR; records comment/edit/review; answers --jq probes.
  cat > "$tmp/bin/gh" <<GH
#!/usr/bin/env bash
echo "gh \$*" >> "$tmp/logs/gh.log"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  echo '[{"number":7,"headRefName":"agent/issue-5","title":"add thing","url":"u","labels":[{"name":"review-needed"}]}]'; exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  case "\$*" in *pr-loop-round*) echo "0";; *) echo "";; esac; exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "diff" ]; then echo "diff --git a/x.ts b/x.ts"; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then echo "ISSUE #5: acceptance — X must Y"; exit 0; fi
exit 0
GH
  chmod +x "$tmp/bin/gh"
  # claude stub: emits a CLI JSON envelope on stdout with the verdict embedded in .result.
  #   transient → model NEVER ran: is_error 429 envelope (session limit).
  #   noverdict → model ran but .result is NOT valid JSON (genuine failure — e.g. prose).
  #   empty     → the #2407 signature: exit 0 having written NOTHING to stdout or stderr. The
  #               model may well have run to completion; the CLI just never serialised its
  #               envelope. Indistinguishable from success or failure at the harness boundary.
  #   pretty    → the #2419 signature: a valid verdict PRETTY-PRINTED across many lines, with no
  #               fences (exactly what the prompt asks for). Every other fixture here emits its
  #               object on ONE line, which is the only shape the old extractor could handle —
  #               so the parser bug that routed #2419 to review-stuck was invisible to this
  #               suite. Whether the model wraps its JSON is not something the harness controls.
  #   fenced    → the model ignores "no markdown fences" and wraps it in ```json … ```.
  cat > "$tmp/bin/claude" <<CL
#!/usr/bin/env bash
echo "claude \$*" >> "$tmp/logs/claude.log"
if [ "$verdict" = "empty" ]; then
  exit 0
fi
if [ "$verdict" = "pretty" ]; then
  echo '{"is_error":false,"result":"{\n  \"verdict\": \"request-changes\",\n  \"summary\": \"pretty-printed across lines\",\n  \"findings\": [\n    {\n      \"file\": \"x.ts\",\n      \"line\": \"10\",\n      \"severity\": \"major\",\n      \"issue\": \"no test for the new branch\"\n    }\n  ]\n}"}'
  exit 0
fi
if [ "$verdict" = "fenced" ]; then
  echo '{"is_error":false,"result":"Here is the review:\n\`\`\`json\n{\n  \"verdict\": \"approve\",\n  \"summary\": \"wrapped in a fence\",\n  \"findings\": []\n}\n\`\`\`"}'
  exit 0
fi
if [ "$verdict" = "transient" ]; then
  echo '{"is_error":true,"api_error_status":429,"output_tokens":0,"result":"You'\''ve hit your session limit · resets 1:20pm (Australia/Sydney)"}'
  exit 0
fi
if [ "$verdict" != "noverdict" ]; then
  if [ "$verdict" = "approve" ]; then
    echo '{"is_error":false,"result":"{\"verdict\":\"approve\",\"summary\":\"meets the criterion\",\"findings\":[]}"}'
  else
    echo '{"is_error":false,"result":"{\"verdict\":\"request-changes\",\"summary\":\"missing a test\",\"findings\":[{\"file\":\"x.ts\",\"line\":\"10\",\"severity\":\"major\",\"issue\":\"no test for the new branch\"}]}"}'
  fi
else
  echo '{"is_error":false,"result":"ok"}'
fi
exit 0
CL
  chmod +x "$tmp/bin/claude"
}
run() {
  local tmp="$1"; shift
  # `env` is required: assignment-prefixes from "$@" expansion are NOT honoured by bash as
  # env assignments (only literal ones are) — env treats every VAR=val arg as an assignment.
  env PR_ROOT="$tmp" PR_GH="$tmp/bin/gh" PR_CLAUDE="$tmp/bin/claude" \
    PR_REVIEWER_LOCK="$tmp/rv.lock" PR_LOGDIR="$tmp/logs" \
    "$@" bash "$RUNNER" > "$tmp/logs/out" 2>&1
}

echo "J-PR-1 — reviewer requests changes"
T1="$(mktemp -d)"; make_env "$T1" request-changes; run "$T1"
assert_grep "$T1/logs/gh.log" "pr comment 7" "posted a review comment"
assert_grep "$T1/logs/gh.log" "labels[]=changes-requested" "labelled changes-requested"
assert_grep "$T1/logs/gh.log" "no test for the new branch" "comment carries the file:line finding"
assert_nogrep "$T1/logs/gh.log" "labels[]=review-approved" "did NOT approve"
# Telemetry (#2390): the review span must actually be written — a regression that broke the span
# call site (e.g. reintroducing a $ROOT-relative lib source that no-ops in a sandbox like this
# one) would otherwise pass every other assertion here.
t1_spans="$(ls "$T1"/state/traces/spans-*.jsonl 2>/dev/null | head -1)"
if [ -n "$t1_spans" ]; then
  t1_stage="$(jq -rs '[.[] | select(.stage=="review")][0].stage // empty' "$t1_spans")"
  [ "$t1_stage" = "review" ] && ok "review span written for the happy-path reviewer run" \
    || bad "no 'review' stage span found in $t1_spans"
else
  bad "no trace spans file written for the happy-path reviewer run"
fi

echo "J-PR-2 — reviewer approves a clean PR (no merge)"
T2="$(mktemp -d)"; make_env "$T2" approve; run "$T2"
assert_grep   "$T2/logs/gh.log" "labels[]=review-approved" "labelled review-approved"
assert_nogrep "$T2/logs/gh.log" "pr merge" "did NOT merge (approval is terminal, not a merge)"
assert_nogrep "$T2/logs/gh.log" "labels[]=changes-requested" "no changes requested on a clean PR"

echo "J-PR-6 — R == F is refused (fail-fast)"
T6="$(mktemp -d)"; make_env "$T6" approve
run "$T6" PR_REVIEWER_MODEL=opus PR_FIXER_MODEL=opus; rc=$?
[ "$rc" -ne 0 ] && ok "exited non-zero when reviewer==fixer model" || bad "should refuse when R==F"
assert_nogrep "$T6/logs/gh.log" "pr comment" "did not touch the PR when models match"

echo "J-PR-7 — transient 429 (session limit) → retried, NOT review-stuck, no round burned"
T7="$(mktemp -d)"; make_env "$T7" transient; run "$T7"
assert_grep   "$T7/logs/claude.log" "claude" "reviewer model was invoked"
assert_nogrep "$T7/logs/gh.log" "labels[]=review-stuck" "a transient limit did NOT escalate to a human"
assert_nogrep "$T7/logs/gh.log" "could not produce a verdict" "did NOT post the stuck comment"
assert_grep   "$T7/logs/gh.log" "labels[]=review-needed" "PR returned to review-needed for the next tick"
assert_grep   "$T7/logs/gh.log" "labels/review-wip" "claimed review-wip label was released"
assert_grep   "$T7/logs/out" "transient limit" "logged the transient-limit skip"

echo "J-PR-8 — model ran clean but wrote NO verdict (genuine failure) → review-stuck"
T8="$(mktemp -d)"; make_env "$T8" noverdict; run "$T8"
assert_grep   "$T8/logs/gh.log" "labels[]=review-stuck" "a genuine no-verdict failure still routes to review-stuck"
assert_grep   "$T8/logs/gh.log" "could not produce a verdict" "posted the stuck comment for the human"
assert_nogrep "$T8/logs/gh.log" "labels[]=review-needed" "did not bounce a genuine failure back to review-needed"

echo "J-PR-10 — an EMPTY envelope (CLI wrote nothing) is retried, NOT escalated (#2407)"
# On 2026-07-31 a review of PR #2407 completed and emitted a valid verdict, but the CLI exited 0
# without writing its envelope. The 0-byte file classified `hard`, so the reviewer escalated to
# "needs a human" and the pipeline burned a re-arm + rebase on a review that had actually
# succeeded. An empty envelope means the harness learned nothing — that is a retry, not a verdict.
T10="$(mktemp -d)"; make_env "$T10" empty; run "$T10" PR_EMPTY_ENVELOPE_RETRIES=2
assert_grep   "$T10/logs/claude.log" "claude" "reviewer model was invoked"
assert_nogrep "$T10/logs/gh.log" "labels[]=review-stuck" "an empty envelope did NOT escalate on the first attempt"
assert_nogrep "$T10/logs/gh.log" "could not produce a verdict" "did NOT post the stuck comment"
assert_grep   "$T10/logs/gh.log" "labels[]=review-needed" "PR returned to review-needed for the next tick"
assert_grep   "$T10/logs/out" "NO output envelope" "logged the empty-envelope retry"

echo "J-PR-11 — consecutive empty envelopes DO escalate once the cap is exhausted"
# The counterweight to J-PR-10: a permanently silent CLI (broken install, dead credentials) must
# reach a human rather than bounce the PR between review-needed and review-wip forever.
T11="$(mktemp -d)"; make_env "$T11" empty
run "$T11" PR_EMPTY_ENVELOPE_RETRIES=1          # attempt 1 → within cap → retry
: > "$T11/logs/gh.log"                          # judge ONLY the second attempt
run "$T11" PR_EMPTY_ENVELOPE_RETRIES=1          # attempt 2 → over cap → escalate
assert_grep   "$T11/logs/gh.log" "labels[]=review-stuck" "escalated once the cap was exhausted"
assert_grep   "$T11/logs/gh.log" "exited without writing an output envelope" "stuck comment names the REAL failure"
assert_nogrep "$T11/logs/gh.log" "could not produce a verdict" "did not use the misleading no-verdict wording"

echo "J-PR-12 — a classifiable result CLEARS the empty streak (cap counts CONSECUTIVE empties)"
# Without this the counter is a lifetime tally: three unrelated hiccups weeks apart would escalate
# a perfectly healthy PR on the third.
T12="$(mktemp -d)"; make_env "$T12" empty
run "$T12" PR_EMPTY_ENVELOPE_RETRIES=1          # streak = 1
make_env "$T12" approve; run "$T12" PR_EMPTY_ENVELOPE_RETRIES=1   # CLI recovers → streak cleared
make_env "$T12" empty; : > "$T12/logs/gh.log"
run "$T12" PR_EMPTY_ENVELOPE_RETRIES=1          # streak restarts at 1 → retry, NOT stuck
assert_nogrep "$T12/logs/gh.log" "labels[]=review-stuck" "an intervening success reset the streak"
assert_grep   "$T12/logs/gh.log" "labels[]=review-needed" "retried again after the reset"

echo "J-PR-13 — a PRETTY-PRINTED (multi-line, unfenced) verdict parses (#2419)"
# On 2026-07-31 the reviewer produced a complete request-changes verdict for PR #2419 and the
# harness threw it away: the bare-object extractor `sed -n '/^{/,/^}$/{p;q}'` quit on the opening
# `{`, that single character was non-empty so the raw fallback was skipped, and jq failed. PR
# #2417 had been approved five minutes earlier on the same model — its object happened to be on
# one line. The prompt forbids fences, so unfenced multi-line is the SHAPE THE PROMPT ASKS FOR;
# it must never depend on whether the model wrapped its output.
T13="$(mktemp -d)"; make_env "$T13" pretty; run "$T13"
assert_grep   "$T13/logs/gh.log" "labels[]=changes-requested" "a multi-line verdict was parsed and acted on"
assert_grep   "$T13/logs/gh.log" "no test for the new branch" "findings survived the multi-line parse"
assert_nogrep "$T13/logs/gh.log" "labels[]=review-stuck" "did NOT escalate a verdict it had in hand"
assert_nogrep "$T13/logs/gh.log" "could not produce a verdict" "did not claim the model produced no verdict"

echo 'J-PR-14 — a ```json-FENCED verdict still parses (salvage rung)'
# The prompt says no fences, but a model that adds them anyway must not strand the PR. This keeps
# the fence extractor honest now that the raw result is tried first.
T14="$(mktemp -d)"; make_env "$T14" fenced; run "$T14"
assert_grep   "$T14/logs/gh.log" "labels[]=review-approved" "unwrapped the fence and read the verdict"
assert_nogrep "$T14/logs/gh.log" "labels[]=review-stuck" "did NOT escalate a fenced verdict"

echo "J-PR-9 — the reviewer model NEVER touches the primary checkout (runs in an isolated worktree)"
# The reviewer runs claude with bypassPermissions; the model `git checkout`s the PR branch to
# inspect it. The intended design is that it works ONLY in its own temp worktree and never moves
# the primary repo's HEAD. This proves it: a real clone on main + a claude stub that checks out
# the branch; the primary clone must stay on main.
T9="$(mktemp -d)"; mkdir -p "$T9/bin" "$T9/logs"; : > "$T9/logs/gh.log"; : > "$T9/logs/claude.log"
git init -q --bare "$T9/origin.git"
git clone -q "$T9/origin.git" "$T9/clone" 2>/dev/null
mkdir -p "$T9/clone/scripts/lib" && cp "$ROOT/scripts/lib/agent-model-call.sh" "$ROOT/scripts/lib/agent-sandbox.sh" "$ROOT/scripts/lib/pr-lock.sh" "$T9/clone/scripts/lib/"
( cd "$T9/clone"
  git config user.email t@t; git config user.name tester
  echo base > base.txt; git add -A; git commit -qm init; git branch -M main; git push -q origin main
  git checkout -q -b agent/issue-5; echo work > target.txt; git add -A; git commit -qm "pr work"; git push -q origin agent/issue-5
  git checkout -q main ) 2>/dev/null
cat > "$T9/bin/gh" <<GH
#!/usr/bin/env bash
echo "gh \$*" >> "$T9/logs/gh.log"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  echo '[{"number":7,"headRefName":"agent/issue-5","title":"t","url":"u","labels":[{"name":"review-needed"}]}]'; exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "diff" ]; then echo "diff --git a/target.txt b/target.txt"; exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then echo "ISSUE #5: acceptance"; exit 0; fi
exit 0
GH
chmod +x "$T9/bin/gh"
cat > "$T9/bin/claude" <<CL
#!/usr/bin/env bash
echo "claude cwd=\$(pwd)" >> "$T9/logs/claude.log"
git checkout agent/issue-5 >/dev/null 2>&1 || true
echo '{"is_error":false,"result":"{\"verdict\":\"approve\",\"summary\":\"ok\",\"findings\":[]}"}'; exit 0
CL
chmod +x "$T9/bin/claude"
env PR_ROOT="$T9/clone" PR_GH="$T9/bin/gh" PR_CLAUDE="$T9/bin/claude" PR_REMOTE="origin" \
  PR_LOGDIR="$T9/logs" PR_REVIEWER_LOCK="$T9/rv.lock" PR_WORKTREE_BASE="$T9/wt" \
  bash "$RUNNER" > "$T9/logs/out" 2>&1
[ "$(git -C "$T9/clone" branch --show-current)" = "main" ] && ok "primary checkout stayed on main (reviewer used an isolated worktree)" || bad "primary checkout was disturbed by the reviewer"
assert_grep "$T9/logs/gh.log" "labels[]=review-approved" "still produced the verdict from the worktree"

rm -rf "$T1" "$T2" "$T6" "$T7" "$T8" "$T9" "$T10" "$T11" "$T12" "$T13" "$T14" 2>/dev/null || true
echo; echo "agent-pr-reviewer e2e: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
