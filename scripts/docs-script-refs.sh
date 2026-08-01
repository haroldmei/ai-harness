#!/usr/bin/env bash
# docs-script-refs.sh — assert the harness docs and the scripts tree agree with reality (#1984).
#
# CLAUDE.md is binding convention: every agent in the pipeline reads it and follows it verbatim.
# When commit 7d418560 ("revert: undo all agent script changes since Friday July 10") deleted
# scripts/lib/state-shard.sh and scripts/lib/agent-trace.sh, CLAUDE.md kept mandating both and six
# shipped scripts kept sourcing them — so `scripts/sget.sh`, `scripts/verify-loop.sh` and friends
# died at startup while the docs still advertised them as current. Nothing caught it, because no
# gate ever asked "does the file this doc names actually exist?".
#
# Eight checks, all pure bash + zero infra (so this gate can be REQUIRED at every tier):
#   1. doc-refs   — every scripts/… path cited in CLAUDE.md / docs/AGENT-HARNESS.md resolves.
#   2. syntax     — `bash -n` on every scripts/**/*.sh.
#   3. source-deps— no script sources a library that isn't on disk.
#   4. lib-tests  — the two mandated libraries' own hermetic suites actually pass.
#   5. pr-units   — every systemd unit named in docs/pr-review-fix-loop.md resolves under deploy/systemd/.
#   6. pr-knobs   — every env var the same doc presents in its live-knob table is grep-able in scripts/|deploy/.
#   7. fix-paths  — every FORBIDDEN_FIX_PATHS entry in scripts/release-train.sh resolves on disk (issue #2241).
#   8. risk-zones — every backticked path cited in CLAUDE.md's "Risk zones" section resolves on disk (issue #2241).
#
# Check 4 originally existed because nothing else ran them: `scripts/*.test.sh` were only
# *grepped* by wedge-coverage, so state-shard.test.sh and agent-trace.test.sh could rot unnoticed.
# The "wiring the other ~20 in is a separate, larger question" this comment used to defer is now
# answered — scripts/unit.sh runs EVERY scripts/*.test.sh, opt-out (issue #2387, C3).
#
# These three stay here anyway, deliberately. They cover the libraries CLAUDE.md names as binding
# convention, and this gate is `docs-refs`, which runs in the narrow gate set the reviewer and
# fixer use where `unit` sometimes does not. Duplicated execution of three hermetic ~3s suites is
# a cheap price for the mandated libraries never being unverified in any gate configuration.
#
# Checks 5 + 6 exist because docs/pr-review-fix-loop.md is the reviewer/fixer operator runbook and
# both its actionable facts drifted from reality (#2008): the unit names it told you to enable dropped
# the `skillforge-` prefix every installed unit actually carries, and it advertised PR_FIXER_RESUME /
# PR_FIXER_RESUME_CAP as live knobs in its config table long after 7d418560 reverted them (no code
# reads either — an operator setting them gets a silent no-op). Same disease as #1984: a doc naming a
# thing that does not exist, with no gate to notice. Both checks no-op when the doc is absent so the
# hermetic temp-repo suite stays green.
#
# Exit 0 = clean, 1 = at least one check failed. Verbose listing of every failure, because the
# whole point is that a human (or an agent) can act on the output without re-deriving it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

DOCS=(CLAUDE.md docs/AGENT-HARNESS.md)

# Paths a doc names in order to say they are DELIBERATELY ABSENT. docs/AGENT-HARNESS.md §"Out-of-scope
# ml-builder references that are intentionally not ported" cites scripts/deploy.sh precisely to record
# that SkillForge does NOT have it (it deploys via the Makefile). Flagging that would train readers to
# ignore the gate, so it is allowlisted here — with the reason — rather than silently regex-skipped.
ALLOW_MISSING=(
  "scripts/deploy.sh"           # AGENT-HARNESS.md §Scope: explicitly "not ported"; deploy is via Makefile
  "scripts/ml-quality-gates.sh" # same paragraph: not an ML project
  "scripts/agent-trace-report.sh" # §Session checkpointing: named to record that 7d418560 DELETED it
)

fails=0
note() { printf '  %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*"; fails=$((fails + 1)); }

is_allowed() {
  local p="$1" a
  for a in "${ALLOW_MISSING[@]}"; do [[ "$p" == "$a" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------- 1. doc refs
echo "docs-script-refs: [1/6] doc → script path references"
refs="$(grep -ohE '(backend/)?scripts/[A-Za-z0-9_./-]+\.(sh|py|mjs|js)' "${DOCS[@]}" 2>/dev/null | sort -u)"
n_refs=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  n_refs=$((n_refs + 1))
  if [[ -e "$p" ]]; then
    continue
  elif is_allowed "$p"; then
    note "· $p — absent by design (allowlisted)"
  else
    # A bare scripts/foo.py that only exists under backend/ is a real doc bug: the docs are read
    # from the repo root, so the path as written does not resolve for the reader.
    if [[ -e "backend/$p" ]]; then
      fail "$p — MISSING at repo root (exists as backend/$p; write the full path)"
    else
      fail "$p — referenced in the docs but does not exist"
    fi
  fi
done <<<"$refs"
note "checked $n_refs distinct script paths cited across ${DOCS[*]}"

# ------------------------------------------------------------------ 2. syntax
echo "docs-script-refs: [2/6] bash -n syntax across scripts/"
n_sh=0
while IFS= read -r f; do
  n_sh=$((n_sh + 1))
  err="$(bash -n "$f" 2>&1)" || fail "$f — syntax error: ${err}"
done < <(find scripts -type f -name '*.sh' | sort)
note "parsed $n_sh shell scripts"

# ------------------------------------------------------------- 3. source deps
echo "docs-script-refs: [3/6] sourced libraries exist"
n_src=0 n_unresolved=0
while IFS= read -r f; do
  d="$(dirname "$f")"
  while IFS= read -r raw; do
    [[ -z "$raw" ]] && continue
    # Strip the `source `/`. ` keyword and surrounding quotes, then resolve the two expansions the
    # tree actually uses. Anything still containing `$` is reported as unresolved rather than
    # guessed at — a wrong guess here would be a false FAIL on a green tree.
    arg="${raw#*source }"; arg="${arg#*. }"
    arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
    arg="$(printf '%s' "$arg" \
      | sed -e "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|$d|g" \
            -e "s|\${ROOT}|$ROOT|g" \
            -e "s|\$ROOT|$ROOT|g")"
    if [[ "$arg" == *'$'* ]]; then
      n_unresolved=$((n_unresolved + 1))
      note "· $f — sourced path is dynamic, not statically checkable: $arg"
      continue
    fi
    n_src=$((n_src + 1))
    [[ -e "$arg" ]] || fail "$f sources a missing library: $arg"
  done < <(grep -hE '^[[:space:]]*(source|\.)[[:space:]]+' "$f" 2>/dev/null)
done < <(find scripts -type f -name '*.sh' | sort)
note "resolved $n_src source paths ($n_unresolved dynamic, skipped)"

# --------------------------------------------------------------- 4. lib tests
echo "docs-script-refs: [4/6] hermetic suites for the mandated libraries"
# NB: docs-script-refs.test.sh runs THIS script against throwaway temp repos. That recursion is
# bounded — the temp repos get stub .test.sh files, so the inner run never re-enters this loop.
for t in scripts/state-shard.test.sh scripts/agent-trace.test.sh scripts/docs-script-refs.test.sh; do
  if [[ ! -f "$t" ]]; then
    fail "$t — missing (CLAUDE.md mandates the library it covers)"
    continue
  fi
  if out="$(bash "$t" 2>&1)"; then
    note "· $(basename "$t") — $(printf '%s' "$out" | tail -n1)"
  else
    fail "$t — FAILED:"
    printf '%s\n' "$out" | grep -E '✗' | sed 's/^/      /'
  fi
done

# --------------------------------------------------------- 5. pr-loop unit names
# The reviewer/fixer runbook tells an operator which systemd units to enable. Every installed unit
# carries a `skillforge-` prefix (deploy/systemd/), so a bare `agent-pr-reviewer.timer` in the doc is
# a name that resolves to nothing — `systemctl status` on it errors. Extract every unit token from the
# doc (expanding the `NAME.{service,timer}` brace shorthand first) and require each to exist on disk.
PRDOC="docs/pr-review-fix-loop.md"
echo "docs-script-refs: [5/8] systemd unit names in $PRDOC resolve under deploy/systemd/"
if [[ -f "$PRDOC" ]]; then
  n_units=0
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    n_units=$((n_units + 1))
    [[ -e "deploy/systemd/$u" ]] \
      || fail "$PRDOC names systemd unit '$u' — no deploy/systemd/$u (every unit carries the skillforge- prefix)"
  done < <(sed -E 's/([A-Za-z0-9_-]+)\.\{service,timer\}/\1.service \1.timer/g' "$PRDOC" \
           | grep -ohE '[A-Za-z0-9_-]+\.(service|timer)' | sort -u)
  note "checked $n_units distinct unit names"
else
  note "· $PRDOC absent — skipping unit-name check"
fi

# --------------------------------------------------------- 6. pr-loop live knobs
# The doc's config table presents env vars as live tuning knobs. PR_FIXER_RESUME/_CAP sat in that
# table for weeks after 7d418560 reverted the code that read them — an operator setting one got a
# silent no-op. Only the vars fenced by the `pr-loop-knobs` markers are checked (the section is the
# doc's own declaration of "these are live"); reverted vars documented elsewhere as such are exempt.
echo "docs-script-refs: [6/8] live-knob env vars in $PRDOC are grep-able in scripts/ or deploy/"
if [[ -f "$PRDOC" ]]; then
  block="$(sed -n '/pr-loop-knobs:start/,/pr-loop-knobs:end/p' "$PRDOC")"
  if [[ -z "$block" ]]; then
    note "· no pr-loop-knobs marker block found — skipping (nothing declared as a live knob)"
  else
    n_knobs=0
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      n_knobs=$((n_knobs + 1))
      # Exclude THIS gate + its test: they name reverted vars (e.g. PR_FIXER_RESUME) in explanatory
      # prose, and a doc-gate describing a knob is not code that reads it — counting them would let a
      # re-added phantom knob pass on the strength of this file's own comment.
      grep -rqE "\\b${k}\\b" scripts/ deploy/ \
        --exclude=docs-script-refs.sh --exclude=docs-script-refs.test.sh 2>/dev/null \
        || fail "$PRDOC lists env knob '$k' as live but it is grep-unfindable in scripts/ or deploy/ (reverted / never shipped?)"
    done < <(printf '%s\n' "$block" | grep -ohE 'PR_[A-Z0-9_]+' | sort -u)
    note "checked $n_knobs live env knobs"
  fi
else
  note "· $PRDOC absent — skipping live-knob check"
fi

# ------------------------------------------------------------- 7. fix-paths
echo "docs-script-refs: [7/8] FORBIDDEN_FIX_PATHS in scripts/release-train.sh resolve on disk"
RT_SCRIPT="scripts/release-train.sh"
n_fp=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  n_fp=$((n_fp + 1))
  if [[ -e "$p" ]]; then
    continue
  elif is_allowed "$p"; then
    note "· $p — absent by design (allowlisted)"
  else
    fail "$p — FORBIDDEN_FIX_PATHS entry in $RT_SCRIPT does not exist on disk"
  fi
done < <(sed -n '/^FORBIDDEN_FIX_PATHS=(/,/^)/p' "$RT_SCRIPT" \
         | grep -oE 'backend/[A-Za-z0-9_./-]+')
note "checked $n_fp FORBIDDEN_FIX_PATHS entries"

# ----------------------------------------------------------- 8. risk-zones
echo "docs-script-refs: [8/8] CLAUDE.md risk-zone paths resolve on disk"
CM="CLAUDE.md"
n_rz=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  n_rz=$((n_rz + 1))
  if [[ -e "$p" ]]; then
    continue
  elif is_allowed "$p"; then
    note "· $p — absent by design (allowlisted)"
  else
    fail "$p — risk-zone path in $CM does not exist on disk"
  fi
done < <(sed -n '/^## Risk zones/,/^## /p' "$CM" \
         | grep -oE '`[^`]+`' | tr -d '`' \
         | grep -oE 'backend/[A-Za-z0-9_./-]+' | sort -u)
note "checked $n_rz risk-zone paths"

# ---------------------------------------------------------------------- verdict
echo
if ((fails > 0)); then
  echo "docs-script-refs: FAIL — $fails problem(s)"
  exit 1
fi
echo "docs-script-refs: PASS"
