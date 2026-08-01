---
name: signal-iterate
description: Signal-Driven Iteration (WARM loop) — the post-launch sibling of `iterate`, driven by REAL user signals (PostHog funnels, Sentry errors, support inbox, top-of-funnel analytics) instead of gap analysis. Prioritizes the next iteration based on what users actually do, not what the model thinks the market wants. Shares the same verification spine as `iterate` (critic gate + `agent verify` + quality-gates.sh + grow-the-net + dogfood); only the front-half (signals vs. gap analysis) differs.
argument-hint: "[optional: signal source override, e.g. 'posthog' or 'sentry-only']"
allowed-tools: Task, WebSearch, WebFetch, Read, Write, Edit, Bash, Glob, Grep
effort: max
---

# Role: Signal-Driven Iteration Engineer

You are running the iteration loop *after* the product is in front of
real users. Unlike the original `iterate` skill (which re-scans the
market and runs gap analysis from imagination), you start from
**evidence**: what users did, what broke, what they asked for.

The hierarchy of signal quality:

1. **What users *did*** (PostHog funnels, session recordings, retention)
2. **What broke** (Sentry / observability errors, failed jobs, 5xx)
3. **What users *said*** (support tickets, NPS comments, in-app feedback)
4. **What the market is doing** (competitor launches — last priority)

This skill ignores #4 unless 1–3 are exhausted. That inversion is
the whole point.

**Optional signal source override:** $ARGUMENTS

---

## Inputs

Required:
- `docs/01c-wedge.md` — wedge sentence, ICP, kill switches
- `docs/01b-product-spec.md` — KPI targets
- A deployed product with at least one real signal source wired

Recommended:
- `docs/06-iteration-log.digest.md` — prior iterations, compact rolling digest (read THIS,
  not every file in `docs/iterations/` — issue #1698)
- `state/state.json` — KPI targets, kill switches
- Environment variables: `POSTHOG_API_KEY`, `SENTRY_API_TOKEN`,
  `SUPPORT_INBOX_URL` (where applicable)

---

## Phase 0 — Signal Source Discovery

Detect available signal sources. For each, record availability and
freshness in `state/signals.json`:

```bash
# PostHog
[ -n "$POSTHOG_API_KEY" ] && curl -fsS \
  "https://app.posthog.com/api/projects/@current/" \
  -H "Authorization: Bearer $POSTHOG_API_KEY"

# Sentry
[ -n "$SENTRY_API_TOKEN" ] && curl -fsS \
  "https://sentry.io/api/0/projects/" \
  -H "Authorization: Bearer $SENTRY_API_TOKEN"
```

If none of #1–#3 are wired, stop and emit:
> ERROR: no real signals available. Wire at minimum PostHog or Sentry,
> then re-run. (Falling back to market re-analysis bypasses the point
> of this skill — invoke `iterate` instead.)

---

## Phase 1 — Behavior Signals (PostHog / analytics)

Pull these for the last 14 days (configurable):

### 1a. Wedge funnel performance

The wedge workflow from `01c-wedge.md` is a funnel. For each step,
fetch the conversion rate from the previous step. Flag any step with
< 50% step-conversion as a leak.

```
signup → activation event → wedge step 2 → wedge step N → paid
```

Top three leaks become candidate problems.

### 1b. Activation event hit-rate

The activation event from `16-pricing.md` Phase 4 is the moment of
proven value. Cohort by signup-day; what fraction reach activation
within 24h, 72h, 7d?

Targets (sanity defaults):
- 24h activation ≥ 30%
- 7d activation ≥ 50%

### 1c. Retention curve

Day-1, day-7, day-30 retention. A "smile curve" (drops then rises)
is the gold standard; "death curve" (drops then flatlines at 0) is
a wedge problem.

### 1d. Session recordings (sample 10)

Watch (read transcripts of) 10 sessions of users who:
- Hit activation (5 sessions): what does *winning* look like?
- Bounced after signup (5 sessions): where did they get stuck?

Note: this requires PostHog session recordings or equivalent. If not
wired, skip and note `[Sampled = 0]`.

Write findings to `docs/iteration-N/signals-behavior.md`.

---

## Phase 2 — Failure Signals (Sentry / observability)

Pull last 14 days:

- Top 10 issues by event count
- Top 10 issues by user count (different — a single high-value user
  hitting one bug 100 times is different from 100 users hitting it once)
- New issues introduced in the last 7 days
- Crash-free rate trend
- Slow endpoint p95 (from observability)
- Failed background jobs (from job queue)

For each top issue, classify:

| Class | Action |
|---|---|
| **Wedge-blocking** | Must fix this iteration. Stop everything else. |
| **Conversion-leaking** | Fix this iteration if behavior signal confirms |
| **Cosmetic** | Add to backlog |
| **Third-party flake** | Suppress filter; do not iterate |

Write to `docs/iteration-N/signals-failure.md`.

---

## Phase 3 — Voice Signals (support / NPS / inbox)

For each channel available:

- **Support tickets** — categorize last 30 by theme (5 buckets max)
- **NPS comments** — pull verbatims, separate promoter / detractor / passive
- **In-app feedback widget** — same
- **Discord / Slack / community** — pull last 100 messages, sentiment-tag

The thing to watch for: **the same complaint phrased three different
ways**. That is a real signal. A complaint mentioned once is noise.

Write to `docs/iteration-N/signals-voice.md`.

---

## Phase 4 — Synthesize: The One Question

Force a single answer to:

> **What is the one change that, if shipped this iteration, would move
> the most-leaking step of the wedge funnel by ≥ 5 percentage points?**

Not five changes. Not "three buckets." One.

If you can't name one, you don't have enough signal — go back to
Phase 1 and pull more, or extend the window.

If you can name three plausible changes, run a tiny effort/impact
matrix (1–5 each), pick the highest impact / lowest effort, and
write down explicitly *why the other two were rejected this iteration*
(not "we'll get to them" — *why* they're not the answer).

Output to `docs/iteration-N/the-one-change.md`:

```markdown
## The One Change — Iteration N

### Proposed change
<one paragraph>

### Funnel step it targets
<step name from wedge workflow>

### Predicted lift
<X percentage points, with reasoning>

### Rejected alternatives (and why not now)
1. <alt 1> — rejected because <reason>
2. <alt 2> — rejected because <reason>

### Success metric
<the specific PostHog query that will tell us this worked>

### Kill criterion
<the lift threshold below which we revert>
```

---

## Phase 5 — Kill Switch Check

Re-read kill switches from `01c-wedge.md`. For each:

- **Demand kill** — do current signals trip it? (e.g. trial-to-paid
  rate below threshold for 30 days)
- **Build kill** — has the wedge workflow proven undeliverable?
- **Defensibility kill** — has a top-3 incumbent shipped the wedge?

If any kill switch is tripped, **stop the iteration loop entirely**
and write `docs/iteration-N/kill-switch-tripped.md` with the
recommendation: pivot, narrow further, or shut down. Surface to user.

This is the only skill that is allowed to recommend killing the
project.

---

## Phase 6 — Plan & Implement

### 6a. Critic gate — refute the one change (REQUIRED)

"The one change" is a high-leverage bet made by a single model. Before any code
is written, spawn a **different-model** `general-purpose` subagent whose only job
is to **refute** `docs/iteration-N/the-one-change.md`:

- Is the targeted step really the top leak, or an artifact of a small/biased sample?
- Does the predicted ≥5pp lift survive scrutiny, or is it wishful?
- Is a rejected alternative actually higher impact / lower effort?

If the critic lands a hit, revise the one change before proceeding (the
`build-product-v2` critic discipline + `adversarial-strategy-loop`'s refute step,
applied to the iteration decision). Record the verdict in
`state.json .critic_verdicts`.

### 6b. Implement

Read the scale tier once — it picks the gate set in 6c:
```bash
TIER=$(jq -r '.scale_tier // "preview"' state/state.json)
```

Append the one-change task to `docs/04-dev-plan.md` tagged
`[Iteration N — signal-driven]`. Spawn the implementer in a fresh subagent
(`backend-developer` or `frontend-developer`).

**Grow the net:** if the change touches a user journey, BEFORE coding add its row
to `state/artifacts/journeys.json` and write its Playwright spec (fails red now).
The `journey-coverage` gate in 6c enforces it — otherwise the suite drifts behind
the product.

Do NOT bundle other changes into this iteration. Resist scope creep
— the discipline is half the point.

### 6c. Verify through the real spine (not ad-hoc)

```bash
agent verify --agent --with-adversarial --tier "$TIER"   # test→route→fix→re-test + loop-until-dry adversary
scripts/quality-gates.sh --tier "$TIER" --keep-going --json state/iter-gates.json
```

`quality-gates.sh` runs the tier-aware layered gates incl. `e2e` (boots+seeds the
real stack) and `journey-coverage`. Then invoke the `dogfood` skill as a **hard
gate** for UI changes (real browser, 0–10 score; below threshold = fail, route
back). The iteration is not complete until every tier-required gate in
`state/iter-gates.json` is PASS and the adversary is dry.

---

## Phase 7 — Instrument the Test

Before shipping, add the analytics event that will measure success.
The success metric from Phase 4 must be queryable in PostHog within
24 hours of deploy.

Write the exact PostHog query (HogQL or insight URL) into
`docs/iteration-N/the-one-change.md` Section "Success metric." This
is what `signal-iterate` iteration N+1 will read first.

---

## Phase 8 — Write Iteration Log File

Create a **new file** under `docs/iterations/` — do NOT append to a shared log.
The naming convention is `docs/iterations/<NNN>-issue-<issue>-<slug>.md` (see
`CLAUDE.md`). The issue number is the uniqueness guarantee; no two concurrent
iterations share it, so git never conflicts.

```bash
ISSUE_N="<issue-number>"       # the issue this signal-driven iteration addresses
SLUG="<short-kebab-slug>"      # e.g., "fix-signup-funnel-leak"
FILE="docs/iterations/$(printf '%03d' $N)-issue-${ISSUE_N}-${SLUG}.md"
```

If there is no issue number, use a short content hash instead:
`docs/iterations/<NNN>-noissue-<hash>-<slug>.md`.

Write:

```markdown
## Iteration N — <YYYY-MM-DD> — signal-driven

### Signal sources used
- [ ] PostHog
- [ ] Sentry
- [ ] Support inbox
- [ ] NPS

### Top leak identified
<step, current %, target %>

### The one change
<one line>

### Predicted lift
<X pp>

### Rejected alternatives
<count, with one-line reasons>

### Kill switches checked
<count tripped, names>

### Critic verdict (one-change refutation)
<survived | revised — one line>

### Hard gates (tier <TIER>)
<pass>/<total> from state/iter-gates.json · adversary dry · dogfood <N>/10 (if UI)

### Status
<PROPOSED | IMPLEMENTED | DEPLOYED | MEASURED>

### Measured lift (filled in N+1)
<actual pp once 14 days of data come back>
```

The "Measured lift" field stays blank this iteration. The next
iteration's first job is to fill it in — that is how the loop
self-corrects. The file is immutable after creation — never modify an
existing iteration file (a quality gate enforces this).

### Update the rolling digest (bounded — never replays the full history)

After writing the file above, update the compact companion so later runs get
prior-iteration context WITHOUT reading every iteration file (issue #1698):

```bash
agent iteration digest --add --iter "$N" --date "$(date +%F)" \
  --headline "<ONE line: the one change shipped this iteration>"
```

The script re-renders a fixed-size window (`docs/06-iteration-log.digest.md`): the last N
iterations verbatim, older ones one-line, the rest collapsed into a "+K earlier" rollup.
When you need prior-iteration context, read THAT digest — never the full
`docs/iterations/` directory.

### Regenerate the index (auto-generated from the directory)

```bash
agent iteration index
```

This regenerates `docs/06-iteration-log.md` as a machine-generated index. Do NOT
hand-edit it.

---

## Git Commit & Push

```bash
git add docs/iteration-N/ "$FILE" docs/06-iteration-log.md docs/06-iteration-log.digest.md docs/04-dev-plan.md
git commit -m "feat: iteration N — signal-driven, ship the one change"
git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
```

---

## Completion summary

```
## Signal-driven iteration N complete

- Signal sources:        <list, with freshness>
- Top leak step:         <step name>, <current%> → <target%>
- The one change:        <one line>
- Predicted lift:        <X pp>
- Kill switches:         <0 tripped | N tripped → STOP>
- Implemented:           <yes | no>
- Measurement query:     <PostHog URL or HogQL>
- Re-run in:             <14 days, or sooner if signals move>
```
