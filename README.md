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

## Status — Phases 0–7 are implemented

**Phase 7** brings the model in-house. `selfhost.md` picks vLLM and a 4-bit 30B on the existing
RTX 4090; what that costs is not the serving, it is the five assumptions the harness had baked in
about a *remote, metered, large-context, well-behaved* model. Cost stops being the rail, so
GPU-seconds become one, reserved before dispatch like dollars are. `reviewer != implementer` has
to survive one 24 GB card, so the GPU gets an owner and the swap gets a bill. The window shrinks
roughly fourfold while `estimate_tokens` was still `len // 4`, so counting became honest and
overflow became a first-class outcome that re-assembles once instead of blaming the model.
Schema conformance stops being nearly free, so guided decoding is *probed* rather than declared.
And whole-file edits become priced in wall-clock, so the model may express an edit as an anchor
and the harness re-materialises the file the broker sees.

Nothing cuts over on a claim: the local reviewer runs in shadow against the cloud one, the
rollback is `roster.engine: claude-cli`, and the two empirical halves — thirty real PRs compared,
seven days unattended — are open rather than assumed. See
[`docs/plans/phase-7-self-hosted-inference.md`](docs/plans/phase-7-self-hosted-inference.md) and
[`docs/runbooks/selfhost.md`](docs/runbooks/selfhost.md).

**Phase 0** changes no behaviour anywhere: the kernel, the typed contracts, the
structured-output layer, gate discovery, and a read-only CLI that runs the repository's *own*
gates. The rollback is "delete the package".

**Phase 1** adds the adapters and the state store. The shell pipeline stays authoritative and
keeps reading labels; it additionally calls `agent record` at each stage boundary, so runs,
checkpoints, counters and cost become queryable *before any behaviour moves*. The rollback is
"stop calling the helper".

**Phase 6** is the periphery, plus the piece that was missing underneath all of it. The
deployment stage (optional inside `VALIDATE`, denied beyond `dev` by policy *and* approval),
seed data as one implementation serving both the gate and the dev deploy, the canary flow, the
scout as a separate service that files issues and — enforced by an import contract — cannot start
a run, loop-until-dry, the optional pgvector adapter, and a real Tree-sitter symbol index that
answers "who calls X" from the call graph rather than from a text match.

Underneath: a **composition root**. Every module here has taken its collaborators as arguments
since Phase 0, which is what made them testable and also what left the graph unassembled — so
`agent work` and `agent tick` did not exist even though `Worker` and `Ticker` were finished.
They exist now, and they refuse to start against a repository whose `profile.engine` is still
`shell`.

**Phase 5** is the scale-out seam, and the first phase whose claims are proven against a real
Postgres rather than SQLite alone: leases move from `flock` to an expiry column any host can
evaluate, the queue becomes `SELECT … FOR UPDATE SKIP LOCKED` over the runs table that is
already there, GitLab arrives as a second `Forge` (one module, not a parallel tree), and spans
become exportable while still carrying a prompt *digest* and never prompt text. Running four
workers against one backlog on real Postgres found a bug that no mock could: two workers that
both find no lease row and both insert one. The unique key makes it safe, and losing that race
is now the ordinary "someone else owns it" answer rather than an exception.

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

.venv/bin/agent work --path .           # claim ready work, advance one boundary, exit
.venv/bin/agent tick --repo owner/name  # reconcile, admit, dispatch, sweep — one pass
.venv/bin/agent install --dry-run       # what the systemd units would be, before writing them
.venv/bin/agent preflight               # is it safe to flip the engine flag right now?

.venv/bin/agent shadow observe 412      # run both reviewers on PR #412; the Python path writes nothing
.venv/bin/agent shadow report --gate    # the §24 cutover gate — exits non-zero while blocked

.venv/bin/agent record --repo o/n --issue 7 --stage reviewer   # called BY the shell stages
.venv/bin/agent ls                      # every run and its (state, status)
.venv/bin/agent inspect <run>           # why is this stuck: the checkpoint timeline
.venv/bin/agent cost --days 7           # what has this cost, per run/repo/template
```

`agent work` and `agent tick` refuse to start unless `profile.engine` is `python`. That flag is
the rollback for every phase from 2 onward, and it is worth nothing if an entry point can route
around it — so the check lives in the composition root, not in the command.

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
| `workers/` | `agent tick` — reconcile, admit, dispatch, sweep — single-pass and safe at a 2-minute cadence, with the scheduler outside the agent; plus the claim-advance-exit worker and local subprocess fan-out |
| `deploy/` | Environments namespaced by run with offset port bands and name-scoped volume reaping, smoke against the *deployed* URL, seed data (seed ≠ verify ≠ idempotent), and the canary flow behind a policy override **and** an approval |
| `scout/` | The issue producer as a separate service: evidence re-verified locally, a different model refuting each candidate, dedup against open **and closed** issues, a per-run cap, and an import contract that stops it starting a run |
| `wiring.py` | The composition root — the only file that constructs what it did not receive, and the one that refuses at startup rather than mid-run |

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
* no credential of any vendor reaches the sandbox — scrubbed by name *shape*, not by a list;
* a lease taken over changes its token, so the old holder's renewal fails instead of silently
  extending a lease it no longer holds;
* two workers that race to create the same lease do not both get it, and the loser is told
  "unavailable" rather than handed an exception;
* the queue does not offer a run somebody is already holding — exactly, via the expiry column,
  with no staleness heuristic anywhere;
* a worker killed mid-run leaves the run resumable by any other worker, from its checkpoint;
* `SKIP LOCKED` is asserted against a genuinely held row lock on real Postgres, under a timeout,
  because a queue that blocks behind one slow worker is the failure it exists to prevent;
* no prompt text is exported to a tracing collector — `template_id`, sha256 and a byte count;
* an unreachable collector degrades to the local JSON sink: losing a span is survivable, losing
  a run is not;
* deploying beyond `dev` is denied by policy, and a policy override still requires an approval —
  two deliberate human acts, never one;
* volume reaping is name-scoped, and an unrelated volume is asserted to survive it;
* ports are offset per slot, never probed — two runs probing a shared base pick the same port;
* the e2e database has tmpfs and no named volume (three incidents of a stale revision surviving);
* seeding, verifying and idempotency are three separate results with three separate failures, and
  a DSN that is not unambiguously this run's own database is refused before any command runs;
* the canary is smoked at its *own* URL, and a rollback restores the recorded revision and still
  fails loudly;
* the scout re-verifies every `file:line` against the working tree, and cannot start a run;
* "who calls X" is answered from the call graph — a text match that is not a call is excluded;
* a stale vector entry is down-weighted and never cited with a line number;
* a repository that is not cut over cannot be driven, and a missing credential is refused at
  startup rather than after a claim has spent a lease;
* a shadow observation survives the process that made it, and re-observing the same review does
  not double-count it;
* the cutover gate requires **a week**, a rate *and* zero unexplained disagreements — perfect
  agreement over one afternoon is not evidence;
* an explanation written by a human is never erased by an automatic re-run;
* `agent install` run twice writes nothing the second time, and refuses to enable a timer for a
  repository that is not cut over.

## Development

```bash
.venv/bin/ruff check ai_harness tests
.venv/bin/mypy                 # strict
.venv/bin/lint-imports         # the layering and the two forbidden edges
.venv/bin/pytest               # hermetic: zero network, zero LLM cost
```

The default test suite blocks outbound sockets and scrubs every ambient `AGENT_*`/`QG_*`
variable, so a suite cannot pass because of something inherited from the host.

The persistence, lease and queue suites are parametrised over both backends. Point them at a
real Postgres to run the half that SQLite cannot demonstrate — `SKIP LOCKED`, `FOR UPDATE`, and
concurrent inserts racing a unique key:

```bash
docker run -d --name harness-pg -p 55432:5432 \
  -e POSTGRES_USER=harness -e POSTGRES_PASSWORD=harness -e POSTGRES_DB=harness postgres:16-alpine
uv pip install --python .venv 'psycopg[binary]'

HARNESS_TEST_POSTGRES_URL=postgresql://harness:harness@127.0.0.1:55432/harness .venv/bin/pytest
HARNESS_DATABASE_URL=postgresql+psycopg://harness:harness@127.0.0.1:55432/harness \
  .venv/bin/alembic upgrade head && .venv/bin/alembic check   # migrations match the models
```

Without it those cases **skip**, and a skipped case proves nothing — which is why the Postgres
pass is what Phase 5's claims rest on.
