#!/usr/bin/env bash
# Hermetic test for scripts/db-restore-drill.sh (issue #197).
#
# The drill normally boots a real scratch Postgres; here `docker` is STUBBED so
# the REAL verification control flow runs with zero containers. It proves the
# drill's DR contract — the part that actually catches a bad backup:
#
#   1. restored counts == dump-time manifest + critical tables non-empty → PASS,
#      and drill evidence JSON is written with status "pass".
#   2. a single restored count diverging from the manifest → FAIL (this is what
#      catches a silently-truncated dump).
#   3. a critical table empty after restore → FAIL (the "restored into an empty
#      DB" silent failure docs/27 H5 flagged).
#   4. pg_restore erroring → FAIL.
#   5. no backup present → FAIL (nothing to drill).
#   6. the scratch container is always torn down (docker rm -f called).
#
#   Run: bash scripts/db-restore-drill.test.sh   (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/db-restore-drill.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null || { echo "jq required for this test"; exit 1; }

# Stub docker. Restored counts come from $STUB_COUNTS_FILE (a table\tcount TSV);
# pg_restore fails when STUB_RESTORE_FAIL=1. Every `docker rm -f` is logged to
# $RM_LOG so the test can assert teardown happened.
make_docker() {
  local dir="$1"
  cat > "$dir/docker" <<'STUB'
#!/usr/bin/env bash
verb="$1"; shift
case "$verb" in
  run) echo "stub-container-id"; exit 0 ;;
  rm)  echo "rm $*" >> "$RM_LOG"; exit 0 ;;
  exec)
    [ "$1" = "-i" ] && shift
    shift                              # container name
    cmd="$1"; shift
    case "$cmd" in
      pg_isready) exit 0 ;;
      createdb)   exit 0 ;;
      pg_restore) cat >/dev/null 2>&1; [ "${STUB_RESTORE_FAIL:-0}" = "1" ] && exit 1 || exit 0 ;;
      psql)
        sql=""; while [ $# -gt 0 ]; do [ "$1" = "-c" ] && { sql="$2"; shift 2; continue; }; shift; done
        if printf '%s' "$sql" | grep -q 'string_agg'; then echo 'GEN_SQL'; else cat "$STUB_COUNTS_FILE"; fi
        ;;
      *) exit 99 ;;
    esac ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$dir/docker"
}

# Build a backup dir holding one dump + a counts manifest with the given JSON.
make_backup() {
  local dir="$1" manifest_tables="$2"
  mkdir -p "$dir"
  printf 'PGDMP-fake' > "$dir/skillforge-skillforge-T.dump"
  printf '{ "db":"skillforge","tables": %s }\n' "$manifest_tables" > "$dir/skillforge-skillforge-T.dump.counts.json"
}

run_drill() {  # $1=tmp  $2=restored-TSV-file  -> echoes rc
  local tmp="$1" counts="$2"
  PATH="$tmp:$PATH" SF_BACKUP_DIR="$tmp/bk" SF_DRILL_STAMP="T" \
    STUB_COUNTS_FILE="$counts" RM_LOG="$tmp/rm.log" \
    STUB_RESTORE_FAIL="${STUB_RESTORE_FAIL:-0}" \
    bash "$SCRIPT" >"$tmp/out.log" 2>&1
  echo $?
}

# ── Test 1: counts match + critical non-empty → PASS ──────────────────────────
T="$(mktemp -d)"; make_docker "$T"
make_backup "$T/bk" '{"courses":2,"modules":3,"lessons":5}'
printf 'courses\t2\nmodules\t3\nlessons\t5\n' > "$T/restored.tsv"
rc="$(run_drill "$T" "$T/restored.tsv")"
[ "$rc" -eq 0 ] && ok "faithful restore → PASS" || bad "faithful restore → PASS (rc=$rc; $(tail -1 "$T/out.log"))"
[ "$(jq -r .status "$T/bk/restore-drill-latest.json" 2>/dev/null)" = "pass" ] && ok "evidence status=pass" || bad "evidence status=pass"
grep -q 'rm -f' "$T/rm.log" 2>/dev/null && ok "scratch container torn down" || bad "scratch container torn down"
rm -rf "$T"

# ── Test 2: one count diverges → FAIL ─────────────────────────────────────────
T="$(mktemp -d)"; make_docker "$T"
make_backup "$T/bk" '{"courses":2,"modules":3,"lessons":5}'
printf 'courses\t2\nmodules\t3\nlessons\t4\n' > "$T/restored.tsv"   # lessons short by 1
rc="$(run_drill "$T" "$T/restored.tsv")"
[ "$rc" -ne 0 ] && ok "count mismatch → FAIL" || bad "count mismatch → FAIL"
[ "$(jq -r .status "$T/bk/restore-drill-latest.json" 2>/dev/null)" = "fail" ] && ok "evidence status=fail on mismatch" || bad "evidence status=fail on mismatch"
grep -q 'rm -f' "$T/rm.log" 2>/dev/null && ok "scratch torn down even on failure" || bad "scratch torn down on failure"
rm -rf "$T"

# ── Test 3: critical table empty (counts still match) → FAIL ──────────────────
T="$(mktemp -d)"; make_docker "$T"
make_backup "$T/bk" '{"courses":0,"modules":3,"lessons":5}'        # courses legitimately 0 in manifest
printf 'courses\t0\nmodules\t3\nlessons\t5\n' > "$T/restored.tsv"   # match → passes count check
rc="$(run_drill "$T" "$T/restored.tsv")"
[ "$rc" -ne 0 ] && ok "empty critical table → FAIL (even when counts match)" || bad "empty critical table → FAIL"
rm -rf "$T"

# ── Test 4: pg_restore errors → FAIL ──────────────────────────────────────────
T="$(mktemp -d)"; make_docker "$T"
make_backup "$T/bk" '{"courses":2,"modules":3,"lessons":5}'
printf 'courses\t2\nmodules\t3\nlessons\t5\n' > "$T/restored.tsv"
STUB_RESTORE_FAIL=1 rc="$(STUB_RESTORE_FAIL=1 run_drill "$T" "$T/restored.tsv")"
[ "$rc" -ne 0 ] && ok "pg_restore error → FAIL" || bad "pg_restore error → FAIL"
rm -rf "$T"

# ── Test 5: no backup present → FAIL ──────────────────────────────────────────
T="$(mktemp -d)"; make_docker "$T"; mkdir -p "$T/bk"
printf 'x\t1\n' > "$T/restored.tsv"
rc="$(run_drill "$T" "$T/restored.tsv")"
[ "$rc" -ne 0 ] && ok "no backup → FAIL" || bad "no backup → FAIL"
rm -rf "$T"

echo "── db-restore-drill.test.sh: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
