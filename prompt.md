# Task: Analyse and Redesign an AI Application-Building Harness

You are a senior software architect with:

* At least 10 years of experience designing finite-state-machine-based software systems.
* At least 5 years of experience designing production multi-agent AI systems.
* Strong experience with Python, shell scripting, Git, GitHub, GitLab, CI/CD, Claude Code CLI, distributed workers, workflow orchestration, and secure autonomous software delivery.

## Objective

Perform a comprehensive analysis of the shell scripts in the `@scripts/` directory.

These scripts form an AI application-building harness built around the Claude Code command-line interface. The current harness automates work against Git repositories, including issue processing, implementation, review, correction, testing, merging, deployment, and recovery.

Based on the existing implementation, propose a robust Python-based replacement architecture for an AI software-engineering agent that can:

1. Run interactively through a local CLI.
2. Run unattended as a scheduled process.
3. Be dispatched as a job to a local or remote worker.
4. Operate against GitHub or GitLab repositories.
5. Resume safely after interruption or infrastructure failure.
6. Degrade gracefully instead of crashing when tools, models, repositories, or external services fail.

Do not produce a generic greenfield architecture. Ground the proposed design in the actual shell scripts, behaviours, conventions, strengths, weaknesses, and operational requirements found in `@scripts/`.

---

# Required Analysis

## 1. Existing Harness Analysis

Inspect all relevant files under `@scripts/` and document:

* The purpose and responsibility of each script.
* Entry points and execution paths.
* Scheduling or dispatch mechanisms.
* Git and worktree lifecycle.
* Issue-to-branch mapping.
* Branch creation and naming.
* Agent invocation patterns.
* Prompt construction.
* Review and fix loops.
* Test and quality-gate execution.
* Merge behaviour.
* Deployment behaviour.
* Seed-data handling.
* Retry and recovery mechanisms.
* State persistence.
* Locking and concurrency control.
* Logging and observability.
* Human escalation points.
* Security assumptions.
* Failure modes.
* Duplicated logic.
* Hidden coupling between scripts.
* Behaviour that depends on shell-specific semantics.

Where useful, cite concrete file names, functions, commands, and line ranges.

Identify which parts should be:

* Preserved.
* Refactored.
* Replaced.
* Removed.
* Wrapped temporarily during migration.

## 2. Current-State Workflow

Reconstruct the current end-to-end workflow, including:

1. Receiving or selecting an issue.
2. Preparing a clean repository environment.
3. Creating an isolated Git worktree.
4. Creating a branch.
5. Running the implementation agent.
6. Reviewing the generated work.
7. Fixing identified problems.
8. Running existing and newly generated quality gates.
9. Preparing development deployment and seed data.
10. Merging safely into the default branch.
11. Cleaning up the worktree and temporary resources.
12. Recovering from interruption or failure.

Represent the current workflow using a Mermaid diagram.

---

# Target Architecture Requirements

Design a Python-based agent orchestration system that supports the complete issue-to-merge lifecycle.

## 3. Repository Work Lifecycle

The system must be able to:

* Connect to a separate target repository without modifying the harness repository.
* Support both GitHub and GitLab through a provider abstraction.
* Initialise work from an issue, task, or manually supplied instruction.
* Create a clean, isolated Git worktree.
* Create a dedicated branch.
* Validate repository cleanliness and expected base revision.
* Analyse and implement the issue.
* Review the implementation independently.
* Apply fixes based on review findings.
* Run quality gates.
* Prepare a development deployment.
* Create or validate seed data where required.
* Merge safely into the default branch.
* Clean up worktrees, branches, locks, credentials, and temporary resources.
* Preserve diagnostic artefacts when a job fails.

The merge strategy must be explicit and safe. Discuss options such as:

* Pull or merge request only.
* Fast-forward-only merge.
* Squash merge.
* Rebase before merge.
* Protected-branch integration.
* Human approval before final merge.

Recommend a default strategy and explain the trade-offs.

## 4. Execution Modes

The same orchestration core must support:

### Local CLI

Example operations should include:

```bash
agent run --repo <repository> --issue <issue-id>
agent resume --run-id <run-id>
agent inspect --run-id <run-id>
agent cancel --run-id <run-id>
agent retry --run-id <run-id> --from-state <state>
```

### Scheduled Execution

Support periodic polling or scheduled execution without embedding scheduling logic deeply inside the agent.

The design should be compatible with mechanisms such as:

* Cron.
* systemd timers.
* Kubernetes CronJobs.
* Cloud Scheduler.
* Celery Beat.
* Temporal schedules.

### Worker Dispatch

Support dispatching jobs to local or remote workers through a typed job contract.

Discuss suitable execution backends such as:

* Local subprocess workers.
* Celery.
* Dramatiq.
* Redis Queue.
* Kubernetes Jobs.
* Cloud Run Jobs.
* Temporal workers.

Recommend one lightweight starting option and one production-scale option.

---

# Orchestration Design

## 5. FSM-Based Multi-Agent Architecture

Use an explicit finite-state-machine-based orchestration model.

The top-level workflow must contain no more than seven states.

Use a two-level architecture only:

1. A primary router or supervisor.
2. Distinct specialist workers or subgraphs.

Do not introduce deeper agent hierarchies.

A recommended state model may include states such as:

1. `PREPARE`
2. `ANALYSE`
3. `IMPLEMENT`
4. `REVIEW`
5. `VALIDATE`
6. `INTEGRATE`
7. `COMPLETE`

You may propose a better state model, but the total must not exceed seven states.

For every state, define:

* Purpose.
* Entry conditions.
* Input schema.
* Output schema.
* Permitted tools.
* Responsible worker or subgraph.
* Deterministic transition conditions.
* Retry policy.
* Timeout policy.
* Failure transition.
* Checkpoint behaviour.
* Human approval conditions.
* Idempotency requirements.

## 6. Modular Subgraphs

Use subgraphs or equivalent modular state containers to hide domain complexity.

Potential domains include:

* Repository preparation.
* Issue analysis.
* Implementation.
* Code review.
* Fix application.
* Testing and quality assurance.
* Deployment preparation.
* Merge and cleanup.

Treat every subgraph as a black box with clear typed input and output contracts.

Subgraphs must not communicate directly with users or with unrelated workers. They return structured results only to the parent orchestrator.

## 7. Deterministic Routing

Use deterministic routing wherever possible.

Do not use LLM calls for standard workflow transitions.

Base routing decisions on:

* Typed state.
* Exit codes.
* Test outcomes.
* Review severity.
* Retry counters.
* Repository status.
* Mergeability.
* Policy rules.
* Human approval state.
* Explicit error categories.

Use LLM-based classification only where semantic judgement is genuinely necessary, and constrain it with typed schemas and confidence thresholds.

---

# Reliability and State Management

## 8. Typed Contracts

Use Pydantic models for:

* Job requests.
* Repository references.
* Issue metadata.
* Agent inputs.
* Agent outputs.
* Tool requests.
* Tool responses.
* Review findings.
* Quality-gate results.
* Deployment results.
* Cost and token usage.
* State transitions.
* Checkpoints.
* Errors.
* Human approval requests.

All LLM outputs must conform to strict Pydantic schemas.

When parsing fails:

1. Capture the invalid response.
2. Retry using a repair or clarification prompt.
3. Limit the number of repair attempts.
4. Fall back to a safe failure or human-review state.
5. Never silently accept malformed output.

## 9. Checkpointing

Persist immutable state snapshots at important transition boundaries.

The design should support PostgreSQL as the durable source of truth. Redis may be used for:

* Short-lived locks.
* Queue coordination.
* Rate limiting.
* Heartbeats.
* Ephemeral caches.

A checkpoint should include:

* Run ID.
* Job ID.
* Repository identity.
* Issue identity.
* Current state.
* Previous state.
* State version.
* Git base commit.
* Branch name.
* Worktree location.
* Prompt and model metadata.
* Tool-call summaries.
* Generated artefacts.
* Review results.
* Test results.
* Deployment results.
* Cost and token consumption.
* Retry counters.
* Timestamps.
* Error information.
* Human approval status.

Explain how checkpoints support:

* Resume.
* Retry from a specific state.
* Rollback.
* Audit.
* Human intervention.
* Worker failover.
* Duplicate-job prevention.

## 10. Idempotency and Concurrency

Design for safe repeated execution.

Address:

* Duplicate issue dispatch.
* Worker crashes.
* Lost acknowledgements.
* Repeated tool calls.
* Stale worktrees.
* Existing branches.
* Partially opened pull requests.
* Merge completed but checkpoint not updated.
* Deployment completed but response lost.
* Multiple workers claiming the same issue.

Use mechanisms such as:

* Idempotency keys.
* Lease-based job claims.
* Heartbeats.
* Optimistic concurrency control.
* Repository-level locks.
* Issue-level locks.
* Unique database constraints.
* Compare-and-swap state transitions.
* Git commit checks.
* Provider-side merge-request identifiers.

## 11. Retry and Fallback Strategy

Wrap external operations in typed retry policies with exponential backoff and jitter.

Categorise errors as:

* Transient.
* Rate limited.
* Authentication-related.
* Repository conflict.
* Validation failure.
* Model failure.
* Tool failure.
* Policy violation.
* Human intervention required.
* Permanent failure.

Define which errors are retryable and which are not.

The system must never enter an unlimited retry loop.

When recovery is not possible, it should:

* Preserve the worktree when diagnostically useful.
* Save logs and artefacts.
* Update the issue or pull request with a clear status.
* Produce a structured failure report.
* Escalate to a human when configured.
* Avoid destructive cleanup that would remove evidence.

---

# Context and Memory

## 12. Context Optimisation

Use a tiered context strategy:

### Active Context

Keep the current task, recent decisions, current diff, current errors, and recent tool results in full.

### Summarised History

Progressively summarise older agent interactions, decisions, failed attempts, and resolved findings.

Summaries must preserve:

* Decisions.
* Constraints.
* File references.
* Unresolved risks.
* Review findings.
* Test failures.
* Required follow-up actions.

### Repository Retrieval

Use repository-aware retrieval instead of sending the entire codebase to the model.

Possible retrieval inputs include:

* File paths.
* Symbols.
* Imports.
* Dependency graphs.
* Git diff.
* Test failures.
* Stack traces.
* Issue keywords.
* Code ownership.
* Recent commits.

Discuss whether a vector database is justified for source-code retrieval. If used, define:

* Chunking strategy.
* Metadata.
* Embedding lifecycle.
* Commit awareness.
* Staleness handling.
* Top-k selection.
* Reranking.
* Permission boundaries.

Prefer simpler repository-native search when it is sufficient, including:

* `ripgrep`.
* AST indexes.
* Language servers.
* Tree-sitter.
* Symbol graphs.
* Git history.
* Dependency analysis.

Do not recommend Pinecone by default unless the repository scale and retrieval pattern justify an external vector service.

---

# Operational Guardrails

## 13. Circuit Breakers

Implement hard limits for:

* State transitions.
* Agent iterations.
* Review-fix cycles.
* Tool calls.
* Model calls.
* Tokens.
* Cost.
* Wall-clock duration.
* Files changed.
* Lines changed.
* Test execution duration.
* Deployment attempts.
* Merge attempts.

When a limit is reached, the workflow must stop safely and produce a structured escalation report.

## 14. Approval Gates

Require explicit human approval for configurable high-risk operations, including:

* Deleting branches or environments.
* Modifying production infrastructure.
* Deploying to production.
* Rotating or changing credentials.
* Running database migrations.
* Removing data.
* Sending external notifications.
* Creating purchases or paid resources.
* Bypassing failed quality gates.
* Force-pushing.
* Overriding protected branches.
* Merging high-risk changes.

Development deployment may be automatic when policy permits. Production deployment should be out of scope by default unless explicitly approved.

## 15. Security

Address:

* Least-privilege repository tokens.
* GitHub App or GitLab application authentication.
* Short-lived credentials.
* Secret redaction.
* Prompt-injection risks from repository content and issue descriptions.
* Untrusted code execution.
* Sandboxed workers.
* Network egress restrictions.
* Tool allowlists.
* Command allowlists or policy validation.
* Dependency-installation risks.
* Supply-chain attacks.
* Malicious tests.
* Path traversal.
* Symlink attacks.
* Submodule risks.
* Audit logging.
* Tenant isolation.

Clearly distinguish trusted instructions from untrusted repository content.

---

# Quality Gates

## 16. Existing and New Quality Gates

The system must discover and execute existing repository quality gates before inventing new ones.

Existing gates may include:

* Unit tests.
* Integration tests.
* End-to-end tests.
* Linters.
* Formatters.
* Type checking.
* Build verification.
* Security scanning.
* Dependency checks.
* Migration checks.
* Container builds.
* CI workflows.

The agent may propose or generate new tests where coverage is missing, but it must not weaken, delete, skip, or rewrite existing quality gates merely to make a change pass.

Define:

* Required versus advisory gates.
* Gate discovery.
* Execution ordering.
* Timeouts.
* Result schemas.
* Flaky-test handling.
* Baseline failure handling.
* Regression comparison.
* Approval requirements for bypasses.
* Evidence attached to the pull or merge request.

## 17. Independent Review

The reviewer must be logically separated from the implementer.

Review should cover:

* Correctness.
* Requirement coverage.
* Maintainability.
* Security.
* Reliability.
* Test coverage.
* Performance.
* Backward compatibility.
* Data migration risk.
* Deployment risk.
* Unnecessary complexity.
* Scope creep.

Review findings must use a typed schema containing fields such as:

* Finding ID.
* Severity.
* Category.
* File.
* Line range.
* Evidence.
* Explanation.
* Required action.
* Blocking status.
* Confidence.

The orchestrator, not the reviewer, determines the next state using deterministic policy.

---

# Deployment and Seed Data

## 18. Development Deployment

Design an optional development-deployment subgraph that can:

* Detect repository-specific deployment configuration.
* Build deployable artefacts.
* Create an isolated development or preview environment.
* Apply safe configuration.
* Publish the preview URL.
* Run smoke tests.
* Record deployment metadata.
* Tear down expired environments.

The deployment interface must be provider-neutral and support adapters for systems such as:

* Docker Compose.
* Kubernetes.
* Cloud Run.
* Vercel.
* Netlify.
* Render.
* Fly.io.
* Repository-specific scripts.

## 19. Seed Data

Design seed-data handling that:

* Detects existing seed mechanisms.
* Avoids production data.
* Produces deterministic test data.
* Supports repeatable execution.
* Supports cleanup.
* Protects personally identifiable information.
* Records the seed version used for a run.
* Can be disabled by policy.

---

# Reusability and Code Organisation

## 20. Reusable Architecture

Do not duplicate orchestration, provider, retry, logging, state, or tool-execution logic.

Propose reusable abstractions for:

* Repository providers.
* Git operations.
* Worktree management.
* Issue providers.
* Pull and merge request providers.
* LLM providers.
* Tool execution.
* Agent workers.
* State transitions.
* Retry policies.
* Quality gates.
* Deployment providers.
* Checkpoint stores.
* Queue backends.
* Approval providers.
* Notification providers.
* Cost accounting.
* Observability.
* Policy enforcement.

Show a proposed Python package structure.

For example:

```text
ai_harness/
  cli/
  orchestration/
  states/
  subgraphs/
  agents/
  schemas/
  providers/
    git/
    github/
    gitlab/
    llm/
    deployment/
  tools/
  quality/
  persistence/
  workers/
  policies/
  security/
  observability/
  tests/
```

Improve this structure where appropriate.

---

# Observability

## 21. Logging, Metrics, and Tracing

Propose structured observability using:

* JSON logs.
* Correlation IDs.
* Run IDs.
* Job IDs.
* Repository IDs.
* Issue IDs.
* State-transition events.
* Tool-call timing.
* Model latency.
* Token usage.
* Cost.
* Retry counts.
* Test results.
* Queue latency.
* Worker health.
* Deployment status.
* Merge outcome.

Discuss OpenTelemetry integration for traces, metrics, and logs.

Include an audit event model for sensitive and irreversible actions.

---

# Migration Strategy

## 22. Shell-to-Python Migration

Provide an incremental migration plan rather than recommending a full rewrite in one step.

The migration plan should:

1. Identify stable shell-script behaviours that can initially be wrapped.
2. Extract shared configuration and schemas.
3. Introduce a Python state store.
4. Introduce typed Git and repository-provider adapters.
5. Move routing logic into a Python FSM.
6. Migrate one workflow stage at a time.
7. Run shell and Python implementations in shadow mode where practical.
8. Compare outcomes.
9. Add regression tests around existing behaviours.
10. Retire shell components only after behavioural parity is demonstrated.

Identify major migration risks and rollback strategies.

---

# Required Output

Write the final result to a Markdown file, such as:

```text
ai-harness-python-architecture.md
```

The document must include the following sections:

1. Executive summary.
2. Scope and assumptions.
3. Existing shell-harness analysis.
4. Current-state architecture.
5. Current-state workflow diagram.
6. Key weaknesses and operational risks.
7. Design principles.
8. Proposed FSM with no more than seven top-level states.
9. State-transition table.
10. Specialist agents and subgraphs.
11. Typed Pydantic contracts.
12. Repository and provider abstractions.
13. Local CLI design.
14. Scheduler and worker-dispatch design.
15. Checkpoint and persistence design.
16. Retry, fallback, and recovery strategy.
17. Context and retrieval strategy.
18. Security and operational guardrails.
19. Quality-gate design.
20. Development-deployment and seed-data design.
21. Observability and cost controls.
22. Proposed Python package structure.
23. Testing strategy.
24. Incremental migration plan.
25. Key trade-offs.
26. Recommended implementation phases.
27. Open questions and decisions requiring confirmation.

Include:

* Mermaid architecture diagrams.
* Mermaid sequence diagrams.
* A Mermaid FSM diagram.
* A state-transition table.
* Example Pydantic models.
* Example Python interfaces.
* Example CLI commands.
* Example worker job payload.
* Example checkpoint record.
* Example review-result schema.
* Example failure and escalation report.
* Pseudocode for the main orchestration loop.
* A clear mapping from existing shell scripts to proposed Python modules.

---

# Design Constraints

* No more than seven top-level FSM states.
* No more than two orchestration levels.
* Deterministic transitions by default.
* No unrestricted subagent-to-subagent communication.
* No duplicated orchestration logic.
* No unlimited retries.
* No silent quality-gate bypasses.
* No destructive actions without policy checks.
* No production deployment by default.
* No assumption that LLM output is valid.
* No assumption that repository content is trustworthy.
* No assumption that a worker will remain alive for the entire run.
* No generic architecture disconnected from the code in `@scripts/`.
* Prefer simple, testable abstractions over unnecessary frameworks.
* Clearly separate what should be implemented immediately from what is appropriate only at larger production scale.

When information cannot be determined from the repository, state the uncertainty explicitly and provide a recommended default rather than inventing facts.
