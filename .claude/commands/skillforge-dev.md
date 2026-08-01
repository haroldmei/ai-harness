# Anti Plagiarism AI — Feature Development Skill

You are a senior full-stack engineer working on **Anti Plagiarism AI**, an AI-native adaptive learning platform. Your job is to implement or improve a specific feature/requirement described in `$ARGUMENTS`, then iterate until all relevant tests pass.

---

## PHASE 0 — Load Project Context

Before writing any code, read and internalize:

1. **CLAUDE.md** — project conventions, risk zones, architectural constraints (always read first)
2. **System Design**: `docs/04-system-design.md` — tech stack, data model, API contracts
3. **SRS**: `docs/03-srs.md` — formal requirements and acceptance criteria
4. **Market Analysis** + **Product Concept**: `docs/01-market-analysis.md`, `docs/02-product-idea.md` — only when the task involves new product surface or user-facing decisions

CLAUDE.md is the single source of truth for conventions. Read it first — it tells you how to validate, what's high-risk, and what rules can't be inferred from config files.

---

## PHASE 1 — Understand the Task

Parse `$ARGUMENTS` to extract:
- **Feature/requirement name** — what is being built or improved
- **Scope** — backend, frontend, or both
- **Acceptance criteria** — explicit or implied from SRS/design docs

If `$ARGUMENTS` is empty, ask the user for a task description before proceeding.

Cross-reference the task against the SRS (`docs/03-srs.md`) to find:
- The formal requirement ID(s) it satisfies
- Non-functional requirements that apply (performance, security, scalability)
- Edge cases mentioned in the spec

---

## PHASE 2 — Explore Existing Implementation

Use Glob and Grep to discover relevant code. Start narrow, expand only as needed:

- Find related models, endpoints, services, schemas in `backend/app/`
- Find related components, pages, hooks, stores in `frontend/src/`
- Find existing tests for the areas you'll touch

Read all files directly relevant to the task before modifying anything. Understand data flow end-to-end.

---

## PHASE 3 — Plan

Before writing any code, output a concise implementation plan:

```
TASK: <task name>
SRS REQ: <requirement IDs>

CHANGES:
  backend/
    - <file>: <what and why>
  frontend/
    - <file>: <what and why>

TESTS TO ADD/MODIFY:
  - <test file>: <what it covers>

RISKS / EDGE CASES:
  - <list any non-obvious concerns>
```

Keep the plan tight — only include files that actually need to change.

---

## PHASE 4 — Implement

Follow these rules strictly:

### Code quality
- Match the existing code style, patterns, and naming conventions exactly
- No new dependencies unless absolutely necessary — check `pyproject.toml` and `package.json` first
- Backend: async throughout, Pydantic v2 schemas, proper error handling with HTTPException
- Frontend: TypeScript strict mode, React hooks, Zustand for global state, React Query for server state, Tailwind CSS only
- Security: validate all inputs at API boundaries, never expose internal errors to clients, use parameterised queries

### Architecture constraints (see CLAUDE.md for full list)
- All AI calls go through `call_with_retry` in `backend/app/services/ai_call.py` — never call provider SDKs directly
- BKT proficiency updates must use the formula in `docs/04-system-design.md`
- Role checks must use the dependency injection pattern (`get_current_user` + role assertion)
- Org-scoping is mandatory on all multi-tenant queries — missing `WHERE org_id = …` is a data-leak bug

### What NOT to do
- Do not refactor code outside the task scope
- Do not add docstrings or comments to unchanged code
- Do not add error handling for scenarios that cannot occur
- Do not create abstractions for one-off operations

---

## PHASE 5 — Write Tests

For every changed file, write or update tests:

**Backend tests** (`backend/tests/`):
- Unit tests in `tests/unit/` — test service logic with mocked dependencies
- Integration tests in `tests/integration/` — test API endpoints end-to-end against real DB (SQLite in CI)
- Use `pytest-asyncio` for async tests
- Use `factory-boy` for test data factories
- Mock Anthropic API calls with `respx` or `unittest.mock`

**Frontend tests** (co-located `*.test.tsx` or `__tests__/`):
- Component tests with React Testing Library
- Hook tests with `renderHook`
- Mock API calls with MSW or `vi.mock`

Test naming: `test_<what>_<when>_<expected_outcome>` (backend) / `renders X when Y` (frontend).

Aim for tests that would catch real bugs — not just happy paths.

---

## PHASE 6 — Iterate Until Green

Run tests and fix failures in a loop:

### Backend
```bash
cd backend && pytest tests/unit/ -v -x 2>&1 | tail -40
cd backend && pytest tests/integration/ -v -x 2>&1 | tail -40
```

### Frontend
```bash
cd frontend && npm test -- --run 2>&1 | tail -40
```

### Rules for the iteration loop
1. Read the full error output before making any change
2. Fix the **root cause**, never silence errors with `# noqa`, `// eslint-disable`, `|| true`, or `try/except: pass`
3. If a test reveals a real bug in your implementation, fix the implementation — not the test
4. If a test is wrong (testing the wrong thing), fix the test — but explain why
5. After each fix, re-run **only the failing tests** first, then the full suite
6. Stop iterating when `pytest` exits 0 and `npm test` exits 0
7. If stuck after 3 iterations on the same error, step back and re-read the relevant SRS requirement and system design section — the solution is usually there

---

## PHASE 7 — Final Checklist

Before declaring done, verify:

- [ ] All new/modified backend tests pass (`pytest tests/ -v`)
- [ ] All new/modified frontend tests pass (`npm test -- --run`)
- [ ] No regressions in the existing test suite
- [ ] Linting clean: `cd backend && ruff check app/` and `cd frontend && npm run typecheck`
- [ ] The feature satisfies the acceptance criteria from PHASE 1
- [ ] No secrets, credentials, or environment-specific values hardcoded
- [ ] API changes are backward-compatible (or explicitly noted as breaking)

---

## PHASE 8 — Summary

Output a brief summary in this format:

```
✅ DONE: <task name>

SRS requirements satisfied: <IDs>

Changes:
  backend/app/...  — <one-line description>
  backend/tests/... — <N tests added>
  frontend/src/...  — <one-line description>

Tests: <N> passed, 0 failed
Coverage delta: +X%

Next logical task: <what to build next, based on SRS>
```

**Session hygiene:** If this session exceeded ~30 turns, write a 3-sentence summary of key decisions
to `state/decisions/$(date -u +%Y%m%d)-<task-slug>.md` before ending. The next session can load this
instead of re-deriving context. See `docs/AGENT-HARNESS.md` for session lifecycle rules.
