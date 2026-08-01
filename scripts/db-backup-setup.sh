#!/usr/bin/env bash
# One-time activation for the DB backup + freshness watchdog (issue #197). SAFE to
# re-run (idempotent). Installs + starts two USER systemd timers:
#   • skillforge-db-backup.timer            — daily pg_dump with retention (RPO 24h)
#   • skillforge-db-backup-freshness.timer  — hourly staleness alert
#
# This is the only step with real side-effects (installs + starts user timers), so it
# is NOT run by the test suite — run it yourself to put live-DB backups in force.
#
#   bash scripts/db-backup-setup.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "1) Installing the user systemd units…"
mkdir -p "$HOME/.config/systemd/user"
cp "$ROOT/deploy/systemd/skillforge-db-backup.service" \
   "$ROOT/deploy/systemd/skillforge-db-backup.timer" \
   "$ROOT/deploy/systemd/skillforge-db-backup-freshness.service" \
   "$ROOT/deploy/systemd/skillforge-db-backup-freshness.timer" \
   "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now skillforge-db-backup.timer
systemctl --user enable --now skillforge-db-backup-freshness.timer

echo "2) Enabling linger (so the timers run even when you're logged out)…"
loginctl enable-linger "$USER" 2>/dev/null || echo "   (could not enable linger — run: sudo loginctl enable-linger $USER)"

echo "3) Taking a first backup now (so the freshness watchdog has something to check)…"
bash "$ROOT/scripts/db-backup.sh" || echo "   (first backup failed — is the deploy stack up? check: docker ps | grep skillforge_postgres)"

cat <<EOF

✅ DB backup + freshness watchdog are live.
   Backup:    daily 02:30  — systemctl --user list-timers skillforge-db-backup.timer
   Freshness: hourly :15   — systemctl --user list-timers skillforge-db-backup-freshness.timer
   Logs:      journalctl --user -u skillforge-db-backup.service -f
   Backups:   ${SF_BACKUP_DIR:-\$HOME/.cache/skillforge-backups}/

Next steps to harden (see docs/38-db-backup-dr-runbook.md):
  • Off-box copy — set SF_BACKUP_REMOTE=gs://… in skillforge-db-backup.service so a
    host loss doesn't take the backups with it (3-2-1 rule). A local-only backup is
    half a backup.
  • Alerting — set SF_BACKUP_NOTIFY_CMD in both services to page on backup failure /
    staleness, and/or scrape ${SF_BACKUP_METRICS_DIR:-…/metrics}/ with node_exporter's
    textfile collector and load deploy/prometheus/backup-freshness.rules.yml.
  • Run the restore drill on a schedule too: bash scripts/db-restore-drill.sh
EOF
