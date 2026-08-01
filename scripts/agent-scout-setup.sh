#!/usr/bin/env bash
# One-time activation for the agent-scout loop. SAFE to re-run (idempotent).
# This is the only step with real side-effects (creates GitHub labels on your repo and
# installs+starts a user systemd timer), so it is NOT run by the test suite — run it
# yourself when you want the producer loop live.
#
#   bash scripts/agent-scout-setup.sh          # create labels + install + start the timer
#   bash scripts/agent-scout-setup.sh --labels-only   # just the labels
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "1) Creating GitHub labels (idempotent)…"
gh label create proposed     --color a371f7 --description "agent-scout: review me (accept→agent / reject→close)" 2>/dev/null || echo "   (proposed exists)"
gh label create proposed-speculative --color d4c5f9 --description "agent-scout: low-confidence proposal (downgraded, not dropped)" 2>/dev/null || echo "   (proposed-speculative exists)"
gh label create single-pass  --color e99695 --description "agent-scout: p0 surfaced by one pass only — extra review"  2>/dev/null || echo "   (single-pass exists)"
gh label create stale        --color cccccc --description "agent-scout: untriaged past the SLA threshold"            2>/dev/null || echo "   (stale exists)"
gh label create bug          --color d73a4a --description "agent-scout: correctness defect"        2>/dev/null || echo "   (bug exists)"
gh label create ux-customer  --color 0e8a16 --description "agent-scout: customer-side UX friction" 2>/dev/null || echo "   (ux-customer exists)"
gh label create ux-business  --color 1d76db --description "agent-scout: business-side UX friction" 2>/dev/null || echo "   (ux-business exists)"
gh label create req          --color 5319e7 --description "agent-scout: requirements-compliance gap (FR→code)" 2>/dev/null || echo "   (req exists)"
gh label create journey      --color 006b75 --description "agent-scout: end-to-end journey not reachable"      2>/dev/null || echo "   (journey exists)"
gh label create docs         --color 0075ca --description "agent-scout: docs missing / verbose / unclear"      2>/dev/null || echo "   (docs exists)"
gh label create security     --color b60205 --description "agent-scout: security vulnerability (exposure/CVE/injection/authz/secret)" 2>/dev/null || echo "   (security exists)"
gh label create p0           --color b60205 --description "severity: must-fix"                     2>/dev/null || echo "   (p0 exists)"
gh label create p1           --color fbca04 --description "severity: should-fix"                   2>/dev/null || echo "   (p1 exists)"
gh label create p2           --color c5def5 --description "severity: nice-to-fix"                  2>/dev/null || echo "   (p2 exists)"

if [ "${1:-}" = "--labels-only" ]; then echo "labels done."; exit 0; fi

echo "2) Installing the user systemd units…"
mkdir -p "$HOME/.config/systemd/user"
cp "$ROOT/deploy/systemd/skillforge-agent-scout.service" "$ROOT/deploy/systemd/skillforge-agent-scout.timer" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now skillforge-agent-scout.timer

echo "3) Enabling linger (so the timer runs even when you're logged out)…"
loginctl enable-linger "$USER" 2>/dev/null || echo "   (could not enable linger — run: sudo loginctl enable-linger $USER)"

cat <<'EOF'

✅ agent-scout is live (producer half of the loop).
   Status:   systemctl --user status skillforge-agent-scout.timer
   Next run: systemctl --user list-timers skillforge-agent-scout.timer
   Logs:     journalctl --user -u skillforge-agent-scout.service -f   (and /tmp/agent-scout-<repo-key>/)
   Dry run:  SCOUT_DRY_RUN=1 bash scripts/agent-scout.sh   (scan + critic, file nothing)

Flow: scout files `proposed` issues → you review on the phone →
  • accept: relabel `proposed`→`agent` (the agent-inbox builds it), or
  • reject: close the issue (its fingerprint is never re-filed).
EOF
