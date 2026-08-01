# Migration runbook — cutting a repository over, and getting back

§24.1 lists seven migration risks with a mitigation and a rollback each. A mitigation that lives
only in a design document is not a mitigation, so this is the operational version: what must be
true before each flip, how to verify it worked, and how to undo it.

**The rule that outranks everything below:** cut over only when no run is in flight for that
repository. Not "when it looks quiet" — `agent ls --status running` must be empty, and
`drained()` is the same check as a function so it can gate a script.

```bash
.venv/bin/agent ls --repo <owner/name> --status running    # must print nothing
```

---

## Phase 0 — foundation

| | |
|---|---|
| **Preconditions** | none |
| **The flip** | none — the package ships read-only commands |
| **Verify** | `agent gates run <repo> --only unit` reproduces the shell scorecard |
| **Rollback** | delete the package |

There is no behaviour to roll back. If `agent gates run` disagrees with `scripts/quality-gates.sh`,
that is a bug in the adapter, not a reason to revert anything.

## Phase 1 — the state store

| | |
|---|---|
| **Preconditions** | a writable database URL; the shell stages can reach the `agent` binary |
| **The flip** | add `agent record …` calls to the shell stages |
| **Verify** | `agent ls` shows runs appearing; a full day of real ticks agrees with the labels |
| **Rollback** | **stop calling the helper** |

The recorder cannot fail its caller. Verify that claim on the actual host before trusting it:

```bash
# Point the config at an unreachable database, then run a stage. It must still exit 0.
HARNESS_DATABASE_URL=postgresql+psycopg://nobody@127.0.0.1:1/none bash scripts/agent-inbox.sh
echo "exit=$?"   # expect 0
```

## Phase 2 — REVIEW in shadow mode

| | |
|---|---|
| **Preconditions** | Phase 1 recording for at least a week |
| **The flip** | run the Python reviewer alongside, writes blocked |
| **Verify** | `ShadowComparator.may_cut_over()` — agreement above threshold **and** zero unexplained disagreements |
| **Rollback** | one flag |

**Do not skip the comparison.** Expect the Python reviewer to be *right* in some disagreements —
the shell reviewer's known defects (#2419's `{`-character extraction, approve-with-blockers) are
in the comparison set. A disagreement is not automatically a regression; an *unexplained* one is
a blocker.

## Phase 3 — ANALYSE + IMPLEMENT

| | |
|---|---|
| **Preconditions** | Phase 2 cut over on this repository; budgets configured |
| **The flip** | `profile.engine: python` for one repository |
| **Verify** | `--dry-run` parity first: same issue, same plan shape, no writes |
| **Rollback** | flip the flag back — the shell path is untouched |

Work is never lost on a bad cutover: the branch is tagged before gating and pushed before
proposing, so the worst case is a branch nobody used.

## Phase 4 — VALIDATE + INTEGRATE

| | |
|---|---|
| **Preconditions** | Phase 3 stable for a week; a **discovered** (not inferred) gate set; a green base |
| **The flip** | `MR_ONLY` first — always, even for repositories that will end on `FF_ONLY` |
| **Verify** | a week of opened-but-human-merged MRs, compared against what the shell merger would have done |
| **Rollback** | re-enable the shell timer; the merger stays installed and disabled for one release |

`FF_ONLY` is refused automatically unless the gates were declared rather than inferred and the
base is confirmed green (`may_enable_ff_only`). When it refuses it opens the MR anyway, so the
work is still delivered and a human just decides.

**This is the phase that touches `main`.** Before enabling `FF_ONLY` anywhere:

1. `agent ls --repo <repo> --status running` is empty;
2. the last twenty MRs from the harness were merged by humans without amendment;
3. someone has read the evidence block on at least five of them and agrees it is accurate;
4. the rollback below has been *rehearsed*, not just read.

## Rollback drill

Run this on a scratch repository before you need it on a real one:

```bash
# 1. Confirm the repository is drained.
.venv/bin/agent ls --repo <repo> --status running

# 2. Flip the engine back.
#    .harness/config.yaml → profile.engine: shell

# 3. Re-enable the shell timer.
systemctl --user start skillforge-agent-pipeline@0.timer

# 4. Verify the shell path picks up where the Python path stopped: the branch is on the
#    remote, the labels are consistent, and the next tick advances it.
.venv/bin/agent inspect <run>     # what the Python engine last recorded
```

Nothing needs to be undone in the database — durable state is a superset of what the shell
reads, and the shell ignores it.

---

## Rolling back a prompt regression

A template change is a deployment (Q13). `template_id` and the prompt `sha256` are on every
span and every checkpoint, so a quality regression can be pinned to the version that caused it:

```bash
.venv/bin/agent inspect <run> --json | jq '.checkpoints[] | {state, template_id, prompt_sha256}'
```

Roll back by pinning the previous `template_id` in the roster. Do not edit the template in
place — that makes the regression invisible in the telemetry that would otherwise explain it.

## What to do when a run is stuck

```bash
.venv/bin/agent ls --status deferred          # what is waiting, and why
.venv/bin/agent inspect <run>                 # the checkpoint timeline and the last error
.venv/bin/agent replay <run>                  # the decision sequence, no side effects
```

Every terminal state has a re-entry path (invariant 12), and the reconciliation sweep runs on
every tick. A run that stays stuck across several ticks is a bug worth filing, not a run to
delete.
