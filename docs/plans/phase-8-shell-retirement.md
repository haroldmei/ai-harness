# Phase 8 — Retiring the shell completely

Status: **accepted** · Date: 2026-08-01 · Tracked by
[#105](https://github.com/haroldmei/ai-harness/issues/105) · Architecture:
[`ai-harness-python-architecture.md`](../../ai-harness-python-architecture.md) · Decisions:
[0001](../decisions/0001-adopted-defaults.md), [0002](../decisions/0002-self-hosted-inference.md)

## Objective

`scripts/` — 91 shell files, 1.6 MB — goes away, and the harness loses nothing it needs. The
design has always said the shell driver retires; what it has never said is *how the last file
leaves*, and the honest reading of the current code is that two of the three things in that
directory are not retirable by porting them at all.

The claim to falsify:

> **Every capability `scripts/` provides is either already in the package, belongs in a different
> repository, or is not a capability anybody needs — and each one can be shown to be so before
> the file is deleted.**

## What "the shell" actually is here

Not one thing. Three, with different owners and different exits:

| Class | Files | Who calls it today | Exit |
|---|---:|---|---|
| **Orchestrator stages** — `agent-inbox.sh`, `agent-pr-reviewer.sh`, `agent-pr-fixer.sh`, `agent-pr-merger.sh`, `agent-pipeline.sh`, `agent-triage-failure.sh`, `state-*.sh` | 14 | systemd timers on the host; nothing in the package | **Ported.** Deleted once the cutover is proven and the rollback is re-based (S4) |
| **Gate and tool spine** — `quality-gates.sh` (1 492 lines, 22 gates), `verify-loop.sh`, `coverage.sh`, `run-e2e.sh`, `i18n-check.sh`, `seed-integrity.sh`, `release-train.sh`, `local-deploy.sh`, `canary-deploy.sh`, … | 38 | `ShellGateAdapter` (rung 2) and `providers/deploy/script.py` | **Relocated.** It is a *product's* toolchain sitting in the harness's repository (S2) |
| **Shell test suite** — `*.test.sh` | 39 | nothing; CI never invokes them | **Retired with what they test** (S4) |

The middle row is the one the current code argues about with itself, and resolving that argument
is most of this design.

## The reframe: §19.1 is about *the repository being worked on*

`quality/adapters/shell.py` opens with a flat statement:

> This is not a migration compromise, it is the permanent design (§19.1). `quality-gates.sh` is
> 1,492 tuned lines that already emit `{gate, status, reason, duration_s}` from `--json`, so **no
> change to the shell is required** for the port to consume it.

That reads like a bar to retirement. It is not, and §19.1 says why in its own first line: *"The
repository owns its gates. The harness discovers, orders, runs, and interprets them."* The
permanent thing is the **adapter and the ladder** — the harness's refusal to reimplement whatever
gate tooling a target repository happens to have. It is a statement about `make check` in
somebody else's repo as much as about `quality-gates.sh`.

Which turns the question around. `scripts/quality-gates.sh` is the *app-builder product's* gate
spine: it sources `scripts/lib/state-shard.sh`, reads `state/state.json`, and gates
`iteration-immutable`, `seed-integrity`, `mobile-e2e`, `visual`. This repository has no `state/`
directory. The spine is not this repository's gates — it is a tenant.

And a tenant is exactly what Q2 forbids:

> **Q2 — first targets, the same host project or external repos? Assume external.** It forces
> `RepoProfile` to be honest from day one and prevents re-introducing the coupling of W12.
> *A test fails if any host-project string reappears in the package.*

The package passes that test. The *repository* does not: it carries the host project's toolchain
in a directory the harness's own discovery ladder then finds and treats as this repo's gate
entry point. Running `agent gates discover .` today reports 22 gates belonging to a product that
is not here. That is W12 with a directory instead of an import.

So the design principle is not violated by retirement — it is **finally satisfied** by it:

> **Retirement is relocation and declaration, never reimplementation.** Every shell file either
> moves to the repository that owns it, where the harness keeps calling it through the ladder, or
> is replaced by a *declaration* the harness already knows how to execute.

## The principle audit

Every rule this retirement could break, and what keeps it intact.

| Principle | What it constrains | How Phase 8 preserves it |
|---|---|---|
| **§19.1 discover, do not invent** | The harness may not reimplement a repo's gate tooling | Nothing is reimplemented. `quality-gates.sh` keeps running — in the product repo, through rung 2. This repo declares its *own* real gates (ruff, format, mypy, import-linter, pytest), which is rung 1, not invention |
| **Never weaken gates** (§19, invariant) | A change may add gates, never remove or dilute them | S2's differential run is the enforcement: the declared spine must produce the same verdict per gate on the same commit, and a gate that disappears is a failure of the migration, not a smaller suite |
| **Q2 / W12 — assume external** | No host-project coupling in the harness | This is the rule retirement *serves*; S2 removes the last coupling, which is a directory rather than an import |
| **§24 rollback discipline** | You may not delete the rollback before the cutover is proven | S3 and S4 are gated on evidence (#91, #94) and on a **rehearsed** drill. S5 replaces the rollback before removing it — a tagged, restorable shell plus `MR_ONLY` plus declared gates |
| **W13 — never scrape a log** | Decisions come from typed contracts, not from grepping output | The one remaining scraper (`shadow_runner.VERDICT_MARKERS`) exists *only* to read the shell reviewer's verdict. Its own docstring: *"It disappears when the shell reviewer does."* S4 deletes it |
| **§14.1 single-pass** | A worker does one pass and exits; the scheduler decides cadence | Unchanged. `agent tick`/`agent work` already hold this; the shell timers are removed, not replaced with a loop |
| **Q13 — versions are attributable** | A behaviour change must be nameable | The shell is archived at a tag, and the retirement is a release, so "what did the shell do here" stays answerable after deletion |
| **§7.4 unknown fails closed** | Absence is never permission | Rung 5 is untouched: a repository whose declared gates cannot be found still escalates rather than merging ungated |

## End state

- No `*.sh` in this repository. `scripts/` does not exist.
- `.harness/gates.yaml` in this repository declares its real gates; `agent gates discover .`
  reports rung 1 and five gates that are actually this repo's.
- `ENTRY_POINTS` in `discovery.py` still names `scripts/quality-gates.sh` — as a *pattern* for
  any target repo, alongside `make check`, `tox`, `nox`. That is the ladder, not a legacy.
- `ShellGateAdapter` and `providers/deploy/script.py` remain, unchanged and unretired. They are
  how the harness meets a repository on its own terms; nothing about them was ever legacy.
- The shell orchestrator exists only at the tag `shell-final`, restorable in one command.
- `agent retire check` exits non-zero if any precondition of the above is not met.

## Sequence

Each step ends in something falsifiable, and no step may start before the previous one's gate is
green. S1 and S2 are safe today; S3 onward consume evidence Phase 7 has not finished producing.

### S1 — This repository declares its own gates *(safe now, no dependency)*

Write `.harness/gates.yaml` for this repo: ruff, ruff-format, mypy, import-linter, pytest — the
five things CI already runs. Rung 1 then answers `agent gates discover .` and the app-builder's
spine stops masquerading as this repository's contract.

**Gate:** `agent gates run .` is green, runs the same five checks CI does, and disagrees with CI
on nothing. The harness gates itself with its own machinery, which is also the first honest
dogfood of the native runner.

### S2 — The product's spine moves to the product's repository

The 38 tool scripts and their `lib/` are the app-builder's. They move to the app-builder's
repository, where the harness discovers them at rung 2 exactly as it would in any external repo.
Nothing is ported and nothing is rewritten.

New tooling, small and both worth having independently:

- **`agent gates adopt <repo>`** — read a shell spine's `GATES=(…)` registry (the reader already
  exists: `discovery._shell_registry_names`) plus one `--json` scorecard, and emit an equivalent
  `.harness/gates.yaml`. The output is a *proposal a human reviews*, never written autonomously —
  the same rule as Q9's "propose gates in the MR body; never write CI config".
- **`GateSpineComparator`** — the shadow pattern (#43, #91) applied to gates: run the shell spine
  and the declared spine on the same commit and diff the scorecards gate by gate. A gate that
  changes status, disappears, or silently becomes a skip is a disagreement, and the criterion is
  the one the reviewers use — **every disagreement explained**, not zero disagreements.

**Gate:** the app-builder repo has its spine, the harness reaches it through rung 2, and a full
differential run over ≥5 commits is explained. Until then `scripts/` stays where it is.

### S3 — One repository actually runs on Python

`profile.engine: python` for a real target, driven by `agent tick` on a timer, with the shell
timer installed and disabled — §24 Phase 4's rule, unchanged.

**Gate:** #91's thirty compared PRs, #94's seven unattended days, and ≥1 release cycle where
every merged MR was produced by the Python path. This is Phase 7's exit criteria doing double
duty; no new evidence is invented for Phase 8.

### S4 — The orchestrator and its tests go

Delete the 14 stages and the 39 `*.test.sh`. Delete `shadow_runner`'s verdict scraper and the
`_shell_decision` path with them — the comparator keeps the two-reviewer form Phase 7 added
(#91), which needs no shell. Delete `HarnessConfig.shell_env()` and `SHELL_ENV_NAMES`: the
beachhead exists to stop two engines disagreeing about `PR_MAX_ROUNDS`, and one engine cannot
disagree with itself.

**Gate:** the suite is green with no shell present anywhere, and a new contract test asserts it —
*no file in `ai_harness/` may reference a `.sh` path outside `discovery.ENTRY_POINTS`*, which is
the mechanical version of "the coupling does not come back" (the W12 test, extended).

### S5 — Replace the rollback before removing it

Today the rollback for Phases 2–5 *is* the shell. After S4 it cannot be, so it becomes three
things that must exist before the deletion is merged, not after:

1. `git tag shell-final` on the last commit containing `scripts/`, documented in the runbook with
   the one command that restores it;
2. `MR_ONLY` remains the shipped default (Q1) — a human is still the last step, so "stop the
   timer" is a real rollback rather than a slogan;
3. declared gates in every driven repository, verified by S2's comparator, so stopping the Python
   path never leaves a repo with no runnable gate.

**Gate:** the drill in `docs/runbooks/migration.md` is rehearsed *from the tag* — restore, run one
PR through the shell path, confirm the branch is where the Python path left it. Rehearsed, not
read; §24's word.

### S6 — Delete, and say so

Remove `scripts/`. Update `docs/runbooks/migration.md` (the rollback is now the tag), `README.md`
(Phase 8 status), and `0001`'s Q2 row (the coupling is gone, and how it was closed).

**Gate:** `agent retire check` exits zero. It is a script-free repository that can still gate
itself, still discover somebody else's shell spine, and still be rolled back.

## What must not change

Stated because retirement is exactly the moment these get quietly taken as well:

- **`ShellGateAdapter` stays.** A target repo with `quality-gates.sh` is normal and supported.
- **Rung 2 stays in the ladder.** Removing it would make the harness demand `.harness/gates.yaml`
  from every repository, which is inventing rather than discovering.
- **`providers/deploy/script.py` stays.** Its docstring already draws this line: wrapping is *"what
  lets them be replaced one at a time, or never"* — and never is a legitimate answer.
- **Rung 5 stays a hard escalation.** No repository merges ungated because a spine moved.

## D1 — decided: relocate

**Where does the app-builder's spine go? Its own repository.** Decided 2026-08-01; S2 is
unblocked and the `legacy/` variant is dropped.

The alternative — a marked `legacy/` directory here, excluded from discovery, archived at the tag
and deleted at S6 — reaches the same end state while keeping the harness carrying a tenant for
another release, and Q2's whole argument is that the coupling costs more the longer it is
tolerated. Relocation also produces the first genuinely external target repository, which is what
#94's soak needs regardless.

Two consequences worth stating, because they are now commitments rather than options:

* the app-builder repo becomes the **first real proving ground** for the ladder's rung 2 — the
  harness meeting a repository on its own terms, which until now has only been tested against
  fixtures;
* `RepoProfile` gets exercised by a second repository, which is the thing Q2 said would keep it
  honest.

## Risks

| Risk | Mitigation | What would falsify the plan |
|---|---|---|
| The declared spine is quietly weaker than the shell one | S2's differential run, gate by gate, disagreements explained | A gate that cannot be expressed as a `GateSpec` at all — then it moves with the product and is never declared |
| The rollback is gone when it is needed | S5 lands the tag, the drill and `MR_ONLY` **before** S6 | The restore drill fails from the tag |
| A capability nobody noticed lives in a tool script | S2 moves rather than deletes; only S4 deletes, and only what was ported | Something in the 38 turns out to be harness behaviour, not product behaviour — it gets ported, and S2 waits |
| "Retired" becomes a claim rather than a state | `agent retire check` is mechanical and in CI | — |

## Proposed issues

Phase 8 epic, plus:

Filed under [#105](https://github.com/haroldmei/ai-harness/issues/105):

| Step | Issue |
|---|---|
| S1 | #96 — gates: this repository declares its own gates (rung 1) |
| S2 | #97 — gates: `agent gates adopt` — a shell spine, proposed as a declaration |
| S2 | #98 — gates: `GateSpineComparator` — the shadow pattern, applied to gates |
| S2 | #99 — Relocate the product's gate and tool spine to its own repository |
| S3 | #100 — Drive one repository on the Python engine for a full release cycle |
| S4 | #101 — Delete the orchestrator stages, the shell test suite and the verdict scraper |
| S4 | #102 — contracts: no package file may reference a `.sh` path outside the ladder |
| S5 | #103 — Re-base the rollback: the `shell-final` tag, the drill, and `MR_ONLY` |
| S6 | #104 — `agent retire check`, and the deletion |
