#!/usr/bin/env bash
# One-time activation for the SEQUENTIAL agent pipeline (docs/AGENT-HARNESS.md). SAFE to re-run
# (idempotent). Creates the GitHub labels + installs/starts the SINGLE agent-pipeline timer that
# drives ONE issue end-to-end: build → PR → review⇄fix → merge → close, then the next issue.
# It SUPERSEDES the four independent stage timers (inbox/reviewer/fixer/merger), which fanned out
# across their whole backlogs in parallel — so this also DISABLES those + deploy-on-merge. The
# merger (run inside the pipeline) is SkillForge's local CI/CD gate (Buildkite retired): it re-runs
# the full gates on the integrated PR and fast-forwards `main` only on green. Deploy stays MANUAL.
# This is the only step with real side-effects, so it is NOT run by the test suite.
#
#   bash scripts/agent-pr-loop-setup.sh                # labels + install + start the pipeline timer
#   bash scripts/agent-pr-loop-setup.sh --labels-only  # just the labels
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "1) Creating GitHub labels (idempotent)…"
gh label create review-needed      --color 0e8a16 --description "pr-loop: ready for (re-)review"                 2>/dev/null || echo "   (review-needed exists)"
gh label create review-wip         --color fbca04 --description "pr-loop: reviewer working (claim)"              2>/dev/null || echo "   (review-wip exists)"
gh label create changes-requested  --color d93f0b --description "pr-loop: reviewer requested changes"            2>/dev/null || echo "   (changes-requested exists)"
gh label create fix-wip            --color fbca04 --description "pr-loop: fixer working (claim)"                 2>/dev/null || echo "   (fix-wip exists)"
gh label create review-approved    --color 1a7f37 --description "pr-loop: passed review — ready to land (NOT merged)" 2>/dev/null || echo "   (review-approved exists)"
gh label create review-stuck       --color b60205 --description "pr-loop: max rounds / unfixable — needs a human" 2>/dev/null || echo "   (review-stuck exists)"
gh label create merge-wip          --color fbca04 --description "pr-loop: merger integrating (claim)"             2>/dev/null || echo "   (merge-wip exists)"
gh label create merged             --color 0e8a16 --description "pr-loop: integrated + auto-merged into main"     2>/dev/null || echo "   (merged exists)"
gh label create merge-stuck        --color b60205 --description "pr-loop: integration conflict / gates red — needs a human" 2>/dev/null || echo "   (merge-stuck exists)"

if [ "${1:-}" = "--labels-only" ]; then echo "labels done."; exit 0; fi

echo "2) Installing the agent-pipeline systemd units…"
# The TEMPLATE units are what actually run: the pipeline is driven by skillforge-agent-pipeline@0,
# @1, @2 (iteration 346, three parallel lanes), not by the un-instanced singleton. This step used
# to copy only the singleton, so every edit to the template — including the merger gate-set
# narrowing in 8bb46028 — sat in the repo and never reached ~/.config/systemd/user. The installed
# template was last placed by hand and had drifted three commits behind by 2026-07-31. Copy both:
# the singleton stays as the reference/fallback (it is left disabled below), the template is live.
mkdir -p "$HOME/.config/systemd/user"
cp "$ROOT"/deploy/systemd/skillforge-agent-pipeline.service \
   "$ROOT"/deploy/systemd/skillforge-agent-pipeline.timer \
   "$ROOT"/deploy/systemd/skillforge-agent-pipeline@.service \
   "$ROOT"/deploy/systemd/skillforge-agent-pipeline@.timer \
   "$ROOT"/deploy/systemd/skillforge-agent-inbox@.service \
   "$ROOT"/deploy/systemd/skillforge-agent-inbox@.timer \
   "$HOME/.config/systemd/user/"
systemctl --user daemon-reload

echo "3) Disabling the OLD parallel stage timers + deploy-on-merge (superseded by the pipeline)…"
# The pipeline runs inbox/reviewer/fixer/merger itself, sequentially. Leaving the per-stage
# timers enabled would double-drive the queue. Deploy is manual — keep deploy-on-merge off.
systemctl --user disable --now \
  skillforge-agent-inbox.timer \
  skillforge-agent-pr-reviewer.timer skillforge-agent-pr-fixer.timer skillforge-agent-pr-merger.timer \
  skillforge-deploy-on-merge.timer 2>/dev/null || true

echo "4) Enabling + starting the pipeline lane timers…"
# PIPELINE_LANES lanes, instantiated from the template. The un-instanced singleton timer must stay
# OFF: it and the lanes drive the same queue, so running both double-drives it.
PIPELINE_LANES="${PIPELINE_LANES:-1}"
systemctl --user disable --now skillforge-agent-pipeline.timer 2>/dev/null || true
for _lane in $(seq 0 $((PIPELINE_LANES - 1))); do
  systemctl --user enable --now "skillforge-agent-pipeline@${_lane}.timer"
done
echo "   lanes enabled: $(seq -s, 0 $((PIPELINE_LANES - 1)))"

# Scale DOWN, not just up. Enabling 0..N-1 does nothing to instances a PREVIOUS run enabled with a
# larger N, so going 3 lanes → 1 used to leave @1 and @2 firing every two minutes while the
# operator believed they were on one lane. Enumerate what is ACTUALLY enabled rather than guessing
# a range — an instance enabled by hand at any index is caught too.
#
# `disable --now` on a TIMER stops the timer, never a service: a lane that is mid-build or
# mid-merge when this runs finishes its work and simply is not re-triggered. Stopping the service
# instead would kill the model process, which on 2026-07-31 stranded a `merge-wip` claim and threw
# away a completed review.
_wants="$HOME/.config/systemd/user/timers.target.wants"
for _t in "$_wants"/skillforge-agent-pipeline@*.timer; do
  [ -e "$_t" ] || continue
  _i="$(basename "$_t")"; _i="${_i#skillforge-agent-pipeline@}"; _i="${_i%.timer}"
  case "$_i" in ''|*[!0-9]*) continue ;; esac        # ignore non-numeric instance names
  [ "$_i" -ge "$PIPELINE_LANES" ] || continue
  echo "   retiring lane ${_i} (beyond PIPELINE_LANES=${PIPELINE_LANES}) — in-flight work is left to finish"
  systemctl --user disable --now "skillforge-agent-pipeline@${_i}.timer" 2>/dev/null || true
done

echo "5) Enabling linger (so the timer runs even when you're logged out)…"
loginctl enable-linger "$USER" 2>/dev/null || echo "   (could not enable linger — run: sudo loginctl enable-linger $USER)"

cat <<'EOF'

✅ Agent pipeline is live — see the lane list printed above; each lane drives one issue end-to-end.
   Lane count is PIPELINE_LANES=<n> (default 1). Re-running with a smaller n retires the extra
   lanes; in-flight work on a retired lane finishes first.
   Status:   systemctl --user list-timers 'skillforge-agent-*'
   Logs:     journalctl --user -u 'skillforge-agent-pipeline@*.service' -f   (and /tmp/skillforge-agent-pipeline/)
   Re-run this script after ANY edit to deploy/systemd/ — the units under
   ~/.config/systemd/user are copies, and systemd never reads the repo.

Per run (scripts/agent-pipeline.sh):
  • if a PR is in flight → drive IT (don't start a new issue);
  • else agent-inbox builds the next `agent` issue → PR `review-needed`;
  • reviewer (opus) → approve (`review-approved`) | request changes (`changes-requested`);
  • fixer (sonnet ≠ reviewer) addresses + re-gates → `review-needed` … until approved or PR_MAX_ROUNDS → `review-stuck`;
  • merger (opus) integrates `review-approved`, re-runs the FULL gates (unit,e2e), fast-forwards `main` on green (`merged`) — else `merge-stuck`;
  • the pipeline then CLOSES the issue (the merger doesn't; there's no Closes-keyword).
CI/CD: the merger's gates ARE the CI gate (Buildkite retired). Deploy is MANUAL — deploy-on-merge is disabled; rebuild the local stack by hand.
EOF
