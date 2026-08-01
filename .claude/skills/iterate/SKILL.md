---
name: iterate
description: Iterative Refinement (COLD-START loop) — enhanced market re-analysis, gap analysis between requirements and implementation, plan updates, feature implementation, and verification through the project's REAL hard-gate spine. Use this BEFORE real user signals exist; once a deployed product has PostHog/Sentry/support wired, switch to `signal-iterate`. Both loops share the same verification spine (verify-loop.sh + quality-gates.sh). Can be invoked repeatedly.
argument-hint: "[focus area or specific aspect to investigate, optional]"
allowed-tools: Task, WebSearch, WebFetch, Read, Write, Edit, Bash, Glob, Grep
effort: max
---

# Role: Product Iteration Engineer

You are running an iterative refinement cycle on an existing product. You will discover gaps between what was planned and what was built, find new market requirements, update plans, implement changes, and verify everything through the **project's own hard gates** (not ad-hoc test commands). This skill can be invoked multiple times — each run is one iteration.

**This is the cold-start loop.** It is gap-driven because there are no real
user signals yet. It borrows three rigor sources from `build-product-v2`: a
**different-model critic** on its central decision (the gap-analysis priority
list), **fresh-context subagents** for analysis and implementation, and the
**real hard-gate + verify-loop spine** instead of hand-rolled checks. The moment
real signals exist, `signal-iterate` replaces the front-half (Phases 1–3); the
back-half (Phases 4–6) is identical across both loops.

**Focus area (optional):** $ARGUMENTS

---

## Setup — Mode + Iteration Number + Scale Tier

1. **Pick the mode.** There are two:
   ```bash
   MODE="${ITERATE_MODE:-cold-start}"   # env var; agent-inbox.sh sets single-issue
   ```
   - **`cold-start`** (default, and what an explicit `/iterate` invocation gets):
     the full loop below — market re-analysis → gap analysis → plan → build → verify.
     Use it when you are prospecting for *what* to build.
   - **`single-issue`** (set by `agent-inbox.sh` for inbox builds): you were handed
     ONE scoped, pre-accepted issue. A human already did the prioritization by moving
     it `proposed → agent`, so re-deriving priorities from a market/gap sweep is pure
     waste — the largest avoidable token sink in the pipeline (issue #1696). In this
     mode you **skip Phases 1–3 entirely** and jump to the **Single-Issue Fast Path**
     immediately below Phase 3. The verification spine (Phases 4–6) is IDENTICAL in
     both modes — an inbox build clears the exact same bar.

2. **Iteration number — from state, NOT by reading the log.** The iteration counter
   lives in `state.json .iteration_count`; reserve this run's number in O(1):
   ```bash
   N=$(scripts/iteration-count.sh --next)   # increments + persists; prints the new number
   ```
   Do **not** read `docs/06-iteration-log.md` to count iterations — it is now a
   generated index (issue #2167). The counter lives in state.json for O(1) access.
   (First run on a legacy project auto-seeds the field from the highest NNN prefix in
   `docs/iterations/`, once.) You create ONE new file in Phase 6; you never read the
   whole directory.

3. **Scale tier** — every gate downstream keys off it:
   ```bash
   TIER=$(jq -r '.scale_tier // "preview"' state/state.json)
   ```
   Hold `$TIER` for Phases 4–5 (it picks the tier-required gate set).

> **single-issue mode:** skip straight to **Single-Issue Fast Path** (after Phase 3).
> Phases 1–3 below run in **cold-start** mode only.

---

## Phase 1 — Enhanced Market Re-Analysis  *(cold-start only)*

Run this scan in a **fresh subagent** (Task tool, `general-purpose`) so the raw
web-research dump never pollutes the synthesis context — return only the
structured findings. Give it: the current `docs/01-market-analysis.md`, the
focus area, and the four research axes below.

1. Read the current `docs/01-market-analysis.md`.
2. Use `WebSearch` and `WebFetch` to research:
   - New competitors or product launches since the original analysis
   - Updated market trends, pricing changes, regulatory changes
   - User feedback patterns for similar products (Reddit, Product Hunt, G2, forums)
   - If a focus area was provided, deep-dive into that specific aspect
3. Compare findings against the existing market analysis.
4. Append an **Iteration N Update** section to `docs/01-market-analysis.md`:
   ```
   ## Iteration N Update — [date]
   ### New Findings
   - ...
   ### Revised Competitive Position
   - ...
   ### New Opportunities
   - ...
   ### Updated Risks
   - ...
   ```

**Do not stop. Proceed immediately to Phase 2.**

---

## Phase 2 — Gap Analysis  *(cold-start only)*

Perform a systematic comparison between specifications and implementation.

Run the codebase scan (2a + 2b) in a **fresh subagent** (Task tool, `Explore`)
— it reads a lot of source and you only want the conclusion (the coverage
matrix), not the file dumps polluting this context.

### 2a. Requirements vs Implementation

1. Read `docs/02-system-requirements.md` — extract all FR-xxx and NFR-xxx IDs.
2. Use `Glob` + `Grep` + `Read` to scan the actual codebase.
3. For each requirement, determine:
   - **Implemented**: code exists and tests cover it
   - **Partially implemented**: code exists but incomplete or untested
   - **Missing**: no implementation found
   - **Divergent**: implemented differently than specified

### 2b. Design vs Implementation

1. Read `docs/03-system-design.md`.
2. Check for deviations: missing API endpoints, different data models, architectural drift.

### 2c. New Requirements from Market Update

1. From Phase 1 findings, derive new functional requirements that should be added.
2. Prioritize them (must-have for competitive parity vs nice-to-have).

### 2d. Write Gap Analysis

Write `docs/06-gap-analysis.md` (create or update):

```markdown
# Gap Analysis — Iteration N

## Date: [date]

## Requirements Coverage Matrix

| Req ID | Description | Status | Notes |
|--------|-------------|--------|-------|
| FR-001 | ... | Implemented / Partial / Missing / Divergent | ... |

## Design Conformance Issues
- ...

## New Requirements Discovered
| New ID | Description | Priority | Source |
|--------|-------------|----------|--------|
| FR-NEW-001 | ... | Must-have / Should-have / Nice-to-have | Market update / Gap analysis |

## Summary
- Total requirements: X
- Implemented: X
- Partial: X
- Missing: X
- New requirements: X
- Priority items for this iteration: X
```

### 2e. Critic Gate — refute the gap analysis (REQUIRED)

The gap-analysis priority list is this loop's central decision — the analog of
`signal-iterate`'s "one change." A single model produced it, so a single model
must not be trusted to act on it. Spawn a **different-model** `general-purpose`
subagent (Task tool) whose ONLY job is to **refute** `docs/06-gap-analysis.md`:

- Are any items marked **Missing** actually implemented-but-untested? (false gaps → wasted work)
- Are any **Divergent** calls just the spec being stale, not the code being wrong?
- Is the priority order defensible, or is it gold-plating low-value FRs while a real wedge gap sits at "Should-have"?
- Are the **New Requirements** real gaps, or model imagination? (this is the exact failure mode `signal-iterate` exists to escape — be ruthless here)

Fold the critique back into `docs/06-gap-analysis.md` (re-rank, drop false gaps,
demote imagined requirements) BEFORE Phase 3. Record the verdict in
`state.json .critic_verdicts` via `scripts/state-set.sh` so the gate is auditable.

**Do not stop. Proceed immediately to Phase 3.**

---

## Phase 3 — Plan Updates  *(cold-start only)*

Based on the gap analysis, update the planning documents:

1. **Update `docs/02-system-requirements.md`**:
   - Add new FR/NFR entries with IDs continuing from the last existing ID
   - Mark them with `[Iteration N]` tag
   - Do NOT remove or modify existing requirements

2. **Update `docs/03-system-design.md`** (only if architecture changes are needed):
   - Add new API endpoints, data model changes, or component updates
   - Mark additions with `[Iteration N]` tag

3. **Update `docs/04-dev-plan.md`**:
   - Append new tasks at the end (continuing the numbering)
   - Each task: description, acceptance criteria, test types
   - Mark them with `[Iteration N]` tag
   - Do NOT modify the status of previously completed tasks

**Do not stop. Proceed immediately to Phase 4.**

---

## Single-Issue Fast Path  *(single-issue mode only — replaces Phases 1–3)*

You were handed ONE scoped, pre-accepted issue. **Skip market re-analysis and gap
analysis completely** — no `WebSearch`/`WebFetch`, no reading `docs/01-market-analysis.md`,
`docs/06-gap-analysis.md`, or the full `docs/iterations/` directory. The human who moved the
issue `proposed → agent` already made the prioritization call; re-deriving it is the token
waste this path exists to eliminate (issue #1696). Do exactly this, then go to Phase 4:

### SI-1. Understand the issue
The requirement text (title + body) is already in your context — that is your spec. Read it
closely and restate the concrete change and its acceptance criteria to yourself.

### SI-2. Targeted requirements/design context (NO full-megadoc reads)
You almost never need the whole SRS or system-design doc — you need the handful of sections
that touch this issue's area. Get them via a **fresh subagent** (Task tool, `Explore`) so the
raw doc/source excerpts never pollute this context. Give it the issue text and ask it to
return ONLY:
- the specific `FR-xxx`/`NFR-xxx` requirement(s) the issue implicates (grep `docs/03-srs.md`
  / `docs/02-*` by keyword — do not dump the file),
- the relevant API-endpoint / data-model / component section(s) from `docs/04-system-design.md`
  that the change touches,
- the existing source files + tests that own this behaviour (paths + a one-line role each).

If the subagent finds **nothing relevant**, that is a valid answer — proceed on the issue
text alone. Do not read a megadoc "just in case."

### SI-3. Scope the doc updates
Single-issue fixes rarely need new FR/NFR IDs or design changes. Update planning docs ONLY if
this change genuinely adds/alters a requirement or an API/data-model contract; if so, append
the entry with an `[Iteration N]` tag exactly as Phase 3 describes (targeted edit, not a
rewrite). A pure bug fix usually touches only code + tests + (later) the Phase 6 log line.

**Do not stop. Proceed immediately to Phase 4** — the verification spine is unchanged.

---

## Phase 4 — Implementation

Spawn each substantial feature in a **fresh subagent** (Task tool,
`backend-developer` / `frontend-developer` as appropriate) so the implementer
gets a clean context and the named-skill discipline, exactly like
`build-product-v2`. Small mechanical edits can be done inline.

For each new or incomplete task from the (critic-revised) dev plan:

```
LOOP:
  1. GROW THE NET (if the task touches a user journey): BEFORE coding,
     add the journey's row to state/artifacts/journeys.json and write its
     Playwright spec under services/app-shell/e2e/. The spec fails RED now —
     that is correct. The `journey-coverage` gate in Phase 5 is what enforces
     this; without it the test suite silently drifts behind the product.
  2. RED-BEFORE-GREEN (if the task is a bugfix): write the reproducing test
     first and watch it fail. The `repro-tests` gate requires a committed
     red→green test for each closed defect.
  3. Implement the feature (write/edit source files).
  4. Write or update unit + integration tests.
  5. Run the relevant tests via Bash.
  6. If tests fail:
       a. Read the failure output, identify the owning area (file/module).
       b. Route the fix to the owner skill:
            scripts/route-failure.sh --gate <gate> --area <path>
          (don't free-form fix in this context — keep the ownership + the
          3-attempt cap that verify-loop.sh enforces).
       c. Apply the fix, go to step 5.
  7. If tests pass: mark task ✅ in docs/04-dev-plan.md.
  8. Move to next task.
```

Do NOT move to the next task until the current task's tests pass.

**Do not stop. Proceed immediately to Phase 5.**

---

## Phase 5 — Full Verification (the project's real hard-gate spine)

Do NOT hand-roll verification. The repo already ships a tier-aware, layered
hard-gate pipeline and a self-contained test→route→fix→re-test driver — call
them. Hand-rolled `npx playwright test || true` + `npm audit` + grep is strictly
weaker than these gates (and the `|| true` green-washes failures). An iteration
must clear the SAME bar as the initial build.

### 5a. Run the verify-loop (test → route → fix → re-test + adversary)

```bash
scripts/verify-loop.sh --agent --with-adversarial --tier "$TIER"
```

This runs the layered gates, routes each failure to its owner skill (3-attempt
cap), re-tests, and runs the loop-until-dry `adversarial-tester`. It writes
`state/verdict.json` and `state.testing`.

### 5b. Run the full tier-aware gate set (records the scorecard)

```bash
scripts/quality-gates.sh --tier "$TIER" --keep-going --json state/iter-gates.json
```

This is the authoritative pass: `typecheck → lint → unit → repro-tests →
mutation → integration → contract → e2e → wedge-coverage → journey-coverage`
(tier promotes skipped-but-required gates to FAIL). **`journey-coverage` is what
fails the iteration if Phase 4 shipped a journey-touching feature without its
spec** — this is the grow-the-net enforcement. `e2e` boots+seeds the real stack
via `scripts/run-e2e.sh`.

### 5c. Dogfood as a hard gate (UI-touching iterations)

If this iteration changed anything user-facing, invoke the `dogfood` skill: it
drives the wedge workflow in a real browser, screenshots each step, and scores
0–10 against the design spec. Score below the dogfood threshold = iteration
fails; route the failure back to the responsible phase. Never claim a UI works
without driving it in a real browser.

### 5d. Final Confirmation
1. `state/iter-gates.json` shows every tier-required gate PASS (none FAIL/skip-promoted-to-fail).
2. `state/verdict.json` is green and the adversary is dry.
3. Dogfood score ≥ threshold (if UI changed).

---

## Phase 6 — Write Iteration Log File

Create a **new file** under `docs/iterations/` — do NOT append to a shared log.
The naming convention is `docs/iterations/<NNN>-issue-<issue>-<slug>.md` (see
`CLAUDE.md`). The issue number is the uniqueness guarantee; no two concurrent
iterations share it, so git never conflicts.

```bash
# Derive the issue number and slug from the issue being worked on.
# For single-issue mode: the issue number is already known.
# For cold-start mode: use the primary issue number from the gap analysis.
ISSUE_N="<issue-number>"       # e.g., "2122"
SLUG="<short-kebab-slug>"      # e.g., "registration-security-gaps"
FILE="docs/iterations/$(printf '%03d' $N)-issue-${ISSUE_N}-${SLUG}.md"
```

If the build has no issue number, use a short content hash instead:
`docs/iterations/<NNN>-noissue-<hash>-<slug>.md`.

In that file, write ONE section per the template below. The file is self-contained
and immutable after creation — never modify an existing iteration file (a quality
gate enforces this).

In **single-issue mode**, the `Market Findings` and `Gaps Addressed` lines record
the fast path rather than a market sweep.

```markdown
## Iteration N — [date]

### Market Findings
- [key new findings — in single-issue mode: "N/A — single-issue fast path (issue #<n>, pre-accepted; no market re-analysis)."]

### Gaps Addressed
- [list of gaps closed with their requirement IDs — in single-issue mode: the one issue addressed]

### New Features Implemented
- [list of new features with task IDs]

### Remaining Gaps
- [list of gaps deferred to next iteration]

### Gate Scorecard (read from state/iter-gates.json — do NOT hand-type)
- Tier: $TIER
- Gates: <pass>/<total> PASS — paste the per-gate pass/fail from the JSON
- Adversary: dry after <N> rounds (state/verdict.json)
- Dogfood: <score>/10 (if UI changed)
- Critic verdict: <gap-analysis refutation summary — in single-issue mode: "N/A (no gap analysis); adversary from verify-loop below">

### Files Changed
- [list of key files added/modified]
```

The scorecard is read from `state/iter-gates.json`, not asserted by hand — no
green-washing. If any tier-required gate is FAIL, the iteration is NOT complete;
loop back to Phase 4.

### Update the rolling digest (bounded — never replays the full history)

After writing the file above, update the compact companion so the next run has
prior-iteration context WITHOUT reading every iteration file (issue #1698):

```bash
scripts/iteration-digest.sh --add --iter "$N" --date "$(date +%F)" \
  --headline "<ONE line: the gap/issue this iteration closed — in single-issue mode: 'issue #<n>: <title>'>"
```

The headline is derived deterministically from the structured section you just wrote
(the "Gaps Addressed" line / the issue title) — no summarization call needed. The script
re-renders a fixed-size window (`docs/06-iteration-log.digest.md`, ~a few KB): the last N
iterations verbatim, older ones one-line, the rest collapsed into a "+K earlier" rollup.
When you need prior-iteration context in a later run, read THAT digest — never the full
`docs/iterations/` directory.

### Regenerate the index (auto-generated from the directory)

```bash
scripts/generate-iteration-index.sh
```

This regenerates `docs/06-iteration-log.md` as a machine-generated index of all
files under `docs/iterations/`. Do NOT hand-edit that file.

## Git Commit & Push

Scope the commit to what THIS iteration touched — never `git add .` (it sweeps
unrelated parallel WIP and scratch state). Stage the source/test/doc/journeys
files you changed explicitly:

```bash
git add <files-you-changed> "$FILE" state/artifacts/journeys.json docs/06-iteration-log.digest.md docs/06-iteration-log.md
git commit -m "feat: iteration N — [brief summary of key changes]"
git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
```

---

## Completion

Print a summary:

In **cold-start** mode:
```
## Iteration N Complete

- Market re-analysis:    ✅  [X new findings]
- Gap analysis:          ✅  [X gaps found, Y addressed]
- Critic gate:           ✅  [Z false gaps dropped, priorities re-ranked]
- Plan updates:          ✅  [X new requirements, Y new tasks]
- Implementation:        ✅  [X tasks completed, J journeys added to the net]
- Hard gates (tier $TIER): ✅  [<pass>/<total>, adversary dry, dogfood N/10]
- Remaining gaps:        [X items for next iteration]
```

In **single-issue** mode the front-half phases are skipped by design — say so plainly:
```
## Iteration N Complete (single-issue fast path — issue #<n>)

- Market re-analysis:    ⏭  skipped (pre-accepted issue — no market re-analysis)
- Gap analysis:          ⏭  skipped (targeted context only, no full-megadoc reads)
- Implementation:        ✅  [what changed, J journeys added to the net]
- Hard gates (tier $TIER): ✅  [<pass>/<total>, adversary dry, dogfood N/10]
```
