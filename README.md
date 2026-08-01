# ai-harness

An FSM-routed, multi-agent software-engineering worker: it takes an issue, builds it in an
isolated worktree, reviews it with a second model, fixes it, runs the repository's own quality
gates, and proposes the result — unattended, resumable, and bounded in dollars.

* **The design**: [`ai-harness-python-architecture.md`](ai-harness-python-architecture.md) —
  an analysis of the 90-script Bash harness in [`scripts/`](scripts/) and the Python
  replacement proposed from it.
* **The plan**: [GitHub issues](https://github.com/haroldmei/ai-harness/issues), grouped into
  seven milestones (P0–P6) that mirror §24 of the design. Each milestone has a tracking epic.
* **The decisions**: [`docs/decisions/0001-adopted-defaults.md`](docs/decisions/0001-adopted-defaults.md)
  — the fourteen open questions of §27, answered.

## Status — Phases 0 and 1 are implemented

**Phase 0** changes no behaviour anywhere: the kernel, the typed contracts, the
structured-output layer, gate discovery, and a read-only CLI that runs the repository's *own*
gates. The rollback is "delete the package".

**Phase 1** adds the adapters and the state store. The shell pipeline stays authoritative and
keeps reading labels; it additionally calls `agent record` at each stage boundary, so runs,
checkpoints, counters and cost become queryable *before any behaviour moves*. Nothing reads that
state to make a decision until Phase 4 — the rollback is "stop calling the helper".

```bash
uv venv --python 3.12 .venv && uv pip install --python .venv -e ".[dev]"

.venv/bin/agent gates discover .        # which rung of the ladder matched, and why
.venv/bin/agent gates run . --only unit # run the repo's own gates, interpret the result
.venv/bin/agent config show .           # the effective configuration, resolved
.venv/bin/agent config shell-env .      # the same bounds, for the existing shell stages

.venv/bin/agent record --repo o/n --issue 7 --stage reviewer   # called BY the shell stages
.venv/bin/agent ls                      # every run and its (state, status)
.venv/bin/agent inspect <run>           # why is this stuck: the checkpoint timeline
.venv/bin/agent cost --days 7           # what has this cost, per run/repo/template
```

`agent config shell-env` is the Phase 0 beachhead: the shell stages and the Python engine read
one schema, so a mixed rollout cannot disagree about `PR_MAX_ROUNDS` or `QG_GATE_TIMEOUT`.

### What is in the package today

| Module | What it carries |
|---|---|
| `kernel/` | `Outcome[T]` + the thirteen-member error taxonomy; retry policy as data; `flock` leases; budgets with pre-dispatch reservation; fingerprints; redaction; injectable clock |
| `schemas/` | Every typed contract, with the cross-field invariants **in** the model: approve-with-blockers is downgraded, a skipped required gate is a failure |
| `llm/` | The extraction ladder (each rung must *parse*), the bounded repair loop, `claude` CLI + Anthropic API + scripted engines, pricing with `effective_from` |
| `quality/` | The five-rung discovery ladder, the shell-spine adapter, the diagnostic-line extractor, inherited-red baselines, tier/requiredness semantics |
| `config.py` | 391 shell environment knobs replaced by one validated schema, plus `RepoProfile` and `Policy` |
| `observability/` | Structured JSON logs with redaction on the write path, and the conditional span-retention policy |
| `persistence/` | Runs, immutable checkpoints, leases, the fingerprint ledger, approvals and cost — one schema over SQLite **and** Postgres, with alembic migrations and the shadow-write recorder |
| `providers/git/` | One git client: worktrees, the three isolation strategies, generated-file rebase resolution, compare-and-swap push |
| `providers/forge/` | The `Forge` protocol, a REST GitHub adapter, labels as a projection, and a `FakeForge` that misbehaves on purpose |
| `workspace/` | Worktree materialisation with the three resume guards, deps provisioning **and verification**, and the evidence-first teardown with a 72h sweeper |

### Invariants under test

Every guarantee below has a named test, and each one is traceable to an incident in the shell
harness's own history (Appendix B of the design):

* a model call that never ran consumes no budget;
* "no output" is `UNKNOWN`, not a model failure;
* each extraction rung must parse — a lone `{` is not an answer;
* a schema-valid but self-contradicting verdict is corrected in code;
* a skipped required check is a failure; an unknown tier aborts;
* a branch is judged by the failures it *adds*;
* "the tooling could not run" is a third outcome, distinct from "the code is broken";
* the diagnostic line, never `tail -n1`;
* telemetry never fails the caller;
* the router cannot reach an LLM — enforced by an import contract, not by convention;
* a checkpoint and its run update land in one transaction, or neither does;
* `npm ci` exiting 0 is not evidence the install landed;
* work is tagged before it is gated, so cleanup cannot orphan a commit;
* a push is a compare-and-swap — if the base moved, it fails rather than forcing;
* the recorder cannot fail the shell stage that calls it.

## Development

```bash
.venv/bin/ruff check ai_harness tests
.venv/bin/mypy                 # strict
.venv/bin/lint-imports         # the layering and the two forbidden edges
.venv/bin/pytest               # hermetic: zero network, zero LLM cost
```

The default test suite blocks outbound sockets and scrubs every ambient `AGENT_*`/`QG_*`
variable, so a suite cannot pass because of something inherited from the host.
