---
name: build-product
description: Full autonomous product builder — takes a product idea, runs all 26 phases (market analysis → product spec → SRS → system design → UX design → backend → frontend → DB migrations → background jobs → email templates → API docs → code review → security audit → E2E tests → performance → legal compliance → env management → CI/CD → infrastructure → observability → landing page → deployment safety → analytics → production readiness → iterate → loop) completely automatically without stopping
argument-hint: "<product idea>"
allowed-tools: WebSearch, WebFetch, Read, Write, Edit, Bash, Glob, Grep
effort: max
---

# Autonomous Product Builder

You are running a fully autonomous product development pipeline. You will take the product idea below and complete ALL twenty-six phases without stopping or asking for confirmation. Do not pause between phases. Do not ask clarifying questions. Make reasonable decisions and document them.

**Product idea:** $ARGUMENTS

---

## PHASE 1 — Market Analysis (CEO)

You are acting as CEO and market strategist.

1. Use `WebSearch` and `WebFetch` to research the market:
   - TAM / SAM / SOM estimates with data sources
   - Market growth trends
   - At least 5 direct and indirect competitors (name, pricing, strengths, weaknesses)
   - Market gaps and differentiation opportunities
   - Top 5 risks
2. Create `docs/` directory if needed.
3. Write the full market analysis report to `docs/01-market-analysis.md` with sections:
   Executive Summary, Problem Statement, Target Audience, Market Size, Market Trends, Competitor Analysis (matrix + profiles), Opportunities & Differentiation, Go-to-Market Wedge, Risk Assessment, Conclusion.
4. Commit and push:
   ```
   git init 2>/dev/null || true
   git add docs/01-market-analysis.md
   git commit -m "feat: add market analysis report"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 2.**

---

## PHASE 2 — Product Specification (Product Manager)

You are acting as a senior product manager.

1. Read `docs/01-market-analysis.md`.
2. Use `WebSearch` to research user behavior patterns for the target audience.
3. Define 3-5 user personas with goals, pain points, and technical proficiency.
4. Create a user story map: epics → stories with Gherkin-style acceptance criteria (Given/When/Then).
5. Assign MoSCoW priority (Must/Should/Could/Won't) and effort estimates (S/M/L/XL).
6. Define MVP scope boundary (V1 vs V1.1 vs V2).
7. Define success metrics (KPIs with 30-day and 90-day targets).
8. Write `docs/01b-product-spec.md` with sections:
   Vision Statement, User Personas, User Story Map, MVP Scope Definition, Success Metrics, Assumptions & Risks.
9. Commit and push:
   ```
   git add docs/01b-product-spec.md
   git commit -m "feat: add product specification with user stories and MVP scope"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 3.**

---

## PHASE 3 — System Requirements (Analyst)

You are acting as a senior system analyst.

1. Read `docs/01-market-analysis.md` and `docs/01b-product-spec.md`.
2. Derive functional requirements (each with ID like FR-001, description, priority, testable acceptance criteria).
3. Derive non-functional requirements (quantified where possible).
4. Write use cases for all major user interactions.
5. Write `docs/02-system-requirements.md` following IEEE 830 structure:
   Introduction, Overall Description, Functional Requirements, Non-Functional Requirements, Use Cases, Data Requirements, External Interface Requirements, Assumptions.
6. Commit and push:
   ```
   git add docs/02-system-requirements.md
   git commit -m "feat: add system requirements specification"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 4.**

---

## PHASE 4 — System Design (Architect)

You are acting as a principal software architect.

1. Read `docs/01-market-analysis.md`, `docs/01b-product-spec.md`, and `docs/02-system-requirements.md`.
2. Choose and justify an architecture style.
3. Design all components, data models, APIs, infrastructure, and security.
4. Write `docs/03-system-design.md` with Mermaid diagrams, including:
   Architecture Overview, Component Design, Data Design, API Design, Infrastructure Design, Security Design, Scalability & Resilience, Technology Stack Summary, Requirements Traceability Matrix.
5. Commit and push:
   ```
   git add docs/03-system-design.md
   git commit -m "feat: add system design specification"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 5.**

---

## PHASE 5 — UX Design (UX/UI Designer)

You are acting as a senior UX/UI designer.

1. Read `docs/01-market-analysis.md`, `docs/01b-product-spec.md`, `docs/02-system-requirements.md`, and `docs/03-system-design.md`.
2. Use `WebSearch` to research competitor UIs and domain-specific UI patterns.
3. Define a complete design system: color palette (WCAG AA), typography, spacing, component inventory, motion.
4. Create ASCII wireframes for each major page.
5. Create Mermaid user flow diagrams for critical paths.
6. Define accessibility requirements (WCAG 2.1 AA, keyboard nav, screen reader, focus management).
7. Generate a Tailwind theme config snippet.
8. Write `docs/03b-ux-design.md`.
9. Commit and push:
   ```
   git add docs/03b-ux-design.md
   git commit -m "feat: add UX design system, wireframes, and accessibility requirements"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 6.**

---

## PHASE 6 — Backend Development (Backend Developer)

You are acting as a senior backend developer.

1. Read all docs (01, 01b, 02, 03, 03b).
2. Create `docs/04-dev-plan.md` — numbered task list covering API routes, authentication, authorization, business logic, database queries, with acceptance criteria and test types (unit/integration). Tag each task `[Backend]`.
3. Scaffold the project backend (directory structure, dependency files, test framework config).
4. For each backend task, run this loop until complete:
   - Implement the API route, service, or business logic
   - Write unit and integration tests
   - Run tests via `Bash`
   - If failures: diagnose → fix → re-run (repeat until green)
   - Mark task ✅ in dev plan, move to next
5. After all backend tasks: run the full backend test suite. Fix any failures.
6. Do not advance to Phase 7 until all backend tests are green.
7. Commit and push:
   ```
   git add .
   git commit -m "feat: implement backend — API routes, auth, business logic, all tests passing"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 7.**

---

## PHASE 7 — Frontend Development (Frontend Developer)

You are acting as a senior frontend developer.

1. Read `docs/03b-ux-design.md` for design system, wireframes, and accessibility requirements.
2. Merge the Tailwind theme config from `docs/03b-ux-design.md` into the project.
3. Build a reusable component library (buttons, inputs, modals, navigation, data display, feedback) matching the design system.
4. Implement all application pages from the wireframes with responsive layouts.
5. Wire up state management, form validation, and API integration.
6. Implement error boundaries, loading states, and empty states for every page.
7. Ensure WCAG 2.1 AA accessibility (keyboard nav, ARIA labels, focus management, contrast).
8. Write component tests for all reusable components and page integration tests.
9. Run the full test suite. Fix any failures until green.
10. Commit and push:
    ```
    git add .
    git commit -m "feat: implement frontend — component library, pages, state management, accessibility"
    git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
    ```

**Do not stop. Proceed immediately to Phase 8.**

---

## PHASE 8 — Database Migrations & Seed Data (DB Migrator)

You are acting as a senior database engineer.

1. Read `docs/03-system-design.md` for data models and `docs/01-market-analysis.md` for domain context.
2. Audit current schema vs design doc — identify drift.
3. Generate versioned migrations for any missing tables, columns, indexes, or constraints.
4. Create seed data script with realistic, domain-appropriate data (5-10 records per entity, all FK relationships respected, idempotent).
5. Apply migrations and run seed.
6. Run the test suite to verify nothing broke.
7. Commit and push:
   ```
   git add prisma/ package.json
   git commit -m "feat: add database migrations and seed data"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 9.**

---

## PHASE 9 — Background Jobs (Background Jobs Engineer)

You are acting as a senior background jobs engineer.

1. Read `docs/03-system-design.md` and `docs/02-system-requirements.md` for async processing needs.
2. Set up BullMQ with Redis (or platform-native equivalent) for job queues.
3. Implement job processors for async tasks (email sending, file processing, AI generation, webhook delivery, data aggregation).
4. Create scheduled cron jobs for recurring tasks (cleanup, digest emails, report generation, expiry alerts).
5. Add retry logic with exponential backoff, dead letter queues, and failure alerting.
6. Write unit tests for all job processors. Run tests and fix until green.
7. Commit and push:
   ```
   git add src/lib/jobs/ package.json
   git add -u
   git commit -m "feat: add background job queues, cron jobs, and async processing"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 10.**

---

## PHASE 10 — Email Templates (Email Engineer)

You are acting as a senior email engineer.

1. Read `docs/01b-product-spec.md` and `docs/03-system-design.md` for transactional email needs.
2. Create responsive HTML email templates for all transactional emails (welcome, verification, password reset, notifications, digests) using inline-styled HTML.
3. Configure email service integration (SendGrid or SES) with environment-based config.
4. Implement email sending service with template rendering, variable substitution, and error handling.
5. Add email preference management (unsubscribe, frequency settings).
6. Wire email sending through the background job queue from Phase 9.
7. Write tests for template rendering and email service. Run tests and fix until green.
8. Commit and push:
   ```
   git add src/lib/email/ package.json
   git add -u
   git commit -m "feat: add transactional email templates and email service"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 11.**

---

## PHASE 11 — API Documentation (API Docs Engineer)

You are acting as an API documentation engineer.

1. Use `Glob` to find all API route files. Read each one.
2. Extract: HTTP method, path, request/response types (from Zod validators), auth requirements, status codes.
3. Cross-reference against `docs/02-system-requirements.md` (FR coverage) and `docs/03-system-design.md` (API design).
4. Generate `openapi.yaml` (OpenAPI 3.1) with all endpoints, schemas, security schemes, and examples.
5. Write `docs/07-api-reference.md` with endpoint tables, request/response examples, and requirements coverage.
6. Validate the OpenAPI spec.
7. Commit and push:
   ```
   git add openapi.yaml docs/07-api-reference.md
   git commit -m "feat: add OpenAPI specification and API reference documentation"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 12.**

---

## PHASE 12 — Code Review & Fix (Reviewer)

You are acting as a senior code reviewer.

1. Use `Glob` + `Read` to review every source file against correctness, security, performance, reliability, test coverage, code quality, requirements coverage, and design conformance.
2. Write `docs/05-code-review.md` with all issues (ID, severity, file+line, description, impact, fix, status: Open).
3. For each issue (highest severity first): apply fix → run tests → mark Fixed.
4. Run the full test suite. Confirm 0 failures.
5. Update `docs/05-code-review.md` Summary.
6. Commit and push:
   ```
   git add .
   git commit -m "fix: resolve all code review issues, all tests passing"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 13.**

---

## PHASE 13 — Security Audit (Security Engineer)

You are acting as a senior application security engineer.

1. Run `npm audit`. Scan for hardcoded secrets. Audit auth & authorization. Check injection vulnerabilities. Verify HTTP security headers. Check data protection. Review infrastructure security.
2. Fix all Critical and High severity issues.
3. Write `docs/09-security-audit.md` with OWASP Top 10 checklist and findings.
4. Run test suite after fixes. Confirm 0 failures.
5. Commit and push:
   ```
   git add docs/09-security-audit.md
   git add -u
   git commit -m "feat: security audit and fix critical vulnerabilities"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 14.**

---

## PHASE 14 — E2E Testing (E2E Test Engineer)

You are acting as a senior E2E test engineer.

1. Install Playwright if not present. Create `playwright.config.ts` with desktop and mobile viewports.
2. Write Playwright test suites in `e2e/`: auth, critical flows, error states, navigation, data integrity.
3. Run and fix loop until all tests pass.
4. Write `docs/08-e2e-test-report.md`.
5. Commit and push:
   ```
   git add e2e/ playwright.config.ts docs/08-e2e-test-report.md package.json
   git commit -m "feat: add Playwright E2E test suite with full coverage"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 15.**

---

## PHASE 15 — Performance Testing & Optimization (Performance Engineer)

You are acting as a senior performance engineer.

1. Run production build, analyze bundle sizes. Scan DB queries for N+1, missing indexes, over-fetching.
2. Create k6 load test scripts in `perf/`. Apply optimizations. Run tests after each fix.
3. Write `docs/10-performance-report.md`.
4. Commit and push:
   ```
   git add perf/ docs/10-performance-report.md
   git add -u
   git commit -m "feat: add performance tests and optimizations"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 16.**

---

## PHASE 16 — Legal Compliance (Legal Engineer)

You are acting as a legal compliance engineer.

1. Read all docs and scan codebase for data collection, cookies, tracking, and third-party integrations.
2. Generate privacy policy page, terms of service page, and cookie policy page at legal routes.
3. Create cookie consent banner component (necessary/analytics/marketing categories, stores preference, blocks tracking until consent).
4. Add registration checkbox for ToS + Privacy Policy agreement.
5. Create `docs/13-data-retention-policy.md` with retention periods, deletion process, and export format.
6. Implement account deletion endpoint and data export endpoint.
7. Write tests for legal components. Run tests and fix until green.
8. Commit and push:
   ```
   git add src/app/ src/components/ docs/13-data-retention-policy.md
   git commit -m "feat: add privacy policy, terms of service, cookie consent, and compliance"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 17.**

---

## PHASE 17 — Environment Management (Env Manager)

You are acting as a senior DevOps engineer.

1. Scan codebase for all `process.env` references. Categorize as secrets vs config.
2. Create `.env.example` documenting ALL variables (no actual secrets).
3. Create `src/lib/config.ts` with typed config, validation of required vars at startup.
4. Create `docker-compose.yml` for local dev dependencies (PostgreSQL, Redis).
5. Create `infra/environments/dev.tfvars` and `infra/environments/prod.tfvars`.
6. Ensure `.gitignore` excludes `.env`, `.env.local`, `*.pem`, `*.key`.
7. Write `docs/14-environment-guide.md` with local setup instructions and env var table.
8. Run test suite to confirm nothing broke.
9. Commit and push:
   ```
   git add .env.example docker-compose.yml src/lib/config.ts docs/14-environment-guide.md
   git commit -m "feat: add environment management with dev/staging/prod separation"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 18.**

---

## PHASE 18 — CI/CD Pipeline (DevOps Engineer)

You are acting as a senior DevOps engineer.

Environment variables available: `$BK_API_TOKEN`, `$BUILDKITE_ORG`, `$DOCKER_USERNAME`, `$DOCKER_PASSWORD`, `$PROJECT_ID`.

1. Create production-optimized multi-stage `Dockerfile` and `.dockerignore`.
2. Create `.buildkite/pipeline.yml` with stages: lint → test → build docker → push docker → deploy.
3. Create `.buildkite/scripts/deploy.sh` (executable).
4. Create the Buildkite pipeline via API.
5. Validate YAML and Dockerfile.
6. Commit and push:
   ```
   git add Dockerfile .dockerignore .buildkite/
   git commit -m "feat: add Buildkite CI/CD pipeline and Dockerfile"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 19.**

---

## PHASE 19 — Infrastructure & Deployment (Infrastructure Engineer)

You are acting as a senior infrastructure engineer.

1. Choose cloud provider (check design doc, then CLI availability, default GCP if `$PROJECT_ID` set).
2. Generate Terraform in `infra/` with modules: compute, database, cache, storage, networking.
3. Create environment tfvars. Update deploy script with Terraform commands.
4. Validate with `terraform fmt` and `terraform validate` if available.
5. Commit and push:
   ```
   git add infra/ .buildkite/
   git commit -m "feat: add Terraform infrastructure for cloud deployment"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 20.**

---

## PHASE 20 — Observability (SRE)

You are acting as a senior site reliability engineer.

1. Create `src/lib/logger.ts` with structured JSON logging (pino).
2. Add request logging middleware and request ID middleware.
3. Create health check endpoints (`/api/health`, `/api/health/ready`).
4. Configure error tracking. Add Terraform monitoring resources (alerts for error rate, latency, health).
5. Write `docs/11-observability.md` with debugging playbook.
6. Run test suite. Confirm 0 failures.
7. Commit and push:
   ```
   git add src/lib/logger.ts src/app/api/health/ docs/11-observability.md infra/modules/monitoring/
   git add -u
   git commit -m "feat: add observability — structured logging, health checks, monitoring"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 21.**

---

## PHASE 21 — Landing Page (Marketing Engineer)

You are acting as a marketing engineer.

1. Read `docs/01-market-analysis.md` and `docs/03b-ux-design.md`.
2. Create responsive, SEO-optimized landing page (hero, problem, features, social proof, CTA, footer).
3. Add SEO meta tags, OpenGraph, JSON-LD, `robots.txt`, `sitemap.xml`.
4. Verify build succeeds.
5. Commit and push:
   ```
   git add src/app/ public/
   git commit -m "feat: add marketing landing page with SEO optimization"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 22.**

---

## PHASE 22 — Deployment Safety (Deployment Safety Engineer)

You are acting as a deployment safety engineer.

1. Create `.buildkite/scripts/pre-deploy.sh`, `verify-deploy.sh`, and `rollback.sh`.
2. Update `.buildkite/pipeline.yml` with verify and rollback steps.
3. Write `docs/12-runbook.md` with deployment flow, health checks, rollback procedures, and escalation.
4. Commit and push:
   ```
   git add .buildkite/ docs/12-runbook.md
   git commit -m "feat: add deployment verification, automatic rollback, and runbook"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 23.**

---

## PHASE 23 — Analytics (Analytics Engineer)

You are acting as a senior analytics engineer.

1. Read `docs/01b-product-spec.md` for KPIs and success metrics.
2. Set up analytics service (PostHog, GA4, or Mixpanel).
3. Define tracking plan: user lifecycle events, core product events, revenue events, engagement events.
4. Create analytics provider component that respects cookie consent from Phase 16.
5. Instrument client-side (page views, form submissions, feature usage) and server-side (API events, payments).
6. Define conversion funnels (signup-to-value, quote-to-completion).
7. Create admin analytics dashboard page with overview metrics, funnels, and time-series charts.
8. Write tests for analytics integration. Run tests and fix until green.
9. Commit and push:
   ```
   git add src/lib/analytics/ src/components/providers/ src/app/admin/analytics/
   git commit -m "feat: add analytics instrumentation and internal dashboard"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 24.**

---

## PHASE 24 — Production Readiness Review (SRE)

You are acting as a senior SRE conducting a Production Readiness Review.

1. **Backup & DR:** Verify database backups (daily, 30-day retention), file storage versioning, PITR enabled. Add to Terraform if missing. Define RTO/RPO.
2. **SLO/SLI:** Define availability (99.9%), latency (p95 < 500ms), error rate (< 0.1%) targets. Add alert policies.
3. **SSL/TLS:** Verify HTTPS enforced, HSTS header set, certificate auto-renewal.
4. **Secrets:** Audit all secrets are in Secret Manager (not hardcoded). Document rotation plan.
5. **Incident Response:** Add incident response plan to `docs/12-runbook.md` (severity levels, response procedure, escalation).
6. **Capacity:** Verify auto-scaling, resource limits, DB connection pooling.
7. **Checklist:** Run through 40-item production readiness checklist (infrastructure, security, observability, reliability, data, application, legal, CI/CD, operations). Fix all FAIL items.
8. Write `docs/15-production-readiness.md` with GO/NO-GO verdict, checklist results, SLO definitions, backup/DR summary, and remaining risks.
9. Commit and push:
   ```
   git add docs/15-production-readiness.md docs/12-runbook.md infra/
   git add -u
   git commit -m "feat: production readiness review — all checks passing"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

**Do not stop. Proceed immediately to Phase 25.**

---

## PHASE 25 — Iterative Refinement (Product Iteration Engineer)

You are acting as a product iteration engineer running the first refinement cycle.

1. **Market Re-Analysis:** Use `WebSearch`/`WebFetch` for new competitors, trends, user feedback. Append "Iteration 1 Update" to `docs/01-market-analysis.md`.
2. **Gap Analysis:** Extract all FR/NFR IDs, scan codebase, classify each as Implemented/Partial/Missing/Divergent. Write `docs/06-gap-analysis.md`.
3. **Plan Updates:** Add new FR/NFR entries (tagged `[Iteration 1]`). Append new tasks to `docs/04-dev-plan.md`.
4. **Implementation:** For each new task, run implement → test → fix loop until tests pass.
5. **Full Verification:** Run ALL tests (unit + integration + smoke + E2E). Run `npm audit` for security. Check build for bundle regressions. Fix any failures.
6. **Iteration Log:** Create `docs/iterations/001-issue-<N>-<slug>.md` (per-iteration file; see CLAUDE.md for naming convention) with findings, gaps addressed, test results. Then run `agent iteration index` to regenerate `docs/06-iteration-log.md`.
7. Commit and push:
   ```
   git add .
   git commit -m "feat: iteration 1 — gap analysis, new requirements, and implementation"
   git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
   ```

---

## PHASE 26 — Iteration Loop

Phase 25 can be repeated by invoking `/iterate` independently. Each subsequent run increments the iteration number, appends to the iteration log, and runs the full quality verification suite.

---

## Completion

When all 26 phases are done, print a summary:

```
## Build Complete

### Planning & Design
- docs/01-market-analysis.md     ✅  market analysis complete
- docs/01b-product-spec.md       ✅  product spec with user stories
- docs/02-system-requirements.md ✅  IEEE 830 SRS
- docs/03-system-design.md       ✅  system architecture
- docs/03b-ux-design.md          ✅  UX design system & wireframes

### Implementation
- docs/04-dev-plan.md            ✅  all tasks complete
- Backend (API, auth, logic)     ✅  all backend tests passing
- Frontend (components, pages)   ✅  all frontend tests passing
- Database migrations & seed     ✅  schema current, seed data loaded
- Background jobs & cron         ✅  async processing configured
- Email templates & service      ✅  transactional emails ready
- openapi.yaml                   ✅  API fully documented
- docs/07-api-reference.md       ✅  API reference

### Quality Assurance
- docs/05-code-review.md         ✅  all issues resolved
- docs/09-security-audit.md      ✅  security hardened
- docs/08-e2e-test-report.md     ✅  E2E tests passing
- docs/10-performance-report.md  ✅  performance optimized

### Legal & Compliance
- Privacy policy                 ✅  accessible
- Terms of service               ✅  accessible
- Cookie consent                 ✅  functional
- docs/13-data-retention-policy.md ✅  retention documented

### Infrastructure & Ops
- .env.example + config          ✅  environment management
- docker-compose.yml             ✅  local dev dependencies
- docs/14-environment-guide.md   ✅  environment guide
- Dockerfile + .buildkite/       ✅  CI/CD pipeline active
- infra/                         ✅  Terraform IaC ready
- docs/11-observability.md       ✅  logging, health checks, alerts
- Landing page                   ✅  SEO-optimized marketing page
- docs/12-runbook.md             ✅  deploy verification, rollback, incident response

### Analytics & Readiness
- Analytics instrumentation      ✅  event tracking, funnels, dashboard
- docs/15-production-readiness.md ✅  GO verdict, all checks passing

### Continuous Improvement
- docs/06-gap-analysis.md        ✅  iteration 1 complete
- docs/iterations/001-issue-N-slug.md ✅  iteration log started
- Test suite: ✅ all passing (unit + integration + smoke + E2E)
```
