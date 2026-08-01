#!/usr/bin/env bash
# Hermetic unit tests for scripts/lib/agent-model-call.sh (classify_model_result).
#
# This library had NO tests until #2407, despite gating the retry-vs-escalate decision for six
# call sites across five scripts (reviewer, fixer x2, inbox, merger, release-train). The bug it
# shipped with — a zero-byte envelope classified `hard` and escalated to a human instead of being
# retried — is exactly the kind a single fixture would have caught.
#
# Fixtures are files on disk, not mocks: the function's whole contract is "read this envelope and
# its stderr sidecar", so anything less would test a different function.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/agent-model-call.sh
. "$ROOT/scripts/lib/agent-model-call.sh"

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# expect <name> <expected-class> <envelope-content|@ABSENT|@EMPTY> [stderr-content]
expect() {
  local name="$1" want="$2" body="$3" err="${4:-}"
  local f="$TMP/env-$((PASS+FAIL)).json"
  case "$body" in
    @ABSENT) : ;;                       # never created
    @EMPTY)  : > "$f" ;;                # created, zero bytes — the #2407 signature
    *)       printf '%s' "$body" > "$f" ;;
  esac
  [ -n "$err" ] && printf '%s' "$err" > "${f%.json}.stderr"
  local got; got="$(classify_model_result "$f")"
  if [ "$got" = "$want" ]; then ok "$name → $got"; else bad "$name → got '$got', want '$want'"; fi
}

echo "MC-1 — the happy path"
expect "valid envelope, is_error false"      ok '{"is_error":false,"result":"{\"verdict\":\"approve\"}"}'
expect "valid envelope, no is_error key"     ok '{"result":"anything"}'

echo "MC-2 — transient failures are retried, not escalated"
expect "is_error + api_error_status 429"     transient '{"is_error":true,"api_error_status":429,"result":""}'
expect "is_error + status 503"               transient '{"is_error":true,"status":503,"result":""}'
expect "is_error + status 529"               transient '{"is_error":true,"status":529,"result":""}'
expect "is_error + 'session limit' text"     transient '{"is_error":true,"result":"You'\''ve hit your session limit · resets 1:20pm"}'
expect "is_error + 'usage limit' text"       transient '{"is_error":true,"result":"usage limit reached"}'
expect "is_error + 'overloaded' text"        transient '{"is_error":true,"result":"Overloaded"}'
expect "non-JSON stdout naming a rate limit" transient 'error: rate limit exceeded, try again'

echo "MC-3 — genuine failures still escalate"
expect "is_error + an unrecognised message"  hard '{"is_error":true,"api_error_status":400,"result":"bad request"}'
expect "non-JSON stdout, no limit marker"    hard 'Segmentation fault'
expect "valid JSON that is not an object"    hard '["not","an","object"]'

echo "MC-4 — an empty envelope is its own class (#2407 regression guard)"
# The bug: both of these returned `hard`, so the reviewer escalated to "needs a human" on a run
# that had in fact produced a verdict the CLI failed to serialise.
expect "zero-byte envelope"                  empty @EMPTY
expect "envelope never created"              empty @ABSENT
expect "empty envelope, empty sidecar"       empty @EMPTY ''

echo "MC-5 — the stderr sidecar is consulted when stdout is unusable"
# The CLI writes limit notices to stderr. Before #2407 the sidecar was captured to disk by every
# caller and read by nothing, so a limit reported there escalated instead of retrying.
expect "empty stdout + 'usage limit' stderr"    transient @EMPTY 'Claude usage limit reached'
expect "empty stdout + 'overloaded' stderr"     transient @EMPTY 'API Error: Overloaded'
expect "non-JSON stdout + limit in stderr"      transient 'partial garbage' 'session limit reached'
expect "empty stdout + unrelated stderr noise"  empty  @EMPTY 'Warning: something cosmetic'
expect "non-JSON stdout + unrelated stderr"     hard   'Segmentation fault' 'Warning: cosmetic'

echo "MC-6 — a valid envelope always outranks the sidecar"
# stderr carries a CLI startup warning on EVERY invocation. A successful review must never be
# reclassified because of noise on the other stream.
expect "ok envelope + noisy stderr"          ok '{"is_error":false,"result":"fine"}' 'session limit'
expect "hard envelope + limit in stderr"     hard '{"is_error":true,"api_error_status":400,"result":"bad request"}' 'usage limit'

echo "MC-7 — the .err sidecar spelling (release-train) is honoured too"
f="$TMP/rt-envelope"; : > "$f"; printf 'usage limit reached' > "${f}.err"
got="$(classify_model_result "$f")"
[ "$got" = "transient" ] && ok "empty envelope + .err sidecar → transient" \
                         || bad "empty envelope + .err sidecar → got '$got', want 'transient'"

printf '\nagent-model-call: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
