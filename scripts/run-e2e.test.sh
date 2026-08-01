#!/usr/bin/env bash
# run-e2e.test.sh — lock in the EPHEMERAL-DB contract of scripts/run-e2e.sh (issue #98).
#
# The e2e gate runs under a FIXED compose project, so its named postgres volume persists
# across runs and branches. When a prior/concurrent branch leaves that volume in a bad state
# (a stale alembic revision, a half-applied migration, mismatched DB creds), `alembic upgrade
# head` fails on api boot and docker reports "dependency failed to start" — blocking EVERY
# branch, not just the one that poisoned it. The fix: reset the DB volume every run so each
# run migrates from a clean baseline.
#
# These are STATIC assertions against the script source — hermetic, no docker daemon, no
# images, no network. They guard against the volume-preserving regression silently coming back.
#
#   Run: bash scripts/run-e2e.test.sh     (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCRIPT="scripts/run-e2e.sh"
[[ -f "$SCRIPT" ]] || { echo "run-e2e.test: $SCRIPT not found"; exit 1; }

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "run-e2e ephemeral-DB contract (issue #98)"

# 1) The boot path must reset the volume BEFORE the stack comes up, so a poisoned volume left
#    by a crashed/killed prior run (which never reached teardown) can't break this run. Assert
#    a 'down -v' line precedes the first 'up -d' by line number.
reset_ln="$(grep -nE '"\$\{DC\[@\]\}" down -v' "$SCRIPT" | head -1 | cut -d: -f1)"
up_ln="$(grep -nE '"\$\{DC\[@\]\}" up -d' "$SCRIPT" | head -1 | cut -d: -f1)"
if [[ -n "$reset_ln" && -n "$up_ln" && "$reset_ln" -lt "$up_ln" ]]; then
  ok "resets the DB volume (down -v) before booting the stack"
else
  bad "no 'down -v' reset before boot — a poisoned volume would survive into this run"
fi

# 2) Teardown must REMOVE the volume, not preserve it — otherwise this run poisons the next.
if grep -qE 'down -v >/dev/null 2>&1 \|\| true' "$SCRIPT"; then
  ok "teardown removes the ephemeral DB volume (down -v)"
else
  bad "teardown does not run 'down -v' — the volume would persist across runs"
fi

# 3) The exact regression we are guarding against: a cleanup `down` with NO -v ("volume
#    preserved"). That bare form is what caused issue #98.
if grep -qE '"\$\{DC\[@\]\}" down >/dev/null' "$SCRIPT"; then
  bad "found a volume-PRESERVING 'down' (no -v) — this is the issue #98 regression"
else
  ok "no volume-preserving bare 'down' remains in the script"
fi
if grep -qiE 'volume preserved' "$SCRIPT"; then
  bad "stale 'volume preserved' wording still present (implies the old behavior)"
else
  ok "no 'volume preserved' wording (DB is documented as ephemeral)"
fi

# 4) Safety: any explicit `docker volume rm` (the issue #171 scrub/reaper) must be NAME-SCOPED
#    to this gate — keyed to "${PROJECT}_" or anchored to the `skillforge-e2e` prefix — never an
#    unscoped removal that could reach the dev stack's skillforge_postgres_data (single underscore,
#    no `-e2e` infix) or another repo's modelforge-e2e_* volumes. Check every `docker volume rm`
#    line carries one of those scopings.
unscoped_rm=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if [[ "$line" != *'${PROJECT}_'* && "$line" != *'skillforge-e2e'* && "$line" != *'"$v"'* ]]; then
    unscoped_rm=1
  fi
done < <(grep -E 'docker +volume +rm' "$SCRIPT" | grep -vE '^[[:space:]]*#' || true)
if [[ "$unscoped_rm" == 0 ]]; then
  ok "every 'docker volume rm' is name-scoped to this project / the skillforge-e2e prefix (dev + other repos untouched)"
else
  bad "found an UNSCOPED 'docker volume rm' — risks removing a volume outside this gate"
fi
# Hard guard: the dev stack's volume name must never appear as a removal target anywhere.
if grep -qE 'docker +volume +rm[^|]*skillforge_(postgres|redis)_data' "$SCRIPT"; then
  bad "a 'docker volume rm' targets the DEV volume skillforge_postgres_data — must never happen"
else
  ok "no removal ever targets the dev stack's skillforge_postgres_data"
fi

# 5) E2E_KEEP debugging path must still leave the stack UP (no reset/teardown), so the volume
#    reset never fires when a human asked to keep the stack for inspection.
if grep -qE 'E2E_KEEP.*== 1' "$SCRIPT" && grep -qE 'leaving the stack UP' "$SCRIPT"; then
  ok "E2E_KEEP=1 still leaves the stack up (reset is skipped on the keep path)"
else
  bad "E2E_KEEP debugging path missing/broken"
fi

# 6) CONCURRENCY (issue #140): E2E_LOCAL_STACK=1 is baked into four systemd agents, so several
#    runs share the SAME fixed compose project + postgres volume. Without a lock, one run's
#    `down -v` wipes another's live postgres mid-init → unset superuser password → "password
#    authentication failed". The script must serialize runs behind a file lock so they queue
#    instead of stomp. Assert it takes a lock AND that the lock encloses the volume reset (the
#    lock must be acquired BEFORE the first `down -v`, or it doesn't protect the shared volume).
if grep -qE '\bflock\b' "$SCRIPT"; then
  ok "serializes concurrent runs with a file lock (flock)"
else
  bad "no flock — concurrent agent runs share the DB volume and corrupt it (issue #140)"
fi
lock_ln="$(grep -nE '\bflock\b' "$SCRIPT" | head -1 | cut -d: -f1)"
if [[ -n "$lock_ln" && -n "$reset_ln" && "$lock_ln" -lt "$reset_ln" ]]; then
  ok "lock is acquired before the DB volume reset (protects the shared volume)"
else
  bad "lock is not held across the 'down -v' reset — a concurrent run could still stomp the volume"
fi
# The lock must be project-scoped (keyed to the compose project), so distinct E2E_PROJECTs still
# run in parallel and the lock can't serialize unrelated stacks.
if grep -qE 'LOCK_FILE=.*PROJECT' "$SCRIPT"; then
  ok "lockfile is keyed to the compose project (distinct projects still run in parallel)"
else
  bad "lockfile is not project-scoped — would needlessly serialize unrelated e2e projects"
fi

# ── POISONED / LEFTOVER VOLUME HARDENING (issue #171) ──────────────────────────────────────
# A poisoned/leftover postgres volume survived the #140 tmpfs change and kept re-failing the gate
# with `dependency failed to start` (blocked #152; the prematurely-closed #158 was the same). The
# fix is layered: (a) the DB is volume-less by construction (tmpfs via !override), (b) a scrub +
# orphan reaper run before boot, (c) the run self-heals in-line if postgres still rejects creds.
OVERLAY="docker-compose.e2e.yml"
[[ -f "$OVERLAY" ]] || { echo "run-e2e.test: $OVERLAY not found"; exit 1; }

echo
echo "run-e2e poisoned/leftover-volume hardening (issue #171)"

# 7) The e2e overlay must REPLACE postgres' volumes (not merge), so the base named-volume mount is
#    dropped unambiguously and NO ${PROJECT}_postgres_data is provisioned. Merging by target path
#    isn't reliable across compose versions; `!override` is. Assert the tag + the tmpfs target.
if grep -qE 'volumes:[[:space:]]*!override' "$OVERLAY"; then
  ok "overlay uses 'volumes: !override' for postgres (replaces, not merges, the base mount)"
else
  bad "overlay postgres volumes is not '!override' — the named mount may survive the merge and persist"
fi
if grep -qE 'type:[[:space:]]*tmpfs' "$OVERLAY" && grep -qE 'target:[[:space:]]*/var/lib/postgresql/data' "$OVERLAY"; then
  ok "postgres data dir is a tmpfs mount (volume-less, initdb + password always run)"
else
  bad "postgres data dir is not a tmpfs at /var/lib/postgresql/data — DB is not volume-less"
fi

# 8) Belt-and-suspenders scrub: before boot, the script must explicitly remove THIS project's
#    leftover named volumes (a survivor down -v couldn't reclaim), scoped to ${PROJECT}_.
if grep -qE 'docker +volume +rm +-f +"\$\{PROJECT\}_postgres_data"' "$SCRIPT"; then
  ok "scrubs the project's postgres_data named volume before boot (survivor can't poison this run)"
else
  bad "no project-scoped scrub of \${PROJECT}_postgres_data — a survivor volume could poison the run"
fi

# 9) Orphan reaper: prune stray skillforge-e2e*_{postgres,redis}_data left by killed custom-project
#    runs. The grep MUST be anchored at `^skillforge-e2e` so it can never match another repo's
#    modelforge-e2e_* (or the dev stack's skillforge_postgres_data) — the explicit blast-radius guard.
if grep -qE "grep -E '\^skillforge-e2e\[\^\[:space:\]\]\*_\(postgres\|redis\)_data\\\$'" "$SCRIPT"; then
  ok "orphan reaper is anchored to ^skillforge-e2e (modelforge-e2e_* and dev volume never matched)"
else
  bad "orphan reaper grep is missing/not anchored to ^skillforge-e2e — risks reaping unrelated repos' volumes"
fi

# 10) In-run recovery: if postgres comes up unhealthy or rejects credentials (the poisoned-volume
#     signature), the run must scrub + re-up ONCE so the gate self-heals instead of dead-ending.
#     Assert an explicit auth pre-flight AND that the volume is torn out (down -v) on the recovery path.
if grep -qE 'PGPASSWORD=postgres psql .*SELECT 1' "$SCRIPT"; then
  ok "pre-flights an explicit postgres auth check (catches a poisoned/half-initialized data dir)"
else
  bad "no in-script postgres auth pre-flight — a credential-poisoned DB wouldn't be detected for recovery"
fi
if grep -qiE 'scrubbing and re-initializing|recovered after scrub' "$SCRIPT" && \
   grep -qE 'boot_db && pg_auth_ok' "$SCRIPT"; then
  ok "self-heals in-run: scrub + re-up once on unhealthy/auth-fail before failing the gate"
else
  bad "no in-run scrub+re-up recovery — a poisoned volume would fail the gate instead of self-healing"
fi

# 12) On api/frontend boot failure the script MUST dump the container logs — a container that
#     exits during `alembic upgrade head` carries the real cause ("migrate: non-transient
#     failure", DatatypeMismatchError, DuplicateTable) in ITS logs, not in compose's generic
#     "dependency failed to start". Without this dump the triage classifier (#172) can't see the
#     migrate marker and misfingerprints a branch's migration bug as infra (dead-ended #152/#210).
if grep -A4 'api/frontend failed to start' "$SCRIPT" | grep -qE '"\$\{DC\[@\]\}" logs .* api'; then
  ok "boot-failure path dumps api/frontend container logs (surfaces migrate errors to triage)"
else
  bad "boot-failure path swallows api logs — a migrate failure is misclassified as infra (#152/#210)"
fi

echo
echo "run-e2e visual-project isolation contract"

# 13) The run_playwright invocation must pin --project=chromium so the `visual` project (and its
#     *.visual.spec.ts files) is NEVER executed by the functional e2e gate. The visual project's
#     specs compare pixels against pinned-container Linux baselines; running them on a host
#     chromium produces spurious diffs and re-introduces the exact flake the container isolation
#     is meant to prevent. The chromium project's testIgnore does not stop the visual project
#     from running — only an explicit --project=chromium filter does.
if grep -E "playwright test" "$SCRIPT" | grep -qE "\-\-project=chromium"; then
  ok "run_playwright scopes playwright to --project=chromium (visual project never runs in the functional gate)"
else
  bad "run_playwright has no --project=chromium — the visual project would run on host chromium and diff against container baselines"
fi

# 14) The visual project must NOT be included in the functional gate's playwright invocation.
#     Guard against the inverse regression: someone adding --project=visual or --project=all here.
if grep -E "playwright test" "$SCRIPT" | grep -qE "\-\-project=(visual|all)"; then
  bad "run_playwright explicitly includes the visual/all project — functional gate must be scoped to chromium only"
else
  ok "no --project=visual or --project=all in run_playwright (visual project cannot sneak into the functional gate)"
fi

echo
echo "run-e2e contract: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
