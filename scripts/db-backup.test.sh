#!/usr/bin/env bash
# Hermetic test for scripts/db-backup.sh (issue #197).
#
# There is no real Postgres to drive here, so this exercises the REAL backup
# script with `docker` STUBBED: zero real containers, deterministic. It proves
# the backup contract:
#
#   1. a valid pg_dump archive is written and a per-table count manifest captured
#      from EXACT count(*) (the numbers the restore drill verifies against);
#   2. a garbage/empty dump is REJECTED (not silently kept as a "backup");
#   3. retention prunes dumps + sidecars older than the window, keeps fresh ones;
#   4. the Prometheus freshness metric is emitted.
#
#   Run: bash scripts/db-backup.test.sh   (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/db-backup.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

# Stub `docker exec <container> <pg_dump|psql> …`. The stub answers:
#   pg_dump            → a minimal valid custom-format archive ("PGDMP…"), or
#                        garbage when STUB_BAD_DUMP=1 (test 2).
#   psql … string_agg  → a non-empty marker (the "generated count SQL"), so the
#                        backup proceeds to the per-table count query.
#   psql … (other -c)  → the fixed count TSV (courses=2, lessons=5, modules=3).
make_docker() {
  local dir="$1"
  cat > "$dir/docker" <<'STUB'
#!/usr/bin/env bash
# argv: exec <container> <cmd> [args…]
shift                                  # drop "exec"
shift                                  # drop container name
cmd="$1"; shift
case "$cmd" in
  pg_dump)
    # --snapshot= flag is accepted transparently; same stub output either way.
    if [ "${STUB_BAD_DUMP:-0}" = "1" ]; then printf 'not-an-archive'; else printf 'PGDMP\x00\x01fake-archive-body'; fi
    ;;
  psql)
    # Parse flags: detect -c (inline SQL) and -F (field separator for the session).
    # Default field sep is '|' (psql -A without -F).  The backup script must pass
    # -F$'\t' so the downstream IFS=$'\t' parser at line 159 works; this stub
    # enforces that contract — omitting -F$'\t' makes count rows pipe-delimited,
    # which corrupts the manifest and trips the jq assertions below.
    field_sep="|"  # psql -A default without -F
    c_sql=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -c)  c_sql="$2"; shift 2 ;;
        -F*) field_sep="${1#-F}"; shift ;;
        *)   shift ;;
      esac
    done
    if [ -n "$c_sql" ]; then
      if printf '%s' "$c_sql" | grep -q 'string_agg'; then
        printf 'GENERATED_COUNT_SQL\n'
      else
        printf 'courses\t2\nlessons\t5\nmodules\t3\n'
      fi
    else
      # Stdin mode: FIFO snapshot session.  Process SQL commands line by line and
      # respond with sentinel-wrapped output the backup script polls for.
      while IFS= read -r stmt; do
        stmt="${stmt%;}"   # strip trailing semicolon
        if printf '%s' "$stmt" | grep -q 'pg_export_snapshot'; then
          printf 'SFSNAP_BFAKESNAP001SFSNAP_E\n'
        elif printf '%s' "$stmt" | grep -qE "'SF(SNAP|CNT)_[BE]'"; then
          # Echo back the sentinel value: SELECT 'SFCNT_B' → SFCNT_B
          printf '%s' "$stmt" | grep -oE "'SF[A-Z_]+'" | tr -d "'" | head -1; printf '\n'
        elif printf '%s' "$stmt" | grep -q 'UNION ALL\|GENERATED_COUNT_SQL'; then
          # Use the field separator from -F flag (tab if script passes -F$'\t', else '|').
          printf "courses${field_sep}2\nlessons${field_sep}5\nmodules${field_sep}3\n"
        fi
        # BEGIN, COMMIT, ROLLBACK, ISOLATION → silent
      done
    fi
    ;;
  *) echo "unexpected docker cmd: $cmd" >&2; exit 99 ;;
esac
STUB
  chmod +x "$dir/docker"
}

# ── Test 1 + 3 + 4: happy path, manifest, retention, metric ───────────────────
T1="$(mktemp -d)"; make_docker "$T1"
BK="$T1/backups"; mkdir -p "$BK"
# A stale dump (+ sidecar) older than the 1-day retention window used here.
touch -d '10 days ago' "$BK/skillforge-skillforge-OLD.dump" "$BK/skillforge-skillforge-OLD.dump.counts.json"

OUT="$T1/out.log"
PATH="$T1:$PATH" SF_BACKUP_DIR="$BK" SF_BACKUP_RETENTION_DAYS=1 SF_BACKUP_STAMP="TESTSTAMP" \
  bash "$SCRIPT" >"$OUT" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "happy-path backup exits 0" || bad "happy-path backup exits 0 (rc=$rc; $(tail -1 "$OUT"))"

DUMP="$BK/skillforge-skillforge-TESTSTAMP.dump"
[ -s "$DUMP" ] && ok "dump archive written" || bad "dump archive written"
head -c5 "$DUMP" 2>/dev/null | grep -q 'PGDMP' && ok "dump is custom-format (PGDMP magic)" || bad "dump magic"

CJSON="$DUMP.counts.json"
if command -v jq >/dev/null && [ -f "$CJSON" ]; then
  [ "$(jq -r '.tables.courses' "$CJSON")" = "2" ] && ok "manifest courses=2" || bad "manifest courses=2 (got $(jq -r '.tables.courses' "$CJSON" 2>/dev/null))"
  [ "$(jq -r '.tables.lessons' "$CJSON")" = "5" ] && ok "manifest lessons=5" || bad "manifest lessons=5"
  [ "$(jq -r '.tables.modules' "$CJSON")" = "3" ] && ok "manifest modules=3" || bad "manifest modules=3"
else
  bad "manifest present + parseable"
fi

[ ! -e "$BK/skillforge-skillforge-OLD.dump" ] && ok "retention pruned the 10-day-old dump" || bad "retention pruned old dump"
[ ! -e "$BK/skillforge-skillforge-OLD.dump.counts.json" ] && ok "retention pruned the old sidecar" || bad "retention pruned old sidecar"
[ -f "$BK/metrics/skillforge_backup.prom" ] && ok "freshness metric emitted" || bad "freshness metric emitted"
grep -q 'skillforge_backup_last_success_timestamp_seconds' "$BK/metrics/skillforge_backup.prom" 2>/dev/null \
  && ok "metric carries last-success timestamp" || bad "metric carries last-success timestamp"
rm -rf "$T1"

# ── Test 2: a garbage dump is rejected, not kept ──────────────────────────────
T2="$(mktemp -d)"; make_docker "$T2"; BK2="$T2/backups"; mkdir -p "$BK2"
PATH="$T2:$PATH" SF_BACKUP_DIR="$BK2" SF_BACKUP_STAMP="BAD" STUB_BAD_DUMP=1 \
  bash "$SCRIPT" >/dev/null 2>&1
rc=$?
[ $rc -ne 0 ] && ok "garbage dump → non-zero exit" || bad "garbage dump → non-zero exit"
[ ! -e "$BK2/skillforge-skillforge-BAD.dump" ] && ok "garbage dump file removed (not kept as a 'backup')" || bad "garbage dump removed"
rm -rf "$T2"

# ── Test 3: backup.prom must NOT contain skillforge_backup_rpo_seconds ─────────
# db-backup-freshness.sh already emits skillforge_backup_rpo_seconds into its own
# .prom file.  If db-backup.sh also emits it, node_exporter's textfile gatherer
# sees a duplicate metric family when both files live in the same METRICS_DIR and
# returns an error — SkillForgeDBBackupStale becomes un-evaluable.
T3="$(mktemp -d)"; make_docker "$T3"; BK3="$T3/backups"; mkdir -p "$BK3"
PATH="$T3:$PATH" SF_BACKUP_DIR="$BK3" SF_BACKUP_STAMP="NORPO" \
  bash "$SCRIPT" >/dev/null 2>&1
! grep -q 'skillforge_backup_rpo_seconds' "$BK3/metrics/skillforge_backup.prom" 2>/dev/null \
  && ok "backup.prom does not contain skillforge_backup_rpo_seconds (no duplicate metric)" \
  || bad "backup.prom must not contain skillforge_backup_rpo_seconds"
rm -rf "$T3"

# ── Test 4: retention prunes at exactly the RETENTION_DAYS boundary ────────────
# -mtime +$((RETENTION_DAYS-1)) prunes files aged >= RETENTION_DAYS days, keeping
# exactly RETENTION_DAYS days of history.  The prior -mtime +"$RETENTION_DAYS" kept
# one extra day (off by one: 15 daily dumps instead of 14).
T4="$(mktemp -d)"; make_docker "$T4"; BK4="$T4/backups"; mkdir -p "$BK4"
touch -d '2 days ago' "$BK4/skillforge-skillforge-BOUNDARY.dump"  # exactly RETENTION_DAYS=2 old
touch -d '1 day ago'  "$BK4/skillforge-skillforge-KEEPER.dump"    # RETENTION_DAYS-1 old; must survive
PATH="$T4:$PATH" SF_BACKUP_DIR="$BK4" SF_BACKUP_RETENTION_DAYS=2 SF_BACKUP_STAMP="T4NEW" \
  bash "$SCRIPT" >/dev/null 2>&1
[ ! -e "$BK4/skillforge-skillforge-BOUNDARY.dump" ] \
  && ok "retention: dump aged == RETENTION_DAYS is pruned (boundary fixed)" \
  || bad "retention: dump aged == RETENTION_DAYS must be pruned"
[ -e "$BK4/skillforge-skillforge-KEEPER.dump" ] \
  && ok "retention: dump aged < RETENTION_DAYS is kept" \
  || bad "retention: dump aged < RETENTION_DAYS must be kept"
rm -rf "$T4"

echo "── db-backup.test.sh: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
