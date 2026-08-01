AI harness for app building

do a comprehensive code analysis for the shell scripts in @scripts/ folder, this is a ai app builder harness built around claude code command line. suggest a design for a robust, python based ai agent that can be scheduled or dispatched to a worker to work on a github/gitlab repository

- Hook and work on a separate reporitory in a clean worktree initialized by an issue, create a branch, review the work, fix the work, then merge back to main
- Can be used in local CLI, and dispatch to a runner

- Modular Orchestration: use FSM routed multi agentic design

- Reusability: the design should abstract common modules to be reused, do not duplicate any part of the system.

- Deterministic Reliability: enforce strict schemas using Pydantic for all LLM outputs. If the response doesn't parse, we retry with a clarified prompt. For tool calls, we wrap everything in retry logic with exponential backoff, and we have graceful fallbacks when things fail. The system should never crash — it should degrade gracefully and communicate clearly

- Context optimization: use a tiered approach. Recent messages stay in full, older conversation gets progressively summarized. For knowledge bases, I use RAG — embed documents into a vector DB like Pinecone, then retrieve only the top-k most relevant chunks for each query. This keeps context focused and costs down

- Operational Guardrails: Production agents need strict guardrails. implement circuit breakers that cap iterations, tokens, and wall-clock time. Any destructive action — deletes, purchases, external sends — requires explicit human approval. We also track costs per session and per user to prevent runaway spending. The agent should be safe to leave running without supervision.

- Quality gate, existing + new
- Dev deployment, seed data