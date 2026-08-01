# 0001 — Adopted defaults for the fourteen open questions

Status: **accepted** · Date: 2026-08-01 · Supersedes: none · Tracked by: [#1](https://github.com/haroldmei/ai-harness/issues/1)

`ai-harness-python-architecture.md` §27 closes with fourteen questions, four of which block
Phase 0 and three Phase 3. **Every recommended default is adopted as written**, so no issue in
the build plan is blocked on a pending answer.

Where a default is a *value* rather than a *direction*, it is expressed in code and asserted by
a test — a decision recorded only in prose is a decision that drifts.

## Blocking before Phase 0

| # | Question | Decision | Where it lives |
|---|---|---|---|
| Q1 | Auto-merge to the default branch, or `MR_ONLY`? | **`MR_ONLY` is the shipped default**; `FF_ONLY` is opt-in per repository. Full auto-merge parity ships in Phase 4 but stays off by default. | `Policy.merge_strategy`, `RepoProfile.merge_strategy`, `policies/rules/standard.yaml` |
| Q2 | First targets — the same host project, or external repos? | **Assume external.** It forces `RepoProfile` to be honest from day one and prevents re-introducing the coupling of W12. | `schemas/profile.py`; a test fails if any host-project string reappears in the package |
| Q3 | Postgres available, or SQLite-only for Phases 0–2? | **Both, behind one `CheckpointStore` protocol**, from the start. | `config.database_url` defaults to SQLite; the protocol lands in Phase 1 (#21, #22) |
| Q4 | Single host, or a fleet within two quarters? | **Single host.** Ship `flock` leases; the `Lease` protocol makes the Postgres upgrade mechanical. | `kernel/lease.py` — `FlockLeaseBackend` today, Postgres in #61 |

## Blocking before Phase 3

| # | Question | Decision | Where it lives |
|---|---|---|---|
| Q5 | Which providers? | Anthropic API + `claude` CLI in Phase 0; **a second provider in Phase 3**, so the `Engine` boundary is validated by an implementation rather than by intent. | `llm/engines/`; #49 |
| Q6 | Per-run cost ceiling, and who owns it? | **$25/run, $500/repo/day.** An unset budget is a *configuration error*, not "unlimited" — the breaker denies a run whose budget was never configured. | `kernel/budget.py: DEFAULT_BUDGET`, `CircuitBreaker.check` |
| Q7 | Are the missing `deploy/systemd`, `docs/` and `CLAUDE.md` available? | **Proceed with the inferred defaults of §2** and reconcile if they appear. `tick` is safe to call every two minutes and holds no cadence of its own. | #56 |

## Non-blocking

| # | Question | Decision | Where it lives |
|---|---|---|---|
| Q8 | May the implementer install dependencies? | Only with a **lockfile present and `--ignore-scripts`**; otherwise approval-gated. Adding a dependency is a supply-chain decision. | `Policy.capabilities[INSTALL_DEPS] = require_approval`, `Policy.allow_deps_install_with_lockfile` |
| Q9 | Propose gates when a repo has none, or refuse? | **Propose in the MR body; never write CI config autonomously.** | `MODIFY_CI = require_approval`; discovery rung 5 escalates |
| Q10 | Retention for preserved worktrees | **72h**, with a TTL sweeper. | `FailurePolicy.preserve_worktree_ttl_h` |
| Q11 | Should `flake_adjudicator` exist? | **Start without it.** A confirmation re-run is deterministic evidence; a model adds judgement where evidence already exists. | `agents/flake_adjudicator.py` stays unimplemented; #53 |
| Q12 | Does the scout belong in this system? | **Separate service.** It shares `kernel/`, `llm/` and `providers/` but has its own lifecycle and accept-rate economics. | #67 |
| Q13 | How are prompt templates versioned? | **Content-addressed** — `template_id` + `sha256` on every span — rolled out per repo. A template change is a deployment. | `schemas/telemetry.Span`, `llm/client.py` |
| Q14 | Should `AWAITING_APPROVAL` time out? | **Yes: 24h → `DEFERRED`, 72h → `ESCALATED`.** An approval nobody answers is a decision not to proceed. | `ApprovalPolicy`, `schemas/approval.py` |

## Explicitly out of scope until asked

Multi-repository atomic changes; autonomous dependency upgrades; production deployment as a
default capability (`DEPLOY_PROD` is **denied**, not approval-gated, in every shipped policy);
agent-authored CI configuration; any action that spends money.
