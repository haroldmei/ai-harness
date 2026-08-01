---
name: mobile-ui-design
description: Design production-ready React Native screens, components, and flows for the SkillForge AI mobile app (Expo SDK 54). Use this skill whenever the user asks to design, wireframe, mockup, restyle, or build any mobile screen, tab, sheet, card, or component in mobile/ — including learner home, lesson player, AI tutor, skills, credentials, onboarding, instructor course build/review, live sessions, settings, or auth screens. Also trigger on mentions of bottom tabs, safe areas, touch targets, native look-and-feel, iOS vs Android differences, Expo primitives, or mobile accessibility. For the WEB frontend use ui-design instead; for native SwiftUI apps use ios-design-review.
---

# SkillForge Mobile — UI Design Skill

Design production-ready UI for the SkillForge **React Native** app (`mobile/`, Expo SDK 54). This is the native companion to the web platform, not a port of it. Doc 47 scopes mobile to **learner** and **instructor** surfaces; manager/org-admin and super-admin remain web-only.

Read this before designing anything: the app has **no design-token module and a deliberately small dependency set**. Most bad mobile designs here fail not on taste but on proposing something the installed stack cannot render. The Platform Budget below is the binding constraint.

## Platform Budget — what you may and may not design

**Installed and usable:** `expo` ~54.0.36, `react-native` 0.81.5, React 19.1, `@react-navigation/native` v7 + `@react-navigation/bottom-tabs` v7, `react-native-safe-area-context` ~5.6, `react-native-screens`, `expo-video`, `expo-audio`, `expo-camera`, `expo-notifications`, `expo-secure-store`, `expo-local-authentication`, `expo-localization`, `i18next` + `react-i18next`, `@tanstack/react-query`, `zustand`, `qrcode`.

**NOT installed — never design a UI that requires these:**

| Missing | Consequence for design |
|---|---|
| `react-native-reanimated`, `react-native-gesture-handler` | No spring physics, no swipe-to-dismiss, no drag-reorder, no shared-element transitions. Animation is RN core `Animated` only (see `OfflineBanner.tsx`, `FlashcardLesson.tsx`). |
| `@expo/vector-icons`, `react-native-svg` | **Icons are emoji in a `<Text>`.** No icon fonts, no SVG illustrations, no custom charts. Radar/graph visualisations from the web design cannot be reproduced — use bars, rows, and numbers. |
| `@react-navigation/native-stack` | **No stack navigator.** No push/pop screen hierarchy, no native header, no swipe-back gesture. |
| `expo-haptics`, `Vibration` | No haptic feedback on any interaction. |
| `nativewind` / Tailwind, `styled-components` | Styling is vanilla `StyleSheet.create` only. |
| `expo-image` | Plain RN `<Image>`; no blurhash or built-in caching. |
| `expo-router` | Navigation is the hand-rolled registry described below. |

If a design genuinely needs one of these, say so explicitly and propose it as a dependency decision — do not silently assume it exists.

## Visual Language

The mobile app is **dark-only**. There is no `useColorScheme`, no theme context, and no light mode anywhere in `mobile/src`. Do not invent a theme toggle.

**Palette** — a Tailwind slate/blue ramp, currently hardcoded as hex literals in every file:

| Token role | Hex | Usage |
|---|---|---|
| Screen background | `#0f172a` | every `container` |
| Surface / card / tab bar | `#1e293b` | cards, modals, tab bar |
| Border / divider / secondary button | `#334155` | 1px borders, hairlines, progress track |
| Muted text / inactive tab | `#64748b` | timestamps, disabled |
| Secondary text | `#94a3b8` | descriptions, body-secondary |
| Label text | `#e2e8f0` | form labels |
| Primary text | `#f8fafc` | headings, card titles |
| Primary action | `#3b82f6` | buttons, progress fill, toggle-on |
| Accent / active tab / link | `#60a5fa` | active tint, links |
| Danger | `#ef4444` (`#f87171` text) | destructive, badges |
| Success | `#22c55e` | completion |
| Warning | `#f59e0b` (`#fbbf24` text) | expiring, caution |
| On-primary | `#ffffff` | text on filled buttons |

Translucent variants use inline `rgba()` at ~0.1–0.15 alpha for tag and badge fills; the modal scrim is `rgba(0,0,0,0.6)`.

**Typography** — system font only (no custom font is loaded). Observed scale: 10 (badge), 11 (tab label, chip), 12 (meta), 13 (card description), 14 (body), 15 (button, label), 16 (card title), 18 (dialog title), 22 (tab emoji), 44 (empty-state emoji). Weights are **strings**: `'500' | '600' | '700'`. Line heights 16/18/20. Monospace requires a platform branch: `fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace'`.

**Spacing** — 4px base. Cards `padding: 16`, screen content `padding: 20`, dialogs `padding: 24`, empty states `padding: 32`. Gaps 6/8/12.

**Radii** — 3 (progress track), 4 (status badge), 6 (tag), 8 (button, difficulty badge), 12 (card), 16 (dialog), 999 (pill/toggle).

**Depth** — there are **no shadows and no `elevation`** in this codebase. Hierarchy comes from background-colour shifts (`#0f172a` → `#1e293b`) plus `borderWidth: 1, borderColor: '#334155'` or `StyleSheet.hairlineWidth`. Keep it that way; a lone elevated card will look foreign.

**Motion** — subtle and rare. Modals use `animationType="fade"`. Respect `useReduceMotion()` from `src/hooks/useAccessibility.ts` before animating anything.

## Navigation Model — bottom tabs, and nothing else

`src/navigation/AppNavigator.tsx` builds a single bottom-tab navigator from `src/navigation/nav-items.ts`. Design within these rules:

- **Six tabs maximum.** `LEARNER_TABS` = home, courses, aiTutor, skills, credentials, settings. `INSTRUCTOR_TABS` = home, instructorCourses, reviews, buildCourse, settings. `tabsForRole(role)` returns the instructor set for `instructor | manager | super_admin`.
- **There is no stack.** A "detail screen" is either a tab screen swapped by internal state, or an inline sub-view inside its parent screen (the lesson player is a sub-view of `CoursesScreen`). **You cannot deep-link to a lesson from another tab.** Design detail views as self-contained states with their own explicit back affordance (`testID="lesson-player-back"`) — there is no OS swipe-back.
- **Inline sub-view vs modal sheet — pick by whether parent state must survive.** An inline swap unmounts the parent, destroying its scroll position, filters, sort, and search. Use an **inline sub-view** for immersive, full-screen destinations the user commits to (lesson player, course detail, review detail) where losing list state is acceptable or even desirable. Use a **modal sheet** for a drill-down the user pops in and out of repeatedly from a filtered list (a skill, a notification, a session) — the parent stays mounted underneath, and dismissal returns the user exactly where they were. When in doubt, ask: "will they open three of these in a row?" If yes, sheet.
- **Non-tab destinations must be registered as hidden screens.** `HOME_CARD_ROUTES = ['courses','credentials','skills','aiTutor']` and `ALWAYS_REGISTERED_ROUTES = ['liveSessions','learningPaths']` are registered with `tabBarButton: () => null` so `navigate()` works for roles where they are not tabs. If you design a new destination reachable from a card or push deep link, it must be added to one of those arrays — otherwise `navigate()` silently no-ops.
- **Tab bar spec:** background `#1e293b`, `borderTopColor: '#334155'` at hairline width, `height: 88`, `paddingTop: 4`; active tint `#60a5fa`, inactive `#64748b`; label 11px/`'600'`; icon is a 22px emoji `<Text>` at `opacity: focused ? 1 : 0.5`.
- **Every tab sets four things:** `tabBarLabel: t(item.labelKey)`, `tabBarAccessibilityLabel: t(item.labelKey)`, `tabBarButtonTestID: 'tab-<key>'`, and `tabBarIcon`. Labels come from the `nav.*` i18n namespace.
- **Unauthenticated flows** use the hand-rolled `PublicNavigator.tsx` — a `useState` array of route objects with `push`/`pop`. Auth gating above it is a set of booleans in `App.tsx`. Any new pre-auth screen extends the `PublicRoute` union.

## Safe Areas and Layout

`SafeAreaProvider` wraps the app; `SafeAreaView` is never used. **Use `useSafeAreaInsets()`** — this is the correct pattern, modelled by `AiTutorScreen.tsx`:

```tsx
const insets = useSafeAreaInsets();
<View style={[styles.header, { paddingTop: insets.top + 8 }]} />
<View style={[styles.composer, { paddingBottom: insets.bottom + 8 }]} />
```

Most existing screens instead hardcode `paddingTop: 60`. That is legacy debt, not the standard — it clips on notched devices and over-pads on older ones. **New screens use insets.** If you touch an old screen's header, migrate it.

Tablet and orientation handling lives in `useLayoutMode()` (`src/hooks/useLayoutMode.ts`) over `src/constants/layout.ts`: breakpoints 768 / 1024, `maxContentWidth` 720/820, `masterPaneWidth` 320/380, `maxSheetHeight` 90% portrait / 80% landscape. Wrap screen content in `<ResponsiveContainer>` so it centres on tablets, use `<SplitView>` for master-detail, and cap modals with `maxSheetHeight`.

Keyboard handling: `behavior={Platform.OS === 'ios' ? 'padding' : undefined}` is the majority idiom; auth screens use `'height'` on Android. Only set `keyboardVerticalOffset` when a fixed header requires it, and make it orientation-aware.

**Bottom-sheet pattern.** There is no sheet library, so build it from `Modal` — the scrim aligns content to the bottom, the sheet rounds only its top corners, and the bottom inset is padded so actions clear the home indicator:

```tsx
overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end' },
sheet: {
  backgroundColor: '#1e293b',
  borderTopLeftRadius: 16, borderTopRightRadius: 16,
  paddingTop: 20, paddingHorizontal: 20,
  borderTopWidth: 1, borderTopColor: '#334155',
},
// applied inline: { maxHeight: maxSheetHeight, paddingBottom: insets.bottom + 20 }
```

Always cap with `useLayoutMode().maxSheetHeight` and make the sheet body a `ScrollView` with `flexGrow: 0`, so a long sheet scrolls internally instead of pushing its action buttons off-screen. Without a gesture handler there is **no swipe-to-dismiss** — every sheet needs a visible close control plus `onRequestClose` for the Android back button.

## Platform Conventions — iOS vs Android

The codebase uses `Platform.OS` branches, never `Platform.select()` in `src/`. Because there is no gesture handler, no haptics, and no elevation, the two platforms deliberately look nearly identical. Branch only where the platform genuinely demands it:

- **iOS only:** Sign in with Apple (`expo-apple-authentication`; hide the button off-iOS), Picture-in-Picture (`allowsPictureInPicture={Platform.OS === 'ios'}`), deep link to `app-settings:` for permission recovery, `Menlo` monospace.
- **Android only:** `FLAG_SECURE` screenshot blocking (`useSecureWindow`), `'height'` keyboard behaviour on auth screens, `monospace` font.
- **Back affordance:** Android has a hardware/gesture back; iOS does not and there is no stack swipe-back. **Every non-tab view needs a visible in-app back control** — do not rely on the platform.
- Do not design ripple effects (`android_ripple`, `TouchableNativeFeedback` are unused) or iOS-style large titles (there are no native headers; `headerShown: false` globally).

## Accessibility

`src/hooks/useAccessibility.ts` is the contract. Honour it:

- **Touch targets:** `MIN_TOUCH_TARGET_PT = 24`. Anything smaller must call `useTouchTarget().hitSlopForSize(renderedSize)`. Prefer a genuine `minHeight: 44` for primary actions.
- **Roles:** `accessibilityRole` on every interactive or structural element — `button` (dominant), `header` on titles, `switch` with `accessibilityState={{ checked }}`, `radio`/`radiogroup` for quiz options.
- **`alert` is for alerts, not for every modal.** Reserve `accessibilityRole="alert"` for dialogs that interrupt to demand a decision or announce a problem (`ConfirmationDialog`) — screen readers announce it assertively and interrupt whatever is being read. An informational drill-down sheet must **not** claim it: give it `accessibilityViewIsModal` plus `accessibilityRole="header"` on its title, and let the user read it at their own pace.
- **Progress needs a value, not just a role.** `accessibilityRole="progressbar"` alone announces "progress bar" with no reading. Always pair it with `accessibilityValue={{ min: 0, max: 100, now: percent }}` and an `accessibilityLabel` naming what is progressing. The visual fill width and the announced `now` must derive from the same variable — never compute them separately.
- **Decorative emoji always get both props:** `accessibilityElementsHidden` and `importantForAccessibility="no-hide-descendants"`. An unlabelled emoji is a screen-reader defect.
- **Composite labels** are concatenated on the parent touchable, not split across children: `` accessibilityLabel={`${label}: ${value} ${sub}`} ``.
- **Font scaling:** `useFontScale().scaleFont` clamps 0.85×–2.0×. Never set a fixed `height` on a text-bearing container — use `minHeight` and let it grow.
- **Reduced motion:** gate animation on `useReduceMotion()`.
- Keep `.maestro/a11y-baseline-flow.yaml` passing — it asserts specific labels such as `"Email address"` and `"Authentication code, 6 digits"`.

## i18n

Every user-facing string goes through `t('namespace.key')` against the five catalogs in `src/i18n/` (`en/es/fr/de/pt`). Never hardcode display copy — `CourseStatusBadge.tsx` currently does and is the counter-example, not the model. Tab labels use `nav.*` and must be mirrored into `tabBarAccessibilityLabel`. Design for ~35% text expansion in German: labels wrap, never truncate mid-word, and tab labels stay short.

## Implementation Conventions

**Styling:** one `const styles = StyleSheet.create({...})` at the bottom of each component file. Dynamic values via array merge: `style={[styles.card, isActive && styles.cardActive, { backgroundColor: dyn }]}`. Variant maps are module-level `Record<Variant, {...}>` consts (see `CourseStatusBadge`, `ConfirmationDialog`'s `CONFIRM_BG`). Nothing is exported for reuse — there is no shared style module.

**Touchables:** `TouchableOpacity activeOpacity={0.7}` is the default. Use `Pressable` only where you need press state.

**testIDs** are load-bearing — Maestro flows target them. Convention is kebab-case `<surface>-<element>-<role>`, with list rows suffixed by entity id: `login-email-input`, `login-submit-button`, `course-card-<id>`, `lesson-row-<id>`, `quiz-option-0`, `tab-courses`, `notif-badge`. Maestro **substring-matches** ids, so `tapOn: { id: "course-card" }` hits the first row — keep prefixes stable and unique. Composites derive children (`SplitView` emits `${testID}-master` / `-detail`).

**Testability:** unit tests mock `react-native` as plain string tags with `StyleSheet.create` as identity, rendering through `react-test-renderer`. So components must not import native-only modules at module scope (lazy-`require` inside the component, as `VideoLesson.tsx` does for `expo-video`), and anything gated on `Platform.OS` at module load needs separate `.ios.test.tsx` / `.android.test.tsx` files.

## Screen Inventory

Design against these; the user may override. Learner: **Home** (KPI cards, continue-learning, skill-gap and quick-action cards), **Courses** (segmented catalog/my-learning, course cards, inline lesson player), **Lesson Player** (per-type renderers: text, video, audio, quiz, slides, flashcard, code exercise, completion panel; plus `LessonSidePanel`), **AI Tutor** (chat with voice input, context panel, micro-lessons feed), **Skills**, **Credentials** (wallet, QR display, verify/scan), **Learning Paths**, **Live Sessions** (register/join/recordings), **My Learning**, **Notifications** (bell + inbox), **Onboarding wizard + placement quiz**, **Settings** (profile, notification/privacy prefs, security, change password, MFA enrolment, account deletion, language switcher, feedback), **Offline/downloads** (storage bar, download queue, offline banner).

Instructor: **Instructor Courses**, **Reviews** (triage), **Build Course** (job monitor + streaming progress), **Lesson Block Editor** (dispatcher over text/callout/quiz block editors, read-only view), **Course Details / Structure editors**.

Auth/public: **Login**, **Register**, **OAuth**, **MFA Challenge**, **Biometric Lock**, **Minor Consent Pending**, **Public Catalog / Course Detail / Lesson Player**, **Credential Verify / Scan**, **Document Capture**.

Minors note: never surface a client-side `is_minor` flag — the mobile User DTO deliberately omits it. Gate social surfaces on the backend's `block_minor_social` 403 response.

## Quality Checklist

Before outputting any mobile design, verify:

- [ ] **Stack-feasible** — needs nothing from the "NOT installed" table; icons are emoji, charts are bars/rows
- [ ] **Dark-only** — uses the slate palette above; no light-mode variant invented
- [ ] **Depth via borders** — no `shadow*`, no `elevation`
- [ ] **Safe areas** — `useSafeAreaInsets()` for top and bottom chrome, not `paddingTop: 60`
- [ ] **Navigation-legal** — fits ≤6 tabs, or is registered as a hidden screen; has an explicit back control
- [ ] **Touch targets** — ≥44pt for primary actions; `hitSlopForSize()` for anything under 24pt
- [ ] **A11y complete** — role + label on every control; decorative emoji hidden; modal has `accessibilityViewIsModal`; `alert` role only on true alerts; every `progressbar` carries `accessibilityValue`
- [ ] **Sheets** — capped by `maxSheetHeight`, scrolling body, visible close control, `onRequestClose` wired (no swipe-to-dismiss exists)
- [ ] **Font-scale safe** — no fixed heights on text containers; tested mentally at 2.0×
- [ ] **i18n** — all copy via `t()`; layout survives ~35% German expansion
- [ ] **testIDs** — kebab-case, prefix-stable, unique enough for Maestro substring matching
- [ ] **States** — loading, empty, error, and offline all specified
- [ ] **Realistic copy** — real seed course/skill/user names, never Lorem ipsum
- [ ] **Tablet** — wrapped in `ResponsiveContainer`; modals capped by `maxSheetHeight`

## Output Format

Default to **a real `.tsx` component** using `StyleSheet.create` and the tokens above — the app cannot consume HTML mockups, and an HTML artifact is misleading here. Structure output as: the component file, then a short note on where it registers (tab vs hidden screen vs inline sub-view), then the testIDs added and the i18n keys required.

Use an ASCII wireframe first when the user is exploring layout rather than asking for code. Reserve HTML/SVG artifacts for flow diagrams and information architecture, never for screen mockups.

## Worked Example

**Prompt:** "Design the learner Credentials tab."

**Approach:**

1. Confirm placement: `credentials` is a `LEARNER_TABS` entry and a `HOME_CARD_ROUTES` member, so it is a visible tab for learners and a hidden registered screen for instructors — no navigator change needed.
2. Wireframe the states: list of credential cards (title, issue date, expiry, status badge), empty state, loading skeleton, offline banner.
3. Produce the `.tsx`:
   - `container: { flex: 1, backgroundColor: '#0f172a' }`, content padded 20 with `paddingTop: insets.top + 12`
   - Wrap in `<ResponsiveContainer>`
   - Card: `#1e293b`, radius 12, padding 16, `borderWidth: 1, borderColor: '#334155'`
   - Status badge via a module-level `Record<Status, {bg, text}>` — active `#22c55e`, expiring `#f59e0b`, expired `#64748b`
   - Row is `TouchableOpacity activeOpacity={0.7}`, `accessibilityRole="button"`, `` accessibilityLabel={`${title}, ${statusLabel}, issued ${date}`} ``, `testID={`credential-card-${id}`}`
   - Detail opens as an inline sub-view with a `credential-detail-back` control (no stack available); QR via `QRCodeDisplay`
   - Empty state: 44px emoji marked decorative + `t('credentials.emptyTitle')` + CTA to Courses
4. List the i18n keys added and note assumptions, then offer to iterate.

## Seed Data Reference

**Courses:** Python for Backend Engineers, Kubernetes for Platform Engineers, Machine Learning Engineering Fundamentals, LLM Engineering — Building Production AI Applications, Zero Trust Security for Cloud-Native Teams, Infrastructure as Code with Terraform, MLOps — Taking Models to Production, System Design for Senior Engineers, Site Reliability Engineering Essentials

**Skills:** Python, TypeScript, Go, Rust, Kubernetes, Docker, Terraform, GCP, AWS, ML Fundamentals, PyTorch, Prompt Engineering, RAG, AI Agents, Zero Trust, SRE, Observability, CI/CD

**Demo users:** Sam Chen (learner), Alex Rivera (admin), Maria Santos (instructor), Jordan Kim (manager)

**Org:** SkillForge Demo | Plan: Growth | 100 seats

**Proficiency:** Python 0.85, Kubernetes 0.72, ML Fundamentals 0.68, Prompt Engineering 0.90, System Design 0.55, Docker 0.78
