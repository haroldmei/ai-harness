# Phase 7 — Self-hosted inference

Status: **planned** · Date: 2026-08-01 · Tracked by
[#95](https://github.com/haroldmei/ai-harness/issues/95) · Source:
[`selfhost.md`](../../selfhost.md) · Architecture:
[`ai-harness-python-architecture.md`](../../ai-harness-python-architecture.md)

## Objective

Run the harness that Phases 0–6 built against a model served on the workstation, so that one
autonomous agent can develop one product with **no per-token API cost**, and without weakening a
single rail that the shell harness paid for in incidents.

The claim to falsify is not "a 4090 can serve a 30B model" — it can. It is:

> **A locally served 30B model is good enough, and fast enough, to close the
> ANALYSE → IMPLEMENT → VALIDATE → REVIEW → INTEGRATE loop unattended.**

Everything below exists to make that claim measurable and, if it is false, to make the failure
visible in a day rather than in a week of silently degraded merges.

## What breaks when the model becomes local and free

Five assumptions are load-bearing in the current code and all five are assumptions about a
*remote, metered, large-context, well-behaved* model. Each is a work item, not a footnote.

1. **Cost stops being the rail.** Every ceiling in `kernel/budget.py` is denominated in USD.
   At $0/token `CircuitBreaker.check` still *runs*, but it can never trip on spend — and the
   scarce resource has moved to GPU-seconds. A loop that used to be stopped by $25 now costs a
   night of the only GPU in the building. §22.2's "checked before any spend" needs a second
   currency.

2. **`reviewer ≠ implementer` must survive one GPU.** `AgentRoster.__post_init__` *refuses to
   construct* a roster where the reviewer and implementer share a model (FR-075), and
   `LLMClient` holds exactly one `Engine`. Locally the two roles are two servers, and 24 GB
   holds one 4-bit 30B model at a time. The seam needs a router; the GPU needs an owner.

3. **The context window shrinks roughly 4×, and nothing measures it.**
   `ContextBudget.max_tokens` defaults to 120 000 and `estimate_tokens` is `len(text) // 4`.
   Against a ~32k local window vLLM answers `400 … maximum context length`, which the engine
   maps to `MODEL_FAILURE` — the wrong classification for the most predictable condition in the
   system. Overflow is deterministic and must be handled deterministically.

4. **Structured output stops being nearly free.** The extraction ladder (`llm/extract.py`) and
   the two-repair loop (`llm/structured.py`) were written for a model that mostly emits valid
   JSON. A 4-bit 30B does not, and a repair is a *full re-generation* — at 30 tok/s a repair
   costs minutes, not cents. Guided decoding turns schema conformance into a transport
   guarantee, and the repair loop becomes the exception path it was always meant to be.

5. **Whole-file edits are now priced in wall-clock.** `agents/implementer.py: FileEdit` writes
   whole files, deliberately (a patch that does not apply is a second failure mode). At 30 tok/s
   a 400-line file is ~90 s of generation and a five-file change is a ten-minute IMPLEMENT
   before a single test runs. Output tokens are the new dollar.

## Decisions adopted (L1–L12)

Recorded here so no issue is blocked on a pending answer, in the same spirit as
[0001](../decisions/0001-adopted-defaults.md). Each is reversible by configuration.

| # | Decision | Where it lives |
|---|----------|----------------|
| L1 | **Qwen3-Coder 30B (4-bit) implements, Devstral 24B (4-bit) reviews.** Both pinned by revision digest; a model upgrade is a deployment, not a pull. | `Roster`, serving unit |
| L2 | **One resident model at a time.** Never co-resident on 24 GB; the swap is taken under a lease, measured, and charged to the run that caused it. | model residency slot |
| L3 | **vLLM, OpenAI-compatible, bound to loopback.** No token leaves the host; the endpoint is not reachable off-box. | serving unit, `security/` |
| L4 | **Guided decoding is used only if the startup probe proves it.** `EngineCapabilities.native_structured_output` is *measured*, never asserted by configuration. | capability probe |
| L5 | **A local model is priced, not free.** Energy plus amortisation gives a small non-zero rate, so `agent cost`, the reservation path and the breaker keep working unchanged; GPU-seconds become the primary local ceiling. | `llm/pricing.py`, `kernel/budget.py` |
| L6 | **The context window is model-declared and tokenizer-measured.** Overflow is a first-class outcome that re-assembles smaller once, and is never `MODEL_FAILURE`. | `context/`, engine mapping |
| L7 | **Cloud fallback is allowed, opt-in per role, and counted.** When it fires it is on the span and in the MR evidence block; three fallbacks in a run escalates. "$0" stays an honest number rather than a hopeful one. | routing engine, `Policy` |
| L8 | **The rollback is one line of config.** `roster.engine: local` → `claude-cli`, exactly as `profile.engine` was the Phase 2–5 rollback. | `config.py` |
| L9 | **Serial by construction.** One in-flight model call per host; the `SKIP LOCKED` queue stays, but a local host advertises concurrency 1. | admission control |
| L10 | **Local is not trusted more for being local.** Trust boundary, broker and policy engine unchanged; injection resistance is *measured*, and expected to be worse. | `tests/security` |
| L11 | **Nothing cuts over on a claim.** The local reviewer runs in shadow against the cloud reviewer on real PRs; cutover needs every disagreement explained — the #43/#76 rule, reused verbatim. | `orchestration/shadow.py` |
| L12 | **Local prompts are new `template_id`s, not edits.** A model family that needs different framing gets `reviewer-v1-local`, so telemetry can attribute a regression to the version that caused it (Q13). | `agents/prompts/` |

`selfhost.md`'s 25–35 tok/s is taken as the **pessimistic bound for planning**, not as a
measurement. Iteration 7A measures the real number on this box, and every timeout, ceiling and
pacing default in 7C/7D is set from that measurement.

## Iterations

Each iteration ends in something falsifiable. Nothing in 7A–7D changes a repository's engine;
the cutover decision belongs to 7E.

**7A — Serving beachhead.** The model runs, the harness can call it, and the box can say why it
cannot. Read-only: `agent gates`-style proof, no run driven.

- #80 — Decision record — self-hosted inference defaults (L1–L12)
- #81 — serving: the vLLM unit, pinned model revisions, and the health contract
- #82 — llm: the vLLM engine and the local error taxonomy
- #83 — llm: the capability probe — guided decoding, prefix caching, context length

**7B — The seam.** Two models, one GPU, and the roster refusal still means something.

- #84 — llm: `RoutingEngine` — one engine per model, so reviewer ≠ implementer survives locally
- #85 — serving: model residency — the GPU slot lease, swap policy and the thrash guard

**7C — Telling the truth.** The two numbers the harness currently guesses become measured.

- #86 — context: tokenizer-accurate accounting, model-aware windows, prefix-cache-shaped ordering
- #87 — kernel: budgets when tokens are free — GPU-seconds, energy pricing and the time breaker

**7D — Fast enough to be useful.** Wall-clock is the constraint; spend it on tests, not on
re-typing files the model already has.

- #88 — agents: anchored edits — cut implementer output tokens at 30 tok/s
- #89 — orchestration: pacing a serial GPU — timeouts, admission control, one worker

**7E — Proving it.** The empirical half, and the only place a cutover is decided.

- #90 — agents: local prompt variants and the pathological-corpus conformance run
- #91 — Shadow-compare the local reviewer against the cloud reviewer on real PRs
- #92 — security: re-run the injection suite against the local model and record the delta

**7F — Operating it.** The box is now part of the system.

- #93 — observability: the GPU is part of the system — serving telemetry and `agent doctor`
- #94 — The unattended soak: one product, one week, and the runbook it produces

## Exit criteria for Phase 7

- One product built end to end, unattended, for seven days, with **API spend at $0** (or with
  every fallback counted and explained).
- Measured tok/s, tokens per state and wall-clock per state present in the run report — so the
  "GPU is idle during most of the workflow" claim in `selfhost.md` is confirmed or refuted with
  this repository's own numbers.
- Every shadow disagreement between the local and cloud reviewer explained, per L11.
- The full suite — unit, property, contracts, golden, chaos, security, integration — green with
  the local roster configured.

## Explicitly out of scope

Multi-GPU and distributed serving (Stage 2 of `selfhost.md`); renting an H100; fine-tuning or
LoRA adaptation of a coding model on this repository; a second concurrent agent; serving models
to anything other than this harness on this host.
