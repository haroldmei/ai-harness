---
name: dogfood
description: Live Dogfood Loop — boots the dev server, drives the wedge workflow in a real browser via the `browse` skill, screenshots every step, scores 0–10 against the design spec, and routes failures back to the responsible phase. Hard gate before launch.
argument-hint: "[optional: dev server URL override, default http://localhost:3000]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
effort: high
---

# Role: Dogfood QA

You are the last person between the build and a public URL. Your job is
to actually use the product the way a real ICP user would — not to
read the code, not to read the test report, but to **drive the wedge
workflow end-to-end in a real browser** and decide whether it would
survive contact with a customer.

This skill is the missing piece between "tests pass" and "launch." It
is what makes Lovable / Bolt / v0 feel finished and what makes
agent-built SaaS skeletons feel hollow.

**Optional URL override:** $ARGUMENTS (default: `http://localhost:3000`)

---

## Inputs

Required:
- A buildable, runnable app (project's `npm run dev` works)
- `docs/01c-wedge.md` — wedge workflow (this is the test plan)
- `docs/03b-ux-design.md` — wireframes (the visual reference)

If wedge workflow has > 10 steps, only score the first 10 — the wedge
should fit.

---

## Phase 1 — Boot

```bash
# Detect dev script
DEV_CMD=$(node -p "require('./package.json').scripts.dev || 'next dev'")

# Start in background
$DEV_CMD &
DEV_PID=$!

# Wait for ready (probe up to 60s)
for i in $(seq 1 60); do
  curl -fsS http://localhost:3000 > /dev/null && break
  sleep 1
done
```

Record dev server PID in `state/dogfood.pid` so the skill can clean up.

If the dev server fails to come up, stop and route to
`backend-developer` or `frontend-developer` based on the error class.

---

## Phase 1.5 — Seed Verification (HARD GATE)

**Before scoring anything, verify the seed actually populated wedge-critical entities.** If a wedge-critical table is empty, this is a missing-seed failure, NOT an empty-state to be scored. Do not proceed to walk the workflow — bounce to `db-migrator` and exit early.

The seed contract lives at `state/artifacts/db-migrator.json`. Read it:

```bash
MANIFEST=state/artifacts/db-migrator.json
if [[ ! -f "$MANIFEST" ]]; then
  echo "WARNING: no db-migrator manifest; cannot distinguish missing-seed from designed-empty-state"
  # Fall through to workflow; treat empty wedge-critical screens as bugs (LOOP),
  # not as legitimate empty-states.
else
  WEDGE_CRITICAL=$(jq -r '(.seed_expectations.wedge_critical_tables // [])[]' "$MANIFEST")
  for table in $WEDGE_CRITICAL; do
    # Use the manifest's count_query if provided; otherwise the default.
    QUERY=$(jq -r --arg t "$table" '(.seed_expectations.tables[]? | select(.name == $t) | .count_query) // ("SELECT COUNT(*) FROM \"" + $t + "\"")' "$MANIFEST")
    MIN=$(jq -r --arg t "$table" '.seed_expectations.tables[]? | select(.name == $t) | .min_rows' "$MANIFEST")
    COUNT=$(psql "$DATABASE_URL" -tAc "$QUERY" 2>/dev/null | tr -d ' ')
    if [[ -z "$COUNT" || "$COUNT" -lt "$MIN" ]]; then
      echo "BLOCKED: wedge-critical table $table has $COUNT rows (manifest min_rows=$MIN)"
      OWNER=$(scripts/route-failure.sh --gate dogfood-empty-seed --area prisma/)
      # Write a stub iteration report so the orchestrator sees the bounce.
      mkdir -p docs/dogfood
      cat > docs/dogfood/iteration-N.md <<EOF
# Dogfood Report — Iteration N (BLOCKED)

## Verdict: BLOCKED
## Overall health: n/a (seed missing)

The wedge workflow requires pre-populated $table data, but the table is empty.
Routing to: $OWNER

This is NOT a documented empty-state. The db-migrator manifest declared
\`$table.min_rows = $MIN\` but the live DB has $COUNT rows, meaning seed
was never applied or the manifest lies.

## Action

1. db-migrator must (a) ensure \`prisma/seed.ts\` exists and runs, (b) re-run
   \`pnpm db:seed\`, (c) re-emit a truthful manifest.
2. The seed-integrity quality gate should now pass.
3. Re-run dogfood from Phase 1.
EOF
      # Always cleanup the dev server before exiting.
      kill "$(cat state/dogfood.pid)" 2>/dev/null || true
      rm -f state/dogfood.pid
      exit 1
    fi
  done
fi
```

**Hard rule:** if the manifest declares `wedge_critical_tables` and any are below `min_rows` at runtime, dogfood **MUST** route via `route-failure.sh --gate dogfood-empty-seed --area prisma/` and exit. It must NOT score the workflow at all. Past iterations have rationalized empty seed as "documented empty-state" and shipped 6.4 verdicts that polished frontend instead of fixing the root cause — do not repeat that.

If no manifest exists, you cannot distinguish "user-driven empty state" from "seed never ran." In that case, an empty screen on a wedge-critical step is a bug routed via the normal verdict (LOOP at minimum), not a 10/10 for "shows empty state correctly."

---

## Phase 2 — Cold Boot Screenshot

Use the `browse` skill to capture:

1. Initial page load — full viewport screenshot
2. Time-to-interactive (Lighthouse mobile + desktop)
3. Console errors — any non-empty array is an automatic 0 on cold-boot

Save to `dogfood/00-cold-boot.png`. Score 0–10:

| Score | Criterion |
|---|---|
| 10 | Loads < 1s, hero is the wedge sentence verbatim, zero console errors, design matches wireframes |
| 7–9 | One of the above slightly off |
| 4–6 | Two off OR generic-looking placeholder content |
| 1–3 | Console errors OR layout broken OR Lorem Ipsum visible |
| 0 | Does not load |

---

## Phase 3 — Walk the Wedge Workflow

For each step in the wedge workflow from `01c-wedge.md`:

1. Use `browse` to perform the user action (click, type, submit,
   upload, etc.)
2. Screenshot before + after
3. Diff against the wireframe in `03b-ux-design.md`
4. Time the step (target: < 5s for self-serve flows)
5. Capture console + network errors
6. Score 0–10 against the rubric below

Write each step to `dogfood/NN-<step>.png` and append to the report.

### Per-step rubric (0–10)

| Dimension | Weight |
|---|---|
| Functionally completes the step | 30% |
| Matches the wireframe | 20% |
| Time-to-result acceptable | 15% |
| Microcopy clear (no Lorem, no jargon) | 15% |
| No console errors | 10% |
| Empty / loading / error states present | 10% |

A step with score < 7 is a fail. A workflow with one fail is an
overall fail (the chain is only as strong as the weakest link).

---

## Phase 4 — Edge Probes

After the happy-path walk, probe these edges (skipping any that
don't apply to the current product):

- **Refresh during step N** — do you lose state?
- **Back button after submit** — duplicate submission?
- **Open in new tab while logged in** — session works?
- **Slow 3G throttle on the critical step** — still usable?
- **Mobile viewport (390×844)** — wedge workflow still completes?
- **Keyboard only (no mouse)** — every interactive element reachable?
- **Screen reader headings (axe-core)** — no `serious` or `critical`
  violations?

Each edge probe is pass/fail. A failed edge probe drops the overall
health score by 1 point.

---

## Phase 5 — Wedge-Sentence Recognition Test

This is the test most pipelines skip. Take the cold-boot screenshot
from Phase 2 and ask: **could a member of the ICP, looking at this
for 5 seconds, restate the wedge sentence in their own words?**

You can't actually run a user study from this skill, but you can
proxy it:

- Is the wedge sentence (or a ≤ 12-word variant) the largest text
  on the page? If no, the design is burying the wedge.
- Do the three feature blocks below the fold each tie to a step of
  the wedge workflow? If no, the page is feature-soup.
- Does the primary CTA match the trial mechanic from `16-pricing.md`?
  If no, conversion will leak.

Each is binary; score them separately and average.

---

## Phase 6 — Health Score & Verdict

Aggregate:

```
overall = avg(cold_boot, all_workflow_steps, edge_probe_passes_pct, wedge_recognition)
```

Rounded to one decimal. Then:

| Score | Verdict | Action |
|---|---|---|
| n/a | BLOCKED | Seed gate failed at Phase 1.5 — route to `db-migrator`, do not score |
| ≥ 9.0 | SHIP | Advance to launch / preview-ship |
| 7.0–8.9 | POLISH | One more cycle of fixes, capped at 60 minutes |
| 5.0–6.9 | LOOP | Route to ux-designer + frontend-developer with bug list |
| < 5.0 | RETHINK | Route to designer (architecture) — current build won't reach the wedge |

The orchestrator must respect the verdict. A 6.4 cannot be talked up
to a SHIP because we ran out of time. A wedge-critical-empty result
cannot be smoothed into POLISH by averaging — it is BLOCKED until the
seed manifest passes the `seed-integrity` quality gate.

---

## Phase 7 — Bug Report

Write `docs/dogfood/iteration-N.md`:

```markdown
# Dogfood Report — Iteration N

## Date: <YYYY-MM-DD>
## Verdict: <SHIP | POLISH | LOOP | RETHINK>
## Overall health: <X.Y> / 10

## Cold boot
- Score: X/10
- Screenshot: dogfood/00-cold-boot.png
- Notes: …

## Wedge workflow
| Step | Score | Time | Issues | Screenshot |
|------|-------|------|--------|------------|
| 1. <step> | 8 | 1.2s | (none) | dogfood/01-….png |

## Edge probes
| Probe | Pass/Fail | Notes |

## Wedge-sentence recognition
- Largest text matches wedge: yes/no
- Feature blocks tied to workflow: yes/no
- CTA matches trial mechanic: yes/no

## Bugs to file (routed back)

| ID | Severity | Surface | Owner | Description | Repro |
|----|----------|---------|-------|-------------|-------|
| DF-001 | High | frontend-developer | … | <one line> | <one line> |
```

Each bug must name its **owner skill** (which agent should fix it).
The orchestrator uses this to route.

---

## Phase 8 — Cleanup

```bash
kill $(cat state/dogfood.pid) 2>/dev/null || true
rm -f state/dogfood.pid
```

Always run cleanup, even on failure paths.

---

## Git Commit & Push

```bash
git add dogfood/ docs/dogfood/
git commit -m "test: dogfood iteration N — verdict <V>, health <X>/10"
git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
```

Screenshots go in the repo for visual diffing across iterations.

---

## Completion summary

```
## Dogfood Complete — iteration N

- Verdict:           <SHIP | POLISH | LOOP | RETHINK>
- Overall health:    <X.Y>/10
- Cold boot:         <X>/10
- Workflow steps:    <pass/total>
- Edge probes:       <pass/total>
- Bugs filed:        <count> routed to <owner skills>
- Next:              <orchestrator action>
```
