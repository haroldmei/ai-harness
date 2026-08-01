# 0002 — Self-hosted inference

Status: **accepted** · Date: 2026-08-01 · Supersedes: none · Amends: [0001](0001-adopted-defaults.md) Q5, Q6 · Tracked by: [#80](https://github.com/haroldmei/ai-harness/issues/80)

[`selfhost.md`](../../selfhost.md) is an analysis, not a decision. It recommends a model, an
engine and a stage plan, and leaves unanswered the four questions that actually bind an
implementation: what happens to dollar-denominated budget rails when tokens are free, how
`reviewer ≠ implementer` survives one 24 GB card, whether cloud fallback is permitted at all,
and what evidence justifies a cutover.

The twelve decisions below are adopted as written in
[`docs/plans/phase-7-self-hosted-inference.md`](../plans/phase-7-self-hosted-inference.md), so
no issue in the Phase 7 build plan is blocked on a pending answer. As in 0001: where a decision
is a *value* rather than a *direction* it is expressed in code and asserted by a test, because a
decision recorded only in prose is a decision that drifts.

## The decisions

| # | Decision | Where it lives |
|---|----------|----------------|
| L1 | **Qwen3-Coder 30B (4-bit) implements; Devstral 24B (4-bit) reviews.** Both pinned by revision digest — a model upgrade changes the behaviour of every agent at once, so it is a deployment, not a pull. | `.harness/models.yaml`, `llm/serving/models.py`; a digest mismatch refuses to start |
| L2 | **One resident model at a time.** Never co-resident on 24 GB. The swap is taken under a lease, awaited to *readiness*, and charged to the run that caused it. | `llm/serving/residency.py`, on `kernel/lease.py` |
| L3 | **vLLM, OpenAI-compatible, bound to loopback.** No prompt, diff or issue text leaves the host; the endpoint is not reachable off-box. | `deploy/serving/`, asserted in `tests/security` |
| L4 | **Guided decoding is used only if the startup probe proves it.** `EngineCapabilities.native_structured_output` is measured by issuing a constrained call, never asserted by configuration. | `llm/serving/probe.py` |
| L5 | **A local model is priced, not free.** Energy plus amortisation over a GPU-second gives a small non-zero rate, so `agent cost`, the reservation path and the MR evidence block keep working unchanged; GPU-seconds become the primary local ceiling. | `llm/pricing.py`, `kernel/budget.py` |
| L6 | **The context window is model-declared and tokenizer-measured.** Overflow is a first-class outcome that re-assembles once at a reduced budget, and is never `MODEL_FAILURE`. | `context/`, `llm/engines/vllm.py` |
| L7 | **Cloud fallback is allowed, opt-in per role, and counted.** When it fires it is on the span and in the MR evidence block; the third fallback in a run escalates. | `llm/engines/routing.py`, `Policy` |
| L8 | **The rollback is one line of configuration** — `roster.engine` back to `claude-cli` — exactly as `profile.engine` was the Phase 2–5 rollback. | `config.py: Roster` |
| L9 | **Serial by construction.** One in-flight model call per host; the `SKIP LOCKED` queue is unchanged, a local host simply advertises concurrency 1. | admission control in `workers/` |
| L10 | **Local is not trusted more for being local.** Trust boundary, broker and policy engine unchanged; injection resistance is measured and expected to be worse. | `tests/security`, `policies/rules/` |
| L11 | **Nothing cuts over on a claim.** The local reviewer runs in shadow against the cloud reviewer on real PRs; cutover requires *every disagreement explained*, not zero disagreements — the #43/#76 rule verbatim. | `orchestration/shadow.py`; #91 |
| L12 | **Local prompts are new `template_id`s, not edits to existing ones.** Q13's content-addressing only attributes a regression to a version if the version changes. | `agents/prompts/*-local.md` |

## The two worth contesting

Both alternatives are recorded rather than dismissed, because both are defensible and the
decision is reversible in configuration.

**L2 — swap, never co-resident.** The alternative is to keep the implementer resident and serve
a *smaller* reviewer alongside it, or to run the reviewer on CPU across the 48 cores. Both avoid
the swap cost entirely, which is the largest single overhead this phase introduces. They were
rejected for the same underlying reason in two forms: a reviewer small enough to co-reside is a
reviewer weak enough to approve what it should block, and CPU prefill on a 30k-token diff costs
more than the swap it avoids. The decision is revisited with numbers once #85 reports swap
seconds per run — if swap time exceeds review time, co-residency wins on evidence.

**L5 — price the local model.** The alternative is to let local cost be zero and rely solely on
time ceilings. It is simpler, and it silently removes the rail W3 exists to provide: every
`max_usd` ceiling becomes untrippable, and `agent cost` reports a column of `$0.00` for a run
that consumed a night of the only GPU. Pricing GPU-seconds keeps one currency across both
rosters and makes "what would this have cost on Anthropic" a subtraction rather than a
re-instrumentation.

## What this amends in 0001

**Q5 (which providers).** Extended: `local` joins `claude-cli`, `anthropic` and `openai`. The
`Engine` boundary was already validated by a second implementation; the local engine validates
it a third time against a provider with genuinely different *failure* modes rather than merely a
different wire format.

**Q6 (cost ceilings).** Unchanged in rule, extended in currency: an unset budget is still a
configuration error rather than "unlimited", and that now includes an unset GPU-second ceiling on
a local roster.

## Explicitly out of scope

Multi-GPU and distributed serving (Stage 2 of `selfhost.md`); renting an H100; fine-tuning or
LoRA adaptation on this repository; a second concurrent agent; serving these models to anything
other than this harness on this host.
