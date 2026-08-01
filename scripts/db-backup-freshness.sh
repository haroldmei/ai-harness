#!/usr/bin/env bash
# db-backup-freshness.sh — alert when the newest DB backup is older than the RPO (issue #197).
#
# A backup cron that silently stops is worse than none — you THINK you are covered.
# This is the watchdog: it finds the newest dump in $BACKUP_DIR and fails (non-zero
# exit + notify hook) when its age exceeds the RPO window, or when there is no backup
# at all. Run it on a tighter cadence than the backup itself (hourly vs daily).
#
# It also refreshes the Prometheus textfile metric skillforge_backup_age_seconds so a
# scraped environment alerts the same way via deploy/prometheus/backup-freshness.rules.yml —
# the host-cron path (exit code + notify) and the Prometheus path agree on one threshold.
#
#   bash scripts/db-backup-freshness.sh        # exit 0 = fresh, non-zero = STALE/missing
#
# Overridable clock (SF_BACKUP_NOW_EPOCH) + binaries make scripts/db-backup-freshness.test.sh
# fully hermetic and deterministic.
set -euo pipefail

BACKUP_DIR="${SF_BACKUP_DIR:-$HOME/.cache/skillforge-backups}"
METRICS_DIR="${SF_BACKUP_METRICS_DIR:-$BACKUP_DIR/metrics}"
DB_NAME="${SF_BACKUP_DB:-skillforge}"
RPO_HOURS="${SF_BACKUP_RPO_HOURS:-24}"
NOTIFY_CMD="${SF_BACKUP_NOTIFY_CMD:-}"
# Deterministic clock seam for tests; defaults to now.
NOW="${SF_BACKUP_NOW_EPOCH:-$(date -u +%s)}"

RPO_SECONDS=$((RPO_HOURS * 3600))

log() { printf '[backup-freshness] %s\n' "$*" >&2; }

# Emit the age metric atomically so a Prometheus scrape never reads a partial file.
# age=-1 sentinel means "no backup exists" (the alert rule treats <0 as stale too).
emit_metric() {
  local age="$1"
  mkdir -p "$METRICS_DIR"
  local f="$METRICS_DIR/skillforge_backup_freshness.prom"
  {
    echo "# HELP skillforge_backup_age_seconds Age in seconds of the newest DB backup (-1 = none found)."
    echo "# TYPE skillforge_backup_age_seconds gauge"
    echo "skillforge_backup_age_seconds ${age}"
    echo "# HELP skillforge_backup_rpo_seconds Configured recovery-point objective window in seconds."
    echo "# TYPE skillforge_backup_rpo_seconds gauge"
    echo "skillforge_backup_rpo_seconds ${RPO_SECONDS}"
  } > "$f.tmp" && mv "$f.tmp" "$f"
}

alert() {
  local msg="$1"
  log "ALERT: $msg"
  [ -n "$NOTIFY_CMD" ] && { SF_ALERT="db-backup STALE: $msg" bash -c "$NOTIFY_CMD" || log "notify cmd failed (non-fatal)"; }
}

newest="$(find "$BACKUP_DIR" -maxdepth 1 -name "skillforge-${DB_NAME}-*.dump" -type f 2>/dev/null \
            | sort | tail -1)"

if [ -z "$newest" ]; then
  emit_metric -1
  alert "no DB backup found in $BACKUP_DIR — RPO ${RPO_HOURS}h cannot be met"
  exit 1
fi

# Newest backup's mtime → age. (mtime, not the filename stamp, so a touched/copied
# file is judged by when it actually last landed.)
mtime="$(stat -c %Y "$newest" 2>/dev/null || stat -f %m "$newest" 2>/dev/null)"
[ -n "$mtime" ] || { emit_metric -1; alert "could not stat newest backup $newest"; exit 1; }

age=$((NOW - mtime))
[ "$age" -lt 0 ] && age=0     # clock skew / future mtime → clamp, don't report negative
emit_metric "$age"

age_h=$((age / 3600))
if [ "$age" -gt "$RPO_SECONDS" ]; then
  alert "newest backup $(basename "$newest") is ${age_h}h old (> RPO ${RPO_HOURS}h)"
  exit 1
fi

log "OK: newest backup $(basename "$newest") is ${age_h}h old (≤ RPO ${RPO_HOURS}h)"
exit 0
