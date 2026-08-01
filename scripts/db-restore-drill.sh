#!/usr/bin/env bash
# db-restore-drill.sh — EXECUTE a disaster-recovery restore drill (issue #197).
#
# A backup you have never restored is not a backup — it is a hope. This drill
# proves the live DB's backups (scripts/db-backup.sh) are actually restorable:
#
#   1. Take the newest dump in $BACKUP_DIR (or a path passed as $1) + its
#      per-table count manifest (<dump>.counts.json).
#   2. Boot a throwaway scratch Postgres container (NEVER the live DB).
#   3. pg_restore the dump into a fresh database on it.
#   4. VERIFY the restore is SOURCE-FAITHFUL: every table's restored row count
#      equals the count captured at dump time, and the seed-critical tables are
#      non-empty (a restore that "succeeds" into an empty DB is the failure mode
#      docs/27 H5 flagged as untested).
#   5. Write drill evidence JSON ($BACKUP_DIR/restore-drill-latest.json) and tear
#      the scratch instance down (always, via trap).
#
# Exit 0 = restore verified; non-zero = drill FAILED (and the evidence says why).
# RPO/RTO and the recorded drill evidence live in docs/38-db-backup-dr-runbook.md.
#
#   bash scripts/db-restore-drill.sh                 # drill the newest backup
#   bash scripts/db-restore-drill.sh path/to.dump    # drill a specific backup
#
# Binaries are overridable (DOCKER/…) so scripts/db-restore-drill.test.sh drives the
# real verification control flow with a stub docker — no real container needed.
set -euo pipefail

BACKUP_DIR="${SF_BACKUP_DIR:-$HOME/.cache/skillforge-backups}"
SCRATCH_IMAGE="${SF_DRILL_IMAGE:-postgres:16-alpine}"
SCRATCH_DB="${SF_DRILL_DB:-skillforge_drill}"
EVIDENCE="${SF_DRILL_EVIDENCE:-$BACKUP_DIR/restore-drill-latest.json}"
# Tables that MUST be non-empty for a restore to count as "complete" (not just
# structurally restored). Space-separated; overridable for other schemas.
CRITICAL_TABLES="${SF_DRILL_CRITICAL_TABLES:-courses modules lessons}"
READY_TIMEOUT="${SF_DRILL_READY_TIMEOUT:-60}"   # seconds to wait for scratch pg

DOCKER="${DOCKER:-docker}"

log()  { printf '[restore-drill] %s\n' "$*" >&2; }
die()  { log "DRILL FAILED: $*"; write_evidence "fail" "$*"; exit 1; }

# Evidence is written on BOTH pass and fail so an operator always has the latest
# drill result on disk (the runbook points at this file).
DRILL_STAMP="${SF_DRILL_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_VERIFIED=0 RESULT_TOTAL=0
write_evidence() {
  local status="$1" detail="${2:-}"
  mkdir -p "$(dirname "$EVIDENCE")"
  printf '{\n  "drill_utc": "%s",\n  "status": "%s",\n  "dump": "%s",\n  "tables_verified": %s,\n  "tables_total": %s,\n  "critical_tables": "%s",\n  "detail": "%s"\n}\n' \
    "$DRILL_STAMP" "$status" "${DUMP:-}" "$RESULT_VERIFIED" "$RESULT_TOTAL" "$CRITICAL_TABLES" "${detail//\"/\'}" \
    > "$EVIDENCE"
}

command -v jq >/dev/null || die "jq is required"

# ── 1. Pick the dump to drill ─────────────────────────────────────────────────
DUMP="${1:-}"
if [ -z "$DUMP" ]; then
  DUMP="$(find "$BACKUP_DIR" -maxdepth 1 -name 'skillforge-*.dump' -type f 2>/dev/null \
            | sort | tail -1)"
fi
[ -n "$DUMP" ] && [ -f "$DUMP" ] || die "no backup dump found in $BACKUP_DIR (run scripts/db-backup.sh first)"
COUNTS="$DUMP.counts.json"
[ -f "$COUNTS" ] || die "missing count manifest $COUNTS (cannot verify source-faithfulness)"
log "drilling $(basename "$DUMP")"

# ── 2. Boot a throwaway scratch Postgres ──────────────────────────────────────
SCRATCH="skillforge_restore_drill_$$"
cleanup() { "$DOCKER" rm -f "$SCRATCH" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "starting scratch instance $SCRATCH ($SCRATCH_IMAGE)"
"$DOCKER" run -d --name "$SCRATCH" -e POSTGRES_PASSWORD=drill "$SCRATCH_IMAGE" >/dev/null \
  || die "could not start scratch container"

# scratch exec helpers
s_exec()  { "$DOCKER" exec    "$SCRATCH" "$@"; }
s_execi() { "$DOCKER" exec -i "$SCRATCH" "$@"; }

log "waiting for scratch pg to accept connections (≤${READY_TIMEOUT}s)"
ready=0
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if s_exec pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || die "scratch pg never became ready"

# ── 3. Restore the dump into a fresh DB ───────────────────────────────────────
log "creating $SCRATCH_DB and restoring"
s_exec createdb -U postgres "$SCRATCH_DB" >/dev/null 2>&1 || die "createdb failed on scratch"
# --no-owner/--no-acl: the scratch superuser owns everything; role grants from the
# source are irrelevant to a count-verification drill and only produce noise.
# pg_restore returns non-zero on hard errors; ignore-on-empty is NOT used so a
# genuinely broken archive fails here.
if ! s_execi pg_restore -U postgres -d "$SCRATCH_DB" --no-owner --no-acl < "$DUMP" 2>/dev/null; then
  die "pg_restore reported errors restoring the dump"
fi

# ── 4. Verify SOURCE-FAITHFULNESS: restored counts == dump-time counts ────────
# Restored EXACT counts, same UNION-ALL shape db-backup.sh used at capture time.
count_sql="$(s_exec psql -U postgres -d "$SCRATCH_DB" -At -c \
  "select string_agg(format('select %L::text as t, count(*) as c from %I.%I', relname, schemaname, relname), ' union all ' order by relname)
     from pg_stat_user_tables;" 2>/dev/null || true)"
declare -A restored
if [ -n "$count_sql" ]; then
  while IFS=$'\t' read -r t c; do
    [ -n "$t" ] && restored["$t"]="$c"
  done < <(s_exec psql -U postgres -d "$SCRATCH_DB" -At -F$'\t' -c "$count_sql" 2>/dev/null)
fi

# Expected counts from the dump-time manifest.
mismatch=""
RESULT_TOTAL=0 RESULT_VERIFIED=0
while IFS=$'\t' read -r t expected; do
  [ -z "$t" ] && continue
  RESULT_TOTAL=$((RESULT_TOTAL + 1))
  got="${restored[$t]:-MISSING}"
  if [ "$got" = "$expected" ]; then
    RESULT_VERIFIED=$((RESULT_VERIFIED + 1))
  else
    mismatch+="    $t: expected $expected, restored $got"$'\n'
  fi
done < <(jq -r '.tables | to_entries[] | "\(.key)\t\(.value)"' "$COUNTS")

if [ -n "$mismatch" ]; then
  log "row-count mismatches:"; printf '%s' "$mismatch" >&2
  die "restored row counts do not match the dump-time manifest"
fi
log "all $RESULT_VERIFIED/$RESULT_TOTAL table counts match the dump-time manifest"

# Seed-critical tables must be non-empty — a structurally-correct restore into an
# empty DB is exactly the silent failure docs/27 H5 said was never tested.
for t in $CRITICAL_TABLES; do
  c="${restored[$t]:-0}"
  [ "${c:-0}" -gt 0 ] 2>/dev/null || die "critical table '$t' is empty after restore ($c rows)"
done
log "critical tables non-empty: $CRITICAL_TABLES"

# ── 5. Pass ───────────────────────────────────────────────────────────────────
write_evidence "pass" "restore verified: $RESULT_VERIFIED tables, counts match manifest, critical tables non-empty"
log "DRILL PASSED — evidence → $EVIDENCE"
