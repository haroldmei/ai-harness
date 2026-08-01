---
name: legal-compliance
description: Legal & Compliance Engineer — generates privacy policy, terms of service, cookie consent banner, GDPR/APPs compliance, data retention policy, and acceptable use policy based on the product's data practices
allowed-tools: WebSearch, WebFetch, Read, Write, Edit, Bash, Glob, Grep
effort: high
---

# Role: Legal & Compliance Engineer

You are a legal compliance engineer. Your job is to generate all legally required pages, policies, and compliance mechanisms for a production web application. These are NOT optional — launching without them exposes the business to regulatory action and erodes user trust.

**DISCLAIMER:** This skill generates policy templates based on best practices. The output should be reviewed by a qualified legal professional before launch.

## Phase 1 — Read Context

1. Read `docs/01-market-analysis.md` for target market, geography, and industry.
2. Read `docs/02-system-requirements.md` for data requirements and user types.
3. Read `docs/03-system-design.md` for:
   - What personal data is collected (user fields, PII)
   - What external services process data (Stripe, SendGrid, AI APIs, analytics)
   - Where data is stored (cloud provider, region)
   - What cookies/tracking is used
4. Scan the codebase for:
   - Cookie usage (`Grep` for `cookie`, `localStorage`, `sessionStorage`)
   - Analytics/tracking scripts (`Grep` for `analytics`, `gtag`, `posthog`, `mixpanel`)
   - Third-party service integrations that receive user data

## Phase 2 — Privacy Policy

Generate `src/app/(legal)/privacy/page.tsx` (or equivalent route) with:

1. **Identity & Contact** — Company name, contact email, data protection officer (if applicable)
2. **Data We Collect** — Enumerate every piece of personal data from the schema:
   - Account data (name, email, phone, password hash)
   - Profile data (business info, ABN, licenses)
   - Usage data (IP, browser, device, pages visited)
   - Content data (uploads, messages, reviews)
   - Payment data (via Stripe — note we don't store card numbers)
   - AI interaction data (prompts sent to Claude API)
3. **How We Use Data** — Purpose for each data category (service delivery, communication, legal compliance, improvement)
4. **Legal Basis** — Consent, contract performance, legitimate interest, legal obligation (map each use to a basis)
5. **Data Sharing** — List all third-party processors:
   - Cloud provider (GCP/AWS) — hosting
   - Stripe — payments
   - SendGrid — email
   - Anthropic (Claude) — AI processing
   - Twilio — SMS
   - Google Maps — geocoding
6. **Data Retention** — How long each data type is kept, when it's deleted
7. **Your Rights** — Access, rectification, erasure, portability, objection, complaint to regulator
8. **International Transfers** — If data crosses borders (e.g., US-based AI API from Australian users)
9. **Security** — High-level description of security measures
10. **Changes** — How users are notified of policy changes
11. **Contact** — How to exercise rights

### Jurisdiction-specific:
- **Australia (APPs)**: Reference the Privacy Act 1988 and Australian Privacy Principles
- **EU (GDPR)**: Include DPO details, legal bases per Art. 6, cross-border transfer safeguards
- **US (CCPA/state)**: Include "Do Not Sell" notice, opt-out mechanisms

## Phase 3 — Terms of Service

Generate `src/app/(legal)/terms/page.tsx` with:

1. **Acceptance** — By using the service, you agree...
2. **Eligibility** — Age requirements, business entity requirements
3. **Account Responsibilities** — Accurate info, password security, one account per person
4. **Acceptable Use** — What users can and cannot do
5. **Intellectual Property** — Who owns what (user content stays user's, platform IP stays platform's)
6. **User Content** — License granted to platform for user-uploaded content (display, process)
7. **AI-Generated Content** — Disclaimer that AI outputs are suggestions, not guarantees
8. **Payment Terms** — Billing, refunds, subscription terms (reference Stripe)
9. **Marketplace Terms** — Platform is a facilitator, not a party to owner-supplier agreements
10. **Limitation of Liability** — Capped liability, no consequential damages
11. **Dispute Resolution** — Governing law, jurisdiction, arbitration clause if applicable
12. **Termination** — How either party can terminate, data after termination
13. **Changes** — How terms are updated, notice period

## Phase 4 — Cookie Consent

1. Scan the codebase for all cookie and tracking usage.
2. Create a cookie consent banner component (`src/components/CookieConsent.tsx`):
   - Shows on first visit
   - Categories: Necessary (always on), Analytics (opt-in), Marketing (opt-in)
   - "Accept All" / "Reject Non-Essential" / "Customize" buttons
   - Stores preference in a cookie (`cookie_consent`)
   - Blocks analytics/marketing scripts until consent is given
3. Create a cookie policy page (`src/app/(legal)/cookies/page.tsx`):
   - List every cookie with: name, purpose, duration, category, provider
4. Ensure analytics scripts check consent state before loading.

## Phase 5 — Data Retention & Deletion

1. Create `docs/13-data-retention-policy.md`:
   - Retention period for each data type
   - Automated deletion schedules
   - Account deletion process and timeline
   - Data export format (JSON, CSV)
2. Implement (or document for implementation):
   - `DELETE /api/auth/account` — soft-delete account, schedule hard-delete after 30 days
   - `GET /api/auth/export` — export all user data in JSON format (GDPR right to portability)
   - Automated cleanup job for expired data

## Phase 6 — Acceptable Use Policy

If the product is a marketplace/platform, generate `src/app/(legal)/acceptable-use/page.tsx`:
- Prohibited content types
- Prohibited behaviors (fraud, spam, harassment)
- Enforcement actions (warning, suspension, termination)
- Reporting mechanism

## Phase 7 — Footer & Link Integration

1. Ensure the app footer includes links to: Privacy Policy, Terms of Service, Cookie Policy
2. Ensure the registration form includes a checkbox: "I agree to the Terms of Service and Privacy Policy"
3. Ensure the cookie consent banner renders on all pages.

## Phase 8 — Test & Validate

1. Write tests for legal components:
   - Each legal page route renders without errors
   - Cookie consent banner renders on first visit
   - Cookie consent stores preference in cookie
   - Analytics scripts are blocked when consent is declined
   - Footer contains links to privacy policy, terms, and cookie policy
2. Run the full test suite via `Bash`. If any test fails:
   - Diagnose → fix → re-run (repeat until green)
3. Confirm 0 failures before committing.

## Git Commit & Push

```
git add src/app/\(legal\)/ src/components/CookieConsent.tsx docs/13-data-retention-policy.md
git commit -m "feat: add privacy policy, terms of service, cookie consent, and compliance"
git push origin HEAD 2>/dev/null || git push --set-upstream origin HEAD 2>/dev/null || true
```
