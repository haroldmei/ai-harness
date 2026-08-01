#!/usr/bin/env bash
# migration-check.test.sh — end-to-end self-test for the drift gate (issue #194).
#
# Proves on a REAL scratch Postgres that:
#   • the gate PASSES on the current tree (no structural model⇄migration drift), and
#   • the gate FAILS when a model declares a table with no migration.
# The second half is driven by `migration-check.sh --self-test`, which injects an
# un-migrated table into Base.metadata and asserts the checker flags it.
#
# SKIPs (exit 0 with a notice) when no Postgres can be provisioned — the pure
# drift logic is covered dialect-independently by
# backend/tests/unit/test_migration_drift_checker.py, so CI without Postgres
# still verifies the mechanism.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "── migration-check self-test ──"
out="$("$ROOT/scripts/migration-check.sh" --self-test 2>&1)"
rc=$?
echo "$out" | grep -E "migration-check:|structural|self-test|✓|✗|DRIFT" || true

if [[ "$rc" -eq 77 ]]; then
  echo "SKIP: no Postgres available to provision a scratch DB"
  exit 0
fi

fail=0
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: gate did not pass on the current tree (exit $rc) — unexpected structural drift?"
  fail=1
fi
if ! echo "$out" | grep -q "self-test passed — checker reports structural drift"; then
  echo "FAIL: the divergent-model self-test did not run or did not detect drift"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: gate is green on the tree AND red on an un-migrated model"
fi
exit "$fail"
