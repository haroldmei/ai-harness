#!/usr/bin/env bash
# One-time activation for the agent-inbox loop. SAFE to re-run (idempotent).
# This is the only step with real side-effects (creates GitHub labels on your repo
# and installs+starts a user systemd timer), so it is NOT run by the test suite —
# run it yourself when you want the loop live.
#
#   bash scripts/agent-inbox-setup.sh          # create labels + install + start the timer
#   bash scripts/agent-inbox-setup.sh --labels-only   # just the labels
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "1) Creating GitHub labels (idempotent)…"
gh label create agent       --color 1f6feb --description "agent-inbox: build me"        2>/dev/null || echo "   (agent exists)"
gh label create wip         --color fbca04 --description "agent-inbox: claimed/in-progress" 2>/dev/null || echo "   (wip exists)"
gh label create done        --color 0e8a16 --description "agent-inbox: PR opened"        2>/dev/null || echo "   (done exists)"
gh label create needs-human --color d73a4a --description "agent-inbox: gates failed / no-op" 2>/dev/null || echo "   (needs-human exists)"

if [ "${1:-}" = "--labels-only" ]; then echo "labels done."; exit 0; fi

echo "2) Installing the user systemd units…"
mkdir -p "$HOME/.config/systemd/user"
cp "$ROOT/deploy/systemd/skillforge-agent-inbox.service" "$ROOT/deploy/systemd/skillforge-agent-inbox.timer" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now skillforge-agent-inbox.timer

echo "3) Enabling linger (so the timer runs even when you're logged out)…"
loginctl enable-linger "$USER" 2>/dev/null || echo "   (could not enable linger — run: sudo loginctl enable-linger $USER)"

cat <<EOF

✅ agent-inbox is live.
   Status:   systemctl --user status skillforge-agent-inbox.timer
   Next run: systemctl --user list-timers skillforge-agent-inbox.timer
   Logs:     journalctl --user -u skillforge-agent-inbox.service -f   (and /tmp/agent-inbox-<repo-key>/)

From your phone: GitHub app → New Issue → describe the requirement → add label "agent".
The loop branches off main, builds it, runs the gates, and replies with a PR link.
EOF
