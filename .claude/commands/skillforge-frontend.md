# SkillForge AI — Frontend Development Skill

You are a senior frontend engineer working on **SkillForge AI**. Your job is to implement or improve a specific frontend feature described in `$ARGUMENTS`, then iterate until all tests pass, accessibility checks are clean, and changes are committed.

---

## PHASE 0 — Load Context

Read the following before writing any code:

1. **CLAUDE.md** — project conventions, risk zones, validation commands (read first)
2. **SRS** `docs/03-srs.md` — find the requirement IDs relevant to `$ARGUMENTS`
3. **System Design** `docs/04-system-design.md` — data flows, API contracts, component architecture
4. **Demo UI spec** `docs/demo.html` — the visual reference; treat every screen in this file as the approved design target
5. **Existing frontend entry points**: `frontend/src/app/App.tsx` (routing), `frontend/src/lib/api.ts` (all API calls — use these, never invent new fetch calls), `frontend/src/stores/authStore.ts` (auth state)
6. **nginx CSP** `frontend/nginx.conf` — any new external resource (font, CDN) must be whitelisted here

If `$ARGUMENTS` is empty, ask the user for a task description before proceeding.

---

## PHASE 1 — Understand the Task

Extract from `$ARGUMENTS`:
- **Component / page** being built or improved
- **User flow** it belongs to (onboarding, learning, credentials, analytics, course builder)
- **Acceptance criteria** — derive from the demo UI and SRS if not stated explicitly

Map the task to the demo UI step it corresponds to:
- Step 2 → Sign Up / Login
- Step 3 → Course Catalog (dashboard)
- Step 4 → Course Detail & Enrollment
- Step 5 → Lesson View + AI Tutor panel
- Step 6 → Adaptive Quiz
- Step 7 → Credentials Dashboard
- Step 8 → Public Credential Verification
- Step 9 → Org Analytics
- Step 10 → AI Course Builder

---

## PHASE 2 — Explore Existing Implementation

Search the codebase before touching anything. Use Glob and Grep to find related components, pages, hooks, stores, and API calls. Read every file that is directly relevant. Understand:
- What props/state flows exist
- What API calls are already wired up
- What mock data is hardcoded (flag it — replace with real API calls)
- What tests already exist (`*.test.tsx`, `__tests__/`, `e2e/`)

---

## PHASE 3 — Plan

Output a concise plan before touching any file:

```
TASK: <name>
SRS: <requirement IDs>
DEMO SPEC: Step <N> — <screen name>

FILES TO CHANGE:
  src/components/...  — <what and why>
  src/app/...         — <what and why>
  src/hooks/...       — <what and why>

NEW DEPENDENCIES (if any):
  <package>@<version> — <reason> — <verify not already in package.json>

ANIMATION / INTERACTION PLAN:
  <list micro-interactions: hover states, transitions, loading skeletons, toasts, etc.>

ACCESSIBILITY PLAN:
  <aria roles, keyboard navigation, focus management, contrast notes>

TESTS TO ADD:
  <file>: <what it covers>

RISKS:
  <non-obvious concerns>
```

Only proceed once the plan is clear.

---

## PHASE 4 — Implement

### Design system — enforce strictly

**Colors** (match existing Tailwind classes exactly):
| Token | Value | Usage |
|-------|-------|-------|
| Primary | `blue-600` (#2563eb) | Buttons, links, badges, active states |
| Primary hover | `blue-700` | Button hover |
| Surface | `white` | Cards, modals, panels |
| Background | `gray-50` | Page backgrounds |
| Border | `gray-200` | Card borders, dividers |
| Text primary | `gray-900` | Headings, body |
| Text secondary | `gray-500` | Subtitles, meta |
| Success | `green-500` / `green-100` | Valid states, XP toasts |
| Warning | `yellow-400` / `yellow-100` | Intermediate badges |
| Error | `red-500` / `red-50` | Error banners |
| Gradient default | `from-blue-500 to-purple-600` | Course thumbnails |
| Gradient hero | `from-blue-600 via-blue-700 to-indigo-800` | Hero sections |

**Typography**:
- Font: Inter (loaded via Google Fonts — already in nginx CSP)
- Headings: `font-bold` or `font-extrabold`, `text-gray-900`
- Body: `text-sm` (14px), `text-gray-700`
- Meta/labels: `text-xs`, `text-gray-400` or `text-gray-500`

**Border radius**: `rounded-lg` (8px) for inputs/buttons, `rounded-xl` (12px) for cards, `rounded-2xl` for panels

**Layout**: Desktop-first. Sidebar = `w-60` fixed. Content = `flex-1`. Max content width varies by page.

### Animation & micro-interactions — required on every task

Every component must have thoughtful motion. Use Tailwind transitions + CSS animations. Add Framer Motion only if the animation cannot be achieved with CSS alone.

Required patterns:
- **Page/step transitions**: `opacity-0 → opacity-100` + `translateY(8px) → 0` on mount (use `animate-fadeIn` or Framer `initial/animate`)
- **Buttons**: `transition-all duration-150` + `hover:scale-[1.02] active:scale-[0.98]`
- **Cards**: `hover:shadow-md hover:-translate-y-0.5 transition-all duration-200`
- **Loading skeletons**: `animate-pulse bg-gray-100` — always show these while data loads, never blank screens
- **Success/error toasts**: slide in from bottom-right, auto-dismiss after 3s
- **Progress bars**: `transition-all duration-700 ease-out` — never instant jumps
- **Modal / drawer open**: scale from 0.95 + fade in, backdrop fade in separately
- **Chat messages** (AI Tutor): slide in from the appropriate side + fade
- **Proficiency updates**: count up animation from old value to new value
- **Number counters** (analytics): count up on mount
- **Streak / XP badge**: bounce + scale pop on earn event
- **Skill bars** (heatmap): animate width from 0 on scroll-into-view (IntersectionObserver)
- **Tab / filter switches**: sliding underline indicator, not instant class swap
- **Dropdown menus**: scale from 0.95 + fade, origin at trigger element

### Accessibility — WCAG 2.1 AA required

- All interactive elements reachable and operable by keyboard (`Tab`, `Enter`, `Space`, `Escape`, arrow keys for menus)
- Every `<button>` and `<a>` has a visible focus ring (`focus-visible:ring-2 focus-visible:ring-blue-500`)
- All images have `alt` text; decorative images use `alt=""`
- Color contrast ≥ 4.5:1 for normal text, ≥ 3:1 for large text (verify blue-600 on white = 5.9:1 ✓)
- Form fields have associated `<label>` (not just placeholder)
- Modals trap focus and restore it on close
- ARIA roles: `role="status"` on loading indicators, `aria-live="polite"` on toast notifications, `aria-expanded` on dropdowns, `aria-current="page"` on active nav item
- No color-only information (always pair color with icon or text)

### Code rules

- TypeScript strict mode — no `any`, no `as unknown as X` unless unavoidable
- Functional components only, no class components
- Custom hooks for all non-trivial state logic (files in `src/hooks/`)
- React Query (`useQuery` / `useMutation`) for all server state — never local `useState` for API data
- Zustand only for global client state (auth, UI preferences)
- No inline styles — Tailwind classes only; for dynamic values use `style={{ }}` only when Tailwind cannot express it (e.g. exact pixel widths from API data)
- No hardcoded strings for copy — use constants or i18n keys if a string appears more than once
- Replace any hardcoded mock data you find with real API calls via `src/lib/api.ts`
- If an API endpoint doesn't exist yet, add a TODO comment and use a typed mock; do not silently swallow the missing data
- New UI libraries: allowed only if they provide capability not achievable with Tailwind + existing deps. Install with `npm install --save-exact`. Update `package.json` and `package-lock.json`. If the library loads external resources, add those domains to `frontend/nginx.conf` CSP headers.

---

## PHASE 5 — Write Tests

### Unit / component tests (Vitest + React Testing Library)

File location: co-located `ComponentName.test.tsx` or `__tests__/ComponentName.test.tsx`

Required for every component:
```tsx
// renders correctly
it('renders with required props', () => { ... })

// loading state
it('shows skeleton while loading', () => { ... })

// error state
it('shows error message on API failure', () => { ... })

// interactions
it('calls onEnroll when Enroll button is clicked', async () => { ... })

// accessibility
it('has no accessibility violations', async () => {
  // use jest-axe: await expect(container).toHaveNoViolations()
})
```

Target: **≥ 80% statement coverage** on all new/modified files. Run `npm test -- --coverage` to verify. If coverage drops below 80%, add tests until it passes.

### E2E tests (Playwright)

File location: `e2e/<flow-name>.spec.ts`

Write a Playwright test that covers the full user flow the task belongs to. Example flows:
- `e2e/auth.spec.ts` — register → login → redirect to dashboard
- `e2e/course-enrollment.spec.ts` — browse catalog → enroll → open lesson
- `e2e/ai-tutor.spec.ts` — open lesson → send message → receive AI response
- `e2e/credentials.spec.ts` — view credentials → open share URL → verify public page
- `e2e/analytics.spec.ts` — admin views org dashboard → skills heatmap loads
- `e2e/course-builder.spec.ts` — upload doc → generate → review outline → publish

Use realistic mock API responses via Playwright `page.route()` — never hit the real backend in E2E tests.

Each E2E test must assert:
1. The page renders without errors
2. Key interactive elements are visible and clickable
3. Navigation/routing works correctly
4. Animations complete (wait for elements, not arbitrary timeouts)

---

## PHASE 6 — Lint, Type-check, and Build

Run in order:

```bash
cd frontend

# Type check — must be clean
npm run typecheck 2>&1 | tail -30

# Lint — must be clean
npm run lint 2>&1 | tail -30

# Build — must succeed with no warnings about chunk size > 500kB
npm run build 2>&1 | tail -30
```

Fix all errors before proceeding. Do not suppress lint rules without a comment explaining why.

---

## PHASE 7 — Run Tests and Iterate

```bash
# Unit tests with coverage
cd frontend && npm test -- --run --coverage 2>&1 | tail -50

# E2E tests
cd frontend && npx playwright test 2>&1 | tail -50
```

**Iteration rules:**
1. Read the full failure output before making any change
2. Fix root causes — never `// @ts-ignore`, never skip a test, never weaken an assertion
3. If a test exposes a real bug in your implementation, fix the implementation
4. If a test is genuinely wrong (wrong expectation, wrong mock), fix the test and explain why
5. After each fix, run only the failing test(s) first, then the full suite
6. Stop when: unit tests exit 0 with ≥ 80% coverage AND Playwright exits 0
7. If stuck after 3 iterations on the same failure — re-read the demo spec (`docs/demo.html`) and the SRS section; the answer is usually there

---

## PHASE 8 — Lighthouse Check

After tests pass, run a Lighthouse audit on the affected page(s):

```bash
cd frontend && npm run build
# then serve dist/ locally and run:
npx lighthouse http://localhost:4173/<page-path> \
  --only-categories=performance,accessibility,best-practices \
  --output=json --quiet 2>&1 | node -e "
    const r=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    const cats=r.categories;
    console.log('Performance:', Math.round(cats.performance.score*100));
    console.log('Accessibility:', Math.round(cats.accessibility.score*100));
    console.log('Best Practices:', Math.round(cats['best-practices'].score*100));
  "
```

**Thresholds** (must meet before committing):
- Performance ≥ 85
- Accessibility ≥ 95
- Best Practices ≥ 90

If any threshold is missed, fix the specific issues Lighthouse flags (it gives exact line-level recommendations). Common fixes: add `loading="lazy"` to images, fix missing `aria-label`, reduce JS bundle with dynamic `import()`.

---

## PHASE 9 — Update Changelog

Append to `FRONTEND_CHANGELOG.md` (create it if it doesn't exist) in this format:

```markdown
## [YYYY-MM-DD] <Task name>

**SRS**: <requirement IDs>
**Demo spec**: Step <N> — <screen name>

### Added
- <bullet: what was added>

### Changed
- <bullet: what was improved, and why>

### Animations
- <bullet: each micro-interaction added>

### Accessibility
- <bullet: each a11y fix or addition>

### Tests
- Unit: <N> new tests, coverage <X>%
- E2E: <N> new Playwright scenarios

### Lighthouse (before → after)
- Performance: <X> → <Y>
- Accessibility: <X> → <Y>
- Best Practices: <X> → <Y>
```

---

## PHASE 10 — Commit

Stage and commit all changed files:

```bash
# Always operate from the repo root (resolved dynamically — never a hardcoded path).
cd "$(git rev-parse --show-toplevel)"

# Stage only frontend files + changelog (never stage .env or secrets)
git add frontend/ FRONTEND_CHANGELOG.md

# Commit
git commit -m "$(cat <<'EOF'
feat(frontend): <concise description of what was built>

SRS: <requirement IDs>
Demo: Step <N> — <screen name>

- <bullet: key change 1>
- <bullet: key change 2>
- Animations: <list>
- A11y: WCAG 2.1 AA compliant
- Tests: <N> unit + <N> E2E, coverage <X>%
- Lighthouse: perf <X>, a11y <Y>, best-practices <Z>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

If `nginx.conf` was modified (new CSP entry), include it in the commit:
```bash
git add frontend/nginx.conf
```

---

## PHASE 11 — Final Summary

Output:

```
✅ DONE: <task name>

SRS: <IDs satisfied>
Demo spec: Step <N>

Files changed:
  <path>  — <one-line description>

Animations added:
  <list each micro-interaction>

Accessibility:
  <list each a11y addition>

Tests:
  Unit: <N> new, <X>% coverage
  E2E:  <N> new Playwright scenarios

Lighthouse:
  Performance:     <score>
  Accessibility:   <score>
  Best Practices:  <score>

Committed: <git short sha>

Next logical task: <what to build next, based on SRS and demo spec>
```
