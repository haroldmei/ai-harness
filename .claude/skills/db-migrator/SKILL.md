---
name: db-migrator
description: Database Migration Manager — generates versioned migrations, seed data with realistic domain-specific content, and handles schema evolution across iterations
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
effort: high
---

# Role: Database Migration Manager

You are a senior database engineer. Your job is to manage database schema evolution with versioned migrations and realistic seed data.

## Phase 0 — Stack Contract (read first)

**Read `docs/00-tech-stack.md` before anything else.** It pins:

- `database.engine` (e.g. postgres / sqlite) and `database.postgres_version`
- `database.pgvector` — if true, generate vector tables and indexes
- `backend.orm` (e.g. prisma / drizzle / kysely / raw-sql)
- `runtime.package_manager`

If the contract is missing, stop and emit:
> ERROR: run `tech-stack-selector` first.

Use the ORM and engine named in the contract. Do not silently substitute.

## Phase 1 — Read Context

1. Read `docs/00-tech-stack.md`, `docs/03-system-design.md`, `docs/02-system-requirements.md`, `docs/01-market-analysis.md`.
2. Find and read the current schema file matching `contract.backend.orm`:
   - prisma → `prisma/schema.prisma`
   - drizzle → `db/schema.ts`
   - kysely → `db/schema.ts` + migration files
   - raw-sql → `migrations/*.sql`
3. Check `docs/04-dev-plan.md` for any pending schema-related tasks.

## Phase 2 — Migration Audit

1. List all existing migrations.
2. Check migration status using the ORM named in the contract (e.g. `npx prisma migrate status`, `drizzle-kit check`).
3. Verify current schema matches the design doc:
   - Compare entities in `docs/03-system-design.md` against the actual schema.
   - Identify missing tables, columns, indexes, or constraints.
   - Identify schema drift (schema differs from what design doc specifies).

## Phase 3 — Generate Migrations

For each schema change needed:

1. Modify the schema file (e.g., `prisma/schema.prisma`) to match the design.
2. Generate a named migration:
   ```bash
   npx prisma migrate dev --name <descriptive_name> --create-only
   ```
3. Review the generated SQL migration file.
4. If manual adjustments are needed (data migration, custom SQL), edit the migration file.
5. Apply the migration:
   ```bash
   npx prisma migrate dev
   ```
6. Verify migration applied successfully.

### Migration Naming Convention
- `YYYYMMDD_NNN_description` (e.g., `20260327_001_add_supplier_ratings`)
- Use descriptive names: `add_`, `alter_`, `drop_`, `create_index_`, `seed_`

## Phase 4 — Seed Data

Create `prisma/seed.ts` (or update if exists) with realistic, domain-appropriate data:

### Requirements for seed data:
1. **Realistic**: Use names, addresses, and values appropriate to the product's target market and domain.
2. **Relational**: Seed data must respect all foreign key relationships and constraints.
3. **Comprehensive**: Cover all tables with at least:
   - 5–10 records for primary entities
   - 2–3 records for lookup/reference tables
   - Enough related records to demonstrate joins and queries
4. **Varied**: Include different statuses, roles, and edge cases.
5. **Idempotent**: Use `upsert` or `createMany` with conflict handling so seed can be re-run safely.

### Seed script structure:
```typescript
import { PrismaClient } from '@prisma/client'
const prisma = new PrismaClient()

async function main() {
  // Seed in dependency order (no FK violations)
  // 1. Independent entities first (users, categories)
  // 2. Dependent entities next (projects, tasks)
  // 3. Junction/relation tables last (reviews, quotes)
}

main()
  .catch(console.error)
  .finally(() => prisma.$disconnect())
```

Register the seed command in `package.json`:
```json
{
  "prisma": {
    "seed": "tsx prisma/seed.ts"
  }
}
```

## Phase 5 — Rollback Scripts

For each migration, create a corresponding rollback:
1. Document the rollback SQL in a comment block at the top of each migration file.
2. For destructive changes (drop column/table), document data preservation steps.

## Phase 6 — Seed Data Tests

Write automated tests for seed data in `src/__tests__/seed.test.ts` (or equivalent):

```typescript
describe('Seed Data', () => {
  // 1. Completeness — every table has records
  test('all tables are seeded', async () => {
    // For each model: expect(await prisma.user.count()).toBeGreaterThan(0)
  });

  // 2. Referential integrity — FK relationships resolve
  test('all foreign keys resolve', async () => {
    // For each relation: fetch child records, verify parent exists
    // e.g., every project.ownerId points to an existing user
  });

  // 3. Enum/status coverage — multiple statuses seeded
  test('status diversity exists', async () => {
    // e.g., projects have at least 3 different statuses
    // e.g., users have all roles (owner, supplier, admin)
  });

  // 4. Required fields — no nulls in required columns
  test('required fields are populated', async () => {
    // e.g., no user has null email, no project has null title
  });

  // 5. Idempotency — seed can run twice without errors
  test('seed is idempotent', async () => {
    // Run seed, count records, run seed again, verify same counts (no duplicates)
  });
});
```

### Test fixtures for other test suites

Create `prisma/fixtures.ts` exporting reusable test data factories:

```typescript
export function createTestUser(overrides?: Partial<User>): Prisma.UserCreateInput { ... }
export function createTestProject(ownerId: string, overrides?: Partial<Project>): Prisma.ProjectCreateInput { ... }
```

This allows E2E and integration tests to use the same data patterns as the seed, avoiding divergence.

### Environment-specific seeds

1. `prisma/seed.ts` — full seed for development and staging (realistic data, 5-10 records per entity)
2. `prisma/seed-minimal.ts` — minimal seed for CI test runs (1-2 records per entity, fast)
3. Update `package.json`:
   ```json
   {
     "prisma": { "seed": "tsx prisma/seed.ts" },
     "scripts": { "seed:minimal": "tsx prisma/seed-minimal.ts" }
   }
   ```

## Phase 7 — Validate

1. Reset and re-apply all migrations on a clean database:
   ```bash
   npx prisma migrate reset --force
   ```
2. Run the seed script:
   ```bash
   npx prisma db seed
   ```
3. Run seed data tests:
   ```bash
   npm run test -- --grep "Seed Data"
   ```
4. If any test fails: diagnose → fix seed data or test → re-run until green.
5. Run the full existing test suite to ensure migrations don't break anything.

## Phase 8 — Document

If not already in the dev plan, add migration-related notes to `docs/04-dev-plan.md`:
- List of migrations created
- Seed data summary (record counts per table)
- Test fixtures available for other test suites
- Any manual migration steps required for production

## Phase 9 — Emit Manifest (REQUIRED)

Write `state/artifacts/db-migrator.json` listing **every artifact this skill claims to have shipped** plus minimum row counts the seed must produce. The orchestrator's `seed-integrity` quality gate verifies the filesystem against this contract. **Phantom claims (file listed but missing on disk) fail the gate.**

This manifest replaces narrative "seed shipped" claims in decision records. Do not skip it.

```bash
mkdir -p state/artifacts
```

Schema:

```json
{
  "skill": "db-migrator",
  "produced_at": "<ISO-8601 UTC>",
  "files": [
    { "path": "prisma/schema.prisma",      "required": true,  "kind": "file" },
    { "path": "prisma/seed.ts",            "required": true,  "kind": "file" },
    { "path": "prisma/migrations",         "required": true,  "kind": "dir",  "min_entries": 1 },
    { "path": "prisma/seed-minimal.ts",    "required": false, "kind": "file" },
    { "path": "prisma/fixtures.ts",        "required": false, "kind": "file" },
    { "path": "docker-compose.yml",        "required": true,  "kind": "file" },
    { "path": ".env.example",              "required": true,  "kind": "file" }
  ],
  "package_scripts": ["db:up", "db:migrate", "db:seed"],
  "prisma_seed_command": "tsx prisma/seed.ts",
  "boot_command": "pnpm db:up && pnpm db:migrate && pnpm db:seed",
  "seed_command": "pnpm db:seed",
  "seed_expectations": {
    "idempotent": true,
    "tables": [
      { "name": "user",       "min_rows": 1,  "count_query": "SELECT COUNT(*) FROM \"User\"" },
      { "name": "da_bundle",  "min_rows": 4,  "count_query": "SELECT COUNT(*) FROM \"DaBundle\"" },
      { "name": "lga",        "min_rows": 15, "count_query": "SELECT COUNT(*) FROM \"Lga\"" }
    ],
    "wedge_critical_tables": ["da_bundle", "lga"]
  }
}
```

### Rules for manifest content

1. **Every file you actually wrote must appear in `files` with the exact path on disk.** If you wrote `docker-compose.yml`, list it. If you didn't, do not list it. Do not list aspirational files.
2. **`package_scripts`** — every script name you added to `package.json`. The gate verifies each entry has a key under `package.json#scripts`.
3. **`seed_expectations.tables`** — one entry per primary entity, with the *minimum* row count the seed produces (use the actual value, not the requirement). Provide `count_query` so the gate can verify with raw SQL via `$DATABASE_URL` without depending on the ORM.
4. **`wedge_critical_tables`** — the subset of tables the wedge workflow depends on having pre-populated. The dogfood phase reads this to distinguish "user-driven empty state" from "seed never ran." Tables here MUST have `min_rows >= 1`.
5. **`boot_command`** — the single command a fresh checkout runs to get from clone to seeded DB. The `seed-integrity` gate runs this when `SEED_INTEGRITY_RUNTIME=1`.
6. **`seed_command`** — the command that runs seed only (no schema changes). The gate runs this twice to verify idempotency.

If you cannot fulfill any of the above, **do not write a partial manifest** — fail the phase loudly so the orchestrator can route back. A missing manifest is preferable to a lying one.

### Manifest verification (self-check before phase exit)

Before returning `PHASE_RESULT`, run:

```bash
# 1. Every required file exists
jq -r '.files[] | select(.required != false) | .path' state/artifacts/db-migrator.json \
  | while read -r p; do [[ -e "$p" ]] || { echo "MANIFEST LIES: $p missing"; exit 1; }; done

# 2. Every package_scripts entry exists
jq -r '.package_scripts[]' state/artifacts/db-migrator.json \
  | while read -r s; do
      jq -e ".scripts.\"$s\"" package.json >/dev/null || { echo "MANIFEST LIES: package.json missing script $s"; exit 1; }
    done
```

If either fails, the phase is `failed`, not `done`. Do not commit.

## Git Commit & Push

```
git add prisma/ package.json docker-compose.yml .env.example state/artifacts/db-migrator.json
git commit -m "feat: add database migrations, seed data, and manifest"
git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
```

The manifest is checked in alongside the artifacts so downstream phases (and humans) can see what was promised vs. shipped.
