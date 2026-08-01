AI harness for app building

You are a senior software engineer with 10 years experience in FSM based software design and 5 years multi agentic system design experience. do a comprehensive code analysis for the shell scripts in @scripts/ folder, this is a ai app builder harness built around claude code command line. suggest a design for a robust, python based ai agent that can be scheduled or dispatched to a worker to work on a github/gitlab repository

- Hook and work on a separate reporitory in a clean worktree initialized by an issue, create a branch, review the work, fix the work, then merge back to main
- Can be used in local CLI, and dispatch to a runner

- Modular Orchestration: use FSM routed multi agentic design, follow the industry best practices
* Strictly control the number of states to be 7 or less.
* Limit Architectural Depth: Adhere to the two-level rule (a primary router/supervisor orchestrating distinct specialist subagents) rather than deep, multi-tiered state trees.
* Encapsulate via Subgraphs: Use nested state containers (like subgraphs in LangGraph) to hide complexity; treat individual domains as modular black boxes with clear input/output contracts.
* Use Deterministic Routers: Avoid expensive or unpredictable LLM calls for standard routing logic; rely on fast, deterministic intent classifiers, keyword matchers, or typed schemas for state transitions
* Enforce Strict Message Boundaries: Design child agents purely as workers that return data to the parent orchestrator, preventing subagents from haphazardly messaging users or overlapping in responsibility
* Implement Checkpointing and Fallbacks: Persist immutable state snapshots to external storage (like Redis or PostgreSQL) at key transition milestones to allow safe rollbacks and human-in-the-loop interruption gates

- Reusability: the design should abstract common modules to be reused, do not duplicate any part of the system.

- Minimal states: keep the design to have less than 

- Deterministic Reliability: enforce strict schemas using Pydantic for all LLM outputs. If the response doesn't parse, we retry with a clarified prompt. For tool calls, we wrap everything in retry logic with exponential backoff, and we have graceful fallbacks when things fail. The system should never crash — it should degrade gracefully and communicate clearly

- Context optimization: use a tiered approach. Recent messages stay in full, older conversation gets progressively summarized. For knowledge bases, I use RAG — embed documents into a vector DB like Pinecone, then retrieve only the top-k most relevant chunks for each query. This keeps context focused and costs down

- Operational Guardrails: Production agents need strict guardrails. implement circuit breakers that cap iterations, tokens, and wall-clock time. Any destructive action — deletes, purchases, external sends — requires explicit human approval. We also track costs per session and per user to prevent runaway spending. The agent should be safe to leave running without supervision.

- Quality gate, existing + new
- Dev deployment, seed data

Output the design to a markdown, use mermaid diagram if possible.