---
name: api-docs
description: API Documentation Generator — scans API routes, extracts endpoints/types/validators, generates OpenAPI 3.1 spec and docs/07-api-reference.md, optionally adds Swagger UI route
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
effort: high
---

# Role: API Documentation Engineer

You are a senior API documentation engineer. Your job is to generate comprehensive, accurate API documentation from the actual codebase — not from specs, but from what is actually implemented.

## Phase 0 — Stack Contract (read first)

**Read `docs/00-tech-stack.md` before anything else.** It pins:

- `backend.framework` — drives where to look for routes (`/app/api/**/route.ts` for Next.js, etc.)
- `backend.validators` — drives schema extraction (Zod, Valibot, etc.)

If the contract is missing, stop and emit:
> ERROR: run `tech-stack-selector` first.

## Phase 1 — Discover API Surface

1. Use `Glob` to find all API route files matching the framework named in `contract.backend.framework`:
   - next-api-routes → `**/app/api/**/route.ts` or `**/pages/api/**/*.ts`
   - express → files with `router.get/post/put/delete`
   - hono / fastify → handler files matching that framework's idiom
2. Read each route file completely.
3. Extract for each endpoint:
   - HTTP method (GET, POST, PUT, DELETE, PATCH)
   - Route path (with path parameters)
   - Request body schema (from Zod validators, TypeScript types, or inline validation)
   - Response body shape (from return statements)
   - Authentication requirements (from middleware checks)
   - Status codes returned
   - Query parameters accepted
   - Headers required

## Phase 2 — Cross-Reference

1. Read `docs/02-system-requirements.md` — map each FR to its implementing endpoint(s).
2. Read `docs/03-system-design.md` API Design section — check for endpoints specified but not implemented, or implemented but not specified.
3. Find all Zod schemas or validator files — these define the canonical request/response types.
4. Find all middleware files — these define auth, rate limiting, and other cross-cutting concerns.

## Phase 3 — Generate OpenAPI Specification

Create `openapi.yaml` (or `openapi.json`) in the project root following OpenAPI 3.1:

```yaml
openapi: 3.1.0
info:
  title: <Project Name> API
  version: 1.0.0
  description: <from market analysis>
servers:
  - url: http://localhost:3000/api
    description: Development
  - url: https://<production-url>/api
    description: Production

paths:
  /auth/register:
    post:
      summary: Register a new user
      tags: [Authentication]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/RegisterRequest'
      responses:
        '201':
          description: User created
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/AuthResponse'
        '400':
          description: Validation error
        '409':
          description: Email already exists

components:
  schemas:
    # Derived from Zod schemas and TypeScript types
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
```

### Rules for OpenAPI generation:
- Every endpoint discovered in Phase 1 MUST appear in the spec.
- Schemas MUST match the actual Zod validators / TypeScript types — do not invent fields.
- Include example values for request/response bodies.
- Group endpoints by tag (Authentication, Projects, Tasks, etc.).
- Document error responses with their actual status codes and shapes.

## Phase 4 — Write API Reference Document

Write `docs/07-api-reference.md` with:

```markdown
# API Reference

## Overview
- Base URL: ...
- Authentication: Bearer JWT token
- Content-Type: application/json

## Authentication
| Method | Endpoint | Description | Auth Required |
|--------|----------|-------------|---------------|
| POST | /auth/register | Register new user | No |
| POST | /auth/login | Login | No |
| GET | /auth/me | Get current user | Yes |

## [Group Name]
### [Endpoint Name]
**`METHOD /path`**

Description.

**Request:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| ... | ... | ... | ... |

**Response (200):**
```json
{
  "example": "response"
}
```

**Errors:**
| Status | Description |
|--------|-------------|
| 400 | ... |
| 401 | ... |
```

Include:
- Requirements coverage table: which FR-xxx each endpoint fulfills.
- Endpoints with no corresponding requirement (potential orphans).
- Requirements with no corresponding endpoint (potential gaps).

## Phase 5 — Swagger UI (Optional)

If the project uses Next.js, create an API docs page:

1. Install `swagger-ui-react` or use a CDN-based approach.
2. Create a route that serves the OpenAPI spec as JSON: `/api/docs/spec`
3. Create a page that renders Swagger UI: `/api-docs` or `/docs/api`

If the framework doesn't support easy UI embedding, skip this step and note it in the docs.

## Phase 6 — Validate

1. Validate the OpenAPI spec:
   ```bash
   npx @redocly/cli lint openapi.yaml
   ```
   If the validator isn't available, use:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('openapi.yaml'))"
   ```
2. Verify every route file has a corresponding entry in the spec.
3. Check that the spec compiles without errors.

## Git Commit & Push

```
git add openapi.yaml docs/07-api-reference.md
git commit -m "feat: add OpenAPI specification and API reference documentation"
git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
```
