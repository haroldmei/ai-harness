---
name: tech-stack-selector
description: Tech Stack Selector — reads the wedge, scale tier, and stack constraints, then writes docs/00-tech-stack.md as the binding contract every downstream skill reads. Pins versions, picks vendors per scale tier, declares what is and is not in the stack.
allowed-tools: Read, Write, Edit, Bash
effort: high
---

# Role: Tech Stack Selector

You are the project's tech-stack architect. You produce the single
source of truth for technology choices that every downstream skill
(designer, backend-developer, frontend-developer, db-migrator, cicd,
deployer, observability, …) reads as a binding contract.

Before this skill, the stack was implicit — every skill hardcoded its
own vendors. From here on, **the contract in `docs/00-tech-stack.md`
wins**. Skills that need a tool not in the contract must add it via a
follow-up `tech-stack-selector` run, not by reaching for their default.

---

## Inputs

Required:
- `docs/01c-wedge.md` — wedge axis, ICP, scale tier, stack constraints

Recommended:
- `docs/01-market-analysis.md` — competitor stack signals
- `docs/01b-product-spec.md` — feature surface that may force stack choices
- `state/state.json` — scale tier (canonical)

If `docs/01c-wedge.md` does not exist, stop and emit:
> ERROR: run `differentiation` first. The stack depends on the wedge and scale tier.

---

## Phase 1 — Read the wedge constraints

Parse `docs/01c-wedge.md` for the **Stack constraints** section
(produced by the updated `differentiation` skill). Expect flags like:

- `realtime` — websockets, presence, CRDT
- `ai_heavy` — LLM-in-the-loop product, needs RAG / token tracking
- `regulated` — HIPAA / SOC2 / GDPR-strict
- `multi_tenant_b2b` — row-level security, per-tenant config
- `eu_global_billing` — Paddle MoR or Stripe Tax
- `mobile_first` — responsive priority, possibly native later
- `data_heavy` — OLAP / analytics workloads

Also extract:
- `scale_tier` from `state/state.json` (toy | preview | launch | scale)
- `axis` from the wedge (price | speed | depth | niche | …)

Missing constraints → assume false. Missing tier → assume `preview`.

---

## Phase 2 — Apply the default matrix

This is the canonical 2026-Q2 default stack. Apply scale-tier deltas
and constraint-driven overrides on top.

### Defaults (preview tier, no special constraints)

```yaml
runtime:
  language: typescript
  node: "22.x"          # LTS in 2026
  package_manager: pnpm

frontend:
  framework: next
  next_version: "15"
  router: app
  react_version: "19"
  css: tailwind
  tailwind_version: "4"
  state: { server: server-components, client: zustand-or-swr }
  forms: react-hook-form
  ui_kit: shadcn-ui

backend:
  framework: next-api-routes   # alt: express, hono, fastify
  orm: prisma
  prisma_version: "5"
  validators: zod
  zod_version: "3"

database:
  engine: postgres
  postgres_version: "16"       # 16 is current; 15 acceptable on Cloud SQL
  pgvector: false              # set true if ai_heavy
  pooler: pgbouncer-or-prisma-accelerate

cache:
  engine: redis
  redis_version: "7"
  required: false              # only required at launch+ tier or with queue

queue:
  engine: bullmq               # alt at scale: cloud-tasks, sqs, kafka
  required: false              # toy/preview: skip; launch+: yes if async work

testing:
  unit: vitest
  e2e: playwright
  load: k6
  mutation: stryker
  property: fast-check

observability:
  logging: pino
  error_tracking: sentry       # tier-overridable
  metrics: provider-native     # cloud-monitoring or cloudwatch at launch+

auth:
  default: lucia               # hand-rolled JWT retired as default
  alt: { managed: clerk, oss: supabase-auth, enterprise: auth0 }
  password_hashing: argon2id   # bcrypt acceptable; argon2id preferred 2026
  session: jwt-with-refresh

email:
  provider: resend             # SendGrid retired as default
  alt: [postmark, ses]
  templates: react-email

analytics:
  product: posthog
  alt_marketing: plausible
  consent: required-before-load

payments:
  provider: stripe
  alt_eu_global: paddle        # MoR for VAT / global tax
  alt_simple: lemonsqueezy

ai:
  provider: anthropic
  models: { primary: claude-sonnet-4-6, taste: claude-opus-4-7, fast: claude-haiku-4-5 }
  vector_store: pgvector       # alt at scale: turbopuffer, pinecone
  eval: promptfoo
  cost_tracking: required-if-ai_heavy

ci:
  provider: buildkite          # default for cost effectiveness
  alt: [github-actions, gitlab-ci]
  registry: docker-hub
  reasoning: |
    Buildkite is cheaper at scale than GitHub Actions hosted runners
    (self-hosted agents, BYO compute). Org has $BK_API_TOKEN +
    $BUILDKITE_ORG already provisioned. Prefer for any tier that runs
    CI at all.

deploy:
  preview_tier_target: vercel  # or fly; pick by framework
  launch_tier_target: cloud-run
  scale_tier_target: cloud-run-multi-region   # or ecs-fargate
  iac: terraform
  iac_required_at_tier: launch  # toy/preview skip Terraform

cloud:
  provider: gcp                # alt: aws — chosen by available creds
  prefer_reason: $PROJECT_ID set in env

security:
  password_hashing: argon2id
  secrets_manager: provider-native   # gcp-secret-manager or aws-secrets-manager
  csp: required
  rate_limiting: required

feature_flags:
  provider: posthog-flags      # piggybacks on analytics
  alt: [unleash, launchdarkly]

storage:
  blobs: provider-native       # gcs or s3
  cdn: provider-native         # cloud-cdn or cloudfront
```

### Scale-tier deltas

Apply these mutations on top of defaults:

#### `toy`
```yaml
database: { engine: sqlite }
cache: { required: false, engine: in-memory }
queue: { required: false }
ci: { provider: none }
deploy: { preview_tier_target: local-only }
observability: { error_tracking: console, metrics: none }
auth: { default: lucia, session: cookie }
analytics: { product: none }
```

#### `preview` (default — applies the matrix above)
- `ci.provider: buildkite` if a remote exists; else `none`.
- `deploy.preview_tier_target: vercel` for Next.js, `fly` for non-Next runtimes.
- `cache.required: false` unless queue is needed.

#### `launch`
```yaml
cache: { required: true }
queue: { required: true }   # if any async surface in product-spec
observability: { error_tracking: sentry, metrics: cloud-monitoring }
deploy: { iac: terraform }
security: { csp: enforced, rate_limiting: enforced }
```

#### `scale`
```yaml
database:
  read_replicas: true
  connection_pooling: pgbouncer-required
deploy:
  multi_region: true
  canary: required
observability:
  tracing: opentelemetry
  slo_dashboard: required
ai:
  vector_store: turbopuffer    # pgvector hits limits; revisit
queue:
  engine: cloud-tasks-or-sqs   # BullMQ scaling concerns at this tier
```

### Constraint-driven overrides

| Constraint | Overrides |
|---|---|
| `ai_heavy` | `database.pgvector: true`, `ai.cost_tracking: required`, add `ai-features` skill phase, `observability.token_metrics: required` |
| `realtime` | `backend.framework: hono-or-fastify` (Next.js API routes weak for websockets), `cache.required: true`, add `realtime: { provider: liveblocks-or-partykit-or-self-hosted-ws }` |
| `regulated` | `auth.default: auth0`, `database.encryption_at_rest: required`, `observability.audit_log: required`, `security.csp: enforced`, `secrets_manager: provider-native`, `compliance: { soc2: in-progress, hipaa: if-health }` |
| `multi_tenant_b2b` | `database.row_level_security: required`, `auth.default: clerk-or-workos`, `feature_flags: required` |
| `eu_global_billing` | `payments.provider: paddle` (MoR handles VAT), or stripe + stripe-tax |
| `mobile_first` | `frontend.responsive_priority: mobile-first`, may add `native: { framework: expo }` later |
| `data_heavy` | `database.olap: { engine: clickhouse-or-bigquery, ingestion: redpanda-or-kinesis }` |

Apply each override that flips on. If two overrides conflict, prefer
the more specific (e.g. `regulated` overrides `multi_tenant_b2b` for
auth).

---

## Phase 3 — Decision rationale

For every choice that diverges from the default matrix, record a
one-line ADR-style rationale:

```
- chose `paddle` over `stripe` because constraint `eu_global_billing` is set (VAT handled by MoR)
- chose `lucia` over `clerk` because `regulated=false` and tier=`preview` (cost)
- chose `buildkite` over `github-actions` because `BK_API_TOKEN` present and CI cost is wedge-relevant
- chose `pgvector` over `turbopuffer` because tier=`launch` and embedding count < 10M
```

For choices that match the default, do **not** add a rationale — keeps
the doc skim-readable.

---

## Phase 4 — Negative space (what is NOT in the stack)

Declare what we will not use, and why. This is the equivalent of the
wedge's anti-axis and is enforced by downstream skills:

```yaml
not_in_stack:
  - kubernetes: "preview tier; Cloud Run is sufficient"
  - graphql: "REST + Zod end-to-end is simpler for this surface"
  - microservices: "single-flow MVP, monolith wins"
  - kafka: "BullMQ + Redis sufficient until volume justifies"
  - sendgrid: "Resend is the 2026 default; SendGrid retired"
  - bcrypt: "argon2id is the 2026 password-hashing default"
  - github-actions: "buildkite cheaper at this org's scale"
```

`backend-developer`, `cicd`, `deployer` etc. will refuse to introduce
anything in `not_in_stack` without rerunning this skill.

---

## Phase 5 — Output: `docs/00-tech-stack.md`

```markdown
# Tech Stack Contract — <product name>

## Date: <YYYY-MM-DD>
## Stack version: 2026-Q2
## Scale tier: <toy | preview | launch | scale>
## Wedge: <one-sentence wedge>
## Constraints: <comma list of active constraints, or "none">

> This document is the **binding contract** for tech choices. Every
> downstream skill reads it. To change a vendor or pin, rerun
> `tech-stack-selector`. Do not silently substitute.

## 1. Stack matrix

```yaml
<the resolved YAML from Phase 2>
```

## 2. Decisions (deltas from default matrix)

<bullet list from Phase 3>

## 3. Negative space (not in stack)

<the not_in_stack block from Phase 4>

## 4. Quarterly review

Stack version pins are reviewed each quarter. Next review: <YYYY-MM-DD + 90 days>.

## 5. How downstream skills use this

| Skill | Reads from contract |
|---|---|
| designer | runtime, frontend, backend, database, cache, queue, ai, security |
| backend-developer | runtime, backend, database, validators, auth, ai |
| frontend-developer | frontend (framework, css, state, forms, ui_kit) |
| db-migrator | database (engine, version, pgvector) |
| ux-designer | frontend.css, frontend.ui_kit |
| api-docs | backend.validators, backend.framework |
| email-templates | email |
| background-jobs | queue, cache |
| analytics | analytics |
| observability | observability, ai (token metrics) |
| cicd | ci |
| deployer | deploy, cloud, iac |
| auth-engineer | auth, security |
| ai-features | ai (provider, models, vector_store, eval) |
```

---

## Phase 6 — Self-critique

Before committing, re-read the resolved contract and check:

- [ ] Every override has a one-line rationale.
- [ ] Tier deltas applied (toy ≠ launch).
- [ ] No constraint flag dropped on the floor.
- [ ] No vendor named that the org doesn't have credentials for (check `~/.bashrc` env vars referenced in the contract).
- [ ] Versions are pinned to majors (not "latest").
- [ ] `not_in_stack` is non-empty (declares at least 3 retired defaults).

If any check fails, mark the doc `Status: DRAFT` and surface the gap.

---

## Git commit & push

```bash
git add docs/00-tech-stack.md
git commit -m "feat: lock tech stack contract for $(jq -r .scale_tier state/state.json) tier"
git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
```

---

## Completion summary

Print:

```
## Tech Stack Locked

- Scale tier:          <tier>
- Active constraints:  <list>
- Frontend:            <framework@version> + <css>
- Backend:             <framework> + <orm@version> + <validators>
- Database:            <engine@version>  pgvector=<bool>
- Auth:                <provider>
- AI:                  <provider> + <vector_store>
- CI:                  <provider>
- Deploy target:       <target>
- Cloud:               <provider>
- Negative space:      <count> entries
- Status:              <LOCKED | DRAFT>
```
