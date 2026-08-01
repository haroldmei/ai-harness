#!/usr/bin/env bash
# One-time activation for the deploy-on-merge loop. SAFE to re-run (idempotent). This is the
# only step with real side-effects (installs + starts a user systemd timer), so it is NOT run
# by the test suite — run it yourself when you want the local auto-deploy live.
#
#   bash scripts/local-deploy-setup.sh     # install + start the deploy-on-merge timer
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "1) Installing the user systemd units…"
mkdir -p "$HOME/.config/systemd/user"
cp "$ROOT/deploy/systemd/skillforge-deploy-on-merge.service" \
   "$ROOT/deploy/systemd/skillforge-deploy-on-merge.timer" \
   "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now skillforge-deploy-on-merge.timer

echo "2) Enabling linger (so the timer runs even when you're logged out)…"
loginctl enable-linger "$USER" 2>/dev/null || echo "   (could not enable linger — run: sudo loginctl enable-linger $USER)"

cat <<EOF

✅ deploy-on-merge is live.
   Status:   systemctl --user status skillforge-deploy-on-merge.timer
   Next run: systemctl --user list-timers skillforge-deploy-on-merge.timer
   Logs:     journalctl --user -u skillforge-deploy-on-merge.service -f
             (and ~/.cache/skillforge-deploy/logs/)

When a PR is merged into main (by the agent-pr-merger, or by you from the GitHub mobile app),
within ~3 min this fast-forwards a pinned checkout (NOT your working copy), rebuilds the docker
stack (postgres+redis+api+frontend), waits for the api to be healthy, reseeds idempotently, and
notifies. GCP staging deploys stay manual: \`make deploy-staging\`.

First run will clone a pinned checkout into ~/.cache/skillforge-deploy/checkout and boot the
stack on the default ports (frontend :3000, api :8000). Override the trigger with
DEPLOY_TRIGGER=any-push, or force a one-off redeploy with DEPLOY_FORCE=1.
EOF
