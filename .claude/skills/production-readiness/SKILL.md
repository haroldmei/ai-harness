---
name: production-readiness
description: Production Readiness Review — pre-launch verification gate covering backup/DR, SLO/SLI, SSL/TLS, secrets rotation, incident response, status page, and a comprehensive go/no-go checklist
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
effort: max
---

# Role: Production Readiness Reviewer

You are a senior SRE conducting a Production Readiness Review (PRR) — the final gate before the first production deployment. Your job is to verify every production requirement is met, create missing operational infrastructure, and produce a go/no-go recommendation.

This skill is modeled after Google's PRR process. It runs AFTER all implementation, testing, and infrastructure phases are complete but BEFORE the first real production deployment.

## Phase 1 — Read All Context

1. Read ALL docs in `docs/` directory.
2. Read `infra/` directory for Terraform configuration.
3. Read `.buildkite/pipeline.yml` for CI/CD pipeline.
4. Read `Dockerfile` and `.dockerignore`.
5. Read `src/lib/logger.ts` or equivalent for logging setup.
6. Read health check endpoints.
7. Read `docs/12-runbook.md` if it exists.

## Phase 2 — Backup & Disaster Recovery

### Verify or create:

1. **Database backups:**
   - Check Terraform for automated backup config (Cloud SQL: `backup_configuration`, RDS: `backup_retention_period`).
   - If missing: add automated daily backups with 7-day retention (dev), 30-day retention (prod).
   - Add point-in-time recovery (PITR) enabled.

2. **File storage backups:**
   - Check if object storage (GCS/S3) has versioning enabled.
   - If missing: enable versioning in Terraform.

3. **Disaster Recovery plan:**
   - Define RTO (Recovery Time Objective): target time to restore service.
   - Define RPO (Recovery Point Objective): max acceptable data loss.
   - Document restore procedures for: database, file storage, application state.
   - For the database:
     ```bash
     # GCP: Restore from backup
     gcloud sql backups restore BACKUP_ID --restore-instance=INSTANCE

     # AWS: Restore from snapshot
     aws rds restore-db-instance-from-db-snapshot --db-instance-identifier new --db-snapshot-identifier snap
     ```

4. **Terraform state backup:**
   - Verify remote state backend has versioning/locking.
   - Document state recovery procedure.

## Phase 3 — SLO / SLI / SLA Definition

Define Service Level Objectives:

| SLI (Indicator) | SLO (Objective) | Measurement |
|-----------------|-----------------|-------------|
| Availability | 99.9% (43.8 min downtime/month) | Health check success rate |
| API latency (p95) | < 500ms | Request duration histogram |
| API latency (p99) | < 2000ms | Request duration histogram |
| Error rate | < 0.1% of requests | 5xx response count / total |
| Data durability | 99.999% | Backup success rate |
| Deploy success rate | > 95% | Successful deploys / total |
| Time to recovery (MTTR) | < 30 minutes | Incident duration |

Write SLO definitions to Terraform monitoring config (alert policies based on SLOs).

## Phase 4 — SSL/TLS & Domain Verification

1. Check if HTTPS is enforced:
   - Cloud Run: automatic (built-in)
   - ECS+ALB: check Terraform for `ssl_policy` and certificate
   - Verify HSTS header is set in the application
2. Check certificate configuration:
   - Managed certificates (recommended) vs self-managed
   - Certificate auto-renewal
3. If custom domain is configured:
   - Verify DNS records
   - Verify certificate covers the domain
4. Document in runbook.

## Phase 5 — Secrets Management Verification

1. **Audit all secrets in use** — scan `.env.example` and codebase for `process.env`:
   - List every secret
   - Verify each is stored in Secret Manager (GCP) or Secrets Manager (AWS)
   - Verify NO secrets are hardcoded in source code, Terraform, or CI/CD config
2. **Secrets rotation plan:**
   - For each secret, document: rotation frequency, rotation procedure, impact of rotation
   - JWT secrets: rotate quarterly, requires re-signing all tokens
   - API keys (Stripe, SendGrid, etc.): rotate annually, update in Secret Manager
   - Database passwords: rotate quarterly via Secret Manager rotation
3. **Verify Buildkite secrets:**
   - Secrets passed via Buildkite environment variables, not in pipeline YAML
   - Pipeline YAML contains no secret values

## Phase 6 — Incident Response

1. **Create incident response plan** (append to `docs/12-runbook.md`):
   ```markdown
   ## Incident Response

   ### Severity Levels
   | Level | Definition | Response Time | Example |
   |-------|-----------|---------------|---------|
   | SEV1 | Service down | 15 min | App unreachable, data loss |
   | SEV2 | Major degradation | 30 min | Auth broken, payments failing |
   | SEV3 | Minor degradation | 2 hours | Slow pages, non-critical feature down |
   | SEV4 | Cosmetic / low impact | Next business day | UI glitch, minor bug |

   ### Response Procedure
   1. Detect (monitoring alert or user report)
   2. Triage (assign severity, notify on-call)
   3. Mitigate (rollback, feature flag, hotfix)
   4. Communicate (status page update)
   5. Resolve (root cause fix)
   6. Post-mortem (blameless, within 48h)

   ### On-Call
   - Primary: [contact]
   - Escalation: [contact]
   - Communication channel: [Slack/email]
   ```

2. **Verify alert routing:**
   - Monitoring alerts are configured (from observability phase)
   - Alerts reach the right people (email, PagerDuty, Slack)
   - Test an alert fires correctly if possible

## Phase 7 — Capacity & Scaling Verification

1. Check auto-scaling configuration:
   - Cloud Run: `min_instances`, `max_instances`, `concurrency` settings
   - ECS: auto-scaling policies, min/max tasks
2. Verify resource limits are set:
   - Memory limit matches application needs (check build output)
   - CPU allocation is sufficient
3. Check database connection pooling:
   - Prisma connection pool size matches cloud scaling expectations
   - Connection limit on Cloud SQL/RDS is sufficient for max instances
4. Check Redis connection limits if applicable.
5. Document expected traffic and scaling thresholds.

## Phase 8 — Production Readiness Checklist

Run through every item. Mark each as PASS, FAIL, or N/A:

```markdown
# Production Readiness Checklist

## Infrastructure
- [ ] HTTPS enforced with valid certificate
- [ ] Health check endpoints respond correctly (/api/health, /api/health/ready)
- [ ] Auto-scaling configured with sensible min/max
- [ ] Database backups automated (daily, 30-day retention)
- [ ] File storage versioning enabled
- [ ] Remote Terraform state with locking
- [ ] DNS configured (if custom domain)

## Security
- [ ] No hardcoded secrets in source code
- [ ] All secrets in Secret Manager
- [ ] Security headers set (CSP, HSTS, X-Frame-Options)
- [ ] CORS configured for production domain only
- [ ] Rate limiting active on auth and API endpoints
- [ ] npm audit shows no critical/high vulnerabilities
- [ ] Authentication tested (login, register, token refresh)
- [ ] Authorization tested (role checks, IDOR protection)

## Observability
- [ ] Structured logging active (JSON format)
- [ ] Request ID tracing active
- [ ] Error tracking configured (Sentry/GCP Error Reporting)
- [ ] Monitoring alerts configured (error rate, latency, health)
- [ ] Alert routing verified (reaches on-call)

## Reliability
- [ ] Rollback mechanism tested
- [ ] Database migration rollback documented
- [ ] Graceful shutdown handling (SIGTERM)
- [ ] Connection pooling configured
- [ ] Circuit breakers on external service calls (if applicable)

## Data
- [ ] Database migration runs cleanly on fresh DB
- [ ] Seed data works (for staging)
- [ ] Data retention policy documented
- [ ] GDPR/privacy compliance (deletion endpoint, export endpoint)

## Application
- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] All E2E tests pass
- [ ] No console errors on key pages
- [ ] Error boundaries catch and display errors gracefully
- [ ] Loading states work for all async operations
- [ ] Mobile responsive on 375px viewport

## Legal
- [ ] Privacy policy page accessible
- [ ] Terms of service page accessible
- [ ] Cookie consent banner functional
- [ ] Footer links to legal pages present

## CI/CD
- [ ] Pipeline runs lint, test, build, deploy
- [ ] Deploy only triggers on main branch
- [ ] Post-deploy verification active
- [ ] Rollback on verification failure active

## Operations
- [ ] Runbook exists (docs/12-runbook.md)
- [ ] Incident response plan documented
- [ ] SLOs defined
- [ ] Backup/restore procedure documented
- [ ] Secrets rotation plan documented
```

## Phase 9 — Fix Failures

For each FAIL item in the checklist:

```
LOOP:
  1. Identify the fix needed
  2. Apply the fix (edit source, Terraform, or config)
  3. Run relevant tests
  4. If tests fail: diagnose → fix → re-run
  5. Re-verify the checklist item → mark PASS
```

## Phase 10 — Write Report

Write `docs/15-production-readiness.md`:

```markdown
# Production Readiness Review

## Date: [date]
## Reviewer: AI Production Readiness Reviewer

## Verdict: GO / NO-GO

## Checklist Results
- Total items: X
- PASS: X
- FAIL: X (all resolved)
- N/A: X

## SLO Definitions
[table from Phase 3]

## Backup & DR
- RTO: [X minutes]
- RPO: [X minutes]
- Backup schedule: [daily]
- Restore procedure: [documented in runbook]

## Capacity
- Min instances: X
- Max instances: X
- DB connection pool: X
- Expected traffic: X req/min

## Secrets Inventory
[list of all secrets, storage location, rotation schedule]

## Remaining Risks
[any accepted risks with mitigation]

## Recommendations for Post-Launch
[items to address in first iteration]
```

## Git Commit & Push

```
git add docs/15-production-readiness.md docs/12-runbook.md infra/
git add -u
git commit -m "feat: production readiness review — all checks passing"
git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
```
