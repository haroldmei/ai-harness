#!/usr/bin/env bash
# Hermetic test for scripts/agent-pipeline.sh — the sequential per-issue orchestrator.
#
# The four stages + gh are STUBBED; the stubs share a tiny state file that models the PR label
# machine (review-needed → review-approved|changes-requested → review-needed → merged) so the
# driver loop actually progresses and terminates. We assert the SEQUENCING contract:
#   - build a new issue ONLY when nothing is in flight,
#   - drive review ⇄ fix → merge,
#   - close the issue once its PR merged.
#
#   Run: bash scripts/agent-pipeline.test.sh     (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/agent-pipeline.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }
has()    { if [ -f "$1" ]; then ok "$2"; else bad "$2 (expected file $1)"; fi; }
hasnt()  { if [ -f "$1" ]; then bad "$2 (unexpected file $1)"; else ok "$2"; fi; }
agrep()  { if grep -qF -e "$2" -- "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
angrep() { if grep -qF -e "$2" -- "$1" 2>/dev/null; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

make_env() { # <tmp>
  local T="$1"; mkdir -p "$T/bin"
  : > "$T/state"   # PR label; "none" = no PR

  cat > "$T/bin/inbox" <<EOF
#!/usr/bin/env bash
echo "[agent-inbox] claiming issue #50: demo → agent/issue-50 (isolated worktree)"
echo review-needed > "$T/state"
echo ran >> "$T/inbox.calls"
echo "\${AGENT_RUN_ID:-}" >> "$T/run_id.inbox"
EOF
  cat > "$T/bin/reviewer" <<EOF
#!/usr/bin/env bash
st="\$(cat "$T/state" 2>/dev/null)"
if [ "\$st" = review-needed ]; then
  if [ -f "$T/want_changes" ]; then rm -f "$T/want_changes"; echo changes-requested > "$T/state"
  else echo review-approved > "$T/state"; fi
fi
echo ran >> "$T/reviewer.calls"
echo "\${AGENT_RUN_ID:-}" >> "$T/run_id.reviewer"
EOF
  cat > "$T/bin/fixer" <<EOF
#!/usr/bin/env bash
st="\$(cat "$T/state" 2>/dev/null)"
[ "\$st" = changes-requested ] && echo review-needed > "$T/state"
echo ran >> "$T/fixer.calls"
echo "\${AGENT_RUN_ID:-}" >> "$T/run_id.fixer"
EOF
  cat > "$T/bin/merger" <<EOF
#!/usr/bin/env bash
st="\$(cat "$T/state" 2>/dev/null)"
[ "\$st" = review-approved ] && echo merged > "$T/state"
echo ran >> "$T/merger.calls"
echo "\${AGENT_RUN_ID:-}" >> "$T/run_id.merger"
EOF
  # gh stub: serves the PR list / merged-check / issue state from \$T/state, records closes.
  cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$T/gh.calls"
st="\$(cat "$T/state" 2>/dev/null || echo none)"
if [ "\$1" = issue ] && [ "\$2" = list ] && printf '%s ' "\$@" | grep -q -- '--label wip'; then
  # Reaper input: an issue stuck in \`wip\`. STALE_WIP_AT places its updatedAt inside or outside the
  # grace window so the test can exercise both sides.
  [ -f "$T/stale_wip" ] && printf '%s\\t%s\\n' 61 "\${STALE_WIP_AT:-2000-01-01T00:00:00Z}"
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = list ] && printf '%s ' "\$@" | grep -q -- '--label fix-wip'; then
  [ -f "$T/stale_fixwip" ] && printf '%s\\t%s\\n' 62 "\${STALE_WIP_AT:-2000-01-01T00:00:00Z}"
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = list ] && printf '%s ' "\$@" | grep -q -- '--label review-wip'; then
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = list ] && printf '%s ' "\$@" | grep -q -- '--label merge-wip'; then
  # A BATCH: the merger claims every approved PR at once (PR_MERGER_MAX_PRS defaults to 20), so one
  # dead merger strands all of them — the reason merge-wip matters more than the other claims.
  if [ -f "$T/stale_mergewip" ]; then
    printf '%s\\t%s\\n' 71 "\${STALE_WIP_AT:-2000-01-01T00:00:00Z}"
    printf '%s\\t%s\\n' 72 "\${STALE_WIP_AT:-2000-01-01T00:00:00Z}"
  fi
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = list ] && printf '%s ' "\$@" | grep -q -- '--json headRefName ' && ! printf '%s ' "\$@" | grep -qE -- '--json (labels|number)'; then
  # all_open_agent_pr_count(): count ALL open agent PRs regardless of label.
  # Returns a raw integer; the function accepts both raw ints (test) and JSON arrays (production).
  echo "\${OPEN_PR_COUNT:-0}"
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = list ] && printf '%s ' "\$@" | grep -qE -- '--json [^ ]*updatedAt'; then
  # escalate_stale_stuck query
  st="\$(cat "$T/state" 2>/dev/null || echo none)"
  if [ "\$st" = merge-stuck ] && [ -f "$T/stale_stuck" ]; then
    echo "[{\"number\":100,\"headRefName\":\"agent/issue-50\",\"labels\":[{\"name\":\"merge-stuck\"}],\"updatedAt\":\"2000-01-01T00:00:00Z\"}]"
  elif [ "\$st" = review-stuck ] && [ -f "$T/stale_stuck" ]; then
    echo "[{\"number\":100,\"headRefName\":\"agent/issue-50\",\"labels\":[{\"name\":\"review-stuck\"}],\"updatedAt\":\"2000-01-01T00:00:00Z\"}]"
  else
    echo "[]"
  fi
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = list ]; then
  if printf '%s ' "\$@" | grep -q -- '--state all'; then
    # Solution 1: count head-matched PRs carrying the \`merged\` label, regardless of GitHub PR
    # state or branch existence. \`branch_gone\` models the rebase+ff shape (CLOSED, branch deleted,
    # merged label) → still counts. \`no_merged_label\` models a closed-but-unshipped PR → 0.
    if [ -f "$T/no_merged_label" ]; then echo 0
    elif [ "\$st" = merged ] || [ -f "$T/branch_gone" ]; then echo 1
    else echo 0; fi
    exit 0
  fi
  case "\$st" in
    review-needed|changes-requested|review-approved|review-stuck|merge-stuck)
      echo "[{\"number\":100,\"headRefName\":\"agent/issue-50\",\"labels\":[{\"name\":\"\$st\"}]}]";;
    *) echo "[]";;
  esac
  exit 0
fi
if [ "\$1" = pr ] && [ "\$2" = view ] && printf '%s ' "\$@" | grep -q -- '--json comments'; then
  if printf '%s ' "\$@" | grep -q 'capture'; then echo "\${REARM_LAST:-}"; else echo "\${REARM_COUNT:-0}"; fi
  exit 0
fi
if [ "\$1" = issue ] && [ "\$2" = list ]; then
  # OPEN issues labeled \`done\`: model issue #50 when the test arms the marker (and it isn't closed).
  [ -f "$T/done_issue" ] && [ ! -f "$T/closed" ] && echo 50
  exit 0
fi
if [ "\$1" = issue ] && [ "\$2" = view ]; then [ -f "$T/closed" ] && echo CLOSED || echo OPEN; exit 0; fi
if [ "\$1" = issue ] && [ "\$2" = close ]; then touch "$T/closed"; exit 0; fi
exit 0
EOF
  # git stub: drives the re-arm "main advanced past the branch" check.
  # git stub. REBASE_FAIL=1 makes \`git rebase\` fail and CONFLICT_FILES (newline-separated)
  # becomes the unmerged-file list, so the re-arm classifier can be driven down each of its
  # branches: clean / generated-only / real conflicts / failed-with-no-conflict-files.
  cat > "$T/bin/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "$T/git.calls"
case "\$*" in
  *"rev-parse --short"*)  echo "abc123" ;;          # origin/main short SHA
  *"rev-list --count"*)   echo "\${BEHIND:-0}" ;;    # commits main is ahead of the branch
  *"diff --name-only --diff-filter=U"*)
                          [ -n "\${CONFLICT_FILES:-}" ] && printf '%s\n' "\${CONFLICT_FILES}" ;;
  rebase*)                [ "\${REBASE_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  *) exit 0 ;;                                       # fetch / checkout / push / anything else
esac
EOF
  chmod +x "$T"/bin/*
  # AGENT_ROOT points at this fake tree, so the libs the runner sources must exist here. Omitting
  # one used to fail silently (source is non-fatal without `set -e`); the runner now exits 2 with a
  # FATAL line instead, which is why this copy is required rather than merely tidy.
  mkdir -p "$T/scripts/lib" && cp "$ROOT/scripts/lib/pr-lock.sh" "$T/scripts/lib/"
}

run() { # <tmp>
  local T="$1"
  AGENT_ROOT="$T" AGENT_GH="$T/bin/gh" AGENT_GIT="$T/bin/git" \
  PIPELINE_INBOX="$T/bin/inbox" PIPELINE_REVIEWER="$T/bin/reviewer" \
  PIPELINE_FIXER="$T/bin/fixer" PIPELINE_MERGER="$T/bin/merger" \
  PIPELINE_LOCK="$T/lock" PIPELINE_LOGDIR="$T/log" \
    bash "$RUNNER" > "$T/out.txt" 2>&1
}

# ── Scenario 1: nothing in flight → build one issue, drive to merge, close it ────
echo "Scenario 1 — build → review → merge → close (happy path)"
T="$(mktemp -d)"; make_env "$T"; echo none > "$T/state"
run "$T"
has   "$T/inbox.calls"    "inbox ran (built a new issue, nothing was in flight)"
has   "$T/reviewer.calls" "reviewer ran"
has   "$T/merger.calls"   "merger ran"
has   "$T/closed"         "issue #50 was closed after its PR merged"
agrep "$T/state" "merged" "PR reached merged state"
# Telemetry (#2390): the pipeline mints ONE run id and exports it so every child stage's
# spans nest under the same tick — regression guard for the $ROOT-relative source bug that
# made this mint silently no-op in a sandboxed AGENT_ROOT tree (this fixture's $T).
run_id_inbox="$(cat "$T/run_id.inbox" 2>/dev/null)"
run_id_reviewer="$(cat "$T/run_id.reviewer" 2>/dev/null)"
run_id_merger="$(cat "$T/run_id.merger" 2>/dev/null)"
if [ -n "$run_id_inbox" ] && [ "$run_id_inbox" = "$run_id_reviewer" ] && [ "$run_id_inbox" = "$run_id_merger" ]; then
  ok "one AGENT_RUN_ID minted and exported to every child stage"
else
  bad "AGENT_RUN_ID not consistently exported (inbox='$run_id_inbox' reviewer='$run_id_reviewer' merger='$run_id_merger')"
fi

# ── Scenario 2: a PR is already in flight → do NOT build a new issue, drain it ───
echo "Scenario 2 — in-flight PR → drain it first, do NOT build a new issue"
T="$(mktemp -d)"; make_env "$T"; echo review-needed > "$T/state"
run "$T"
hasnt "$T/inbox.calls"    "inbox did NOT run (a PR was still in flight)"
has   "$T/merger.calls"   "merger ran (drained the in-flight PR)"
has   "$T/closed"         "in-flight issue closed after merge"

# ── Scenario 3: reviewer requests changes → fixer fixes → re-review → merge ──────
echo "Scenario 3 — review ⇄ fix loop then merge"
T="$(mktemp -d)"; make_env "$T"; echo none > "$T/state"; touch "$T/want_changes"
run "$T"
has   "$T/inbox.calls"    "inbox ran"
has   "$T/fixer.calls"    "fixer ran (a changes-requested round happened)"
has   "$T/closed"         "issue closed after the fix round merged"
agrep "$T/state" "merged" "PR merged after review⇄fix"
# the reviewer must have run at least twice (request-changes, then approve)
rc="$(wc -l < "$T/reviewer.calls" 2>/dev/null || echo 0)"
[ "${rc:-0}" -ge 2 ] && ok "reviewer ran ≥2 rounds (request-changes then approve)" || bad "reviewer should run ≥2 rounds (got ${rc})"

# ── Scenario 4: re-arm a stuck PR when main has advanced past its branch ─────────
echo "Scenario 4 — review-stuck PR, main advanced (branch behind) → re-armed to review-needed"
T="$(mktemp -d)"; make_env "$T"; echo review-stuck > "$T/state"
BEHIND=2 REARM_COUNT=0 run "$T"
agrep  "$T/out.txt" "re-arming stuck PR #100" "detected stuck PR with main ahead → re-arm"
agrep  "$T/gh.calls" "labels/review-stuck"    "dropped review-stuck"
agrep  "$T/gh.calls" "labels[]=review-needed" "re-enrolled as review-needed"
agrep  "$T/gh.calls" "pr comment 100"         "left a re-arm marker comment"

# ── Scenario 5: stuck PR but main has NOT advanced → leave it alone ──────────────
echo "Scenario 5 — review-stuck PR, branch up-to-date (behind=0) → NOT re-armed"
T="$(mktemp -d)"; make_env "$T"; echo review-stuck > "$T/state"
BEHIND=0 run "$T"
angrep "$T/gh.calls" "labels/review-stuck"    "no re-arm when main hasn't advanced past the branch"

# ── Scenario 6: stuck PR, re-arm budget exhausted → leave it alone ───────────────
echo "Scenario 6 — review-stuck PR, re-arm budget exhausted → leave it (truly stuck)"
T="$(mktemp -d)"; make_env "$T"; echo review-stuck > "$T/state"
BEHIND=2 REARM_COUNT=3 PIPELINE_REARM_MAX=3 run "$T"
angrep "$T/gh.calls" "labels[]=review-needed" "no re-arm past the budget"
agrep  "$T/out.txt"  "budget exhausted"        "logged budget exhaustion"

# ── Scenario 7: PR merged OUTSIDE this run (race / external / earlier-tick failure) ──────────
# The PR is already merged and is NOT driveable, so nothing is built or driven this run and the
# issue is absent from target_issues. The stateless reconcile sweep must still close it via its
# OPEN+`done` membership — this is the regression guard for the #901 post-merge-race strand.
echo "Scenario 7 — merged PR, issue not in target_issues → reconcile sweep closes it"
T="$(mktemp -d)"; make_env "$T"
echo merged > "$T/state"     # PR already merged: not driveable, not built this run
touch "$T/done_issue"        # issue #50 is OPEN and labeled \`done\`
cat > "$T/bin/inbox" <<EOF   # inbox finds nothing eligible → target_issues stays empty
#!/usr/bin/env bash
echo ran >> "$T/inbox.calls"
EOF
chmod +x "$T/bin/inbox"
run "$T"
hasnt "$T/merger.calls" "merger did NOT run (nothing driveable in flight)"
has   "$T/closed"       "open \`done\` issue with a merged PR was closed by the reconcile sweep"
agrep "$T/out.txt" "closed issue #50 (PR merged)" "logged the reconcile close (not gated on target_issues)"

# ── Scenario 8: shipped PR, head branch deleted, state=CLOSED, NO issue comment → still closed ──
# Regression guard for #901/#931/#902: the merger rebases+fast-forwards (not a GitHub merge), so a
# shipped PR is state=CLOSED with the branch deleted (the #967/#1007/#1008 shape), and a manually-
# recovered issue has NO `PR:…/pull/N` comment. `--head …issue-<N> --state all` matches the PR by
# its immutable head ref and the close hinges purely on the `merged` LABEL — independent of GitHub
# state, branch existence, and any issue comment.
echo "Scenario 8 — shipped PR, branch deleted, state=CLOSED, no issue comment → --state all + merged label closes it"
T="$(mktemp -d)"; make_env "$T"
echo merged > "$T/state"   # internal model: the PR shipped...
touch "$T/branch_gone"     # ...branch deleted, GitHub state CLOSED — but it carries the `merged` label
touch "$T/done_issue"      # issue #50 is OPEN and labeled `done`; NO PR:…/pull/N comment is modelled
cat > "$T/bin/inbox" <<EOF # inbox finds nothing → target_issues empty (stray, not driven this run)
#!/usr/bin/env bash
echo ran >> "$T/inbox.calls"
EOF
chmod +x "$T/bin/inbox"
run "$T"
has   "$T/closed"  "stray shipped issue closed via --head --state all + merged label (branch deleted, no comment)"
agrep "$T/out.txt" "closed issue #50 (PR merged)" "logged the reconcile close"

# ── Scenario 9: deleted-branch PR, state=CLOSED, but NO `merged` label → sweep does NOT close ──
# The false-positive guard. The branch is gone and GitHub state is CLOSED — exactly the shape that
# would tempt a `branch-gone ⇒ assume shipped` heuristic. Because the merger never stamped the
# `merged` label (a closed-unmerged PR), the sweep MUST leave the issue OPEN. This proves the close
# hinges on the LABEL, not on branch state or PR state.
echo "Scenario 9 — deleted-branch PR, state=CLOSED, NO merged label → sweep leaves the issue OPEN"
T="$(mktemp -d)"; make_env "$T"
echo merged > "$T/state"     # irrelevant here (no_merged_label forces the --state all count to 0)
touch "$T/branch_gone"       # branch gone, PR state=CLOSED — the tempting-but-wrong shape
touch "$T/no_merged_label"   # ...but the merger never stamped `merged` → NOT shipped
touch "$T/done_issue"        # issue #50 is OPEN and labeled `done`
cat > "$T/bin/inbox" <<EOF   # inbox finds nothing → target_issues empty
#!/usr/bin/env bash
echo ran >> "$T/inbox.calls"
EOF
chmod +x "$T/bin/inbox"
run "$T"
hasnt "$T/closed"  "issue WITHOUT the merged label was NOT closed (no false positive on state=CLOSED)"
angrep "$T/out.txt" "closed issue #50 (PR merged)" "no reconcile-close logged for the unshipped PR"

# ── Two drivers must never dispatch on the SAME PR (#2152) ────────────────────────
# The failure this pins: two pipeline instances both see the one in-flight PR, both run
# reviewer+fixer on it, and two fixer runs in one round produce divergent commits. `drivable_prs`
# filters out PRs another instance holds a per-PR lock on, so instance B must find nothing to drive.
# The gh stub reports PR 100 whenever $T/state names a driveable label.
echo "J-PL-EXTRA — a PR held by another instance is not driven (per-PR exclusion)"
T="$(mktemp -d)"; make_env "$T"
echo review-needed > "$T/state"
export PR_LOCK_DIR="$T/prlocks"; mkdir -p "$PR_LOCK_DIR"
( source "$ROOT/scripts/lib/pr-lock.sh"; pr_lock_try _f 100 && exec sleep 30 ) &
holder=$!
for _ in $(seq 1 50); do
  ( source "$ROOT/scripts/lib/pr-lock.sh"; pr_lock_is_held 100 ) && break
  sleep 0.1
done
run "$T"
agrep "$T/out.txt" "is being driven by another instance" "instance B declined the PR another instance holds"
hasnt "$T/reviewer.calls" "reviewer NOT dispatched on a PR another instance holds"
hasnt "$T/fixer.calls"    "fixer NOT dispatched on a PR another instance holds (the #2152 shape)"
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
# Once the holder is gone the PR becomes drivable again — the exclusion must not be sticky.
: > "$T/out.txt"; run "$T"
agrep "$T/reviewer.calls" "" "reviewer dispatched once the other instance released the PR" 2>/dev/null \
  || { [ -f "$T/reviewer.calls" ] && ok "reviewer dispatched once the PR was released" \
       || bad "PR stayed undrivable after its holder died"; }
unset PR_LOCK_DIR
rm -rf "$T" 2>/dev/null || true

# ── Stale-claim reaper ────────────────────────────────────────────────────────────
# A claim LABEL outlives the process that wrote it, so a build/fix killed mid-flight leaves `wip` or
# `fix-wip` set with nobody working — and because those labels exclude the job from every lane's
# eligibility the job is stranded until a human intervenes (#2086; two PRs sat in `fix-wip` on
# 2026-07-25 while three lanes idled). The per-job flock makes "claimed but unlocked" decidable.
echo "J-PL-REAP — a claim whose holder is gone is released; a live one is not"
T="$(mktemp -d)"; make_env "$T"
export PR_LOCK_DIR="$T/claims"; mkdir -p "$PR_LOCK_DIR"
touch "$T/stale_wip" "$T/stale_fixwip" "$T/stale_mergewip"
run "$T"
agrep "$T/gh.calls" "issues/61/labels/wip"      "stale wip removed from the issue"
agrep "$T/gh.calls" "labels[]=agent"            "issue re-queued for a fresh build"
agrep "$T/gh.calls" "issues/62/labels/fix-wip"  "stale fix-wip removed from the PR"
agrep "$T/gh.calls" "labels[]=changes-requested" \
  "PR restored to changes-requested (fix-wip is NOT in the driveable set, so it would rot otherwise)"
# The whole BATCH is released — this is the case with the worst blast radius, since one dead merger
# holding 20 PRs would otherwise strand every one of them invisibly.
agrep "$T/gh.calls" "issues/71/labels/merge-wip"  "stale merge-wip released on the first batched PR"
agrep "$T/gh.calls" "issues/72/labels/merge-wip"  "stale merge-wip released on the second batched PR"
agrep "$T/gh.calls" "labels[]=review-approved"    "batched PRs restored to review-approved (back in the driveable set)"

# A LIVE claim must survive: same labels, but a process holds the locks.
T2="$(mktemp -d)"; make_env "$T2"
export PR_LOCK_DIR="$T2/claims"; mkdir -p "$PR_LOCK_DIR"
touch "$T2/stale_wip" "$T2/stale_fixwip" "$T2/stale_mergewip"
# A live merger holds a per-PR lock for EVERY PR in its batch, so both 71 and 72 must survive.
( source "$ROOT/scripts/lib/pr-lock.sh"; issue_lock_try _a 61; pr_lock_try _b 62; pr_lock_try _c 71; pr_lock_try _d 72; exec sleep 30 ) &
holder=$!
for _ in $(seq 1 50); do
  ( source "$ROOT/scripts/lib/pr-lock.sh"; issue_lock_is_held 61 ) && break
  sleep 0.1
done
run "$T2"
angrep "$T2/gh.calls" "issues/61/labels/wip"     "a LIVE build's wip claim is left alone"
angrep "$T2/gh.calls" "issues/62/labels/fix-wip" "a LIVE fixer's claim is left alone"
angrep "$T2/gh.calls" "issues/71/labels/merge-wip" "a LIVE merger's batch is left alone (PR 71)"
angrep "$T2/gh.calls" "issues/72/labels/merge-wip" "a LIVE merger's batch is left alone (PR 72)"
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# Inside the grace window nothing is reaped even when unlocked — that window is what stops the
# reaper stealing a job in the gap between labelling and locking.
T3="$(mktemp -d)"; make_env "$T3"
export PR_LOCK_DIR="$T3/claims"; mkdir -p "$PR_LOCK_DIR"
touch "$T3/stale_wip"
STALE_WIP_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" run "$T3"
angrep "$T3/gh.calls" "issues/61/labels/wip" "a freshly-updated claim is inside the grace window and kept"
unset PR_LOCK_DIR
rm -rf "$T2" "$T3" 2>/dev/null || true

# ── Scenario J-PL-CAP — at capacity (≥3 open agent PRs), inbox does NOT fire ───
unset PR_LOCK_DIR
Tc="$(mktemp -d)"; make_env "$Tc"
OPEN_PR_COUNT=3 run "$Tc"
hasnt  "$Tc/inbox.calls" "inbox did NOT fire — at capacity (3 open PRs, cap 3)"
agrep  "$Tc/out.txt" "at capacity" "logged the capacity message"
rm -rf "$Tc" 2>/dev/null || true

# ── Scenario J-PL-CAP-BELOW — below cap, inbox runs normally ─────────────────────
Tb="$(mktemp -d)"; make_env "$Tb"
OPEN_PR_COUNT=1 run "$Tb"
has    "$Tb/inbox.calls" "inbox DID fire — below cap (1 open PR, cap 3)"
rm -rf "$Tb" 2>/dev/null || true

# ── Scenario J-PL-ESCALATE — stale merge-stuck PR → escalated to needs-human ─────
Te="$(mktemp -d)"; make_env "$Te"
echo merge-stuck > "$Te/state"
touch "$Te/stale_stuck"
REARM_COUNT=3 run "$Te"
agrep "$Te/gh.calls" "needs-human" "stale stuck PR escalated to needs-human"
agrep "$Te/out.txt" "escalating stale stuck" "logged the escalation"
rm -rf "$Te" 2>/dev/null || true

# ── J-PL-C1: the re-arm rebase classifier must actually GATE the re-arm ──────────
# The classifier lives in a `( … )` subshell and used `continue` to skip the relabel that
# follows it. `continue` in a subshell with no loop is a bash ERROR, not a skip: it printed
# to stderr and execution carried on into the relabel. A PR with real conflicts was
# escalated to needs-human AND re-armed, re-entering the merge loop holding needs-human
# (issue #2387, C1). These three scenarios pin one branch of the classifier each.
echo "J-PL-C1a — rebase with REAL conflicts → needs-human, and NOT re-armed"
Tc="$(mktemp -d)"; make_env "$Tc"; echo review-stuck > "$Tc/state"
BEHIND=2 REARM_COUNT=0 REBASE_FAIL=1 CONFLICT_FILES="backend/app/api/v1/endpoints/auth.py" run "$Tc"
agrep  "$Tc/out.txt"  "real conflicts" "classified as real conflicts"
agrep  "$Tc/gh.calls" "labels[]=needs-human" "escalated to needs-human"
# The bug: these ran anyway. review-stuck must NOT be swapped for review-needed.
angrep "$Tc/gh.calls" "labels[]=review-needed" "did NOT re-arm the PR to review-needed"
# The escalation must remove the stuck label the PR actually carries, so it lands on
# needs-human alone rather than needs-human + review-stuck. The old code passed the whole
# comma-joined label list ("review-stuck,agent") as ONE label name via `${labels%%:*}` — a
# no-op strip, since there is no colon in the list — so the DELETE silently 404'd.
agrep  "$Tc/gh.calls" "issues/100/labels/review-stuck" "stripped the stuck label it actually carried"
angrep "$Tc/gh.calls" "labels/review-stuck,agent" "did not send a comma-joined label list as one name"
rm -rf "$Tc" 2>/dev/null || true

echo "J-PL-C1b — rebase conflicts ONLY in generated files → auto-resolved and re-armed"
Tg="$(mktemp -d)"; make_env "$Tg"; echo review-stuck > "$Tg/state"
BEHIND=2 REARM_COUNT=0 REBASE_FAIL=1 CONFLICT_FILES="docs/06-iteration-log.md" run "$Tg"
agrep  "$Tg/out.txt"  "auto-resolving" "generated-file conflicts auto-resolved"
agrep  "$Tg/gh.calls" "labels[]=review-needed" "re-armed to review-needed (this branch SHOULD re-arm)"
angrep "$Tg/gh.calls" "labels[]=needs-human" "did not escalate a generated-file conflict"
rm -rf "$Tg" 2>/dev/null || true

echo "J-PL-C1c — rebase failed with NO conflict files → skipped, nothing relabelled"
Tn="$(mktemp -d)"; make_env "$Tn"; echo review-stuck > "$Tn/state"
BEHIND=2 REARM_COUNT=0 REBASE_FAIL=1 CONFLICT_FILES="" run "$Tn"
agrep  "$Tn/out.txt"  "no conflict files" "classified as a transient non-conflict failure"
angrep "$Tn/gh.calls" "labels[]=review-needed" "did NOT re-arm after a transient rebase failure"
angrep "$Tn/gh.calls" "labels[]=needs-human" "did NOT escalate a transient rebase failure"
# H5: the "no conflict files" block was duplicated verbatim ten lines below itself. With the
# broken `continue` the copy was reachable, so the message printed twice and the run then fell
# into the generated-files branch and force-pushed an UN-rebased branch. One log line, no push.
dupes="$(grep -c "no conflict files" "$Tn/out.txt" 2>/dev/null || echo 0)"
[ "${dupes:-0}" -eq 1 ] && ok "the transient-failure branch is not duplicated (logged once)" \
  || bad "transient-failure log printed ${dupes}× — the duplicated block is back (H5)"
angrep "$Tn/git.calls" "push --force" "did not force-push a branch that never rebased"
rm -rf "$Tn" 2>/dev/null || true

# ── J-PL-H3: merge-stuck recovery must not be blocked by a lock nobody holds ─────
# The guard was `[ -f "$lock" ] && flock -n …`: a MISSING lock file fell to the else branch
# and logged "merger lock held", so recovery never ran and reported the opposite reason.
# The default path was also missing the $NS suffix agent-pr-merger.sh appends, so outside
# systemd the two never named the same file at all (issue #2387, H3).
echo "J-PL-H3 — merge-stuck recovery runs when no merger holds the lock (fails open)"
Th="$(mktemp -d)"; make_env "$Th"; echo merge-stuck > "$Th/state"
PR_MERGER_LOCK="$Th/definitely-absent.lock" run "$Th"
agrep  "$Th/out.txt"  "recovering merge-stuck PR #100" "recovery ran with no lock file present"
angrep "$Th/out.txt"  "skipping merge-stuck recovery" "did not claim the lock was held"
rm -rf "$Th" 2>/dev/null || true

echo "J-PL-H3b — recovery DOES stand down while a merger genuinely holds the lock"
Th2="$(mktemp -d)"; make_env "$Th2"; echo merge-stuck > "$Th2/state"
: > "$Th2/merger.lock"
# Hold it for the duration of the run, exactly as a live merger would.
flock "$Th2/merger.lock" -c 'sleep 20' & held=$!
sleep 0.3
PR_MERGER_LOCK="$Th2/merger.lock" run "$Th2"
kill "$held" 2>/dev/null || true; wait "$held" 2>/dev/null || true
agrep  "$Th2/out.txt" "skipping merge-stuck recovery" "stood down while the lock was genuinely held"
angrep "$Th2/out.txt" "recovering merge-stuck PR" "did not recover behind a live merger"
rm -rf "$Th2" 2>/dev/null || true

rm -rf "$T" 2>/dev/null || true
echo
echo "agent-pipeline: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
