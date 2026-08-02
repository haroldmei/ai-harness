# ai-harness — user manual

This is the operator's manual for the `agent` command: what it does, how to configure it, how to
run it, and what it refuses to do. It documents the **implementation as it stands** — where a
capability exists only as a library with no entry point, or as a state with no subgraph, this
manual says so rather than describing the design.

Companion documents:

* [`README.md`](../README.md) — what each phase added, and the invariants under test.
* [`ai-harness-python-architecture.md`](../ai-harness-python-architecture.md) — the design the
  package is a port of. Section numbers (§9, §19.2, …) in command output refer to it.
* [`docs/decisions/0001-adopted-defaults.md`](decisions/0001-adopted-defaults.md) — the fourteen
  questions (Q1–Q14) whose answers are the shipped defaults.
* [`docs/runbooks/migration.md`](runbooks/migration.md) — cutting a repository over, and back.
* [`docs/runbooks/selfhost.md`](runbooks/selfhost.md) — the local-model roster, day to day.

---

## Contents

1. [What this is](#1-what-this-is)
2. [Install](#2-install)
3. [Five minutes, read-only](#3-five-minutes-read-only)
4. [Concepts](#4-concepts)
5. [Configuration](#5-configuration)
6. [Command reference](#6-command-reference)
7. [Task recipes](#7-task-recipes)
8. [Operating a fleet](#8-operating-a-fleet)
9. [Self-hosted models](#9-self-hosted-models)
10. [Troubleshooting](#10-troubleshooting)
11. [Current limits](#11-current-limits)
12. [Developing on the harness](#12-developing-on-the-harness)

---

## 1. What this is

`ai-harness` is a **finite-state-machine-routed, multi-agent software-engineering worker**. Given
an issue, it prepares an isolated worktree, plans, implements, runs the repository's *own* quality
gates, has a *second, different* model review the result, fixes what that review found, and opens
a merge request — unattended, resumable, and bounded in dollars (and, on a local roster, in
GPU-seconds).

Three properties shape everything in this manual:

* **The FSM is the product.** Seven states, one transition table held as data, and a router that
  cannot reach an LLM — enforced by an import contract, not by convention. Every routing decision
  is deterministic and replayable.
* **Nothing is invented.** The harness discovers, orders, runs and interprets *your* gates. It
  never writes CI configuration autonomously and never weakens a check that already exists.
* **Everything refuses early.** A missing credential, an unknown engine name, an unknown gate
  tier, a roster where the reviewer and implementer share a model, a repository that has not been
  cut over — each is a startup error with a named remedy, not a mid-run surprise that has already
  spent a lease.

It is also a **port in progress**. This repository still contains the 91-script Bash harness in
`scripts/` that the Python package replaces. Phases 0–7 are implemented; Phase 8 (delete the
shell) is under way. Section [11](#11-current-limits) states precisely what is and is not
drivable today.

### What it is not

* Not a chat interface, an IDE plugin, or a code-completion tool.
* Not a production deploy system. `DEPLOY_PROD` is **denied** in the standard policy — not
  approval-gated, denied — because a capability you can approve your way into is a capability you
  have.
* Not a merge bot by default. `MR_ONLY` is the shipped merge strategy; `FF_ONLY` is opt-in per
  repository and is refused automatically unless the gates were *declared* rather than inferred
  and the base is confirmed green.

---

## 2. Install

Requires **Python 3.12+**. [`uv`](https://github.com/astral-sh/uv) is used below; `pip` works
identically.

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv -e ".[dev]"
.venv/bin/agent --help
```

Optional extras, each pulled in only when the feature is used:

| Extra | Installs | Needed for |
|---|---|---|
| `postgres` | `psycopg[binary]` | a shared store, SQL leases, `SKIP LOCKED` queueing, multi-host fleets |
| `treesitter` | `tree-sitter`, `tree-sitter-language-pack` | the call-graph symbol index ("who calls X") |
| `otel` | OpenTelemetry SDK + OTLP exporter | span export to a collector |
| `dev` | pytest, hypothesis, ruff, mypy, import-linter | running the harness's own gates |

```bash
uv pip install --python .venv -e ".[dev,postgres,treesitter,otel]"
```

The console script is `agent` (declared as `ai_harness.cli.main:app`). Everything below writes it
as `.venv/bin/agent`; put `.venv/bin` on `PATH` and it is just `agent`.

### Where state lives

| Path | What | Created by |
|---|---|---|
| `.harness/config.yaml` | the repository's configuration | you |
| `.harness/gates.yaml` | declared gates (discovery rung 1) | you, or `agent gates adopt --out` |
| `.harness/models.yaml` | the local model registry | you, for a self-hosted roster |
| `.harness/state/harness.db` | the SQLite run store | opened on first use |
| `.harness/state/probe-cache.json` | cached local-model capability probes | `agent serving probe` |
| `state/*.json` | the product build's sharded blackboard | `agent product init`, `agent verify` |
| `/tmp/ai-harness-leases/` | `flock` lease files (SQLite backend only) | the lease manager |

---

## 3. Five minutes, read-only

None of these writes to a forge, a branch, or your working tree. Run them in any repository.

```bash
.venv/bin/agent gates discover .          # which rung of the ladder matched, and why the others did not
.venv/bin/agent gates run . --only lint,format   # run some of the repo's own gates, interpret the result
.venv/bin/agent config show .             # the effective configuration, resolved
.venv/bin/agent config policy standard    # the shipped policy, with capabilities resolved
.venv/bin/agent route --gate typecheck --area src/app/page.tsx   # who owns this failure
.venv/bin/agent ls                        # every recorded run and its (state, status)
.venv/bin/agent doctor                    # can this box serve models? (needs .harness/models.yaml)
```

`gates discover` on this repository prints:

```
rung        : harness_config
entry point : —
inferred    : no
gates       : lint, format, typecheck, contracts, unit
```

`gates run . --only lint,format`:

```
── gates (tier launch, full set) ──
  ✅ lint                     0s
  ✅ format                   0s
  · typecheck                    filtered out
  · contracts                    filtered out
  · unit                         filtered out

wall-clock 0s · gate-time 0s (2.0x parallel)
RESULT: all required gates pass
```

Note what `·` means there: `typecheck` was *not selected* (absent from `--only`), which is an
honest skip. A required gate removed with `--skip`, or one that ran and reported "tooling absent",
is promoted to a **failure** — see [Gates](#gates-tiers-and-the-discovery-ladder).

---

## 4. Concepts

### The run

A **run** is the durable unit of work: one issue, one branch, one row. Its position is the pair
`(state, status)`, and everything a shell pipeline used to reconstruct by scraping PR comments —
review rounds, self-repair attempts, empty-envelope streaks, deps retries — is a durable counter
on that row.

Runs are identified by a `run_id`; `agent ls` shows the first 8 characters, and `agent inspect`
accepts either.

### The seven states

```
PREPARE → ANALYSE → IMPLEMENT → VALIDATE → REVIEW → INTEGRATE → COMPLETE
```

| State | What happens | Default timeout | Max attempts |
|---|---|---|---|
| `PREPARE` | materialise the worktree, pin the base, provision deps | 15 min | 3 |
| `ANALYSE` | the one state where a model makes a routing-relevant judgement, schema-constrained | 10 min | 3 |
| `IMPLEMENT` | one subgraph, three briefs (`build`, `fix`, `repair`) | 45 min | 6 |
| `VALIDATE` | run the gates; classify whose fault a red one is | 90 min | 6 |
| `REVIEW` | a *different* model reviews; verdict is schema-checked and self-corrected | 20 min | 4 |
| `INTEGRATE` | compare-and-swap push, conflict scan, open the MR | 30 min | 3 |
| `COMPLETE` | terminal | 60 s | 1 |

There is no eighth state. **Parking is not a state** — a deferred run *is* in its state, which is
what makes resume trivially "re-enter the same state".

### The status axis

| Status | Meaning |
|---|---|
| `running` | in flight, or ready to be advanced |
| `deferred` | waiting out a timer (transient error, rate limit, environment) |
| `blocked` | waiting on an external blocker; cleared by reconciliation when the blocker closes |
| `awaiting_approval` | a human must decide; 24 h → deferred, 72 h → escalated (Q14) |
| `parked_terminal` | finished; see `disposition` |

### Dispositions

`delivered` (an MR is open — the `MR_ONLY` success), `merged`, `escalated`, `blocked`,
`abandoned` (someone else holds the claim), `cancelled`. Every terminal disposition has a
re-entry path; a queue with terminal states and no way back rots.

### Signals and the transition table

A subgraph that ran successfully returns a **signal** — `advance`, `replan`, `fix`, `regate`,
`repin`, `retry_same`, `needs_approval`, `blocked`, `escalate`, `delivered`, `merged`,
`abandoned`. A subgraph that failed returns an **error category**, and the two are routed by two
separate tables in `ai_harness/orchestration/transitions.py`:

* `SIGNAL_ROUTES` — one row per `(state, signal)`. A missing edge is a test failure, not a
  runtime surprise.
* `route_error(state, category)` — uniform across states, because "the provider rate-limited us"
  means the same thing everywhere.

The consequence that matters operationally: categories in `NON_BUDGET_CONSUMING` park the run in
the **same** state, increment nothing, and cost nothing. *A model call that never ran consumes no
budget* is structural, not a convention.

Deferral times by category: `transient` 60 s, `rate_limited` 300 s, `environment` 300 s,
`unknown` 30 s. `auth` is never retried. `policy` denial is never retried and no context can
soften it.

### Gates, tiers and the discovery ladder

`agent gates discover` walks five rungs, most authoritative first:

| Rung | Source | Marked |
|---|---|---|
| 1 | `.harness/gates.yaml` | declared |
| 2 | an entry point: `scripts/quality-gates.sh`, `make check`, `just ci`, `tox`, `nox` | declared |
| 3 | a parseable CI workflow | **inferred** |
| 4 | a manifest (`pyproject.toml`, `package.json`, `go.mod`, `Cargo.toml`) | **inferred** |
| 5 | nothing | escalates |

Rung 5 is a hard rule: **a repository with no discoverable gate cannot be autonomously delivered
into.** It can still get an MR under `MR_ONLY`, carrying a `no_gates_discovered` banner — what it
cannot do is merge ungated. `agent gates discover` exits **3** in that case.

The `inferred` mark travels with the profile all the way to the MR evidence block, and `FF_ONLY`
is refused when gates were inferred rather than declared.

**Tiers** — `toy`, `preview`, `launch` (default), `scale` — decide *requiredness*, not
membership. A gate declares `required_from_tier: toy` and is then required at every tier at or
above it. An **unknown tier aborts** rather than defaulting downward: guessing low is the one
interpretation that can ship red code.

**Skip is not pass.** A gate required at this tier that returns "tooling or inputs absent" (exit
77) is promoted to `FAIL`, and the report says so (`promoted: a skipped required check is a
failure`). Absence from `--only` is an honest skip; removal via `--skip` is not.

**Inherited red is forgiven.** A branch is judged by the failures it *adds*: a gate already
failing on the exact base sha is marked `inherited` and does not fail the branch.

**"The tooling could not run" is a third outcome**, distinct from "the code is broken" and from
"the base was already red". `agent gates run` exits **4** for it.

### Policy, capabilities and approvals

No tool executes without a **capability**, and an unregistered tool is denied rather than
defaulted. Policy is evaluated against the capability, never against a command string.

The standard policy:

| Capability | Decision |
|---|---|
| `read_repo`, `write_workspace`, `run_tests`, `git_push`, `forge_comment` | allow |
| `install_deps` | require_approval (Q8 — a dependency addition is a supply-chain decision) |
| `network`, `git_force_push`, `forge_merge`, `modify_ci`, `modify_migrations`, `deploy_dev` | require_approval |
| `deploy_prod`, `bypass_gate` | **deny** |

An unknown capability denies. An approval nobody answers is a decision not to proceed: 24 h →
`deferred`, 72 h → `escalated`. Approvals **park** the run; they never block a process.

Three shipped policies live in `policies/rules/`: `standard`, `permissive`, `readonly`, plus
`local` (see [§9](#9-self-hosted-models)), which moves `install_deps`, `git_force_push` and
`deploy_dev` from *approvable* to *denied* — under prompt injection the approval **is** the
attack surface.

Touching a `protected_paths` entry routes to approval regardless of how green the gates are.

### Budgets

Checked **before any spend**, not recorded after it. An unset budget is a *configuration error*,
never "unlimited" — the only reading of an unset ceiling that cannot spend someone's money by
accident.

| Ceiling | Default (`DEFAULT_BUDGET`) |
|---|---|
| `max_usd_per_run` | $25 |
| `max_usd_per_repo_day` | $500 |
| `max_wall_clock_s` | 6 h |
| `max_model_seconds_per_run` | unset (set to 2 h by `LOCAL_BUDGET` / the `local` policy) |
| `max_gpu_seconds_per_repo_day` | unset (16 h locally) |

On a local roster the dollar rails cannot trip in a working day, so **GPU-seconds are the rail** —
reserved before dispatch and settled against actual generation time, exactly as dollars are.

### Isolation and the sandbox

Isolation is **probed at startup**, in preference order container → bubblewrap → none, and the
level actually obtained is recorded on the run. A run that silently degraded to no isolation is a
run whose safety claims are false, so degradation is loud and `allow_degraded_isolation: false`
refuses it.

**No credential reaches the sandbox.** The environment is scrubbed by the *shape* of the variable
name (`(^|_)(TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|AUTH|APIKEY|PAT)($|_)`), plus known prefixes —
not by a vendor list somebody remembered. Git runs in the harness; the model gets a filesystem and
no way to push.

### Trust boundary

Issue bodies, diffs, gate logs and review comments are **untrusted content**, and that is a
different *type* from instructions — untrusted content cannot enter the instruction section of a
prompt because the type system does not permit it.

### Leases, the queue and concurrency

* **SQLite store** → `flock` leases in `lease_dir`. One host by construction, and `flock` is both
  correct and cheaper there.
* **Postgres store** → SQL leases with an expiry column any host can evaluate, and a queue built
  on `SELECT … FOR UPDATE SKIP LOCKED` over the runs table.

A lease taken over changes its token, so the old holder's renewal fails rather than silently
extending a lease it no longer holds. Two workers racing to create the same lease do not both get
it; the loser is told "unavailable", which is an ordinary answer and not an exception.

A worker holds **no local state and no affinity to a run**. One that dies is replaced by any
other, and the run resumes from its last checkpoint. That is why the fleet story is "start the
process more than once".

`host_concurrency` (default **1**) is how many runs *this host* may advance at once. One is not a
placeholder: a local roster serves one model call at a time, so a second concurrent run halves
throughput and adds model swaps on top.

### Single-pass, always

No command in this package contains a sleep loop or a cron expression. `agent work` and
`agent tick` do one pass and exit; systemd, Kubernetes or a person decides the cadence. A binary
that loops internally needs its own health checks, back-pressure and shutdown story, and is still
a worse version of what a supervisor already provides.

---

## 5. Configuration

### Precedence

Lowest to highest:

1. defaults declared on the models;
2. `.harness/config.yaml` (committed, reviewable);
3. environment variables prefixed `HARNESS_`, with `__` nesting;
4. explicit CLI arguments.

The file sits *below* the environment deliberately: an operator overriding one setting for one run
should not have to edit a committed file.

```bash
HARNESS_PROFILE__ENGINE=python .venv/bin/agent config show .
HARNESS_DATABASE_URL=postgresql+psycopg://harness:harness@127.0.0.1:5432/harness .venv/bin/agent ls
```

Configuration is a **schema**, not a pile of `${VAR:-default}`: an invalid value fails at startup
with its field path, and an unknown key is rejected (`extra: forbid`) rather than silently
ignored. This replaces the 391 distinct shell knobs the harness used to carry.

### `.harness/config.yaml` — the full surface

```yaml
# ── where and how ────────────────────────────────────────────────────────────
forge: github                 # github | gitlab
tier: null                    # null → use profile.tier
log_level: info               # debug | info | warning | error
log_format: json
host_concurrency: 1           # runs this host may advance at once
state_dir: .harness/state
lease_dir: /tmp/ai-harness-leases
database_url: sqlite:///.harness/state/harness.db

# ── the repository's own conventions (nothing here is inferred) ───────────────
profile:
  name: acme/app              # owner/name — required by tick and install
  default_branch: main
  remote: origin
  branch_prefix: "agent/issue-"      # agent/issue-N, bidirectional, no stored table
  workspaces: [backend, frontend]    # used by deps provisioning and reset lists
  tier: launch                       # toy | preview | launch | scale
  gate_entry_point: null             # override the discovered entry point
  iterations_dir: docs/iterations
  iteration_index: ""                # empty → this repo keeps no generated index
  generated_paths: []                # conflicts here: take base + regenerate, never a model
  provisioned_paths: [node_modules, .env, .venv, "*/node_modules"]
  env_files: []
  compose_project_prefix: harness
  merge_strategy: mr_only            # mr_only | ff_only | merge_commit | squash
  build_skill: null                  # the repo's own build convention, if it has one
  protected_paths:                   # touching one routes to approval, however green
    - ".github/workflows/**"
    - "**/migrations/**"
    - "**/alembic/**"
    - "infra/**"
    - "**/*.tf"
    - "Dockerfile*"
    - "docker-compose*.yml"
  engine: shell                      # shell | python — THE per-repo cutover flag

# ── who plays which role ─────────────────────────────────────────────────────
roster:
  engine: claude-cli          # claude-cli | anthropic | openai | local
  planner_model: claude-sonnet-5
  implementer_model: claude-sonnet-5
  reviewer_model: claude-opus-5        # MUST differ from implementer_model
  conflict_resolver_model: claude-opus-5
  triager_model: claude-haiku-4-5-20251001
  engines: {}                 # per-model engine names; see §9
  fallback_engine: null       # null = a local outage defers rather than spends money
  fallback_models: []
  max_fallbacks_per_run: 3

# ── the operating envelope ───────────────────────────────────────────────────
policy:
  name: standard
  merge_strategy: mr_only
  require_isolation: bubblewrap
  allow_degraded_isolation: false
  require_approval_to_start: false
  allow_deps_install_with_lockfile: true
  egress_allowlist: []
  capabilities:
    read_repo: allow
    write_workspace: allow
    run_tests: allow
    install_deps: require_approval
    network: require_approval
    git_push: allow
    git_force_push: require_approval
    forge_comment: allow
    forge_merge: require_approval
    modify_ci: require_approval
    modify_migrations: require_approval
    deploy_dev: require_approval
    deploy_prod: deny
    bypass_gate: deny
  budget:
    max_usd_per_run: "25"
    max_usd_per_repo_day: "500"
    max_wall_clock_s: 21600
  approval:
    max_files_changed: 40
    max_lines_changed: 1500
    approve_on_risk: true
    timeout_to_deferred_h: 24
    timeout_to_escalated_h: 72
  failure:
    preserve_worktree_on: [escalated]
    preserve_worktree_ttl_h: 72
    always_preserve_artefacts: true
    update_forge_on_failure: true
    notify_on: [escalated, blocked]

# ── bounds, shared with any surviving shell stage ────────────────────────────
bounds:
  pipeline_max_rounds: 10
  pipeline_rearm_max: 3
  pipeline_max_open_prs: 3
  pipeline_escalate_stuck_hours: 6
  pr_max_rounds: 4
  pr_empty_envelope_retries: 2
  pr_fixer_max_self_repair: 3
  pr_fixer_deps_max_retry: 3
  pr_merger_max_env_defer: 3
  merger_resolver_retries: 3
  triage_max_attempts: 3
  triage_max_open: 5
  triage_max_self_repair: 2
  triage_max_transient: 8
  gate_timeout_s: 3600
  cpu_jobs: 3
  stack_jobs: 2
```

> **The named policies are templates, not references.** `policies/rules/*.yaml` are read by
> `agent config policy <name>` for inspection. The `policy:` block above is the one the harness
> actually uses, so adopting `local` or `readonly` means copying its body into
> `.harness/config.yaml`.

`bounds` exists for the mixed rollout: `agent config shell-env` renders exactly the variables the
remaining shell stages read, so both engines cannot disagree about `PR_MAX_ROUNDS` or
`QG_GATE_TIMEOUT`.

```bash
eval "$(.venv/bin/agent config shell-env .)"
```

### Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `HARNESS_*` (`__` nests) | every command | overrides any config field |
| `HARNESS_DATABASE_URL` | the store, and alembic's `env.py` | the run store |
| `GITHUB_TOKEN` / `GH_TOKEN` | `build_forge` | without one, `INTEGRATE` is left **unbound** and runs escalate there with a reason |
| `GITLAB_TOKEN` | `build_forge` when `forge: gitlab` | as above |
| `ANTHROPIC_API_KEY` | the `anthropic` engine | **required at startup**, refused early |
| `OPENAI_API_KEY` | the `openai` engine | as above |
| `VLLM_API_KEY` | the `vllm`/`local` engine | optional |
| `HARNESS_TEST_POSTGRES_URL` | the test suite | enables the Postgres half of persistence/lease/queue tests |

Note the asymmetry, and it is deliberate: a missing **API key** for a configured engine refuses at
startup, while a missing **forge token** does not — a repository can be analysed, implemented and
validated without one. What it cannot do is integrate, so that state is left unbound and the run
parks for a human instead of failing at the moment it tries to push.

### `.harness/gates.yaml` — declaring gates (rung 1)

```yaml
tier: launch

gates:
  - name: lint
    kind: shell
    command: [".venv/bin/ruff", "check", "ai_harness", "tests"]
    required_from_tier: toy      # required at toy and every tier above
    timeout_s: 300
    resource: cpu                # `stack` gates boot containers/bind ports → own semaphore
    after: []                    # ordering dependencies
    advisory: false              # advisory gates are never required
    baseline: false
    flake_retries: 0             # confirmation re-runs, never blind retries
    artefacts: []
    workdir: "."
    env: {}

fast_set: [lint, format, typecheck, contracts]
cpu_jobs: 4
stack_jobs: 1
```

Write commands as explicit paths (`.venv/bin/ruff`), not bare names. A bare `ruff` is whichever
`ruff` is on `PATH`, which is how a gate quietly starts checking with a different version than the
one that gates the merge.

A declaration that has drifted from the pipeline it claims to mirror is worse than no declaration,
because it reads as a promise — this repository has a unit test asserting its `gates.yaml` matches
its CI.

### `.harness/models.yaml` — the local model registry

See [§9](#9-self-hosted-models). Every number in it is an *artefact fact* (weights, KV bytes per
token, native window), and the vLLM flags are derived from them — never copied from a blog post
written against an 80 GB card.

---

## 6. Command reference

### Exit codes

Used consistently across commands:

| Code | Meaning |
|---|---|
| 0 | success / green / nothing to do |
| 1 | red — a gate failed, a check is unhealthy, the cutover is blocked, a run is in flight |
| 2 | configuration refused — bad value, unknown tier, missing token, not cut over |
| 3 | no gates discovered (distinct from "a gate failed") |
| 4 | the tooling could not run (environment) |

`agent record` is the exception: it **always exits 0**.

---

### `agent gates`

#### `agent gates discover [PATH] [--tier T] [--json]`

Walk the ladder; report the rung that matched and why the ones above it did not. Exits **3** when
nothing was discovered.

#### `agent gates run [PATH] [--only A,B] [--skip C] [--tier T] [--fast] [--json]`

Run the repository's gates and interpret the result. A *discovered* spine (rung 2) is called
through its own entry point and its scorecard consumed; a *declared* profile (rung 1) has no entry
point, so the native runner executes the specs directly.

`--only` is an allow-list (honest skip); `--skip` is a deny-list (a required gate removed this way
becomes a failure). `--fast` runs `fast_set`. Exits 0 green, 1 red, 3 no gates, 4 environment.

> **`--fast` and required gates.** Selection is computed from `--only`/`--skip` only, so a gate
> that `fast_set` merely omits keeps selection `ran`. If it is required at this tier it is then
> promoted to a failure and the fast run reports **red**, whereas the same gate omitted via
> `--only` is an honest skip. On this repository `--fast` excludes `unit` — which is
> `required_from_tier: toy` — so `agent gates run . --fast` exits 1 with
> `❌ unit  filtered out  [promoted: a skipped required check is a failure]`. Use
> `--only <fast gates>` for a genuinely fast green run, or keep every required gate in `fast_set`.

#### `agent gates adopt [PATH] [--spine P] [--scorecard S] [--out O] [--tier T]`

Read a shell spine and **propose** the equivalent `.harness/gates.yaml`. Writes nothing without
`--out` — a gate declaration is the contract by which the harness is allowed to merge, so a human
reads it before it becomes one (Q9). Gates it cannot express are listed with a reason.

#### `agent gates compare [PATH] [--declared D] [--commit SHA] [--repo R] [--explain "gate=why"] [--report]`

Run both spines on this commit and diff them per gate; record the comparison. Exits non-zero while
any disagreement is unexplained, so a nightly job notices rather than a person remembering to look.
`--explain gate=why` accounts for one. `--report` reads the record and runs nothing.

Disqualifying disagreements are fixed in advance: a lost gate, a verdict that flipped green, a
gate demoted to advisory.

---

### `agent verify` and `agent route`

#### `agent verify [PATH] [--tier T] [--max-attempts 3] [--max-rounds 1] [--report-only | --loop]`

Run the gates, route each failure to its owner, and write `state/verdict.json`. This is the
**product build's** red→green loop, not the harness's review⇄fix loop.

* Attempts are counted **per gate**, durably, in `state/testing.json` — a loop bounded by rounds
  lets one gate consume the whole budget while another is never attempted.
* The verdict is a value, not an exit code: `PASS`, `ISSUES_OPEN` (gates green but adversarial
  findings remain), `ROUTED`, `EXHAUSTED`.
* **Report-only by default.** The orchestrator applies fixes; a loop that iterated without a fixer
  would run identical gates against an identical tree and call that progress.

```
═══ verdict: ROUTED  (rounds=1) ═══
  routed: typecheck → frontend-developer (attempt 1)
  EXHAUSTED: e2e → e2e-tester (attempt 3)
```

#### `agent route --gate G [--area PATH]`

Which agent owns a failing gate. `typecheck`, `lint` and `unit` route by the **failing path**, not
by the gate — a type error under `src/components/` is the frontend developer's and the same error
under `prisma/` is the migrator's. Prints `unknown` when nothing claims it, which is deliberate: an
unrouted gate is one somebody has to look at, and silently assigning it would hide that.

---

### `agent config`

| Command | What |
|---|---|
| `agent config show [PATH]` | the **effective** configuration as JSON — resolved values, not the file's contents |
| `agent config shell-env [PATH]` | `export` lines for the knobs the shell stages read |
| `agent config policy NAME` | print a shipped policy (`standard`, `permissive`, `readonly`, `local`, or a path) |

---

### `agent record` — the shell's dual-write helper

```bash
agent record --repo owner/name --stage reviewer [--issue 7] [--outcome merged] \
             [--branch B] [--base-sha S] [--head-sha S] [--mr 412] [--error E] [--path .]
```

Called **by** the surviving shell stages at each stage boundary. Stages map onto states
(`inbox`/`build`/`fixer` → `IMPLEMENT`, `triage` → `ANALYSE`, `gates` → `VALIDATE`,
`reviewer` → `REVIEW`, `merger` → `INTEGRATE`); an unmapped stage records as `PREPARE` rather than
being dropped, because an unmapped stage is still evidence.

**It always exits zero**, and it is idempotent — a boundary is keyed by `(run, state, seq)`. That
is what keeps Phase 1's rollback at "stop calling the helper": an observability helper that can
fail the production pipeline is worse than no helper.

---

### Reading durable state

| Command | Answers |
|---|---|
| `agent ls [--repo R] [--status S] [--state ST] [--limit 25] [--json]` | every run and its `(state, status)`, with a one-line *why* |
| `agent inspect RUN [--json]` | why is this run where it is: position, spend, last error, checkpoint timeline |
| `agent cost [--repo R] [--days 7]` | what this has cost — per run, per repo, per template; local and hosted split, GPU-seconds beside dollars |
| `agent replay RUN` | the decision sequence reconstructed from checkpoints. No side effects |

`agent ls` on a fresh checkout prints `no runs recorded`, not `no such table` — a reader should
never have to know whether a writer has run yet.

---

### Driving runs

#### `agent work [--path .] [--worker-id ID] [--batch 1] [--repo R] [--force]`

Claim ready work, advance each claimed run to its next boundary, and exit. `--batch` is capped by
`host_concurrency` (and the reduction is logged with its reason).

#### `agent tick [--path .] [--repo owner/name] [--force]`

One pass: **reconcile → admit → dispatch → sweep**. Safe at a 2-minute cadence; two overlapping
ticks do no double work, because dispatch takes a lease per run and a held lease is a no-op rather
than an error.

Reconciliation is a **stateless sweep** — it takes no argument about "what just happened", reads
the world as it is, and makes it consistent. It closes every open issue whose branch has landed
*regardless of who landed it*, which fixes the post-merge index race, a dropped `close` call, and a
human merge, all with one behaviour. It also releases stale claims, unblocks runs whose blocker
closed, and escalates anything parked past the deadline.

`tick` requires a forge token: without one, every check reconciliation performs would silently
pass, and a tick that does nothing still looks like a tick that ran.

**Both refuse to start unless `profile.engine` is `python`.** The check lives in the composition
root, not in the command, so no entry point can route around it:

```
refusing to start: this repository is not cut over: profile.engine is 'shell'. The shell
pipeline is still authoritative for it, and driving both would mean two engines advancing one
run. Set engine: python to cut over — that flag is also the rollback.
```

`--force` overrides that for a scratch repository. Do not use it against a repository the shell
timer is still driving.

---

### `agent install` and `agent preflight`

#### `agent install [--path .] [--repo R] [--unit-dir D] [--interval 2min] [--labels-only] [--units-only] [--enable] [--dry-run]`

Render and write the `tick` and `work` systemd user units and their timers, and record the label
set the loop projects onto (`agent`, `wip`, `done`, `needs-human`, `harness-shadow`, `proposed`,
`proposed-speculative`).

**Idempotent in the strong sense**: nothing is *written* on a second run. Every action reports
`created`, `updated` or `unchanged`, and a re-run yields all-unchanged — comparing content rather
than existence is what keeps `daemon-reload` unnecessary and "did anything change?" answerable.

`--enable` also enables and starts the timers, and **refuses** (exit 1) if `profile.engine` is not
`python`. It never disables the shell timer: the migration keeps the shell merger installed and
disabled for one release, and removing it automatically would remove the rollback while installing
the thing that might need it.

Start with `--dry-run`.

#### `agent preflight [--path .] [--repo R]`

Is it safe to flip the engine flag right now? Exits non-zero if any run is in flight, so the flip
is gated by a script rather than by someone deciding a list looked empty at 6pm on a Friday.

---

### `agent shadow` — the cutover gate

| Command | What |
|---|---|
| `agent shadow observe PR [--repo R] [--round 1]` | run the Python reviewer beside the shell one on a pull request and record the pair. Writes nothing to the forge — and *refuses* unless the configured forge client is write-blocked |
| `agent shadow explain RUN HEAD_SHA "which engine was right, and why" [--round 1]` | account for one disagreement. **One at a time, on purpose** — a bulk-clear would satisfy the letter of the criterion and destroy the point |
| `agent shadow report [--repo R] [--days 7] [--gate]` | agreement rate, observation window, per-path cost, and the reasons the cutover is still blocked, in words. `--gate` exits non-zero while blocked |

The gate requires **a week**, a rate above threshold, *and* zero unexplained disagreements.
Perfect agreement over one afternoon is not evidence. Expect the Python reviewer to be *right* in
some disagreements; a disagreement is not automatically a regression, but an unexplained one is a
blocker. An explanation written by a human is never erased by an automatic re-run.

---

### `agent product` and `agent iteration`

The product build's sharded blackboard, ported off `jq`. Paths are validated as *parses*, not
regexes — the parsed segments are what performs the write, so an expression that survived the
check still could not be executed. Every path resolves to exactly one shard by construction; a key
with no owner does not silently fall back to a write.

| Command | What |
|---|---|
| `agent product init ["the idea"]` | create the shards, or fill in fields a previous version lacked. The existing document always wins |
| `agent product set KEY JSON` | set one field in whichever shard owns it; prints the file it changed |
| `agent product get KEY` | read one field, as JSON, pipeable |
| `agent product decide PHASE DECISION REASON` | append to both `decisions.md` and the `decisions` array |
| `agent product show` | every shard, merged, for reading |
| `agent iteration count [current\|next\|peek]` | `next` claims and persists; `peek` does not |
| `agent iteration index [--check]` | regenerate the iteration index; `--check` fails if stale |
| `agent iteration check [--base origin/main]` | fail if this branch modified or deleted a past iteration |

```bash
agent product set .scale_tier '"launch"'
agent product get '.testing.gate_attempts."e2e"'
```

Writes take a `flock` per shard — a set is a read-modify-write, and `mv` makes the replacement
atomic without doing anything about two builds racing between the read and the write. Output is
byte-identical to `jq`'s, because the skills that read these files treat the format as an
interface.

`iteration index` needs `profile.iteration_index` set; where a repository keeps its iterations is
that repository's convention, and hard-coding it would assume the one project the package is
supposed to be able to target.

---

### `agent doctor` and `agent serving`

See [§9](#9-self-hosted-models).

---

## 7. Task recipes

### Run your repository's gates through the harness

```bash
.venv/bin/agent gates discover .           # confirm which rung matched
.venv/bin/agent gates run . --fast         # the fast set
.venv/bin/agent gates run . --json > report.json
```

If discovery lands on rung 3 or 4 (`inferred: yes`), the harness can still run the gates but will
refuse `FF_ONLY`. Move to rung 1 or 2 before expecting autonomous merges.

### Turn a shell spine into a declaration, and prove it faithful

```bash
.venv/bin/agent gates adopt . --spine scripts/quality-gates.sh --out .harness/gates.yaml
# read it — this is the contract by which the harness may merge

.venv/bin/agent gates compare . --commit "$(git rev-parse HEAD)" --repo acme/app
.venv/bin/agent gates compare . --explain "e2e=the shell spine ran it against a stale container"
.venv/bin/agent gates compare . --report        # exits non-zero while anything is unexplained
```

Run `compare` over at least five commits before trusting the declaration.

### Record shell-stage state without changing any behaviour

Add to each shell stage, at its boundary:

```bash
eval "$(agent config shell-env .)"
agent record --repo "$REPO" --issue "$ISSUE" --stage reviewer --outcome "$OUTCOME" \
             --branch "$BRANCH" --head-sha "$HEAD_SHA"
```

Then verify the "cannot fail its caller" claim on the actual host:

```bash
HARNESS_DATABASE_URL=postgresql+psycopg://nobody@127.0.0.1:1/none bash scripts/agent-inbox.sh
echo "exit=$?"    # expect 0
```

Within a day, `agent ls` and `agent cost --days 1` answer *why is this stuck* and *what has this
cost* — before any behaviour moves.

### Cut a repository over

The rule that outranks everything: **cut over only when no run is in flight.**

```bash
.venv/bin/agent preflight --repo acme/app        # exits non-zero if anything is running
.venv/bin/agent shadow report --repo acme/app --gate   # zero unexplained disagreements, a week of data
# .harness/config.yaml → profile.engine: python
.venv/bin/agent install --repo acme/app --dry-run
.venv/bin/agent install --repo acme/app --enable
```

Rolling back is the same flag in reverse plus re-enabling the shell timer. Nothing needs undoing
in the database: durable state is a superset of what the shell reads, and the shell ignores it.
[`docs/runbooks/migration.md`](runbooks/migration.md) has the per-phase preconditions and the
rollback drill — rehearse it on a scratch repository before you need it on a real one.

### Roll back a prompt regression

A template change is a deployment (Q13). `template_id` and the prompt `sha256` ride on every span
and checkpoint:

```bash
.venv/bin/agent inspect <run> --json | jq '.checkpoints[] | {state, template_id, prompt_sha256}'
```

Pin the previous `template_id` in the roster. **Do not edit the template in place** — that makes
the regression invisible in the telemetry that would otherwise explain it.

### Move the store to Postgres

```bash
docker run -d --name harness-pg -p 5432:5432 \
  -e POSTGRES_USER=harness -e POSTGRES_PASSWORD=harness -e POSTGRES_DB=harness postgres:16-alpine
uv pip install --python .venv 'psycopg[binary]'

export HARNESS_DATABASE_URL=postgresql+psycopg://harness:harness@127.0.0.1:5432/harness
.venv/bin/alembic upgrade head
.venv/bin/alembic check          # migrations match the models
```

Then set `database_url` in `.harness/config.yaml`. Two things change automatically: leases move
from `flock` to an expiry column any host can evaluate, and the queue becomes `FOR UPDATE SKIP
LOCKED`. **Alembic owns the schema in deployment** — the Postgres store is opened with
`create=False`, so a worker cannot start against a database nobody migrated.

---

## 8. Operating a fleet

### The cadence

```
[Unit]
Description=ai-harness tick for acme/app

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
```

`agent install` renders both unit pairs. Use `--dry-run` first; use `--enable` only after the
cutover.

### What to look at

```bash
.venv/bin/agent ls --status running          # in flight
.venv/bin/agent ls --status deferred         # waiting, and why
.venv/bin/agent ls --status awaiting_approval
.venv/bin/agent cost --days 1
.venv/bin/agent inspect <run>
```

`agent ls` prints a *why* column that answers "why is this stuck" without opening a log:
`blocked on <ref>`, `awaiting approval <id>`, `deferred until <ts>`, `running after: <error>`.

### Scaling out

Start `agent work` on more than one host against a shared Postgres. There is nothing else to
configure — no worker identity registry, no partitioning. Running four workers against one backlog
on real Postgres is what found the bug no mock could: two workers that both find no lease row and
both insert one. The unique key makes it safe, and losing that race is now the ordinary "someone
else owns it" answer.

### Telemetry

Structured JSON logs with **redaction on the write path**, so a caller who forgets to redact is
still safe. Telemetry never fails the caller: a broken sink is swallowed, because losing a log
line is survivable and losing a run is not.

Span retention is conditional: errors and expensive calls for 14 days, a deterministic ~8%
content-hash sample for 3 days, the rest dropped at the end of the tick. Content-hashed rather
than random, so the *same* failure is retained or dropped consistently across runs.

**No prompt text is ever exported** to a tracing collector — `template_id`, a sha256 and a byte
count. An unreachable collector degrades to the local JSON sink.

---

## 9. Self-hosted models

Phase 7 brings the model in-house: vLLM serving a 4-bit 30B implementer and a 4-bit 24B reviewer on
one 24 GB card. The cost is not the serving — it is the five assumptions the harness had baked in
about a *remote, metered, large-context, well-behaved* model.

The consequences you will meet as an operator:

* **One model is resident at a time (L2).** Two 4-bit models do not fit 24 GB, so
  `reviewer != implementer` is preserved by *swapping*, and the GPU has an owner and a residency
  lease. Each rendered unit `Conflicts` with the others; a hand-typed `systemctl start` is the one
  path the lease cannot see.
* **GPU-seconds are a rail** (see [Budgets](#budgets)), reserved before dispatch like dollars.
* **The window shrinks roughly fourfold**, so token counting became honest and context overflow is
  a first-class outcome that re-assembles once rather than blaming the model.
* **Schema conformance stops being nearly free**, so guided decoding is *probed*, not declared.
* `lease_ttl_s` rises to 3600 s automatically when any engine is `local`/`vllm` — a local state can
  be a model swap plus several minutes of generation, and a lease that expires mid-generation is a
  lost run.

### Before anything

```bash
.venv/bin/agent doctor
```

Read-only; it fixes nothing on purpose — a diagnostic that repairs things is a diagnostic people
are afraid to run. Real output on a healthy box with nothing started:

```
ok   gpu                          RTX 4090: 2% busy, 22.1 GB free, 35°C
ok   thermals                     clocks are not being limited
warn serving:qwen3-coder-30b      the serving endpoint exposed no metrics: All connection attempts failed
     remedy: start it: `systemctl --user start ai-harness-serve-qwen3-coder-30b`
ok   vram:qwen3-coder-30b         qwen3-coder-30b needs 19.0 GB; 22.1 GB free
```

| Check | Meaning | Action |
|---|---|---|
| `gpu` FAIL | no driver, or the card is invisible from this environment | install the NVIDIA driver; under WSL, check `nvidia-smi` in the same shell |
| `thermals` warn | clocks are being limited | the box generates slower than every timeout was derived from — check airflow and the power limit, then re-run `bench` |
| `serving:<m>` warn | that model's server is down | normal for the non-resident model. If *neither* is up, start one |
| `vram:<m>` warn | not enough free memory | stop the other model's unit first |

### Starting the stack

```bash
.venv/bin/agent serving ls                                   # what fits, and the derived window
.venv/bin/agent serving args qwen3-coder-30b --explain       # the flags, and the arithmetic
.venv/bin/agent serving unit qwen3-coder-30b \
  > ~/.config/systemd/user/ai-harness-serve-qwen3-coder-30b.service
systemctl --user daemon-reload
systemctl --user start ai-harness-serve-qwen3-coder-30b
.venv/bin/agent serving check qwen3-coder-30b
```

`check` demands a **returned token**, not a bound port: vLLM accepts connections while still
loading, and that window is long enough for a worker to claim a run against a model that cannot
answer yet. It also refuses a server whose loaded revision is not the pinned one.

Nothing in `agent serving` starts or stops anything. Installing is `agent install`'s job, and the
separation is deliberate: a command that both renders and starts is one people run before they
have read what it renders.

### Measuring this box (once, and after any driver or model change)

```bash
.venv/bin/agent serving bench qwen3-coder-30b --out docs/measurements/serving.md
.venv/bin/agent serving probe qwen3-coder-30b
.venv/bin/agent serving conformance qwen3-coder-30b --out docs/measurements/conformance.md
```

Every timeout, ceiling and pacing default cites the bench numbers, which is why they are committed.
`probe` caches capabilities against the exact `(server, model, revision)` — an unprobed server is
*slower*, not unsafe: every structured call falls back to the extraction ladder and costs repairs.
The composition root warns rather than refusing, because it does no network I/O.

### The roster on a local box

```yaml
roster:
  engines:
    qwen3-coder-30b: local
    devstral-24b: local
  implementer_model: qwen3-coder-30b
  reviewer_model: devstral-24b
  planner_model: qwen3-coder-30b
  triager_model: qwen3-coder-30b
  conflict_resolver_model: devstral-24b
  fallback_engine: anthropic       # null → a local outage defers rather than spends money
  fallback_models: ["devstral-24b"]
  max_fallbacks_per_run: 3
```

When `engines` is non-empty, **every** model the roster names must appear in it. An unlisted model
is a startup error, because defaulting would route a typo somewhere plausible — and the resulting
review would look exactly like a real one.

Fallback is opt-in per model and counted. When it fires it appears on the span and in the MR
evidence block, and the third one in a run escalates rather than spending more.

Use `policies/rules/local.yaml` as the policy body: local is not trusted *more* for being local.
Instruction-hierarchy adherence is one of the clearest capability gaps between a frontier model and
a 30B one, and this harness feeds the model issue bodies, diffs and gate logs written by strangers.

### Upgrading a model

A model upgrade changes the behaviour of every agent at once. It is a deployment.

1. update `revision` in `.harness/models.yaml` — a **digest, never a tag**;
2. `agent serving check <model>` — it refuses a server serving anything else;
3. `agent serving probe <model>` — the cache is keyed on the revision, so new weights get a new answer;
4. `agent serving conformance <model>` — compare against the committed baseline;
5. commit both the pin and the new numbers.

### Rollback

```yaml
roster:
  engine: claude-cli
  engines: {}
```

That is the whole rollback. The states, the queue, the store and the gates are identical on either
roster. Rehearse it before the soak, not after.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `refusing to start: … not cut over: profile.engine is 'shell'` | `work`/`tick` guard | set `profile.engine: python`, or pass `--force` on a scratch repo |
| `refusing to start: tick needs a forge token` | no `GITHUB_TOKEN`/`GITLAB_TOKEN` | export one; without it every reconciliation check would silently pass |
| `INTEGRATE is unbound: no forge token is configured` (warning) | same, but non-fatal | runs escalate at `INTEGRATE` with a reason rather than failing mid-push |
| `ANTHROPIC_API_KEY is not set` at startup | a configured engine needs it | export it — refusing now costs a process exit; refusing later costs a lease and a dispatch |
| `unknown engine 'claude-cl'` | typo in `roster.engine` | nothing is defaulted on purpose; fix the name |
| `roster.engines names no engine for X` | mixed roster missing a mapping | map every model the roster names |
| `REFUSING: the reviewer and the implementer must use DIFFERENT models` | roster validator (FR-075) | give them different models — a self-review that looks like a review is worse than none |
| `no gates discovered` / exit 3 | ladder rung 5 | declare `.harness/gates.yaml`, or add an entry point |
| exit 4 from `gates run` | the tooling could not run | fix the environment; this is *not* "the code is broken" |
| a gate shows `promoted: a skipped required check is a failure` | a required gate returned 77, or was `--skip`ped | run it, or stop requiring it at this tier |
| `--fast` reports red with `❌ <gate> filtered out [promoted: …]` | the gate is required at this tier but absent from `fast_set`, and fast-set filtering does not mark it *not selected* | use `--only` for a scoped run, or add the gate to `fast_set` |
| a gate shows `inherited from the base — forgiven` | the base sha already failed it | expected; the branch is judged on what it *adds* |
| `--tier lanuch` → error, not a weaker run | unknown tier aborts | fix the spelling; guessing downward is the one reading that ships red code |
| `invalid configuration in .harness/config.yaml: profile.tier: …` | schema validation | the message names the field path |
| a run sits in `deferred` | transient/rate-limit/environment | `agent inspect <run>`; it retries next tick and consumed no budget |
| a run sits in `awaiting_approval` | policy or protected path | answer it; 24 h → deferred, 72 h → escalated |
| a run sits in `blocked` | an external blocker | reconciliation unblocks it when the blocker closes |
| a run stays stuck across several ticks | a bug | file it — every terminal state has a re-entry path, so this is not a run to delete |
| `agent preflight` exits 1 | a run is in flight | wait; flipping mid-run means two engines advancing one run |
| `agent install --enable` refuses | repository not cut over | install the units now, enable them after the shadow comparison closes |
| `shadow observe` refuses: "the configured forge can write" | shadow needs a write-blocked client | the shell path owns the label during the comparison |
| `serving check` says the revision does not match | the server loaded other weights | restart the unit against the pinned digest |
| Postgres tests skip | `HARNESS_TEST_POSTGRES_URL` unset | a skipped case proves nothing — set it |

---

## 11. Current limits

Honest scope, verified against the code rather than the roadmap:

* **`PREPARE` and `COMPLETE` have no subgraph.** `ai_harness/subgraphs/prepare.py` and
  `complete.py` are placeholders. `wiring.build_registry` binds `ANALYSE`, `IMPLEMENT`, `REVIEW`,
  `VALIDATE` and (with a forge token) `INTEGRATE`. A run entering an unbound state gets a
  `NEEDS_HUMAN` failure — *"PREPARE is not implemented yet (arrives in a later phase)"*, remedy
  *"drive this state with the shell engine until that phase lands"* — which parks the run in
  `awaiting_approval` for a human rather than letting it look like a success. Since every run
  starts at `PREPARE`, a fully autonomous issue→MR run is **not** drivable end to end from the CLI
  today.
* **There is no run-intake command.** Nothing in the CLI creates a run from an issue. Rows arrive
  either from the shell stages calling `agent record`, or programmatically via
  `SqlStore.create(JobRequest(...))`. `agent tick` reconciles, dispatches and sweeps existing runs;
  it does not poll the forge for new issues.
* **The scout has no entry point.** `ai_harness/scout/service.py` implements the five disciplines
  (evidence re-verification, a different-model critic, dedup against open *and closed* issues, a
  per-run cap, and an import contract that stops it starting a run) — but nothing constructs it and
  there is no `agent scout` command.
* **There is no `agent deploy`.** The deployment library (`deploy/`, `providers/deploy/`) exists;
  the command in the Phase 8 plan does not.
* **`scripts/` is still present** — 91 shell files. Phase 8 deletes them one group at a time, and
  nothing is deleted because it was ported: only because the port was *shown* to behave the same.
* **Two empirical claims are open**: thirty real PRs compared between the local and cloud
  reviewers, and seven days unattended. The code they need is in place; the numbers belong in
  `docs/measurements/`.

---

## 12. Developing on the harness

```bash
.venv/bin/ruff check ai_harness tests
.venv/bin/ruff format --check ai_harness tests
.venv/bin/mypy                 # strict
.venv/bin/lint-imports         # the layering and the two forbidden edges
.venv/bin/pytest               # hermetic: zero network, zero LLM cost
```

Or through the harness itself — these five *are* its declared gates:

```bash
.venv/bin/agent gates run .                              # all five
.venv/bin/agent gates run . --only lint,format,typecheck,contracts   # the fast four
```

(`--fast` reports red here — see the note under
[`agent gates run`](#agent-gates-run-path---only-ab---skip-c---tier-t---fast---json).)

The default suite **blocks outbound sockets** and scrubs every ambient `AGENT_*`/`QG_*` variable,
so a suite cannot pass because of something inherited from the host.

`lint-imports` enforces two edges that are contracts rather than style: the router cannot reach an
LLM, and subgraphs cannot import each other sideways. A violation is a build failure, never a
review comment.

### The Postgres half

```bash
docker run -d --name harness-pg -p 55432:5432 \
  -e POSTGRES_USER=harness -e POSTGRES_PASSWORD=harness -e POSTGRES_DB=harness postgres:16-alpine
uv pip install --python .venv 'psycopg[binary]'

HARNESS_TEST_POSTGRES_URL=postgresql://harness:harness@127.0.0.1:55432/harness .venv/bin/pytest
HARNESS_DATABASE_URL=postgresql+psycopg://harness:harness@127.0.0.1:55432/harness \
  .venv/bin/alembic upgrade head && .venv/bin/alembic check
```

Without it, `SKIP LOCKED`, `FOR UPDATE` and the concurrent-insert race **skip** — and a skipped
case proves nothing, which is exactly what Phase 5's claims rest on.

### Adding a state, a gate or a capability

* **A transition** is a row in `SIGNAL_ROUTES`, not a branch in code. `render_table()` emits it as
  Markdown so documentation cannot drift from the behaviour.
* **A gate** is data (`GateSpec`). The harness never invents one.
* **A capability** is a member of `Capability` plus a decision in the policy. Unknown capabilities
  deny — unknown fails closed, everywhere.
* **A collaborator** is a constructor argument. `wiring.py` is the only file allowed to construct
  what it did not receive, which is what makes everything else testable and what keeps the
  "refuse at startup" guarantee in one place.
