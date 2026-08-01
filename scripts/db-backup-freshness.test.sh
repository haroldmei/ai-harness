#!/usr/bin/env bash
# Hermetic test for scripts/db-backup-freshness.sh (issue #197).
#
# No real backups or clock needed: the script takes an injectable now-epoch
# (SF_BACKUP_NOW_EPOCH). Proves the freshness-alert contract:
#
#   1. a backup within the RPO window → exit 0 (fresh), metric written;
#   2. a backup older than the RPO window → exit 1 (STALE) + notify hook fires;
#   3. no backup at all → exit 1, metric age = -1 sentinel;
#   4. the emitted metric is valid Prometheus exposition (age + rpo gauges).
#
#   Run: bash scripts/db-backup-freshness.test.sh   (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/db-backup-freshness.sh"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

NOW=1700000000   # fixed reference epoch

# ── Test 1: fresh backup (1h old, RPO 24h) → exit 0 ───────────────────────────
T="$(mktemp -d)"; BK="$T/bk"; mkdir -p "$BK"
dump="$BK/skillforge-skillforge-FRESH.dump"; : > "$dump"
touch -d "@$((NOW - 3600))" "$dump"
SF_BACKUP_DIR="$BK" SF_BACKUP_RPO_HOURS=24 SF_BACKUP_NOW_EPOCH="$NOW" bash "$SCRIPT" >"$T/o" 2>&1
rc=$?
[ $rc -eq 0 ] && ok "fresh backup → exit 0" || bad "fresh backup → exit 0 (rc=$rc)"
m="$BK/metrics/skillforge_backup_freshness.prom"
[ -f "$m" ] && ok "metric file written" || bad "metric file written"
grep -q '^skillforge_backup_age_seconds 3600$' "$m" 2>/dev/null && ok "metric age = 3600s" || bad "metric age = 3600s (got: $(grep age_seconds "$m" 2>/dev/null | tail -1))"
grep -q '^skillforge_backup_rpo_seconds 86400$' "$m" 2>/dev/null && ok "metric rpo = 86400s" || bad "metric rpo = 86400s"
rm -rf "$T"

# ── Test 2: stale backup (48h old, RPO 24h) → exit 1 + notify fires ───────────
T="$(mktemp -d)"; BK="$T/bk"; mkdir -p "$BK"
dump="$BK/skillforge-skillforge-STALE.dump"; : > "$dump"
touch -d "@$((NOW - 48*3600))" "$dump"
SF_BACKUP_DIR="$BK" SF_BACKUP_RPO_HOURS=24 SF_BACKUP_NOW_EPOCH="$NOW" \
  SF_BACKUP_NOTIFY_CMD="echo fired > $T/notify.flag" bash "$SCRIPT" >"$T/o" 2>&1
rc=$?
[ $rc -eq 1 ] && ok "stale backup → exit 1" || bad "stale backup → exit 1 (rc=$rc)"
[ -f "$T/notify.flag" ] && ok "notify hook fired on stale" || bad "notify hook fired on stale"
grep -q '^skillforge_backup_age_seconds 172800$' "$BK/metrics/skillforge_backup_freshness.prom" 2>/dev/null \
  && ok "metric age = 172800s on stale" || bad "metric age = 172800s on stale"
rm -rf "$T"

# ── Test 3: no backup at all → exit 1, age = -1 sentinel ──────────────────────
T="$(mktemp -d)"; BK="$T/bk"; mkdir -p "$BK"
SF_BACKUP_DIR="$BK" SF_BACKUP_RPO_HOURS=24 SF_BACKUP_NOW_EPOCH="$NOW" bash "$SCRIPT" >"$T/o" 2>&1
rc=$?
[ $rc -eq 1 ] && ok "no backup → exit 1" || bad "no backup → exit 1 (rc=$rc)"
grep -q '^skillforge_backup_age_seconds -1$' "$BK/metrics/skillforge_backup_freshness.prom" 2>/dev/null \
  && ok "metric age = -1 sentinel when no backup" || bad "metric age = -1 sentinel"
rm -rf "$T"

# ── Test 4: exactly at the RPO boundary is still fresh (age == RPO) ────────────
T="$(mktemp -d)"; BK="$T/bk"; mkdir -p "$BK"
dump="$BK/skillforge-skillforge-EDGE.dump"; : > "$dump"
touch -d "@$((NOW - 24*3600))" "$dump"
SF_BACKUP_DIR="$BK" SF_BACKUP_RPO_HOURS=24 SF_BACKUP_NOW_EPOCH="$NOW" bash "$SCRIPT" >"$T/o" 2>&1
[ $? -eq 0 ] && ok "age == RPO is fresh (boundary)" || bad "age == RPO is fresh (boundary)"
rm -rf "$T"

echo "── db-backup-freshness.test.sh: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
