---
name: ui-design
description: Design production-ready UI screens, components, and flows for SkillForge AI — an adaptive corporate learning platform for tech teams. Use this skill whenever the user asks to design, wireframe, mockup, or prototype any screen, page, component, flow, or visual for SkillForge. Also trigger when the user mentions dashboards, course views, learner progress, credential pages, onboarding flows, admin panels, analytics views, settings pages, or any UI work related to the SkillForge product. This includes style guides, design tokens, component libraries, and responsive layout specs.
---

# SkillForge AI — UI Design Skill

Design production-ready UI for SkillForge AI, an adaptive corporate learning platform targeting tech teams of 50–2,000 employees. Every design decision should serve three audiences: **learners** (engineers consuming content), **managers** (tracking team skills), and **admins** (managing the org). The platform competes against tired, cluttered LMS interfaces — SkillForge must feel modern, focused, and effortless.

## Design Philosophy

### Who We're Designing For

SkillForge users are software engineers, data scientists, DevOps practitioners, and their managers. They spend their days in VS Code, GitHub, and Slack. They have high standards for tool quality and zero patience for friction. The UX bar is set by tools like Linear, Vercel, Notion, and Raycast — not by legacy LMS platforms.

**Key user traits:**
- Keyboard-first; expect shortcuts and command palettes
- Dark mode is the default assumption; light mode is the alternate
- Density-tolerant — they read code all day, they can handle information
- Skeptical of decorative UI; every element must earn its space
- Mobile use is secondary (commute learning, progress checks) but must work

### Visual Language

**Tone:** Professional, calm, confident. Not playful (it's a workplace tool), not corporate (it's for engineers). Think "developer tool that happens to teach" — closer to Linear or Vercel's aesthetic than Duolingo or Coursera.

**Color system:**
- **Background:** Dark surfaces as primary (`#0a0a0f` base, `#12121a` elevated, `#1a1a25` cards)
- **Text:** High-contrast white (`#f0f0f5`) for primary, muted (`#8888a0`) for secondary
- **Brand accent:** Indigo-violet (`#6366f1` primary, `#818cf8` hover, `#4f46e5` active) — signals intelligence and depth
- **Semantic:** Green `#22c55e` success, Amber `#f59e0b` warning, Red `#ef4444` error, Blue `#3b82f6` info
- **Skill proficiency gradient:** Red (0.0) → Amber (0.4) → Green (0.7) → Indigo (1.0)
- Light mode: Invert surfaces to white/gray, keep accent colors

**Typography:**
- **Display/headings:** `"JetBrains Mono"` or `"IBM Plex Mono"` — reinforces the developer identity
- **Body text:** `"Inter"` or `"IBM Plex Sans"` at 14–16px — optimized for long reading
- **Code blocks:** `"JetBrains Mono"` or `"Fira Code"` with ligatures enabled
- **Scale:** 12 / 14 / 16 / 20 / 24 / 32 / 48px — use sparingly and intentionally

**Spacing:** 4px base unit. Use multiples: 4, 8, 12, 16, 24, 32, 48, 64. Generous padding inside cards (24px), tight spacing between related elements (8px), clear separation between sections (48px+).

**Borders & surfaces:** 1px borders at `rgba(255,255,255,0.06)`. Cards use subtle elevation via background color shifts, not box-shadow. Rounded corners: 8px for cards, 6px for inputs, 4px for tags/badges, full-round for avatars.

**Motion:** Subtle, functional. 150ms ease-out for hover states, 200ms for panel transitions, 300ms for page transitions. No bouncy animations. Progress bars animate smoothly. Skeleton loaders for async content.

### Layout Principles

- **Sidebar + main content** for authenticated views (sidebar: 240px collapsed to 64px icon-only)
- **Max content width:** 1200px for reading content, full-width for dashboards/analytics
- **Responsive breakpoints:** 320px (mobile), 768px (tablet), 1024px (desktop), 1440px (wide)
- **Mobile-first for learner flows** (lesson view, progress, AI tutor chat); desktop-first for admin/analytics

### Accessibility (WCAG 2.1 AA)

- All text meets 4.5:1 contrast ratio (3:1 for large text)
- Focus rings visible on all interactive elements (2px indigo outline, 2px offset)
- All images have alt text; decorative elements use `aria-hidden`
- Skip-to-content link on every page
- Keyboard navigable: Tab order follows visual order, Escape closes modals
- Screen reader announcements for dynamic content (toast notifications, progress updates)
- Reduced motion: respect `prefers-reduced-motion`, disable animations

## Output Formats

Choose the format based on what the user needs:

### HTML artifact (default for full screens/pages)
Use when designing complete pages, multi-section layouts, or interactive prototypes. Include inline CSS and vanilla JS. Use CDN links for icons (Lucide/Heroicons). Produce a single self-contained file.

### React/TSX artifact (for component specs)
Use when the user asks for a specific component (button, card, modal, form) or when the output will be integrated into the existing React + TypeScript + Tailwind frontend. Use Tailwind classes matching the design tokens above. Include TypeScript types for props.

### SVG artifact (for diagrams and flows)
Use for user journey maps, information architecture, skills graph visualizations, or flow diagrams. Clean, styled SVG with embedded fonts.

## Screen Inventory

When asked to design any of these, use the brief below as the requirements baseline. The user may override or extend.

### 1. Login / Registration
- Email + password form, OAuth buttons (Google, GitHub, Microsoft)
- Minimal chrome — centered card on dark background with subtle brand mark
- "Start learning in under 5 minutes" messaging
- SSO entry point for enterprise customers

### 2. Onboarding Flow (New Learner)
- 3–4 step wizard: role selection → tech stack preferences → first course recommendation → start learning
- Progress indicator (step dots, not a heavy stepper)
- Skip option always visible
- Personalization: ask for current skills so the AI tutor can adapt

### 3. Learner Dashboard (Home)
- **Continue Learning** section: current course card with progress bar, resume button
- **Daily Streak** widget: flame icon, streak count, calendar heatmap (last 30 days)
- **XP & Level** indicator in sidebar or header
- **Recommended Courses** row: 3–4 cards based on skill gaps
- **Recent Credentials** if any earned
- **AI Tutor** floating action button (bottom-right) or sidebar panel

### 4. Course Catalog
- Grid of course cards: thumbnail, title, difficulty badge, estimated hours, skill tags, avg rating
- Filters: difficulty (beginner/intermediate/advanced), domain, skill tags, duration
- Search with instant results
- Sort by: relevance, newest, highest rated, most enrolled

### 5. Course Detail Page
- Hero: course title, description, instructor, difficulty, estimated hours, rating
- **Curriculum** accordion: modules → lessons with completion checkmarks
- **Skills You'll Learn** tag list with current proficiency indicators
- **Enroll** CTA button (or "Continue" if enrolled)
- Reviews section with star breakdown

### 6. Lesson View
- **Content area** (center, max 720px): markdown rendered text, code blocks with syntax highlighting, embedded video player
- **Sidebar** (right, collapsible): lesson navigation, module progress
- **Quiz inline**: questions appear within content flow, not a separate page
- **Code exercise**: split-pane editor (Monaco) left, instructions right, test output bottom
- **Flashcard mode**: flip-card UI with spaced repetition controls (Easy/Medium/Hard)
- **AI Tutor panel** (right drawer): chat interface, context-aware to current lesson

### 7. AI Tutor Chat
- Chat bubble interface: user messages right, tutor left
- Tutor messages support markdown, code blocks, LaTeX
- "Thinking..." indicator with subtle animation
- Suggested follow-up questions as chip buttons
- Context badge showing which lesson/skill the tutor is referencing
- Socratic mode indicator (tutor asks questions, doesn't just give answers)

### 8. Skills Graph / Profile
- **Radar chart** or **tree visualization** showing proficiency across skill domains
- Each skill node: name, proficiency bar (0.0–1.0), attempts count
- Color-coded by proficiency level (red → amber → green → indigo)
- Clickable nodes that expand to show related courses and credentials
- Compare view: "Your skills" vs "Role requirements"

### 9. Credentials / Certificates
- **Credential card**: clean, minimal, print-ready design
- Shows: learner name, credential title, issue date, expiry, skills demonstrated, QR code linking to verification URL
- **Credential list view**: cards with status badges (active, expiring soon, expired)
- **Public verification page** (unauthenticated): displays credential details, verification status, issuer info
- **Share actions**: Download PDF, Copy link, Share to LinkedIn

### 10. Admin Dashboard
- **Overview cards**: active learners, total learning hours, courses published, credentials issued
- **Engagement chart**: daily/weekly/monthly active learners (line chart)
- **Skills coverage heatmap**: teams × skills matrix with color-coded proficiency
- **Top courses** table: title, enrollments, completion rate, avg rating
- **Alerts**: seats nearing limit, low-engagement teams, expiring credentials

### 11. Team Manager View
- **Team members table**: name, role, active courses, skill coverage %, last activity
- **Skills gap analysis**: required skills for the team vs demonstrated proficiency
- **Assign learning** action: select courses/paths, assign to team members with optional due date
- **Leaderboard**: XP rankings within the team

### 12. Organization Settings
- **General**: org name, logo upload, billing plan display
- **Branding**: primary color, accent color, custom domain
- **Members**: invite, role management, seat count
- **Integrations**: Slack, GitHub, SSO config panels with connect/disconnect toggles
- **Billing**: current plan, usage, invoices table, payment method, upgrade CTA

### 13. Course Builder (Instructor)
- **Step 1**: Upload source materials (drag-drop zone) or enter topic
- **Step 2**: AI generates outline — editable tree of modules → lessons
- **Step 3**: Edit individual lessons — rich text editor with preview
- **Step 4**: Review quizzes/flashcards generated by AI, edit as needed
- **Step 5**: Publish with metadata (tags, difficulty, thumbnail)
- Real-time generation progress indicator during AI processing

### 14. Notification / Activity Feed
- Chronological feed: course completions, credential earned, streak milestones, team assignments
- Grouped by day, with relative timestamps
- Action buttons inline (e.g., "View Credential", "Continue Course")

## Quality Checklist

Before outputting any design, verify:

- [ ] **Spacing scale** — all spacing uses 4px multiples; no arbitrary pixel values
- [ ] **Color contrast** — all text passes WCAG AA (4.5:1 body, 3:1 large text); verify accent-on-dark combos
- [ ] **Interactive states** — hover, focus (visible ring), active, disabled states shown for all controls
- [ ] **Responsive** — layout works at 320px, 768px, and 1440px; specify what collapses/stacks
- [ ] **Realistic copy** — use real course titles, skill names, and user names from the seed data; never "Lorem ipsum"
- [ ] **Loading states** — skeleton loaders or spinners for async content
- [ ] **Empty states** — what the screen looks like with zero data (no courses, no credentials, no team members)
- [ ] **Dark mode first** — design in dark mode; note light mode adjustments if relevant
- [ ] **Developer identity** — the UI feels like a tool engineers would respect, not a consumer ed-tech product
- [ ] **Keyboard accessible** — tab order logical, focus management for modals/drawers, escape to close

## Worked Example

**User prompt:**
> "Design the learner dashboard home screen"

**Response approach:**

1. Acknowledge the screen and its role (the learner's daily starting point)
2. Produce an HTML artifact with:
   - Dark theme matching the design tokens
   - Sidebar with nav: Dashboard (active), Courses, Skills, Credentials, AI Tutor
   - Main content area with:
     - Greeting: "Good morning, Sam" with XP badge and streak flame
     - "Continue Learning" card: "Python for Backend Engineers" at 60% progress, resume button
     - "Daily Streak" widget: 14-day streak, last 30 days heatmap
     - "Recommended for You" row: 3 course cards from the seed catalog
     - "Recent Credentials" row: 2 credential cards
   - AI Tutor FAB in bottom-right corner
   - All text uses realistic names/titles from the seed data
   - Hover states on cards (subtle border glow)
   - Responsive: sidebar collapses to icons at <1024px, cards stack at <768px

3. Note any assumptions and offer to iterate (e.g., "I used a sidebar layout — want to try a top-nav variant?")

```html
<!-- Abbreviated example structure -->
<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SkillForge — Dashboard</title>
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@500;700&family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-base: #0a0a0f;
      --bg-elevated: #12121a;
      --bg-card: #1a1a25;
      --text-primary: #f0f0f5;
      --text-secondary: #8888a0;
      --accent: #6366f1;
      --accent-hover: #818cf8;
      --success: #22c55e;
      --border: rgba(255,255,255,0.06);
      --radius: 8px;
      --font-display: 'IBM Plex Mono', monospace;
      --font-body: 'Inter', sans-serif;
    }
    /* ... full implementation follows ... */
  </style>
</head>
<body>
  <!-- Sidebar navigation -->
  <!-- Main content: greeting, continue learning, streak, recommendations -->
  <!-- AI Tutor FAB -->
</body>
</html>
```

## Seed Data Reference

Use these real values in designs instead of placeholder text:

**Courses:** Python for Backend Engineers, Kubernetes for Platform Engineers, Machine Learning Engineering Fundamentals, LLM Engineering — Building Production AI Applications, Zero Trust Security for Cloud-Native Teams, Infrastructure as Code with Terraform, MLOps — Taking Models to Production, Fine-Tuning and Adapting LLMs, System Design for Senior Engineers, Site Reliability Engineering Essentials

**Skills:** Python, JavaScript, TypeScript, Go, Rust, Kubernetes, Docker, Terraform, GCP, AWS, ML Fundamentals, PyTorch, Prompt Engineering, RAG, AI Agents, Zero Trust, IAM, SRE, Observability, CI/CD

**Demo users:** Sam Chen (learner), Alex Rivera (admin), Maria Santos (instructor), Jordan Kim (manager)

**Org:** SkillForge Demo | Plan: Growth | 100 seats

**Proficiency scores:** Python 0.85, Kubernetes 0.72, ML Fundamentals 0.68, Prompt Engineering 0.90, System Design 0.55, Docker 0.78
