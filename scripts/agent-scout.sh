#!/usr/bin/env bash
# agent-scout.sh — the unattended "scan the product → file dev items for review" runner.
#
# The PRODUCER half of the loop (agent-inbox.sh is the consumer). A systemd user timer
# calls this periodically; each run scans the product against its spec + requirements +
# the real code, and FILES GitHub issues — labelled `proposed` — for you to review on the
# phone and accept (relabel `agent` → the inbox builds it) or reject (close `wontfix`).
#
# Engines, different evidence sources (see docs/33-agent-scout.md, docs/34 for req/journey/docs):
#   • bug         — adversarial, code-grounded, REPRODUCTION-FIRST: a finding becomes an
#                   issue only with a failing-test / concrete repro + file:line evidence.
#                   (SCOUT_LINT_REPORT=<path> seeds a tsc/eslint/log report for the model to triage.)
#   • ux          — customer + business friction vs the design spec (doc 03b) + journeys;
#                   each item carries the journey/screen that exposes it + the Nielsen heuristic it
#                   violates. (SCOUT_UX_DOGFOOD=1 escalates to a real-browser dogfood pass.)
#   • req         — requirements-compliance: maps each FR-NNN (docs/02) → implementing module; files
#                   the missing/partial/contradicted ones + a compliance matrix artifact.
#   • journey     — end-to-end journey coverage: traces each journey (journeys.json) start→finish,
#                   files dead-ends + a coverage matrix. SCOUT_SINCE scopes it to changed journeys
#                   (regression mode); SCOUT_JOURNEY_DOGFOOD=1 drives P0 journeys in a real browser.
#   • docs        — embedded documentation review: missing / too-verbose / unclear docs (static-first).
#   Default SCOUT_ENGINES is "bug ux req journey docs"; the others are opt-in until each proves its accept-rate.
#
# Five disciplines that keep your accept-rate high and triage cheap (docs/33 §why):
#   1. EVIDENCE   — every candidate cites file:line (bug) or a journey/screen (ux); the
#                   bug engine's file:line is then RE-VERIFIED locally before filing.
#   2. CRITIC     — a DIFFERENT-model pass refutes each candidate before it's filed
#                   (false gap / already-built / stale-spec / imagined / duplicate / low-value).
#   3. DEDUP      — a stable fingerprint per finding, checked against OPEN *and* CLOSED
#                   issues, PLUS near-duplicate clustering across the batch before filing.
#   4. RATE-LIMIT — at most SCOUT_MAX_ISSUES filed per run; "found nothing" files nothing.
#   5. ISOLATION  — the scan runs in a DEDICATED git worktree off origin/main; it never
#                   touches your primary working copy and never pushes.
#
# Learning + prioritisation layer (the 2026 best-practice backlog, docs/33 §learning):
#   • OUTCOME LEDGER  — accept/reject per fingerprint is recorded each run; a rolling
#                       accept-rate by engine is printed (phased-confidence telemetry).
#   • REJECTION DIGEST— recently-rejected findings are fed back into the producer prompt so
#                       whole CLASSES of low-value findings don't recur under new fingerprints.
#   • QUEUE RANKING   — survivors across both engines are ranked by severity×confidence×
#                       business-impact; the filed issue carries its rank.
#   • SPECULATIVE TIER— low-confidence-but-plausible survivors are filed `proposed-speculative`
#                       (downgraded, not dropped) so real-but-hard-to-repro defects don't vanish.
#   • DOUBLE-PASS p0  — p0 candidates get a second producer pass; agreement promotes, a
#                       single-pass p0 is flagged for extra review.
#   • AUDIT LOG       — every candidate's critic verdict + file/skip decision is appended as
#                       JSONL so "why did Scout file / not file X?" is queryable post-run.
#   • DYNAMIC BUDGET  — per-engine candidate budget shifts toward the higher-yield engine.
#   • STALENESS NUDGE — an untriaged p0 `proposed` past a threshold is bumped.
#   • REGRESSION LINK — diff-scoped (SINCE) findings link the commit that introduced them.
#
#   Labels filed: `proposed`|`proposed-speculative` + {bug,ux-customer,ux-business} + {p0,p1,p2}.
#   Setup: scripts/agent-scout-setup.sh  ·  Test: scripts/agent-scout.test.sh
#
# Single-pass by design (the timer re-invokes it). Every external command + path is
# overridable via env so the journey is testable hermetically with NO real GitHub
# side-effects and NO LLM cost.
set -uo pipefail

# ── Injectable dependencies (defaults = production; tests override) ──────────────
ROOT="${SCOUT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GH="${SCOUT_GH:-gh}"                        # GitHub CLI (stubbed in tests)
CLAUDE="${SCOUT_CLAUDE:-claude}"            # Claude Code CLI (stubbed in tests)
BASE="${SCOUT_BASE:-main}"                  # branch the scan reads
REMOTE="${SCOUT_REMOTE:-origin}"            # git remote
PROPOSED_LABEL="${SCOUT_LABEL:-proposed}"   # the review label
SPECULATIVE_LABEL="${SCOUT_SPECULATIVE_LABEL:-proposed-speculative}" # low-confidence tier
MODEL="${SCOUT_MODEL:-opus}"                # producer model alias
CRITIC_MODEL="${SCOUT_CRITIC_MODEL:-sonnet}" # critic model — DIFFERENT from the producer
ENGINES="${SCOUT_ENGINES:-bug ux req journey docs security}"          # which engines to run this tick (bug ux req journey docs security)
MAX_ISSUES="${SCOUT_MAX_ISSUES:-15}"         # global cap on issues filed per run
MAX_PER_ENGINE="${SCOUT_MAX_PER_ENGINE:-5}" # per-engine cap (base; dynamic budget may adjust)
SINCE="${SCOUT_SINCE:-}"                     # optional git ref: scope the bug/journey scan to its diff
ARTIFACT_DIR="${SCOUT_ARTIFACT_DIR:-$ROOT/state/artifacts}" # where coverage matrices (req/journey) land
DOC_MAX_RATIO="${SCOUT_DOC_MAX_RATIO:-2.0}" # docs engine: comment:code ratio over which a block is "too verbose"
LINT_REPORT="${SCOUT_LINT_REPORT:-}"        # bug engine: optional tsc/eslint/log report to seed/triage
# Telemetry (#2390) — CLAUDE.md requires a span per `claude` invocation. Sourcing the shared
# model-call lib brings in both classify_model_result and agent_trace_span, and mints the run id
# in THIS shell so the producer/critic/pass2 spans of one tick nest under a single run.
# Libs live NEXT TO this script, so resolve them from BASH_SOURCE — never from $ROOT.
# $ROOT is overridable (AGENT_ROOT/PR_ROOT/SCOUT_ROOT) and every hermetic suite points it at a
# sandbox clone with no scripts/lib, so a $ROOT-relative source silently fails there: without
# `set -e` the script sails on with classify_model_result AND agent_trace_span undefined, and
# the span the gate believes it is checking is never emitted (#2390).
# shellcheck source=scripts/lib/agent-model-call.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/agent-model-call.sh"
# ── Per-repo namespace — so two scouts in DIFFERENT repos never collide on a global /tmp
# lock. The bug: /tmp/agent-scout.lock was one inode for EVERY checkout on the machine, so a
# manual `bash scripts/agent-scout.sh` here aborted whenever ml-builder's scout held it (and
# clobbered each other's logs/worktrees). The git common dir is stable across a repo's own
# worktrees yet unique per repo; resolve it to an ABSOLUTE path first because
# `--git-common-dir` returns a bare ".git" at a repo root (every repo would hash identically
# otherwise). Mirrors agent-pr-merger's git-common-dir-derived worktree lock. Two scouts of
# the SAME repo still share the key → still serialize. All three paths stay env-overridable.
scout_repo_ns() {
  local d
  d="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  d="$(cd "$ROOT" 2>/dev/null && cd "$d" 2>/dev/null && pwd)" || return 1
  printf '%s' "$d" | sha1sum | cut -c1-12
}
NS="$(scout_repo_ns || true)"; [ -n "$NS" ] || NS="nogit"
LOCK="${SCOUT_LOCK:-/tmp/agent-scout-$NS.lock}"
LOGDIR="${SCOUT_LOGDIR:-/tmp/agent-scout-$NS}"
WORKTREE_BASE="${SCOUT_WORKTREE_BASE:-/tmp/agent-scout-$NS/worktrees}"
DEPS_MODE="${SCOUT_DEPS:-symlink}"          # symlink (fast, read-only scan) | install
DRY_RUN="${SCOUT_DRY_RUN:-0}"               # 1 = compute everything, file nothing
# ── learning + prioritisation layer (all overridable for hermetic tests) ─────────
LEDGER="${SCOUT_LEDGER:-${LOGDIR}/ledger.jsonl}"   # rolling accept/reject outcomes (persists)
AUDIT="${SCOUT_AUDIT:-${LOGDIR}/audit.jsonl}"      # per-candidate decision audit (this run)
DYNAMIC_BUDGET="${SCOUT_DYNAMIC_BUDGET:-1}"        # 1 = size per-engine budget by accept-rate
DUP_PCT="${SCOUT_DUP_PCT:-60}"                     # near-dup Jaccard threshold (percent)
STALE_DAYS="${SCOUT_STALE_DAYS:-3}"                # untriaged p0 `proposed` nudge threshold
NOW="${SCOUT_NOW:-$(date -u +%s)}"                 # clock (override for deterministic tests)
RUN_TS="${SCOUT_RUN_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

cd "$ROOT" || { echo "[agent-scout] cannot cd to $ROOT" >&2; exit 2; }
mkdir -p "$LOGDIR" "$WORKTREE_BASE" "$(dirname "$LEDGER")" "$(dirname "$AUDIT")"
log() { printf '[agent-scout] %s\n' "$*"; }

# ── Toolchain bootstrap — systemd/cron start from a BARE env (no ~/.bashrc, no nvm) ─
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
[ -s "$HOME/miniconda3/etc/profile.d/conda.sh" ] && . "$HOME/miniconda3/etc/profile.d/conda.sh" >/dev/null 2>&1 || true
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) [ -d "$PNPM_HOME" ] && PATH="$PNPM_HOME:$PATH";; esac

# ── Preflight — fail LOUD + early on a missing dependency ────────────────────────
PREFLIGHT_TOOLS="${SCOUT_PREFLIGHT_TOOLS:-git jq node npx}"
missing=""
for t in $PREFLIGHT_TOOLS "$GH" "$CLAUDE"; do
  command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
done
if [ -n "$missing" ]; then
  log "PREFLIGHT FAILED — not on PATH:${missing}"
  log "  systemd/cron use a bare env; ensure nvm/conda/pnpm init is sourced (see docs/26 §PATH)."
  exit 1
fi

# ── Single-instance lock — never run two scans at once (of THIS repo; see NS above) ─
log "single-instance lock: $LOCK"
exec 9>"$LOCK"
if ! flock -n 9; then log "another scan in progress — exiting"; exit 0; fi

# ── One rich issue snapshot — feeds dedup, the outcome ledger, the rejection digest,
# and the staleness nudge from a single GitHub round-trip. ───────────────────────
log "gathering issue snapshot (open+closed) for dedup / ledger / digest…"
all_issues_json="$("$GH" issue list --state all --limit 300 \
  --json number,title,labels,state,stateReason,body,createdAt 2>/dev/null || echo '[]')"
[ -n "$all_issues_json" ] || all_issues_json='[]'
echo "$all_issues_json" | jq -e . >/dev/null 2>&1 || all_issues_json='[]'

# Fingerprints already known (open *and* closed) — nothing rejected is ever re-filed.
existing_fps="$(jq -r '.[].body // "" | capture("scout-fp: (?<fp>[a-z0-9._-]+)";"g").fp' \
  <<<"$all_issues_json" 2>/dev/null | sort -u || true)"
seen_fp() { [ -n "$existing_fps" ] && grep -qxF "$1" <<<"$existing_fps"; }

# ── helper: derive an engine/severity/confidence triple from an issue's labels+body ─
issue_engine()   { jq -r '[.labels[]?.name] | map(select(.=="bug" or .=="ux-customer" or .=="ux-business" or .=="req" or .=="journey" or .=="docs" or .=="security")) | .[0] // "bug"'; }
issue_severity() { jq -r '[.labels[]?.name] | map(select(.=="p0" or .=="p1" or .=="p2")) | .[0] // "p2"'; }

# ── #1 OUTCOME LEDGER — record accept/reject per fingerprint, persisted across runs.
# accepted = the owner relabelled it `agent`; rejected = closed not-planned / `wontfix`.
update_ledger() {
  touch "$LEDGER"
  jq -c '.[] | select((.body // "") | test("scout-fp:"))' <<<"$all_issues_json" 2>/dev/null \
  | while IFS= read -r iss; do
      [ -n "$iss" ] || continue
      local fp outcome eng sev conf labels state reason
      fp="$(jq -r '.body | capture("scout-fp: (?<f>[a-z0-9._-]+)").f // empty' <<<"$iss")"
      [ -n "$fp" ] || continue
      labels="$(jq -r '[.labels[]?.name] | join(" ")' <<<"$iss")"
      state="$(jq -r '.state // ""' <<<"$iss")"
      reason="$(jq -r '.stateReason // ""' <<<"$iss")"
      outcome=""
      if grep -qw agent <<<"$labels"; then outcome="accepted"
      elif [ "$state" = "CLOSED" ] && { [ "$reason" = "NOT_PLANNED" ] || grep -qw wontfix <<<"$labels"; }; then outcome="rejected"
      fi
      [ -n "$outcome" ] || continue
      # idempotent: a terminal outcome is recorded once.
      grep -q "\"fingerprint\":\"${fp}\"" "$LEDGER" 2>/dev/null && continue
      eng="$(issue_engine <<<"$iss")"; sev="$(issue_severity <<<"$iss")"
      conf="$(jq -r '.body | (capture("confidence (?<c>high|medium|low)").c) // "medium"' <<<"$iss" 2>/dev/null || echo medium)"
      jq -nc --arg fp "$fp" --arg e "$eng" --arg s "$sev" --arg c "$conf" \
             --arg o "$outcome" --arg ts "$RUN_TS" \
        '{ts:$ts,fingerprint:$fp,engine:$e,severity:$s,confidence:$c,outcome:$o}' >> "$LEDGER"
    done
}

# group an engine label into its run-engine bucket: ux-customer/ux-business → ux;
# bug/req/journey/docs are their own bucket.
bucket() { case "$1" in ux-*) echo ux ;; req|journey|docs|security) echo "$1" ;; *) echo bug ;; esac; }

# accepted/rejected counts for a run-engine bucket, read from the ledger.
# jq mirror of bucket(): collapse ux-* → ux, keep bug/req/journey/docs as-is.
ledger_counts() { # $1=bucket → "accepted rejected"
  local b="$1" a r
  if [ ! -s "$LEDGER" ]; then echo "0 0"; return; fi
  a="$(jq -r --arg b "$b" 'select(((.engine // "bug") | if startswith("ux") then "ux" else . end)==$b) | .outcome' "$LEDGER" 2>/dev/null | grep -c '^accepted$' || true)"
  r="$(jq -r --arg b "$b" 'select(((.engine // "bug") | if startswith("ux") then "ux" else . end)==$b) | .outcome' "$LEDGER" 2>/dev/null | grep -c '^rejected$' || true)"
  echo "${a:-0} ${r:-0}"
}

# ── #1 print rolling accept-rate (the phased-confidence telemetry) ────────────────
print_accept_rate() {
  local any=0 line="accept-rate (rolling):"
  for b in bug ux req journey docs security; do
    read -r a r <<<"$(ledger_counts "$b")"
    local tot=$((a + r))
    if [ "$tot" -gt 0 ]; then
      any=1
      local pct=$(( a * 100 / tot ))
      line="${line} ${b}=${pct}% (${a}/${tot})"
    fi
  done
  [ "$any" -eq 1 ] && log "$line" || log "accept-rate (rolling): no outcomes recorded yet"
}

# ── #12 DYNAMIC PER-ENGINE BUDGET — shift candidate budget toward the higher-yield engine.
declare -A ENGINE_CAP
compute_engine_budgets() {
  local e
  for e in $ENGINES; do ENGINE_CAP["$e"]="$MAX_PER_ENGINE"; done
  [ "$DYNAMIC_BUDGET" = "1" ] || return 0
  [ -s "$LEDGER" ] || return 0
  # smoothed accept-rate weight per engine; allocate ~2×MAX_PER_ENGINE proportionally.
  local total_w=0 budget_line="engine budgets:" have=0
  declare -A W
  for e in $ENGINES; do
    read -r a r <<<"$(ledger_counts "$e")"
    local tot=$((a + r)) rate=0
    [ "$tot" -gt 0 ] && { rate=$(( a * 100 / tot )); have=1; }
    # weight = accept-rate% + 50 smoothing (so a zero-yield engine still gets a floor).
    W["$e"]=$((rate + 50)); total_w=$((total_w + W["$e"]))
  done
  [ "$have" = 1 ] || return 0
  local pool=$(( MAX_PER_ENGINE * 2 ))
  for e in $ENGINES; do
    local cap=$(( (W["$e"] * pool + total_w/2) / total_w ))   # rounded proportional share
    [ "$cap" -lt 1 ] && cap=1
    [ "$cap" -gt "$MAX_ISSUES" ] && cap="$MAX_ISSUES"
    ENGINE_CAP["$e"]="$cap"
    budget_line="${budget_line} ${e}=${cap}"
  done
  log "$budget_line"
}

# ── #2 REJECTION DIGEST — recently-rejected findings fed back as negative exemplars ─
rejection_digest=""
build_rejection_digest() {
  rejection_digest="$(jq -r '.[]
      | select(.state=="CLOSED")
      | select((.stateReason=="NOT_PLANNED") or ([.labels[]?.name]|index("wontfix")))
      | select((.body // "")|test("scout-fp:"))
      | "- " + (.title // "untitled")' <<<"$all_issues_json" 2>/dev/null \
    | head -25 || true)"
  [ -n "$rejection_digest" ] && log "rejection digest: $(grep -c '^- ' <<<"$rejection_digest") previously-rejected class(es) fed back"
}

# ── #10 STALENESS NUDGE — bump an untriaged p0 `proposed` past the threshold ───────
nudge_stale_p0() {
  [ "$DRY_RUN" = "1" ] && return 0
  local stale_secs=$(( STALE_DAYS * 86400 ))
  jq -c '.[] | select(.state=="OPEN")
      | select([.labels[]?.name] | (index("proposed") or index("proposed-speculative")) and index("p0"))
      | {n:.number, created:.createdAt, title:.title}' <<<"$all_issues_json" 2>/dev/null \
  | while IFS= read -r row; do
      [ -n "$row" ] || continue
      local n created cts age
      n="$(jq -r '.n' <<<"$row")"; created="$(jq -r '.created // ""' <<<"$row")"
      [ -n "$created" ] || continue
      cts="$(date -u -d "$created" +%s 2>/dev/null || echo 0)"
      [ "$cts" -gt 0 ] || continue
      age=$(( NOW - cts ))
      if [ "$age" -ge "$stale_secs" ]; then
        local days=$(( age / 86400 ))
        "$GH" issue edit "$n" --add-label stale >/dev/null 2>&1 || true
        "$GH" issue comment "$n" --body "🔭 agent-scout: this p0 proposal has sat untriaged for ${days}d (≥ ${STALE_DAYS}d). Accept (relabel \`agent\`) or close (\`wontfix\`)." >/dev/null 2>&1 || true
        log "nudged #${n} (stale p0, ${days}d untriaged)"
      fi
    done
}

update_ledger
print_accept_rate
compute_engine_budgets
build_rejection_digest
nudge_stale_p0

# ── Isolated worktree off the latest base — NEVER touches the primary working copy ─
git fetch -q "$REMOTE" "$BASE" >/dev/null 2>&1 || true
base_ref="${REMOTE}/${BASE}"
git rev-parse --verify -q "$base_ref" >/dev/null || base_ref="$BASE"
wt="${WORKTREE_BASE}/scan"
git worktree remove --force "$wt" >/dev/null 2>&1 || true
rm -rf "$wt" >/dev/null 2>&1 || true
if ! git worktree add -f --detach "$wt" "$base_ref" >/dev/null 2>&1; then
  log "could not create an isolated scan worktree — exiting"; exit 1
fi
cleanup() { cd "$ROOT" 2>/dev/null || true; git worktree remove --force "$wt" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Provision node_modules so the bug engine can actually RUN a repro test. symlink = fast
# (read-only scan); install = hermetic but slow. Mirrors the inbox's provisioning.
if [ -f "$ROOT/frontend/package.json" ] && [ -d "$wt/frontend" ]; then
  if [ "$DEPS_MODE" = "symlink" ]; then
    [ -d "$ROOT/frontend/node_modules" ] && [ ! -e "$wt/frontend/node_modules" ] && ln -s "$ROOT/frontend/node_modules" "$wt/frontend/node_modules" 2>/dev/null || true
  else
    ( cd "$wt/frontend" && npm install --no-audit --no-fund --silent ) >>"${LOGDIR}/deps.log" 2>&1 || true
  fi
fi

# Optionally scope the bug scan to a diff (post-merge mode): the files changed since $SINCE.
changed_files=""
if [ -n "$SINCE" ]; then
  changed_files="$(git -C "$wt" diff --name-only "${SINCE}" HEAD 2>/dev/null | head -200 || true)"
fi

filed_total=0
CONTRACT_FAIL=0
SURVFILE="${LOGDIR}/survivors.jsonl"; : > "$SURVFILE"
: > "$AUDIT"

# ── #6 AUDIT LOG — one JSONL line per candidate decision, queryable post-run. ─────
audit() { # fp engine severity confidence critic_keep critic_reason decision detail
  jq -nc --arg fp "$1" --arg engine "$2" --arg sev "$3" --arg conf "$4" \
         --arg ck "$5" --arg cr "$6" --arg dec "$7" --arg detail "$8" --arg ts "$RUN_TS" \
    '{ts:$ts,fingerprint:$fp,engine:$engine,severity:$sev,confidence:$conf,
      critic_keep:$ck,critic_reason:$cr,decision:$dec,detail:$detail}' >> "$AUDIT"
}

# ── #7 EVIDENCE RE-VERIFY — at least one cited `path:line` must resolve to a real, in-range
# location in the worktree. The anti-hallucination guard: a finding whose cited locations are
# ALL fabricated is dropped; a finding that points at ≥1 real location is kept (whether the
# CLAIM about that code is correct is the critic's job, not this one).
#
# Crucial: bug evidence writes the full path ONCE then uses BASENAME shorthands for the rest
# ("services/.../orgs.ts:179 … orgs.ts:302 … orgs.ts:309"). The old "drop if ANY ref fails to
# resolve as a repo-root path" therefore dropped nearly every real finding (the shorthand
# `orgs.ts` doesn't exist at the root). So we (a) resolve a bare basename to its tracked file,
# and (b) keep if ANY ref resolves — drop only when NONE do (a true hallucination).
verify_evidence() {
  local evidence="$1" ref path line resolved any_ref=0 verified=0 n base hit
  # nothing to check → don't block here (the critic already judged plausibility).
  grep -qoE '[A-Za-z0-9_./-]+:[0-9]+' <<<"$evidence" || return 0
  while IFS= read -r ref; do
    path="${ref%:*}"; line="${ref##*:}"; any_ref=1; resolved=""
    if [ -f "$wt/$path" ]; then
      resolved="$wt/$path"
    else
      # Basename shorthand (e.g. "orgs.ts:302") — resolve to the tracked file by name.
      base="${path##*/}"
      hit="$(git -C "$wt" ls-files "*/$base" "$base" 2>/dev/null | head -1)"
      [ -n "$hit" ] && resolved="$wt/$hit"
    fi
    [ -n "$resolved" ] || continue                  # this ref didn't resolve → try the next
    n="$(wc -l < "$resolved" 2>/dev/null || echo 0)"
    [ "$line" -le "$((n + 1))" ] && verified=1       # a real file + in-range line (+1: no trailing \n)
  done < <(grep -oE '[A-Za-z0-9_./-]+:[0-9]+' <<<"$evidence")
  [ "$any_ref" -eq 0 ] && return 0                  # no parseable refs → don't block
  [ "$verified" -eq 1 ] && return 0                 # ≥1 cited location is real + in range → keep
  return 1                                          # every cited path:line is fabricated → drop
}

# ── #11 REGRESSION ORIGIN — for SINCE runs, blame the cited line to its introducing commit.
regression_origin() {
  local evidence="$1" ref path line sha subj
  [ -n "$SINCE" ] || return 0
  ref="$(grep -oE '[A-Za-z0-9_./-]+:[0-9]+' <<<"$evidence" | head -1)"
  [ -n "$ref" ] || return 0
  path="${ref%:*}"; line="${ref##*:}"
  [ -f "$wt/$path" ] || return 0
  sha="$(git -C "$wt" blame -L "${line},${line}" --porcelain -- "$path" 2>/dev/null | head -1 | awk '{print $1}')"
  [ -n "$sha" ] && [ "$sha" != "0000000000000000000000000000000000000000" ] || return 0
  subj="$(git -C "$wt" log -1 --format='%s' "$sha" 2>/dev/null || true)"
  printf '%s %s' "${sha:0:12}" "$subj"
}

# ── tokenise a string for near-duplicate clustering (#9) ──────────────────────────
norm_tokens() {
  tr '[:upper:]' '[:lower:]' <<<"$1" \
    | tr -cs 'a-z0-9' '\n' \
    | grep -vE '^(the|and|for|with|that|this|when|from|into|missing|lacks|should|does|not|are|has|its)$' \
    | grep -E '.{3,}' | sort -u
}
# Jaccard overlap (percent) between two token files.
jaccard_pct() {
  local a="$1" b="$2" inter union
  inter="$(comm -12 "$a" "$b" 2>/dev/null | grep -c . || true)"
  union="$(cat "$a" "$b" 2>/dev/null | sort -u | grep -c . || true)"
  [ "${union:-0}" -eq 0 ] && { echo 0; return; }
  echo $(( inter * 100 / union ))
}

# ── #8 CONTRACT LINT — a composed body MUST carry a fingerprint marker + acceptance. ─
lint_body() {
  local body="$1"
  grep -qE 'scout-fp: [a-z0-9._-]+' <<<"$body" || return 1
  local acc
  acc="$(awk '/^### Acceptance/{f=1;next} f&&NF{print;exit}' <<<"$body")"
  [ -n "$acc" ] && [ "$acc" != "(none)" ]
}

# ── Compose a single issue body from a candidate's structured fields ─────────────
# Guarantees the fingerprint marker + an explicit acceptance criterion are present, and
# surfaces the queue rank, regression origin, and double-pass confirmation where known.
compose_body() {
  local c="$1"
  local engine sev conf evidence repro fix rationale accept fp rank impact regr p0c heuristic
  engine="$(jq -r '.engine // "bug"' <<<"$c")"
  heuristic="$(jq -r '.heuristic // empty' <<<"$c")"
  sev="$(jq -r '.severity // "p2"' <<<"$c")"
  conf="$(jq -r '.confidence // "medium"' <<<"$c")"
  impact="$(jq -r '.business_impact // "medium"' <<<"$c")"
  evidence="$(jq -r '.evidence // "(none)"' <<<"$c")"
  repro="$(jq -r '.repro // "(none)"' <<<"$c")"
  fix="$(jq -r '.proposed_fix // "(none)"' <<<"$c")"
  rationale="$(jq -r '.rationale // ""' <<<"$c")"
  accept="$(jq -r '.acceptance // "(none)"' <<<"$c")"
  fp="$(jq -r '.fingerprint' <<<"$c")"
  rank="$(jq -r '._rank // empty' <<<"$c")"
  regr="$(jq -r '._regression // empty' <<<"$c")"
  p0c="$(jq -r 'if has("_p0_confirmed") then (._p0_confirmed|tostring) else "" end' <<<"$c")"

  local rank_line="" p0_line="" regr_block=""
  [ -n "$rank" ] && rank_line="**Queue rank ${rank}** (severity×confidence×business-impact: ${sev}·${conf}·${impact})"$'\n'
  case "$p0c" in
    true)  p0_line="✓ **Confirmed by a second producer pass** (double-pass agreement)."$'\n' ;;
    false) p0_line="⚠️ **Single-pass p0** — surfaced by one pass only; give this extra review before accepting."$'\n' ;;
  esac
  [ -n "$regr" ] && regr_block="
### Regression origin (introduced since \`${SINCE}\`)
\`${regr}\`
"
  local heuristic_line=""
  [ -n "$heuristic" ] && heuristic_line="**Nielsen heuristic violated:** \`${heuristic}\`"$'\n'
  cat <<MD
**Scout-proposed ${engine} · severity ${sev} · confidence ${conf}** — review and accept (relabel \`agent\`) or close (\`wontfix\`).
${rank_line}${heuristic_line}${p0_line}
${rationale}

### Evidence
${evidence}

### Reproduction / where it shows
${repro}
${regr_block}
### Proposed fix
${fix}

### Acceptance criterion (the bar a fix must clear)
${accept}

---
<sub>🔭 filed by agent-scout. Accepting relabels this \`agent\` and the agent-inbox will build it against the criterion above.</sub>
<!-- scout-fp: ${fp} -->
MD
}

# ── COLLECT one engine: produce → critic → evidence re-verify → dedup → accumulate ─
# (Ranking, near-dup clustering, and filing happen ONCE across all engines afterward.)
collect_engine() {
  local engine="$1"
  local cap="${ENGINE_CAP[$engine]:-$MAX_PER_ENGINE}"

  local cand_out="${LOGDIR}/cand-${engine}.json"
  local verdict_out="${LOGDIR}/verdict-${engine}.json"
  rm -f "$cand_out" "$verdict_out"

  # Coverage engines (req/journey) also emit a full matrix artifact, regenerated every
  # run even when zero issues are filed (issues are the delta; the matrix is the state).
  local matrix_out="" artifact="" matrix_block=""
  case "$engine" in
    req)     matrix_out="${LOGDIR}/matrix-req.json";     artifact="$ARTIFACT_DIR/scout-compliance.json" ;;
    journey) matrix_out="${LOGDIR}/matrix-journey.json"; artifact="$ARTIFACT_DIR/scout-journeys-coverage.json" ;;
  esac

  # Engine-specific focus + valid engine label(s) appended to the shared producer contract.
  local focus engine_values
  case "$engine" in
  bug)
    engine_values="bug"
    local lint_block=""
    if [ -n "$LINT_REPORT" ] && [ -f "$LINT_REPORT" ]; then
      lint_block="
STATIC SIGNAL TO TRIAGE (from a tsc/eslint/log report at ${LINT_REPORT}). For EACH entry, decide
whether it is a REAL, reproducible defect worth filing — DON'T re-derive these warnings, spend your
budget judging which are genuine. Ignore the noise:
$(head -100 "$LINT_REPORT")
"
    fi
    focus="ENGINE: BUG (correctness → bug-free). Hunt REAL, REPRODUCIBLE defects adversarially in
this corporate-learning platform: data-integrity, auth & RBAC (learner vs admin) & IDOR,
multi-tenant seat/team isolation, concurrency & races (background course-builder jobs),
scoring/credential integrity, error-handling & unhandled exceptions, input validation, and
spec/requirement violations. REPRODUCTION-FIRST: only propose a defect you can back with a concrete
failing test (backend pytest / frontend vitest / Playwright) or exact repro steps + file:line. If
you cannot, DROP it. Ground every item in docs/03-srs.md and the real code (backend/app FastAPI
routes & services, frontend/src React).${lint_block}${changed_files:+
Focus on these changed files (post-merge diff):
${changed_files}}"
    ;;
  ux)
    engine_values="ux-customer | ux-business"
    focus="ENGINE: UX (customer + business). Find friction that hurts the product against the
design spec (docs/04-system-design.md, docs/21-ux-audit-issues.md, docs/28-ai-content-creation-ux-research.md)
and the user-journey tests (docs/19-user-journey-verification-tests.md). File each item as engine
\"ux-customer\" (the learner taking courses / earning credentials) or \"ux-business\" (the admin/manager
running team & seat management, course building, and analytics). Cite the exact screen/component
(frontend/src) or journey that exposes the friction.
USABILITY RUBRIC — for EACH item name WHICH of Nielsen's 10 heuristics it violates in a
\"heuristic\" field (one of: visibility-of-system-status, match-system-and-real-world,
user-control-and-freedom, consistency-and-standards, error-prevention, recognition-over-recall,
flexibility-and-efficiency, aesthetic-and-minimalist, help-users-recognise-recover-from-errors,
help-and-documentation). Carry a usability severity in the standard severity field.${SCOUT_UX_DOGFOOD:+
Drive the running product with the dogfood/browse skill and attach what you observe.}"
    ;;
  req)
    engine_values="req"
    focus="ENGINE: REQ (requirements-compliance). Map every FR-NNN in docs/03-srs.md
to its implementing module(s) under backend/app and frontend/src (use docs/04-system-design.md for the intended map).
Classify each FR as {implemented, partial, missing, contradicted}. FILE an issue ONLY for
partial/missing/contradicted; 'implemented' is a coverage datapoint, not an issue. A MISSING
requirement legitimately has NO file:line — cite the FR id + the design-doc module that SHOULD hold
it as evidence (do not invent a fake line). Inherit severity from the FR tag: [wedge-critical] →
p0/p1, [wedge-supporting] → p1/p2. The acceptance criterion IS the FR's own description.
ALSO write the FULL compliance matrix (every FR, including implemented) as a JSON array to:
  ${matrix_out}
Each row: {\"fr\":\"FR-NNN\",\"status\":\"implemented|partial|missing|contradicted\",\"evidence\":\"...\",\"missing_part\":\"...\",\"severity\":\"p0|p1|p2\"}."
    matrix_block="MATRIX: also write the full per-FR compliance matrix to ${matrix_out} (see ENGINE block)."
    ;;
  journey)
    engine_values="journey"
    focus="ENGINE: JOURNEY (end-to-end coverage). For EACH journey in
docs/19-user-journey-verification-tests.md (and the Playwright specs under frontend/tests/e2e),
trace the FULL path — entry point → each step's UI/route/handler → terminal state — through the
frontend/src React routes and backend/app FastAPI handlers and docs/04-system-design.md flows.
Classify {complete, blocked, partial}. FILE an issue ONLY for blocked/partial, naming the EXACT hop
that breaks (screen/route/handler) and why (missing route, button with no handler, guard that always
fails, error branch with no recovery). Inherit severity from journey.priority (P0→p0). This is
reachability ACROSS steps, NOT friction within a screen (that is the ux engine's job).${SCOUT_JOURNEY_DOGFOOD:+
DOGFOOD: drive each P0 journey in a real browser via the dogfood/browse skill rather than tracing
statically — turn 'the route exists' into 'a human can complete it'.}${changed_files:+
REGRESSION MODE (post-merge diff is set): prioritise journeys whose traced code touches these
changed files, flagging any P0 journey a recent diff may have broken:
${changed_files}}
ALSO write the FULL journey-coverage matrix as a JSON array to:
  ${matrix_out}
Each row: {\"id\":\"S-NNN\",\"status\":\"complete|blocked|partial\",\"evidence\":\"...\",\"broken_hop\":\"...\",\"severity\":\"p0|p1|p2\"}."
    matrix_block="MATRIX: also write the full per-journey coverage matrix to ${matrix_out} (see ENGINE block)."
    ;;
  docs)
    engine_values="docs"
    focus="ENGINE: DOCS (embedded documentation review). Flag documentation that is MISSING where it
is needed, TOO VERBOSE, or UNCLEAR/STALE — balance embedded clarity against the repo's own terseness
rule (CLAUDE.md: 'terse … minimal verbosity'). Read docs/*, code comments + docstrings under
backend/app and frontend/src, and public exports / FastAPI route handlers (where missing docs hurt most). Categories:
 • MISSING: an exported function / public route / env var / config flag with no doc comment (severity
   by surface area: a public API route > an internal helper).
 • VERBOSE: a doc/comment block whose comment:code ratio exceeds ${DOC_MAX_RATIO} or that runs to
   wall-of-text paragraphs → flag 'trim/make scannable'.
 • UNCLEAR/STALE: a doc that references a symbol/path that no longer exists, or a README step that
   contradicts the code.
For each item, tag the exact block (file:line where it exists) + a one-line 'make it say X' rewrite
in proposed_fix. Mostly static/cheap — only judge CLARITY on the survivors."
    ;;
  security)
    engine_values="security"
    focus="ENGINE: SECURITY (find exploitable weaknesses before an attacker does). Hunt REAL,
concrete security defects in THIS repository's OWN code, its dependencies, and its
deployment/runtime configuration — the OWASP Top 10 and, above all, the classes that lead to
remote server compromise. Look for, at minimum:
 • NETWORK EXPOSURE: a service/container/dev-server bound to 0.0.0.0 or published to the host/LAN
   (docker-compose ports, HOST/HOSTNAME=0.0.0.0, listen addresses), a dev-only compose/port/env
   OVERRIDE that a real deployment loads, an admin/internal/debug endpoint reachable without auth,
   and dev-bypass flags (NODE_ENV, *_DEV_AUTH_BYPASS, *_DEBUG, seed/demo logins) that can leak into
   a deployed build.
 • VULNERABLE DEPENDENCIES: a pinned package/image version with a KNOWN CVE — check package.json /
   lockfiles / requirements.txt / Dockerfile base images against the fixed version. Cite the
   package, the pinned version, the CVE id, and the fixed version (e.g. next@15.1.0 → CVE-2025-29927,
   fixed 15.2.3). Only claim a CVE you are confident maps to the pinned range.
 • INJECTION / RCE: attacker-influenced input reaching child_process/exec/spawn/eval/new Function,
   unsafe deserialization, template/SQL/command injection, path traversal, or SSRF in a server-side
   fetch/proxy handler.
 • BROKEN AUTH / ACCESS CONTROL: missing or spoofable authn/authz, IDOR (one tenant/user reading or
   mutating another's data), auth-bypass via a trusted-but-attacker-controlled header, weak
   session/cookie flags (missing HttpOnly/Secure/SameSite), unsigned/again-verifiable tokens.
 • SECRETS: hardcoded credentials / API keys / tokens in source or committed env files, secrets
   written to logs or error responses, over-broad service-account or IAM scopes.
Ground EVERY item in checkable evidence: file:line for code/config, the exact dependency+version
line for a CVE, or the compose/env line for an exposure. REPRODUCTION-FIRST: prefer a concrete
attack sketch (the request/header/input that exploits it) or a failing security test; if you cannot
back it with checkable evidence, DROP it. Inherit severity from blast radius: remote-unauthenticated
code-exec or data exposure → p0; authenticated privilege-escalation / IDOR → p1;
hardening / defense-in-depth → p2.${changed_files:+
Focus on these changed files (post-merge diff):
${changed_files}}"
    ;;
  *)
    engine_values="$engine"
    focus="ENGINE: ${engine}."
    ;;
  esac

  log "engine ${engine}: scanning (model ${MODEL}, budget ${cap})…"
  local digest_block=""
  [ -n "$rejection_digest" ] && digest_block="
RECENTLY REJECTED by the owner — do NOT re-propose these OR their close cousins, even under a
NEW fingerprint (whole classes of low-value findings, not just exact repeats):
${rejection_digest}
"
  local prompt
  prompt="$(cat <<EOF
You are agent-scout, running UNATTENDED and READ-ONLY in an isolated worktree of the
SkillForge product. Do NOT modify the working tree, do NOT commit, do NOT push.

Your job: find the highest-value, most defensible NEW development items by diffing the
product's intent (docs/01-market-analysis.md, docs/02-product-idea.md, docs/03-srs.md, the
design spec docs/04-system-design.md) against the EXISTING implementation (the real code). Read with
the \`Explore\` style — read broadly, conclude tightly.

${focus}

For EACH item, attach evidence and a fingerprint. The fingerprint is a STABLE kebab-case id
derived from the defect's LOCATION + ASSERTION (e.g. "gateway-score-route-missing-rbac"), so
the SAME finding always hashes the same — this is how we avoid re-filing. Do NOT invent a new
fingerprint for a finding that already exists below.

ALREADY-FILED fingerprints (do NOT re-propose these — open or already-rejected):
${existing_fps:-（none yet）}
${digest_block}
Write ONLY a JSON object (no prose, no markdown fence) to the file:
  ${cand_out}
Schema:
{
  "candidates": [
    {
      "fingerprint": "kebab-stable-id",
      "engine": "<one of: ${engine_values}>",
      "title": "imperative, specific issue title",
      "severity": "p0|p1|p2",
      "confidence": "high|medium|low",
      "business_impact": "high|medium|low",  // blast radius if real (revenue/trust/data)
      "rationale": "1-3 sentences: why this matters to quality/UX",
      "evidence": "file:line refs (bug) · FR id + design module (req) · screen/journey (ux/journey) · doc block (docs) — concrete, checkable",
      "repro": "a failing-test sketch or exact steps (bug) / the journey or FR that exposes it",
      "proposed_fix": "the change you'd make",
      "acceptance": "a falsifiable criterion a fix must satisfy (ideally a test/journey)",
      "heuristic": "(ux only) the Nielsen heuristic violated — omit for other engines"
    }
  ]
}
${matrix_block:+${matrix_block}
}Cap: at most ${cap} candidates, highest-value first. If you find nothing that clears the
reproduction/evidence bar, write {"candidates": []}. Quality over quantity.
EOF
)"
  printf '%s\n' "$prompt" > "${LOGDIR}/prompt-${engine}.txt"   # auditability: the exact prompt
  rm -f "$matrix_out"
  # Export the out path(s) so a test stub can honor them (the real agent reads them from the prompt).
  # `env` array so the optional SCOUT_MATRIX_OUT is a real assignment (a `${x:+VAR=v}` prefix would
  # expand to a word bash then tries to exec as the command name, not an assignment).
  local prod_env=(SCOUT_CANDIDATES_OUT="$cand_out")
  [ -n "$matrix_out" ] && prod_env+=(SCOUT_MATRIX_OUT="$matrix_out")
  env "${prod_env[@]}" "$CLAUDE" -p "$prompt" \
    --permission-mode bypassPermissions --model "$MODEL" --output-format json \
    >"${LOGDIR}/agent-${engine}.json" 2>&1 || log "engine ${engine}: agent exited non-zero — continuing"
  # CLAUDE.md: every `claude` invocation emits a span (#2390). The scout engine is carried in
  # template_id (`scout-<engine>-v1`), NOT in the span's `engine` field — that field names the CLI
  # (claude), so overloading it would make the six producer engines look like six different CLIs.
  # Digest hashes the raw `prompt=` string sent to claude (like every other call site), NOT the
  # archived prompt_file above — that file is written via `printf '%s\n' "$prompt"`, one trailing
  # byte larger than what was actually sent, which put the producer's digest on a different base
  # than pass2's and defeated the verbatim-re-send comparison for the pair most likely to match.
  agent_trace_span "${LOGDIR}/agent-${engine}.json" scout-producer model="$MODEL" \
    outcome="$(classify_model_result "${LOGDIR}/agent-${engine}.json")" \
    template="scout-${engine}-v1" prompt="$prompt"

  # ── COVERAGE MATRIX (req/journey) — regenerated every run, even with zero filed issues.
  if [ -n "$matrix_out" ]; then
    mkdir -p "$ARTIFACT_DIR"
    if [ -s "$matrix_out" ] && jq -e 'type=="array"' "$matrix_out" >/dev/null 2>&1; then
      cp "$matrix_out" "$artifact"
      log "engine ${engine}: coverage matrix → $(basename "$artifact") ($(jq 'length' "$matrix_out" 2>/dev/null || echo 0) row(s))"
    else
      echo '[]' > "$artifact"
      log "engine ${engine}: no matrix produced — wrote empty $(basename "$artifact")"
    fi
  fi

  # Robust read: prefer the file; if the model wrapped it, slice first{…last}.
  local cand_json=""
  if [ -s "$cand_out" ] && jq -e . "$cand_out" >/dev/null 2>&1; then
    cand_json="$(cat "$cand_out")"
  elif [ -s "$cand_out" ]; then
    cand_json="$(sed -n '0,/}/p' "$cand_out" 2>/dev/null)"; jq -e . <<<"$cand_json" >/dev/null 2>&1 || cand_json=""
  fi
  if [ -z "$cand_json" ]; then log "engine ${engine}: no parseable candidates — skipping"; return 0; fi

  local n_cand; n_cand="$(jq '.candidates | length' <<<"$cand_json" 2>/dev/null || echo 0)"
  log "engine ${engine}: ${n_cand} raw candidate(s)"
  [ "${n_cand:-0}" -eq 0 ] && return 0

  # ── CRITIC GATE — a DIFFERENT model refutes each candidate before we keep it ─────
  local critic_prompt
  critic_prompt="$(cat <<EOF
You are an adversarial reviewer. Below is a JSON list of proposed development items for the
SkillForge product. For EACH candidate, decide keep=true ONLY if ALL hold:
  • it is a REAL gap/defect (not already implemented — verify against the code if unsure),
  • the evidence is concrete and checkable (file:line, or a real screen/journey),
  • it is NOT an imagined requirement nobody asked for, and NOT stale-spec (doc wrong, code right),
  • it is worth a human's time (meaningful quality/UX value).
Default to keep=false when uncertain — a false issue wastes the owner's triage.

Candidates:
${cand_json}

Write ONLY a JSON object (no prose) to:
  ${verdict_out}
Schema: { "verdicts": [ { "fingerprint": "...", "keep": true|false, "reason": "short" } ] }
EOF
)"
  log "engine ${engine}: critic refutation (model ${CRITIC_MODEL})…"
  SCOUT_VERDICTS_OUT="$verdict_out" "$CLAUDE" -p "$critic_prompt" \
    --permission-mode bypassPermissions --model "$CRITIC_MODEL" --output-format json \
    >"${LOGDIR}/critic-${engine}.json" 2>&1 || log "engine ${engine}: critic exited non-zero — continuing"
  # CLAUDE.md: every `claude` invocation emits a span (#2390). The critic runs a DIFFERENT model
  # from the producer (FR-075), so costing it separately is what makes the two arms comparable.
  agent_trace_span "${LOGDIR}/critic-${engine}.json" scout-critic model="$CRITIC_MODEL" \
    outcome="$(classify_model_result "${LOGDIR}/critic-${engine}.json")" \
    template="scout-critic-v1" prompt="$critic_prompt"

  if [ ! -s "$verdict_out" ] || ! jq -e . "$verdict_out" >/dev/null 2>&1; then
    log "engine ${engine}: no critic verdict — refusing to file unrefuted candidates"; return 0
  fi

  # ── #5 DOUBLE-PASS for p0 — a second producer pass to confirm critical findings. ─
  local pass2_fps=""
  if jq -e '[.candidates[]? | select(.severity=="p0")] | length > 0' <<<"$cand_json" >/dev/null 2>&1; then
    local cand_out2="${LOGDIR}/cand-${engine}-pass2.json"; rm -f "$cand_out2"
    log "engine ${engine}: p0 present — second producer pass for confirmation…"
    local pass2_prompt="${prompt}

SECOND PASS: independently re-derive findings (different review order); we promote only p0s
that BOTH passes surface."
    SCOUT_CANDIDATES_OUT="$cand_out2" SCOUT_PASS=2 "$CLAUDE" -p "$pass2_prompt" \
      --permission-mode bypassPermissions --model "$MODEL" --output-format json \
      >"${LOGDIR}/agent-${engine}-pass2.json" 2>&1 || true
    # CLAUDE.md: every `claude` invocation emits a span (#2390). The p0 double-pass only fires when
    # a critical finding is present, so its cost is bursty — it needs its own line, not the
    # producer's. Digest hashes the ACTUAL pass-2 prompt (producer prompt + suffix) via `prompt=`,
    # NOT the producer's archived prompt_file — those differ, and hashing the producer's file made
    # every pass-2 span misread as a verbatim re-send of the producer turn.
    agent_trace_span "${LOGDIR}/agent-${engine}-pass2.json" scout-pass2 model="$MODEL" \
      outcome="$(classify_model_result "${LOGDIR}/agent-${engine}-pass2.json")" \
      template="scout-${engine}-pass2-v1" prompt="$pass2_prompt"
    if [ -s "$cand_out2" ] && jq -e . "$cand_out2" >/dev/null 2>&1; then
      pass2_fps="$(jq -r '.candidates[]?.fingerprint // empty' "$cand_out2" 2>/dev/null || true)"
    fi
  fi

  # ── Filter candidates: critic verdict → evidence re-verify → known-dup → accumulate.
  local i count; count="$(jq '.candidates | length' <<<"$cand_json")"
  for ((i=0; i<count; i++)); do
    local c fp eng sev conf ck cr
    c="$(jq -c ".candidates[$i]" <<<"$cand_json")"
    fp="$(jq -r '.fingerprint // empty' <<<"$c")"
    [ -z "$fp" ] && continue
    eng="$(jq -r '.engine // "bug"' <<<"$c")"
    sev="$(jq -r '.severity // "p2"' <<<"$c")"
    conf="$(jq -r '.confidence // "medium"' <<<"$c")"
    case "$eng" in bug|ux-customer|ux-business|req|journey|docs) ;; *) [ "$engine" = ux ] && eng="ux-customer" || eng="$engine" ;; esac
    case "$sev" in p0|p1|p2) ;; *) sev="p2" ;; esac
    ck="$(jq -r --arg fp "$fp" '.verdicts[]? | select(.fingerprint==$fp) | .keep' "$verdict_out" 2>/dev/null | head -1)"
    cr="$(jq -r --arg fp "$fp" '.verdicts[]? | select(.fingerprint==$fp) | .reason' "$verdict_out" 2>/dev/null | head -1)"

    if [ "$ck" != "true" ]; then
      log "  · drop ${fp} (critic refuted)"; audit "$fp" "$eng" "$sev" "$conf" "false" "${cr:-refuted}" "dropped-critic" ""; continue
    fi
    # #7 independent file:line re-verification (bug-style evidence only)
    if { [ "$eng" = "bug" ] || [ "$eng" = "security" ]; } && ! verify_evidence "$(jq -r '.evidence // ""' <<<"$c")"; then
      log "  · drop ${fp} (evidence-not-found)"; audit "$fp" "$eng" "$sev" "$conf" "true" "$cr" "evidence-not-found" "cited file:line absent in worktree"; continue
    fi
    if seen_fp "$fp"; then
      log "  · skip ${fp} (already filed — open or rejected)"; audit "$fp" "$eng" "$sev" "$conf" "true" "$cr" "skipped-dedup" ""; continue
    fi

    # #5 confirmation flag for p0s
    local p0c=""
    if [ "$sev" = "p0" ]; then
      if [ -n "$pass2_fps" ] && grep -qxF "$fp" <<<"$pass2_fps"; then p0c="true"; else p0c="false"; fi
    fi
    # normalise engine/severity + attach computed fields, then accumulate.
    jq -c --arg eng "$eng" --arg sev "$sev" --arg cr "$cr" --arg p0c "$p0c" --arg run "$engine" \
      '. + {engine:$eng, severity:$sev, _critic_reason:$cr, _run_engine:$run}
         + (if $p0c=="" then {} else {_p0_confirmed:($p0c=="true")} end)' <<<"$c" >> "$SURVFILE"
  done
}

# ── #3 + #9 RANK across the whole batch, then near-dup cluster, then FILE. ─────────
file_survivors() {
  [ -s "$SURVFILE" ] || { log "no survivors across engines — nothing to file"; return 0; }

  # #3 score = severity × confidence × business-impact; rank descending.
  local ranked; ranked="$(jq -s '
      def sw: {"p0":3,"p1":2,"p2":1}[.severity // "p2"] // 1;
      def cw: {"high":3,"medium":2,"low":1}[.confidence // "medium"] // 1;
      def iw: {"high":3,"medium":2,"low":1}[.business_impact // "medium"] // 1;
      map(. + {_score:(sw*cw*iw)})
      | sort_by(-._score, .fingerprint)
      | to_entries | map(.value + {_rank:(.key+1)})' "$SURVFILE")"

  local count; count="$(jq 'length' <<<"$ranked")"
  log "ranking ${count} survivor(s) across engines by impact×confidence…"

  # near-dup clustering state: token files of already-filed candidates.
  local -a kept_tok=()
  local i
  for ((i=0; i<count; i++)); do
    local c fp title eng sev conf p0c
    c="$(jq -c ".[$i]" <<<"$ranked")"
    fp="$(jq -r '.fingerprint' <<<"$c")"
    title="$(jq -r '.title // "untitled"' <<<"$c")"
    eng="$(jq -r '.engine // "bug"' <<<"$c")"
    sev="$(jq -r '.severity // "p2"' <<<"$c")"
    conf="$(jq -r '.confidence // "medium"' <<<"$c")"
    p0c="$(jq -r 'if has("_p0_confirmed") then (._p0_confirmed|tostring) else "" end' <<<"$c")"

    if [ "$filed_total" -ge "$MAX_ISSUES" ]; then
      log "  · over-cap ${fp} (global cap ${MAX_ISSUES} reached)"
      audit "$fp" "$eng" "$sev" "$conf" "true" "" "over-cap" ""; continue
    fi

    # #9 near-duplicate clustering — compare this title's tokens to everything filed so far.
    local tokf; tokf="$(mktemp)"; norm_tokens "$title $(jq -r '.evidence // ""' <<<"$c")" > "$tokf"
    local dup_of="" k
    for k in "${kept_tok[@]:-}"; do
      [ -n "$k" ] || continue
      local pct; pct="$(jaccard_pct "$tokf" "${k%%::*}")"
      if [ "$pct" -ge "$DUP_PCT" ]; then dup_of="${k##*::}"; break; fi
    done
    if [ -n "$dup_of" ]; then
      log "  · near-dup ${fp} (~merges into ${dup_of}) — not filed"
      audit "$fp" "$eng" "$sev" "$conf" "true" "" "near-duplicate" "of ${dup_of}"
      rm -f "$tokf"; continue
    fi

    # #11 regression origin for diff-scoped runs
    local regr; regr="$(regression_origin "$(jq -r '.evidence // ""' <<<"$c")")"
    [ -n "$regr" ] && c="$(jq -c --arg r "$regr" '. + {_regression:$r}' <<<"$c")"

    local body; body="$(compose_body "$c")"
    # #8 contract lint — never file a body missing its fingerprint or acceptance criterion.
    if ! lint_body "$body"; then
      log "  · ✗ CONTRACT VIOLATION ${fp} — composed body missing fingerprint/acceptance; NOT filed"
      audit "$fp" "$eng" "$sev" "$conf" "true" "" "contract-violation" "missing fp/acceptance"
      CONTRACT_FAIL=1; rm -f "$tokf"; continue
    fi
    printf '%s\n' "$body" > "${LOGDIR}/filed-${fp}.body.md"   # auditability + test surface

    # #4 speculative tier — low-confidence survivors are downgraded, not dropped.
    local review_label="$PROPOSED_LABEL" tier="proposed"
    if [ "$conf" = "low" ]; then review_label="$SPECULATIVE_LABEL"; tier="speculative"; fi
    # #5 a single-pass p0 gets an extra-review label.
    local extra_labels=()
    [ "$p0c" = "false" ] && extra_labels+=(--label single-pass)

    if [ "$DRY_RUN" = "1" ]; then
      log "  · DRY-RUN would file [#${fp} rank $(jq -r '._rank' <<<"$c") ${sev}/${eng}/${tier}] ${title}"
      audit "$fp" "$eng" "$sev" "$conf" "true" "" "dry-run" "tier=${tier}"
    else
      if "$GH" issue create --title "$title" --body "$body" \
            --label "$review_label" --label "$eng" --label "$sev" "${extra_labels[@]+"${extra_labels[@]}"}" >/dev/null 2>&1; then
        log "  · filed [rank $(jq -r '._rank' <<<"$c") ${sev}/${eng}/${tier}] ${title} (${fp})"
        audit "$fp" "$eng" "$sev" "$conf" "true" "" "filed" "tier=${tier}"
      else
        log "  · gh issue create FAILED for ${fp} — continuing"
        audit "$fp" "$eng" "$sev" "$conf" "true" "" "file-error" ""
        rm -f "$tokf"; continue
      fi
    fi
    existing_fps="${existing_fps}"$'\n'"${fp}"   # in-run dedup too
    kept_tok+=("${tokf}::${fp}")                 # remember tokens for near-dup checks
    filed_total=$((filed_total+1))
  done
}

for engine in $ENGINES; do
  case "$engine" in
    bug|ux|req|journey|docs|security) collect_engine "$engine" ;;
    *) log "unknown engine '${engine}' — skipping" ;;
  esac
done
file_survivors

log "scan complete — ${filed_total} issue(s) filed (cap ${MAX_ISSUES})."
if [ "$CONTRACT_FAIL" -eq 1 ]; then
  log "FAILED — at least one composed body violated the scout contract (missing fingerprint/acceptance)."
  exit 1
fi
exit 0
