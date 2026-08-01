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
* **The runbook**: [`docs/runbooks/migration.md`](docs/runbooks/migration.md) — what must be true
  before each cutover, how to verify it, and how to get back.

## Status — Phases 0–4 are implemented

**Phase 0** changes no behaviour anywhere: the kernel, the typed contracts, the
structured-output layer, gate discovery, and a read-only CLI that runs the repository's *own*
gates. The rollback is "delete the package".

**Phase 1** adds the adapters and the state store. The shell pipeline stays authoritative and
keeps reading labels; it additionally calls `agent record` at each stage boundary, so runs,
checkpoints, counters and cost become queryable *before any behaviour moves*. The rollback is
"stop calling the helper".

**Phase 4** completes the loop: `VALIDATE` (whose fault is a red gate — with "the tooling could
not run" as a third answer) and `INTEGRATE` (`MR_ONLY` by default, compare-and-swap push, a
conflict-marker scan the resolver's own verdict cannot talk its way past). Plus `agent tick`
replacing the shell driver, the MR evidence block, and the chaos and security suites. `FF_ONLY`
is refused automatically unless the gates were *declared* rather than inferred and the base is
confirmed green.

**Phase 3** adds the states that write code: `ANALYSE` (the only state where a model makes a
routing-relevant judgement, schema-constrained) and `IMPLEMENT` (one subgraph, three briefs,
replacing three drifted shell implementations). Plus the capability broker, the approval
gateway, the triager, a second model provider and end-to-end budgets. Still behind the same
per-repo flag — nothing drives production until #76 closes.

**Phase 2** adds the orchestration core and the first ported state. The seven-state machine, the
pure router, the sandbox, the context layer and the reviewer all exist and run — but in **shadow
mode**: the Python reviewer produces a verdict and records it, while the shell path keeps posting
and owning the label. `ShadowComparator` diffs the *decisions*, and the cutover requires
agreement above threshold **and** every disagreement explained. The rollback is one flag
(`profile.engine`).

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
| `orchestration/` | The §9 transition table as data, a pure LLM-free router, the supervisor loop with breakers-before-spend and atomic checkpoints, and the shadow comparator |
| `security/` | Probed container/bubblewrap isolation that degrades loudly, path containment, and a sandbox environment with no credentials in it |
| `context/` | The trust boundary as a *type*, tiered assembly with pinned facts, diff bundling with elision markers, and repo-native retrieval (no vector store) |
| `agents/` | The `Agent` base (the only caller of `call_structured`), the roster that refuses a self-review, and the reviewer with its versioned prompt |
| `subgraphs/` | `REVIEW`, `ANALYSE` and `IMPLEMENT` — isolated, bounded, idempotent |
| `tools/` + `policies/` | Capability resolution before every action, path containment, an audit record per call, and approvals that park rather than block |
| `workers/` | `agent tick` — reconcile, admit, dispatch, sweep — single-pass and safe at a 2-minute cadence, with the scheduler outside the agent |

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
* the recorder cannot fail the shell stage that calls it;
* untrusted content cannot enter the instruction section — it is a different *type*;
* a reviewer and an implementer sharing a model cannot be configured at all;
* an empty envelope consumes no review round, and the streak is bounded at two;
* a verdict for an unchanged commit is reused rather than re-bought;
* nothing raises across a state boundary — the run parks, the process lives;
* no tool executes without a capability, and an unregistered tool is denied, not defaulted;
* a policy denial is never retried, and no context can soften one;
* an approval nobody answers is a decision not to proceed (24h → deferred, 72h → escalated);
* a red gate is classified from evidence before judgement — "the tooling could not run" is a
  third outcome, and a red base is never blamed on an unconfirmed guess;
* work with no signature never opens a self-filing loop;
* a deleted or skipped test parks the run **regardless of how green the suite is**;
* a flake is confirmed by re-running only the failed gate, and is reported rather than hidden;
* conflict markers never become a commit — the tree is the evidence, not the resolver's verdict;
* a push is refused if the base moved, and `FF_ONLY` is refused if the gates were inferred;
* no credential of any vendor reaches the sandbox — scrubbed by name *shape*, not by a list.

## Development

```bash
.venv/bin/ruff check ai_harness tests
.venv/bin/mypy                 # strict
.venv/bin/lint-imports         # the layering and the two forbidden edges
.venv/bin/pytest               # hermetic: zero network, zero LLM cost
```

The default test suite blocks outbound sockets and scrubs every ambient `AGENT_*`/`QG_*`
variable, so a suite cannot pass because of something inherited from the host.
