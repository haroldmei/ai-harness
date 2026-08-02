# Phase 8 — Port the shell to Python agents, then delete it

Status: **accepted, rewritten 2026-08-02 (D3)** · Tracked by
[#105](https://github.com/haroldmei/ai-harness/issues/105) · Architecture:
[`ai-harness-python-architecture.md`](../../ai-harness-python-architecture.md) · Decisions:
[0001](../decisions/0001-adopted-defaults.md), [0002](../decisions/0002-self-hosted-inference.md)

## Objective

Every shell script becomes a Python agent or command. Every caller — including the Claude skills
— calls the Python. Then `scripts/` is deleted, and no `.sh` remains anywhere in this repository.

The claim to falsify:

> **Each script's behaviour can be shown to survive its port before the script is deleted, and
> every caller can be shown to have moved.**

## D3 — decided: port everything, then delete

Supersedes D1 (*relocate the spine to a product repository*) and D2 (*keep the app-builder's
runtime as live shell*). Both answered the wrong question, and both are kept at the end of this
document — a decision that quietly disappears is indistinguishable from one that was never made.

D1 asked where the spine should *go*. D2 asked whether it should *stay*. The goal is that it
should **not exist**: the shell is the previous implementation, the Python engine is the current
one, and a system carrying two implementations of one behaviour has two places for it to drift.
That is the argument the port was started on, and it does not stop applying at the gate spine.

## What has to move

104 shell files. Classified by **who calls it**, established by grepping rather than by reading
names.

| Group | Files | Callers | Port target |
|---|---:|---|---|
| **Orchestrator stages** `agent-*.sh` | 10 | systemd timers | Done — subgraphs, workers, the state machine |
| **Their tests** `agent-*.test.sh` | 11 | nothing | Deleted with them |
| **Product build state** `state-init/set/decide.sh`, `lib/state-shard.sh` | 4 | `build-product`, `build-product-v2`, `iterate`, `signal-iterate` | `agent product` + `ai_harness/product/` |
| **The gate spine** `quality-gates.sh`, `ml-quality-gates.sh` + 39 gate implementations | 41 | `build-product-v2`, `dogfood`, `cicd` | `GateSpec`s + Python implementations, run by the existing `GateRunner` |
| **The verify loop** `verify-loop.sh`, `adversarial-loop.sh` | 2 | `build-product-v2`, `adversarial-strategy-loop` | `agent verify`; `quality/adversarial.py` already exists |
| **Iteration bookkeeping** `iteration-*.sh`, `generate-iteration-index.sh` | 4 | `build-product-v2`, `iterate` | `agent iteration` |
| **Deploy surface** `deploy.sh`, `pre-deploy.sh`, `verify-deploy.sh`, `rollback.sh`, `local-deploy.sh`, `canary-deploy.sh`, `release-train.sh` | 7 | `deployer`, `rollback`, `env-manager`, `cicd` | `agent deploy`; `deploy/` and `providers/deploy/` largely exist |
| **Setup scripts** `*-setup.sh` | 6 | operators | classified below (#111): 1 covered, 3 obsolete, 1 out of scope, 1 blocked on #114 |
| **Remaining tests and `lib/`** | 19 | nothing / each other | Deleted with what they test |

Ten skills invoke shell today — `build-product`, `build-product-v2`, `iterate`, `signal-iterate`,
`dogfood`, `cicd`, `deployer`, `rollback`, `env-manager`, `adversarial-strategy-loop`. Each is
part of the port rather than an afterthought: a script with no callers left is deletable; a script
whose caller still names it is not.

## The six setup scripts, classified (#111)

Each installs labels and a systemd timer for a shell loop. What replaced the loop decides what
happens to its setup — and only one of the six needs anything built.

| Script | Classification | Why |
|---|---|---|
| `agent-inbox-setup.sh` | **covered** by `agent install` | Labels plus a timer for the inbox loop. `agent install` already renders the `tick` and `work` units and creates `LABELS`; the states replaced the loop |
| `agent-pr-loop-setup.sh` | **obsolete** | Its nine labels — `review-needed`, `fix-wip`, `merge-stuck` … — *are* the shell pipeline's state machine. The Python engine keeps run state in the store, where it can be queried and replayed, so the labels have nothing left to mean |
| `local-deploy-setup.sh` | **obsolete** | Deployment is a state inside a run (#65), not a timer watching merges. That fan-out is exactly what the sequential pipeline replaced |
| `db-backup-setup.sh` | **out of scope** | Product infrastructure — a database's backup schedule — and it copies units from `deploy/systemd/`, which does not exist in this repository |
| `release-train-setup.sh` | **out of scope, wrapped** | The release train is periphery, wrapped as a subprocess adapter by `providers/deploy/script.py` per §3.16's *wrap temporarily — or never* |
| `agent-scout-setup.sh` | **blocked on #114** | Its labels are already in `LABELS`. Its timer is not, and cannot be: `scout/service.py` exists and **nothing constructs or starts it** |

The scout finding is the Phase 6 shape again — *"`agent work` and `agent tick` did not exist even
though `Worker` and `Ticker` were finished and tested"*. `Scout` needs a producer and a critic
injected, the composition root builds neither, and there is no command. That is an entry point to
build (#114), not a setup script to port.

**One behaviour has to survive the deletion, and it is not in any of these files' output.**
`agent-pr-loop-setup.sh` *disables* the timers it supersedes. When the stages are deleted (#101),
whatever is left running on an operator's box has to be disabled too, or a host keeps firing
timers into binaries that no longer exist.

## Does this break §19.1?

§19.1 says the harness may not reimplement a repository's gate tooling: *"The repository owns its
gates. The harness discovers, orders, runs, and interprets them."* Porting `quality-gates.sh` into
Python looks exactly like what that forbids.

It is not, and the distinction is **who authored the gates**:

* for a **target** repository — one the harness is asked to work on — the ladder discovers what is
  there and the adapter calls it. Unchanged and permanent, which is why `ShellGateAdapter`, rung 2
  and `providers/deploy/script.py` all survive this phase untouched;
* for a product **this harness builds**, the harness supplies the gates. They are its own tooling,
  and porting your own implementation from bash to Python is not reimplementing somebody else's.
  Leaving it in bash while the engine that calls it is Python is two places for one behaviour to
  drift.

The test of that reading is mechanical and is in the phase gate: after the port, `agent gates
discover` against a target repo carrying a `quality-gates.sh` must still find it and run it.

## The equivalence rule

Nothing is deleted because it was ported. It is deleted because the port was **shown** to behave
the same — and the instrument already exists. `GateSpineComparator` (#98) runs both spines on the
same tree and diffs them per gate, with the disqualifying set fixed in advance: a lost gate, a
verdict that flipped green, a gate demoted to advisory.

This is what #97 and #98 were actually for. They were built to adopt a *foreign* spine ahead of a
relocation that is not happening; their real job is proving this port faithful.

For scripts that are not gates, the same rule in its general form: a port lands with a test that
fails against the old behaviour and passes against the new, or it does not land.

## Sequence

Each group ports, proves, switches its callers, and only then loses its scripts. The groups are
independent apart from the state module, which several others read.

| Step | What | Gate |
|---|---|---|
| **P1** | Product build state → `agent product` | A build driven end to end through the Python state, with `state/` shards byte-identical to the shell's |
| **P2** | The gate spine → `GateSpec`s + Python implementations | `agent gates compare` clean over ≥5 commits, every disagreement explained |
| **P3** | Verify and adversarial loops → `agent verify` | The same red→green sequence on a seeded failure |
| **P4** | Iteration bookkeeping → `agent iteration` | Identical index and digest output on the existing corpus |
| **P5** | Deploy surface → `agent deploy` | A dev deploy, a smoke check and a rollback, all through Python |
| **P6** | Setup scripts → `agent install` | Idempotent; the second run writes nothing |
| **P7** | The ten skills call `agent …` | Every skill runs green with `scripts/` renamed away |
| **P8** | Cutover of the PR loop | #100: one repository, one release cycle, Python end to end |
| **P9** | Delete `scripts/`, tag `shell-final`, rehearse the restore | #102's second half passes: no `.sh` tracked |

P7 is the honest checkpoint. Renaming `scripts/` to `scripts.off` and running each skill is the
cheapest possible proof that nothing still reaches for it, and it is reversible in one command.

## What must not change

- **`ShellGateAdapter`, ladder rung 2, `providers/deploy/script.py`.** A *target* repository with
  a shell spine is normal and supported for ever; the port is of this repository's own tooling.
- **Rung 5 escalates.** No repository merges ungated because a gate changed language.
- **The incident citations.** `agent-pr-merger.sh:112` in a docstring is why a guard exists, and
  deleting the script must not delete the reason.
- **The rollback discipline.** §24: the tag and its rehearsed restore land *before* the deletion.

## Risks

| Risk | Mitigation |
|---|---|
| A gate is subtly weaker after porting | #98's comparator, per gate, every disagreement explained; requiredness demotion is disqualifying |
| A skill still calls a script nobody noticed | P7 renames `scripts/` away and runs every skill |
| The port stalls half-done, leaving two implementations | Each group switches its callers in the change that lands its port; no group is "ported" while a caller still names the script |
| Genuinely shell-shaped logic (`shellcheck`, `docs-script-refs`) | It stays shell *content* invoked as a `GateSpec` command. A gate may run `shellcheck`; what must go is the harness's own dispatch logic living in bash |

## Superseded decisions

**D1 — relocate the spine to the product's repository** (2026-08-01). Premise: `scripts/` was a
separate product's toolchain. Wrong — this repository is the app-builder.

**D2 — keep the app-builder's runtime as live shell** (2026-08-02). Premise: because live skills
invoke it, it is not legacy. Wrong in the other direction — being invoked is what makes it a port
target, not what makes it permanent.
