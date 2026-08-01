#!/usr/bin/env bash
# db-backup.sh — scheduled logical backup of the LIVE deploy Postgres (issue #197).
#
# The always-on local deploy (docker-compose.deploy.yml) runs Postgres on a plain
# `postgres_data` volume with NO backups — a disk/volume loss was total data loss.
# This is the self-hosted backup path the issue mandates as the alternative to
# moving prod onto the already-Terraformed Cloud SQL (PITR + automated backups,
# infrastructure/terraform/modules/cloud-sql/main.tf). The provisioning DECISION
# (Cloud SQL vs self-hosted bucket) is the human's; this script delivers the
# self-hosted cron + retention + freshness metric so the live DB is covered today.
#
# What one run does (idempotent, safe to re-run):
#   1. pg_dump the live DB in custom format (-Fc, compressed) → $BACKUP_DIR.
#   2. Sidecar a per-table row-count manifest (<dump>.counts.json) so the restore
#      drill (scripts/db-restore-drill.sh) can verify a restore is SOURCE-FAITHFUL
#      (restored counts == counts captured at dump time), not merely non-empty.
#   3. Prune dumps older than the retention window ($RETENTION_DAYS).
#   4. Emit a Prometheus textfile metric (skillforge_backup_*) for the freshness
#      alert (scripts/db-backup-freshness.sh + deploy/prometheus/backup-freshness.rules.yml).
#   5. Optionally mirror the dump to object storage ($BACKUP_REMOTE, gs:// or s3://).
#
# RPO/RTO/retention and the executed restore-drill evidence: docs/38-db-backup-dr-runbook.md.
#
#   bash scripts/db-backup.sh                 # back up the live deploy DB now
#   SF_BACKUP_REMOTE=gs://my-bucket/sf bash scripts/db-backup.sh   # + mirror off-box
#
# Every external binary is overridable (DOCKER/PG_DUMP/…) so scripts/db-backup.test.sh
# can drive the REAL control flow hermetically with stubs — zero real DB calls.
set -euo pipefail

# ── Config (env-overridable) ──────────────────────────────────────────────────
BACKUP_DIR="${SF_BACKUP_DIR:-$HOME/.cache/skillforge-backups}"
METRICS_DIR="${SF_BACKUP_METRICS_DIR:-$BACKUP_DIR/metrics}"   # node_exporter textfile dir
PG_CONTAINER="${SF_BACKUP_PG_CONTAINER:-skillforge_postgres}" # live deploy DB container
DB_NAME="${SF_BACKUP_DB:-skillforge}"
DB_USER="${SF_BACKUP_DB_USER:-postgres}"
RETENTION_DAYS="${SF_BACKUP_RETENTION_DAYS:-14}"             # mirrors Cloud SQL retained_backups=14
RPO_HOURS="${SF_BACKUP_RPO_HOURS:-24}"                        # daily backups → 24h RPO
REMOTE="${SF_BACKUP_REMOTE:-}"                                # gs://… / s3://… (off by default)
NOTIFY_CMD="${SF_BACKUP_NOTIFY_CMD:-}"                        # optional alert hook on FAILURE
STAMP="${SF_BACKUP_STAMP:-}"                                  # override UTC stamp (tests)

# Overridable binaries (hermetic test seam — see canary-deploy.sh for the pattern).
DOCKER="${DOCKER:-docker}"
GSUTIL="${GSUTIL:-gsutil}"
AWS="${AWS:-aws}"

log() { printf '[db-backup] %s\n' "$*" >&2; }

# Alert on failure: same posture as local-deploy.sh notify() — run the hook if set,
# never let a flaky hook mask the real exit code.
fail() {
  log "FAILED: $*"
  [ -n "$NOTIFY_CMD" ] && { SF_ALERT="db-backup FAILED: $*" bash -c "$NOTIFY_CMD" || log "notify cmd failed (non-fatal)"; }
  exit 1
}

mkdir -p "$BACKUP_DIR" "$METRICS_DIR"

# UTC, sortable, filename-safe. Date.now()-free callers can pin SF_BACKUP_STAMP.
[ -z "$STAMP" ] && STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="$BACKUP_DIR/skillforge-${DB_NAME}-${STAMP}.dump"
COUNTS="$DUMP.counts.json"

# pg_dump / psql run INSIDE the DB container so we need neither a host pg client nor
# an exposed port, and the version always matches the server. Plain `docker exec`
# (no -t) already allocates no TTY, so dump bytes stream clean to the host file.
in_db() { "$DOCKER" exec "$PG_CONTAINER" "$@"; }

# ── Per-table count manifest + dump (snapshot-consistent) ────────────────────
# Counts and dump share the same REPEATABLE READ snapshot so the manifest always
# reflects exactly what pg_dump captured — no false DR-drill failures when the DB
# receives writes during backup.
#
# A named FIFO keeps an interactive psql session open in the container while count
# queries and pg_dump --snapshot= both run against the same exported snapshot.
# Closing the write end of the FIFO (fd 8) after pg_dump completes lets psql commit
# and exit.  Sentinel-wrapped SELECTs ("SFSNAP_B…E", "SFCNT_B…E") let us extract
# the snapshot ID and counts from the output stream without relying on psql's prompt
# or footer format.

# Step 1: enumerate user tables (catalog read; does not need to be in the snapshot).
log "capturing per-table row counts"
count_sql="$(in_db psql -U "$DB_USER" -d "$DB_NAME" -At -c \
  "select string_agg(format('select %L::text as t, count(*) as c from %I.%I', relname, schemaname, relname), ' union all ' order by relname)
     from pg_stat_user_tables;" 2>/dev/null)" \
  || fail "could not enumerate tables"

# Step 2: open a persistent psql session via a FIFO.
# exec 8<> opens the FIFO for read+write (O_RDWR) without blocking; docker exec then
# opens the read end for psql's stdin.  fd 8 stays open as long as we are running.
SNAP_FIFO="$(mktemp -u /tmp/sf_snap_XXXXXX)"
SNAP_OUT="$(mktemp /tmp/sf_out_XXXXXX)"
mkfifo "$SNAP_FIFO"
exec 8<>"$SNAP_FIFO"
# Close fd 8 in the child before reading: the background process must NOT hold the
# write end of the FIFO or the parent's "exec 8>&-" can never signal EOF to psql.
{ exec 8>&-; in_db psql -U "$DB_USER" -d "$DB_NAME" -At -F$'\t'; } < "$SNAP_FIFO" > "$SNAP_OUT" 2>/dev/null &
SNAP_PID=$!
_snap_cleanup() {
  exec 8>&- 2>/dev/null || true
  [ -n "${SNAP_PID:-}" ] && { wait "$SNAP_PID" 2>/dev/null || true; SNAP_PID=""; }
  rm -f "${SNAP_FIFO:-}" "${SNAP_OUT:-}"
  SNAP_FIFO="" SNAP_OUT=""
}
trap '_snap_cleanup' EXIT

# Step 3: begin REPEATABLE READ and export the snapshot ID.
printf 'BEGIN ISOLATION LEVEL REPEATABLE READ;\n' >&8
printf "SELECT 'SFSNAP_B' || pg_export_snapshot() || 'SFSNAP_E';\n" >&8
SNAP_ID=""
for _i in $(seq 1 100); do
  SNAP_ID="$(grep -o 'SFSNAP_B[^ ]*SFSNAP_E' "$SNAP_OUT" 2>/dev/null | \
             sed 's/SFSNAP_B//;s/SFSNAP_E//' | head -1)" || true
  [ -n "$SNAP_ID" ] && break
  sleep 0.1
done
if [ -z "$SNAP_ID" ]; then
  _snap_cleanup; fail "snapshot export timed out (psql did not respond in 10 s)"
fi

# Step 4: run count queries within the snapshot.
counts_tsv=""
if [ -n "$count_sql" ]; then
  printf "SELECT 'SFCNT_B';\n" >&8
  printf '%s;\n' "$count_sql" >&8
  printf "SELECT 'SFCNT_E';\n" >&8
  for _i in $(seq 1 100); do
    grep -q '^SFCNT_E$' "$SNAP_OUT" 2>/dev/null && break
    sleep 0.1
  done
  counts_tsv="$(sed -n '/^SFCNT_B$/,/^SFCNT_E$/p' "$SNAP_OUT" | \
    grep -v '^SFCNT_[BE]$' | grep -v '^$')" || true
fi

# Step 5: dump using the same snapshot (pg_dump uses SET TRANSACTION SNAPSHOT internally).
log "dumping $DB_NAME from container $PG_CONTAINER → $DUMP"
if ! in_db pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc --snapshot="$SNAP_ID" > "$DUMP" 2>/dev/null; then
  _snap_cleanup; rm -f "$DUMP"
  fail "pg_dump failed (is $PG_CONTAINER up? does $DB_NAME exist?)"
fi
# A custom-format dump always begins with the magic "PGDMP"; a 0-byte/garbage file
# here would otherwise sail through and only blow up at restore time (too late).
if ! head -c5 "$DUMP" 2>/dev/null | grep -q 'PGDMP'; then
  _snap_cleanup; rm -f "$DUMP"
  fail "dump is not a valid pg_dump custom-format archive"
fi
SIZE="$(wc -c < "$DUMP" | tr -d ' ')"
log "dump ok (${SIZE} bytes)"

# Step 6: release the psql session (snapshot transaction commits/rolls back on exit).
_snap_cleanup
trap - EXIT

{
  printf '{\n  "db": "%s",\n  "stamp": "%s",\n  "dump": "%s",\n  "size_bytes": %s,\n  "tables": {\n' \
    "$DB_NAME" "$STAMP" "$(basename "$DUMP")" "$SIZE"
  first=1
  while IFS=$'\t' read -r t n; do
    [ -z "$t" ] && continue
    [ $first -eq 1 ] && first=0 || printf ',\n'
    printf '    "%s": %s' "$t" "${n:-0}"
  done <<< "$counts_tsv"
  printf '\n  }\n}\n'
} > "$COUNTS"
log "counts manifest → $(basename "$COUNTS")"

# ── Retention: prune dumps (and their sidecars) older than the window ─────────
log "pruning backups older than ${RETENTION_DAYS}d"
pruned=0
while IFS= read -r old; do
  [ -z "$old" ] && continue
  rm -f "$old" "$old.counts.json"
  pruned=$((pruned + 1))
done < <(find "$BACKUP_DIR" -maxdepth 1 -name "skillforge-${DB_NAME}-*.dump" -type f \
           -mtime +$((RETENTION_DAYS - 1)) 2>/dev/null)
[ "$pruned" -gt 0 ] && log "pruned $pruned expired backup(s)"

# ── Optional off-box mirror (3-2-1: a local-only backup dies with the host) ───
if [ -n "$REMOTE" ]; then
  log "mirroring → $REMOTE"
  case "$REMOTE" in
    gs://*) "$GSUTIL" cp "$DUMP" "$COUNTS" "$REMOTE/" || fail "gsutil mirror failed" ;;
    s3://*) "$AWS" s3 cp "$DUMP" "$REMOTE/" && "$AWS" s3 cp "$COUNTS" "$REMOTE/" || fail "aws s3 mirror failed" ;;
    *)      fail "unsupported SF_BACKUP_REMOTE scheme: $REMOTE (want gs:// or s3://)" ;;
  esac
fi

# ── Prometheus textfile metric — drives the freshness alert ───────────────────
# Written atomically (.tmp → mv) so a scrape never reads a half-written file.
now_epoch="$(date -u +%s)"
metric_file="$METRICS_DIR/skillforge_backup.prom"
{
  echo "# HELP skillforge_backup_last_success_timestamp_seconds Unix time of the newest successful DB backup."
  echo "# TYPE skillforge_backup_last_success_timestamp_seconds gauge"
  echo "skillforge_backup_last_success_timestamp_seconds ${now_epoch}"
  echo "# HELP skillforge_backup_size_bytes Size in bytes of the newest DB backup."
  echo "# TYPE skillforge_backup_size_bytes gauge"
  echo "skillforge_backup_size_bytes ${SIZE}"
} > "$metric_file.tmp" && mv "$metric_file.tmp" "$metric_file"
log "metric → $metric_file"

log "backup complete: $(basename "$DUMP") (${SIZE} bytes, retention ${RETENTION_DAYS}d, RPO ${RPO_HOURS}h)"
