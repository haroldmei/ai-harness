---
name: build-product-v2
description: Default product builder. State-machine orchestrator with critic gates, scale-tier branching, and per-phase subagent contexts. Spawns general-purpose subagents that each invoke a single named skill (differentiation, pricing, dogfood, etc.).
argument-hint: "<product idea>"
allowed-tools: Task, Skill, WebSearch, WebFetch, Read, Write, Edit, Bash, Glob, Grep
effort: max
---

# Autonomous Product Builder v2

You are the orchestrator of a state-machine pipeline that turns a product
idea into a market-competitive product. You do **not** run all phases in
your own context. You spawn `general-purpose` subagents per phase, each
of which invokes a single named skill via the `Skill` tool against a
small, phase-specific context manifest. You enforce critic gates and
scale-tier branching. You loop on failure rather than executing a
waterfall.

**Product idea:** $ARGUMENTS

---

## Operating principles

1. **Subagent per phase.** Each phase runs in a fresh `general-purpose`
   subagent. The subagent's prompt instructs it to invoke one named
   skill via `Skill` and report back a structured result. This gives
   you the fresh-context property without leaving Claude Code.
2. **Blackboard state.** Persistent state lives in `state/state.json`.
   The orchestrator updates it via `scripts/state-set.sh`. Subagents
   return structured summaries that the orchestrator merges into state.
3. **Wedge is law.** After Phase 2, every subsequent subagent receives
   `docs/01c-wedge.md` in its context manifest and must embed the
   one-sentence wedge in its output. Out-of-wedge work → `[V2]`.
4. **Critic gate at every boundary.** Spawn a separate `general-purpose`
   subagent that invokes `/codex` (when available) or runs a critic
   prompt against the just-produced artifact. Different subagent =
   fresh context = no monoculture.
5. **Scale tier gates ops phases.** A `preview` product never enters
   the Terraform / PRR / SLO branch.
6. **Loops, not waterfall.** Failures route back to the responsible
   phase via `scripts/route-failure.sh`. Critic verdicts can demote
   `LOCKED` artifacts to `DRAFT` and replan.
7. **Hard gates beat soft gates.** Use `scripts/quality-gates.sh` —
   typecheck → lint → seed-integrity → unit → mutation ≥ 70% →
   integration → contract → e2e → a11y → Lighthouse → visual. Each
   gate is a separate hard pass.
8. **No ops bloat.** Default scale tier is `preview`. Most products
   ship without Terraform, BullMQ, or a PRR.

---

## Subagent invocation pattern

Every phase uses this template. Replace the `<…>` slots per phase.

```
Task(
  subagent_type = "general-purpose",
  description   = "<3–5 word phase description>",
  prompt        = """
    You are running ONE phase of build-product-v2. Your job is to
    invoke the `<skill_name>` skill and report a structured result.

    Steps:
    1. Read the context manifest:
       - <doc 1>
       - <doc 2>
       (do not read other docs; this is the entire context budget)

    2. Invoke the skill via the Skill tool:
       Skill(skill="<skill_name>", args="<args or empty>")

    3. After the skill completes, return a single message with this
       structured block (and nothing else):

       PHASE_RESULT
       phase: <phase_name>
       status: <done | failed | draft>
       artifact_path: <path the skill wrote, or "">
       wedge_sentence: <if set>
       scale_tier: <if set>
       critic_required: <true | false>
       open_issues: <count>
       summary: <≤ 240 chars>

    Do not write code, do not modify files outside what the skill
    writes, do not invoke other skills.
  """,
  model = "<opus | sonnet | haiku>"
)
```

The orchestrator parses `PHASE_RESULT`, updates `state.json` via
`scripts/state-set.sh`, and decides the next edge.

**Parallel fan-out** (Phase 7 implementation): emit multiple `Task`
calls in a single message; they run concurrently. Wait for all to
return before proceeding.

---

## Critic invocation pattern

After phases that produce a strategic artifact (`ceo`,
`differentiation`, `product-spec`, `designer`, `ux-designer`,
`pricing`, `positioning`):

```
Task(
  subagent_type = "general-purpose",
  description   = "Critic gate — <phase>",
  prompt        = """
    You are an adversarial critic. You did NOT write the artifact at
    <path>. Read it now (and only it; plus docs/01c-wedge.md if Phase 2+).

    If the `codex` skill is available, invoke it via:
       Skill(skill="codex", args="review <path>")
    Otherwise, apply the critic checklist for this phase (see below).

    Return:
       CRITIC_VERDICT
       phase: <phase>
       verdict: <pass | fail>
       must_fix: <bullet list of blocking issues>
       nice_to_have: <bullet list>
       evidence_quality: <strong | weak | absent>
  """,
  model = "<a different model than the producer>"
)
```

Critic checklists per phase live in §"Critic checklists" below.

---

## State file: `state/state.json`

Initialize on first run via `scripts/state-init.sh "<product idea>"`.
Schema (defaults from the script):

```json
{
  "schema_version": 2,
  "started_at": "<ISO-8601>",
  "product_idea": "<arg>",
  "wedge_sentence": null,
  "icp": null,
  "axis": null,
  "anti_axis": null,
  "scale_tier": "preview",
  "stack_constraints": {
    "realtime": false,
    "ai_heavy": false,
    "regulated": false,
    "multi_tenant_b2b": false,
    "eu_global_billing": false,
    "mobile_first": false,
    "data_heavy": false
  },
  "tech_stack": {
    "ci_provider": null,
    "cloud": null,
    "auth": null,
    "ai_heavy": false,
    "stack_version": null
  },
  "current_phase": "ceo",
  "phase_status": {},
  "critic_verdicts": {},
  "kill_switches": [],
  "decisions": [],
  "open_issues": [],
  "kpi_targets": {},
  "testing": {
    "gate_attempts": {},
    "open_issues_drained": false,
    "adversarial_rounds": 0,
    "last_mutation_score": null,
    "last_verdict": null,
    "last_run_at": null
  },
  "signal_sources": { "posthog": {...}, "sentry": {...}, "support": {...} }
}
```

`open_issues` holds two kinds of entry: legacy free-form **strings** (informal
notes) and structured **objects** — only the latter gate. An adversarial bug is
a structured object: `{ "id": "AT-<n>", "severity": ..., "surface": ...,
"repro_test": "<path>", "owner": "<skill>", "status": "open"|"routed"|"fixed",
"tags": ["adversarial"] }`. The `repro-tests` gate requires every still-open
object issue to carry a `repro_test` that exists on disk (red-before-green).

After every phase, run `scripts/state-decide.sh <phase> "<decision>" "<reason>"`
to append a one-line ADR.

---

## State machine

```mermaid
stateDiagram-v2
  [*] --> bootstrap
  bootstrap --> ceo
  ceo --> ceo_critic
  ceo_critic --> differentiation: pass
  ceo_critic --> ceo: fail

  differentiation --> diff_critic
  diff_critic --> human_checkpoint_1: pass (LOCKED)
  diff_critic --> differentiation: fail (DRAFT)

  human_checkpoint_1 --> tech_stack_selector: confirmed
  human_checkpoint_1 --> differentiation: revise

  tech_stack_selector --> stack_critic
  stack_critic --> product_spec: pass
  stack_critic --> tech_stack_selector: fail

  product_spec --> spec_critic
  spec_critic --> analyst: pass
  spec_critic --> product_spec: fail

  analyst --> designer
  designer --> design_critic
  design_critic --> ux_designer: pass
  design_critic --> designer: fail

  ux_designer --> human_checkpoint_2
  human_checkpoint_2 --> auth_engineer: confirmed
  human_checkpoint_2 --> ux_designer: revise

  auth_engineer --> email_branch
  state email_branch <<choice>>
  email_branch --> email_templates: needs_email=true
  email_branch --> ai_features_branch: needs_email=false
  email_templates --> ai_features_branch

  state ai_features_branch <<choice>>
  ai_features_branch --> ai_features: ai_heavy=true
  ai_features_branch --> impl_fanout: ai_heavy=false
  ai_features --> impl_fanout

  state impl_fanout <<fork>>
  impl_fanout --> backend
  impl_fanout --> frontend
  impl_fanout --> db_migrator

  backend --> impl_join
  frontend --> impl_join
  db_migrator --> impl_join

  state impl_join <<join>>
  impl_join --> api_docs
  api_docs --> e2e_tester
  e2e_tester --> quality_gates

  quality_gates --> adversarial: pass
  quality_gates --> route_failure: fail
  route_failure --> backend
  route_failure --> frontend
  route_failure --> e2e_tester: gate=e2e

  adversarial --> quality_gates: re-run
  quality_gates --> security: pass

  security --> dogfood
  dogfood --> perf_branch: health >= 9
  dogfood --> frontend: health < 9 (cosmetic)
  dogfood --> ux_designer: health < 7 (structural)
  dogfood --> designer: health < 5 (architectural)

  state perf_branch <<choice>>
  perf_branch --> perf_tester: tier >= launch
  perf_branch --> launch_branch: tier in {toy, preview}
  perf_tester --> reviewer
  reviewer --> launch_branch

  state launch_branch <<choice>>
  launch_branch --> pricing_positioning
  pricing_positioning --> human_checkpoint_3
  human_checkpoint_3 --> landing_page
  landing_page --> legal_compliance
  legal_compliance --> tier_branch

  state tier_branch <<choice>>
  tier_branch --> preview_ship: tier in {toy, preview}
  tier_branch --> ops_phases: tier in {launch, scale}

  ops_phases --> rollback_setup
  rollback_setup --> preview_ship
  preview_ship --> human_checkpoint_4
  human_checkpoint_4 --> analytics: GO
  analytics --> [*]
```

---

## Per-phase context manifests

The orchestrator passes each subagent only these docs (the prompt
template's "context manifest" slot).

| Phase | Reads | Writes |
|---|---|---|
| `ceo` | product idea | `01-market-analysis.md` |
| `differentiation` | `01` | `01c-wedge.md` (now incl. Stack constraints) |
| `tech-stack-selector` | `01c`, `state.json` | `00-tech-stack.md` |
| `product-spec` | `00`, `01`, `01c` | `01b-product-spec.md` |
| `analyst` | `00`, `01`, `01b`, `01c` | `02-system-requirements.md` |
| `designer` | `00`, `01b`, `01c`, `02` | `03-system-design.md` |
| `ux-designer` | `00`, `01b`, `01c`, `03` | `03b-ux-design.md` |
| `auth-engineer` | `00`, `01c`, `02`, `03` | auth code, `04-dev-plan.md` |
| `email-templates` (conditional) | `00`, `01b`, `02`, `03`, `03b` | email service, templates |
| `ai-features` (conditional) | `00`, `01c`, `02`, `03` | `src/lib/ai/`, `src/prompts/`, `evals/` |
| `backend-developer` | `00`, `01c`, `02`, `03` | code, `04-dev-plan.md` |
| `frontend-developer` | `00`, `01c`, `03`, `03b` | code |
| `db-migrator` | `00`, `03` | migrations, seed |
| `api-docs` | code, `02`, `03` | `07-api-reference.md`, `openapi.yaml` |
| `e2e-tester` | code, `02`, `03b` | `e2e/`, `playwright.config.ts` |
| `adversarial-tester` | code, `02` | `tests/adversarial/`, `08b` |
| `security-auditor` | code, `00`, `03` | `09-security-audit.md` |
| `dogfood` | running app, `01c`, `03b` | `dogfood/`, `dogfood/iter-N.md` |
| `perf-tester` (launch+) | code, `02`, `03` | `10-performance-report.md`, k6 tests |
| `reviewer` (launch+) | full repo, `02`, `03` | `05-code-review.md` |
| `pricing` | `01`, `01b`, `01c` | `16-pricing.md` |
| `positioning` | `01c`, `01b`, `16` | `17-positioning.md` |
| `landing-page` | `00`, `01c`, `03b`, `16`, `17` | landing page code |
| `legal-compliance` | `00`, `01b`, `01c`, `02`, `03` | legal pages, consent banner |
| `cicd` | `00`, `03`, `04` | `.buildkite/` (or `.github/workflows/`), `Dockerfile` |
| `deployer` | `00`, `03`, `state.json` | `infra/` or `vercel.json`/`fly.toml` |
| `rollback` (launch+) | `00`, `03`, deploy state | rollback runbook, deploy verification hooks |
| `observability` (launch+) | `00`, `02`, `03` | logging, health checks, dashboards |
| `signal-iterate` | analytics + `01c` | `iteration-N/...` |

---

## Phase execution

### Phase 0 — Bootstrap (orchestrator runs directly)
```bash
mkdir -p state docs
scripts/state-init.sh "$ARGUMENTS"
git init 2>/dev/null || true
```

### Phase 1 — `ceo`
Spawn a subagent using the template above with:
- skill: `ceo`
- manifest: `(idea only)`
- model: `opus`
- args: `$ARGUMENTS`

On `PHASE_RESULT.status = done` → run critic gate (next phase).

### Phase 1c — `ceo_critic`
Critic spawn against `docs/01-market-analysis.md`, model `sonnet`.
Pass criteria:
- TAM/SAM/SOM cited with sources
- ≥ 5 competitors with pricing or "no public price" called out
- Competitor matrix non-trivial (not just product names)
- Wedge candidates non-empty
- No platitudes ("revolutionary," "next-generation")

Fail → loop to `ceo` with `must_fix` as input.

### Phase 2 — `differentiation`
Subagent template, skill `differentiation`, manifest `[01]`, model `opus`.
On done, the skill writes `01c-wedge.md`. Parse and run:
```bash
scripts/state-set.sh '.wedge_sentence' "\"$WEDGE\""
scripts/state-set.sh '.scale_tier'     "\"$TIER\""
scripts/state-set.sh '.icp'            "\"$ICP\""
scripts/state-set.sh '.axis'           "\"$AXIS\""
scripts/state-set.sh '.anti_axis'      "\"$ANTI\""
```

### Phase 2c — `diff_critic`
Critic spawn, model `sonnet`. Checks:
- Single axis (not "we'll be better at everything")
- Anti-axis non-empty and binding
- Wedge sentence < 140 chars
- Could-copy-in-a-weekend test fails (i.e. non-trivial)

If `verdict = fail` AND `01c-wedge.md` is `Status: DRAFT`, loop to
`differentiation`. If `verdict = fail` AND `LOCKED`, demote to DRAFT
in state and loop.

### Phase 2.5 — Human checkpoint 1
Use `AskUserQuestion` to surface:
- Wedge sentence
- ICP one-liner
- Scale tier
- Active stack constraints (the `true` flags from differentiation Phase 5b)

Options: `confirm | revise | abandon`. **Mandatory.** This is the
single highest-leverage human decision. Confirming it locks the wedge
AND the stack constraints — both are inputs to the next phase.

### Phase 2.7 — `tech-stack-selector` (NEW)
Subagent, skill `tech-stack-selector`, manifest `[01c]`, model `sonnet`.
On done, the skill writes `docs/00-tech-stack.md`. Parse the resolved
contract and persist key fields:
```bash
scripts/state-set.sh '.tech_stack.ci_provider'  "\"$(yq '.ci.provider' docs/00-tech-stack.md)\""
scripts/state-set.sh '.tech_stack.cloud'        "\"$(yq '.cloud.provider' docs/00-tech-stack.md)\""
scripts/state-set.sh '.tech_stack.auth'         "\"$(yq '.auth.default' docs/00-tech-stack.md)\""
scripts/state-set.sh '.tech_stack.ai_heavy'     "$([[ -n \"$(yq '.ai.cost_tracking // empty' docs/00-tech-stack.md)\" ]] && echo true || echo false)"
```

### Phase 2.7c — `stack_critic`
Critic spawn against `docs/00-tech-stack.md`, model `opus` (different
from selector's `sonnet`). Pass criteria:
- Versions pinned to majors (no "latest")
- `not_in_stack` non-empty (≥ 3 retired defaults)
- Every override has a one-line rationale
- All constraint flags from `01c-wedge.md` are addressed
- Vendors named only when org has corresponding env vars (e.g. Buildkite needs `$BK_API_TOKEN`)
- `ci.provider: buildkite` chosen unless explicit reason against (cost-effective default)

Fail → loop to `tech-stack-selector` with `must_fix` as input.

### Phase 3 — `product-spec`
Subagent, skill `product-spec`, manifest `[00, 01, 01c]`, model `sonnet`.
Hard cap: one critical flow + 3 supporting; rest tagged `[V2]`.

### Phase 4 — `analyst`
Subagent, skill `analyst`, manifest `[01, 01b, 01c]`, model `sonnet`.
Every FR tagged `[wedge-critical]`, `[wedge-supporting]`, or
`[Out-of-wedge → V2]`.

### Phase 5 — `designer`
Subagent, skill `designer`, manifest `[01b, 01c, 02]`, model `opus`.
Critic enforces tier-appropriate architecture (no microservices on
preview).

### Phase 6 — `ux-designer`
Subagent, skill `ux-designer`, manifest `[01b, 01c, 03]`, model `sonnet`.
Pre-step: instruct the subagent to use the `browse` skill to
screenshot the top 3 competitors before designing. Critic uses the
`plan-design-review` rubric (≥ 7 across all dimensions).

### Phase 6.5 — Human checkpoint 2
Surface design target before building.

### Phase 6.7 — `auth-engineer` (NEW, sequential before fan-out)
Subagent, skill `auth-engineer`, manifest `[00, 01c, 02, 03]`,
model `sonnet`. Scaffolds auth per `contract.auth.default` so
backend-developer can wire routes against the established session/user
table. Skipped if `contract.auth.default: hand-rolled-jwt` (legacy
path; backend-developer owns it).

### Phase 6.8 — `ai-features` (NEW, conditional, sequential before fan-out)
Run **only if** `state.tech_stack.ai_heavy == true` (set during Phase
2.7). Subagent, skill `ai-features`, manifest `[00, 01c, 02, 03]`,
model `opus` (taste-heavy). Establishes RAG schema, prompts, eval
harness, and cost-tracking ledger so backend-developer wires call sites
against existing infrastructure. If `ai_heavy: false`, skip silently.

### Phase 6.9 — `email-templates` (NEW, conditional, sequential before fan-out)
Run only if `docs/01b-product-spec.md` mentions transactional emails
(verification, password reset, notifications, digests). Detect with:

```bash
grep -iE 'email|verification|password reset|notification|digest' docs/01b-product-spec.md \
  && state.email_needed=true || state.email_needed=false
```

Subagent, skill `email-templates`, manifest `[00, 01b, 02, 03, 03b]`,
model `haiku`. Configures the provider per `contract.email.provider`
(default Resend), generates templates per `contract.email.templates`
(default React Email), so backend-developer can call a working
`sendEmail()` instead of stubbing it. If `email_needed: false`, skip
silently.

### Phase 7 — Implementation fan-out (PARALLEL)
Emit three `Task` calls in **one message**:
- `backend-developer` (sonnet)
- `frontend-developer` (sonnet)
- `db-migrator` (haiku)

Each writes its `phase_status` field. Wait for all three to return.
All three read `docs/00-tech-stack.md` as their first action and refuse
to introduce vendors not in the contract.

**`db-migrator` post-condition (HARD):** the phase is only `done` if
`state/artifacts/db-migrator.json` exists AND every required path it
lists is present on disk AND every `package_scripts` entry is in
`package.json`. The orchestrator must verify this before advancing,
not trust the subagent's `PHASE_RESULT.summary`:

```bash
scripts/quality-gates.sh --only seed-integrity
```

If this fails, the phase is `failed` (not `done`); route via
`scripts/route-failure.sh --gate seed-integrity --area prisma/`. This
catches the "phantom artifact" failure mode where a subagent narrates
"seed shipped" but never wrote the file.

### Phase 7.5 — `api-docs` (NEW, sequential after impl join)
Subagent, skill `api-docs`, manifest `[code, 02, 03]`, model `haiku`.
Scans the now-implemented routes, extracts validators and types, and
writes `docs/07-api-reference.md` + `openapi.yaml`. The frontend code
already exists at this point — `api-docs` is documenting reality, not
specifying it. Subsequent `frontend-developer` reruns (e.g. from
`route-failure.sh`) will read this if they need API shapes.

### Phase 7.7 — `e2e-tester` (NEW, sequential before quality gates)
Subagent, skill `e2e-tester`, manifest `[code, 02, 03b]`, model
`sonnet`. Generates a Playwright suite covering the wedge workflow plus
auth, error states, and responsive layouts. Without this, the `e2e`
quality gate has nothing to run.

The skill iterates until all generated tests pass against the local
dev server. If a test fails because a feature is broken (not the
test), routes back via `route-failure.sh --gate e2e --area <path>` to
the appropriate implementer.

### Phase 8 — Quality gates + fix loop (orchestrator runs the driver)

Do **not** hand-roll the gate/route/fix loop — run the codified driver:

```bash
scripts/verify-loop.sh --agent          # test → route → fix → re-test until green
```

`verify-loop.sh` is the deterministic form of this phase: it runs
`scripts/quality-gates.sh --keep-going --json` (all gates, tier-aware), routes
every failure through `route-failure.sh`, persists the attempt count in
`state.testing.gate_attempts`, and — with `--agent` — spawns the owner skill via
`claude -p` to fix the root cause, looping until all gates pass or a gate hits
`--max-attempts` (default 3, then surfaced). It writes a machine-readable
`state/verdict.json` and updates `state.testing`.

Gates are **tier-aware**: a gate in the tier's required set that would SKIP for
missing tooling/inputs is promoted to FAIL (no silent green). The required sets
live in `quality-gates.sh`; `launch+` requires `mutation`, `repro-tests`, and
`wedge-coverage`. Emit `state/artifacts/wedge-files.json` (the wedge-critical
source paths) so `wedge-coverage` can enforce that the wedge workflow is tested.

If you are driving the loop yourself instead of with `--agent` (report-only),
`verify-loop.sh` still routes and writes the verdict; you apply each fix via the
Task tool, then re-run it.

### Phase 9 — `adversarial-tester` (loop-until-dry)

Run the adversary in a loop, not a single pass:

```bash
scripts/adversarial-loop.sh --agent     # repeat adversarial-tester until DRY_STOP empty rounds
```

`adversarial-loop.sh` repeatedly invokes the `adversarial-tester` skill (model
`opus`, **different from the implementer** to break monoculture), deduping
findings by issue id across rounds, until two consecutive rounds add zero new
bugs (or `--max-rounds`). Each real bug is filed as a structured `open_issues`
object with a committed `repro_test`; the tester never fixes (tester ≠ fixer).
Then re-run Phase 8 (`verify-loop.sh`) — the `repro-tests` gate guarantees every
filed bug carries a reproducing test and the implementer's fix drains it.

### Phase 10 — `security-auditor`
Subagent, skill `security-auditor`. Tier gate: `preview` → Critical/High
only; `launch+` → full OWASP ASVS.

### Phase 11 — `dogfood` (NEW)
Subagent, skill `dogfood`, manifest `[01c, 03b]`, model `opus`.
The skill returns a verdict. Routing:
- `BLOCKED` → loop to `db-migrator` (seed gate failed at Phase 1.5;
  re-run `seed-integrity` quality gate after the loop)
- `SHIP` → advance to perf branch
- `POLISH` → loop to `frontend-developer` (one round, capped)
- `LOOP` → loop to `ux-designer` + `frontend-developer`
- `RETHINK` → loop to `designer` (architecture)

### Phase 11.5 — `perf-tester` (NEW, launch+ only)
Run only if `state.scale_tier in {launch, scale}`. Subagent, skill
`perf-tester`, manifest `[code, 02, 03]`, model `sonnet`. Generates k6
load tests against the wedge workflow, scans Prisma queries for N+1
patterns, checks for missing DB indexes, captures bundle-size
baselines, and writes `docs/10-performance-report.md`.

Hard-fail criteria:
- p95 latency on the wedge workflow > 2× the NFR target
- Any N+1 query on a hot path
- Bundle size > 1.5× the prior baseline (from `benchmark` if present)

Failures route back to `backend-developer` (queries / indexes) or
`frontend-developer` (bundle), depending on the issue class.

For `toy` and `preview` tiers, skip — Lighthouse from the quality gate
is sufficient at those scales.

### Phase 11.7 — `reviewer` (NEW, launch+ only)
Run only if `state.scale_tier in {launch, scale}`. Subagent, skill
`reviewer`, manifest `[full repo, 02, 03]`, model `opus` (different
from per-artifact critics — full-repo cross-cutting view). Writes
`docs/05-code-review.md`.

Per-artifact critics covered each artifact in isolation; this is the
first phase that reads the entire codebase together. Looks for:
- Cross-module inconsistency (one module uses transactions, another
  doesn't, for the same kind of write)
- Dead code / unused exports
- Tests missing for entire surfaces (e.g. one route file has 0 tests)
- Security boundary violations the per-route security audit missed
  because they require cross-route context (e.g. tenant isolation
  across endpoints)

Findings are auto-fixed iteratively (read the SKILL.md — it loops on
each issue). For `toy`/`preview` tiers, skip; the per-artifact critics
already covered everything you need.

### Phase 12 — `pricing` + `positioning` (PARALLEL)
Two `Task` calls in one message:
- `pricing` (sonnet, manifest `[01, 01b, 01c]`)
- `positioning` (sonnet, manifest `[01c, 01b, 16]` — runs after `pricing`)

Actually `positioning` reads `16-pricing.md`, so they cannot fully
parallelize. Run `pricing` first, then `positioning`.

### Phase 12.5 — Human checkpoint 3
Surface tiers, prices, trial mechanic, headline. Confirm or revise.

### Phase 13 — `landing-page`
Subagent, skill `landing-page`, manifest `[01c, 03b, 16, 17]`, model `sonnet`.

### Phase 13.5 — `legal-compliance` (NEW, always for any public deploy)
Subagent, skill `legal-compliance`, manifest `[00, 01b, 01c, 02, 03]`,
model `haiku`. Generates privacy policy, terms of service, cookie
consent banner, GDPR data-access/deletion endpoints
(`DELETE /api/auth/account`, `GET /api/auth/export`), and acceptable
use policy.

Hard gate at `regulated: true` or `eu_global_billing: true` — the
phase fails and blocks `preview_ship` if these constraints are set
but the legal pages are missing.

For `toy` tier, skip (no public exposure).

### Phase 14 — Scale-tier branch (orchestrator)
```
case state.scale_tier in
  toy|preview)  goto preview_ship  ;;
  launch|scale) run 15–18, then preview_ship ;;
esac
```

### Phase 15 — `background-jobs` (launch+ only)
Skill gates itself: if no async needs, returns "[Deferred]".

### Phase 16 — `env-manager` + `cicd` (launch+ only, sequential)

### Phase 17 — `deployer` + `observability` (launch+; scale-only deltas inside)
Run both. `deployer` provisions Vercel/Fly for `preview` (already done
in Phase 19 if tier is preview), or Terraform Cloud Run / ECS for
`launch+`. `observability` wires pino + Sentry + provider-native
monitoring (Cloud Monitoring or CloudWatch) per the contract.

Multi-region, read-replicas, and OpenTelemetry tracing are scale-tier
deltas declared inside `deployer` and `observability` SKILL.md — the
orchestrator does not need a separate phase for them.

### Phase 17.5 — `rollback` (NEW, launch+ only)
Subagent, skill `rollback`, manifest `[00, 03, deploy state]`, model
`haiku`. Wires deploy verification (smoke tests against the deployed
URL) and automatic rollback on failure. Captures the current revision
in `/tmp/rollback-target.env` pre-deploy; if smoke tests fail
post-deploy, rolls back to the captured revision via
`gcloud run services update-traffic` (GCP) or
`aws ecs update-service` (AWS).

Updates `.buildkite/scripts/deploy.sh` to invoke verification + auto-revert.
Writes a runbook to `docs/19-rollback-runbook.md`.

### Phase 18 — `production-readiness` (scale only)

### Phase 19 — Preview ship (orchestrator)

**Phase 19a — Local quickstart runbook (ALL tiers, mandatory).**
Before any tier branching, write `docs/RUN.md` with a single
copy-pasteable line that takes a fresh clone to a seeded, running app,
sourced from the db-migrator manifest. This guarantees every build —
toy, preview, launch, scale — ships with a frictionless local-eval
path. `docs/RUN.md` is reserved for this purpose; it does not collide
with `docs/12-runbook.md` (deploy/incident runbook, launch+ only).

```bash
BOOT=$(jq -r '.boot_command' state/artifacts/db-migrator.json)
PM=$(jq -r '.tech_stack.package_manager // "pnpm"' state/state.json)
DEV_CMD="$PM run dev"
ONELINER="$PM install && $BOOT && $DEV_CMD"
SEED_CMD=$(jq -r '.seed_command' state/artifacts/db-migrator.json)

mkdir -p docs

# Overwrite docs/RUN.md every run so it stays in sync with the
# current db-migrator manifest. This file has exactly one purpose.
cat > docs/RUN.md <<EOF
# Run locally

Fresh clone to seeded, running app:

\`\`\`bash
$ONELINER
\`\`\`

- Seed contents: see \`state/artifacts/db-migrator.json#.required_paths\`
- Re-seed only: \`$SEED_CMD\`
- Deploy / incident runbook: \`docs/12-runbook.md\` (launch+ only)
EOF

# Persist for the Completion block.
scripts/state-set.sh '.local_quickstart' "\"$ONELINER\""
```

This phase is **non-skippable**. If `state/artifacts/db-migrator.json`
is missing or `boot_command` is null, fail and route back to
`db-migrator` — the seed-integrity gate should have caught this at
Phase 7, so reaching Phase 19 without a manifest is a bug.

**Phase 19b — Tier-dependent deploy:**
- `toy`     → no deploy; the runbook is the deliverable
- `preview` → Vercel/Fly preview URL
- `launch+` → `cicd` + `deployer` deploy
Then run a canary check (spawn `qa` subagent against the deployed URL).

### Phase 19.5 — Human checkpoint 4
GO/NO-GO before public exposure.

### Phase 20 — `analytics` + handoff to `signal-iterate`
Instrument the wedge workflow only. Schedule:
```
/schedule signal-iterate weekly
```

---

## Critic checklists (used when `/codex` is unavailable)

### `ceo` critic
- [ ] TAM/SAM/SOM each cite a source
- [ ] ≥ 5 competitors with at least 4 columns of detail
- [ ] No platitudes
- [ ] Wedge candidates non-empty

### `differentiation` critic
- [ ] Single axis named (not multi)
- [ ] Anti-axis is binding (it forbids something)
- [ ] Wedge sentence < 140 chars
- [ ] Wedge survives "could a competitor copy in a weekend?"
- [ ] Workflow has ≤ 10 steps with concrete inputs/outputs
- [ ] Stack constraints section present (Phase 5b); each `true` flag justified

### `tech-stack-selector` critic
- [ ] Versions pinned to majors (no "latest")
- [ ] `not_in_stack` non-empty (≥ 3 retired defaults)
- [ ] Every default-override has a one-line rationale
- [ ] All `true` constraints from `01c-wedge.md` translated into overrides
- [ ] No vendor named without org credentials present (e.g. `$BK_API_TOKEN` for Buildkite)
- [ ] `ci.provider: buildkite` chosen unless explicit reason against (cost-effective default)
- [ ] Tier deltas applied (toy ≠ launch in stack shape)

### `product-spec` critic
- [ ] Exactly one critical flow
- [ ] ≤ 3 supporting flows
- [ ] All else `[V2]`-tagged
- [ ] KPIs measurable, not aspirational

### `designer` critic
- [ ] Architecture matches scale tier (preview ≠ microservices)
- [ ] Justification for every "we chose X over Y"
- [ ] Each NFR tied to an architectural decision

### `ux-designer` critic
- [ ] Competitor teardown present (≥ 3 products)
- [ ] Wireframes for every wedge-workflow step
- [ ] WCAG AA contrast on color palette
- [ ] Hero microcopy = wedge sentence (or ≤ 12-word transform)

### `pricing` critic
- [ ] 2 or 3 tiers (not 4+)
- [ ] No "unlimited"
- [ ] Each tier names its upgrade trigger
- [ ] Trial mechanic matches wedge axis

### `positioning` critic
- [ ] Headline ≤ 12 words
- [ ] Competitive frame names a specific alternative
- [ ] Anti-positioning section non-empty
- [ ] Voice axis locked (not "all of the above")

---

## Failure-routing matrix

| Failure | Route to |
|---|---|
| Critic rejects spec/wedge | last passing producer |
| Quality gate: typecheck/lint | `route-failure.sh --gate <g> --area <path>` |
| Quality gate: seed-integrity | `db-migrator` (manifest mismatch / phantom artifact) |
| Quality gate: mutation | `adversarial-tester` |
| Quality gate: contract | `backend-developer` |
| Quality gate: e2e | `e2e-tester` (test bug) or `frontend-developer`/`backend-developer` (feature bug) |
| Perf hard-fail (p95 > 2× NFR) | `backend-developer` (queries/indexes) |
| Perf hard-fail (bundle > 1.5×) | `frontend-developer` |
| Reviewer finds cross-cutting issue | the responsible implementer (`backend-developer` / `frontend-developer`) |
| Dogfood `BLOCKED` (empty wedge-critical seed) | `db-migrator` (re-run `seed-integrity` after) |
| Dogfood `LOOP` | `ux-designer` + `frontend-developer` |
| Dogfood `RETHINK` | `designer` |
| Security Critical/High | `backend-developer` (code) or `env-manager` (secrets) |
| Legal-compliance hard-fail (regulated/EU) | `legal-compliance` (rerun) |
| Canary fails | `rollback` auto-reverts; then `cicd` (pipeline), `deployer` (infra), or `frontend-developer` (build) |

After 3 failed attempts on the same phase, **stop and surface to the
user** via `AskUserQuestion`. This is the safety valve.

---

## Mandatory human-in-the-loop checkpoints

1. **After `differentiation`** — wedge + ICP + tier confirm
2. **After `ux-designer`** — competitive teardown + design target
3. **After `pricing` + `positioning`** — tiers + headline
4. **At preview-ship** — GO/NO-GO before public URL

These are non-skippable in v2. Use `AskUserQuestion`.

---

## Model routing

Pass `model=` to each `Task` call:

| Phases | Model |
|---|---|
| `ceo`, `differentiation`, `designer`, `dogfood`, `adversarial-tester`, `ai-features`, `reviewer` (all need taste/reasoning) | opus |
| `tech-stack-selector`, `product-spec`, `analyst`, `ux-designer`, `auth-engineer`, `backend-developer`, `frontend-developer`, `e2e-tester`, `perf-tester`, `pricing`, `positioning`, `signal-iterate`, `observability`, `iterate` | sonnet |
| `api-docs`, `env-manager`, `email-templates`, `db-migrator`, `cicd`, `legal-compliance`, `rollback` | haiku |

**Critic** always runs on a *different* model from the producer, to
break monoculture.

---

## Prompt-cache strategy

The six "always-read" docs (`00`, `01`, `01b`, `01c`, `02`, `03`) form
a stable prefix from the tech-stack-selector phase onward. `00` (the
tech-stack contract) goes first because every implementation skill
reads it first. List them in the same order in every subagent's
context manifest so the cache hits. Don't interpolate per-phase data
into the middle of that prefix.

---

## Completion

When the state machine reaches `[*]`, print the summary block followed
by the guaranteed local-run one-liner. The one-liner is the **last
line** of the orchestrator's output — never omit it, never reorder
below it, regardless of tier or any phase being skipped.

```
## Build Complete (v2)

Wedge:           <wedge sentence>
Scale tier:      <tier>
Phases run:      <list, with skipped phases marked>
Loops taken:     <list of (phase, count)>
Critic gates:    <pass/fail counts>
Quality gates:   <which passed, which were waived and why>
Dogfood health:  <final score>
Preview URL:     <or "local-only">
Next steps:      <iterate cadence; what kill switch to watch>

Run locally:     <state.local_quickstart>     (also in docs/RUN.md)
```

`state.local_quickstart` is set by Phase 19a and is verified by the
`seed-integrity` quality gate. If it is null at completion, the build
is incomplete — do not print "Build Complete" and surface to the user.

Create `docs/iterations/000-issue-<N>-<slug>.md` as iteration 0, then run `scripts/generate-iteration-index.sh` to regenerate the index at `docs/06-iteration-log.md`.

---

## Design principles

- **Wedge-driven** — every phase reads `01c-wedge.md`; out-of-wedge
  work is auto-tagged `[V2]`.
- **Subagent isolation** — fresh `general-purpose` subagent per phase
  invokes a single skill via `Skill`. No more 200K-token monolithic
  context by Phase 20.
- **Critic gates** — every strategic artifact is reviewed by a
  different-model subagent before advancing.
- **Scale-tier branching** — `preview` is not forced through Terraform.
- **Loops, not waterfall** — failures route back via `route-failure.sh`.
- **Dogfood loop** — real browser walk of the wedge workflow before ship.
- **Human checkpoints** — at the four high-leverage moments.
- **Model routing** — Opus for taste, Sonnet for volume, Haiku for
  mechanical work.
- **Real scripts** — `state-init.sh`, `state-set.sh`, `state-decide.sh`,
  `quality-gates.sh`, `route-failure.sh` are actual files in `scripts/`.

See `docs/00-pipeline-research-and-redesign.md` for the rationale and
remaining backlog.
