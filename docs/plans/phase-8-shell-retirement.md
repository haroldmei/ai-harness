# Phase 8 — Retiring the shell orchestrator

Status: **accepted, revised 2026-08-02** · Date: 2026-08-01 · Tracked by
[#105](https://github.com/haroldmei/ai-harness/issues/105) · Architecture:
[`ai-harness-python-architecture.md`](../../ai-harness-python-architecture.md) · Decisions:
[0001](../decisions/0001-adopted-defaults.md), [0002](../decisions/0002-self-hosted-inference.md)

## Objective

The 21 shell files the Python engine replaced go away, and the harness loses nothing it needs.
The design has always said the shell *driver* retires; what it never said is how the last file
leaves, and the first draft of this plan got the boundary wrong.

The claim to falsify:

> **Every capability the Python engine replaced can be shown to be replaced before its script is
> deleted — and everything else in `scripts/` is live tooling that was never in scope.**

## Revision, 2026-08-02

The first draft assumed `scripts/quality-gates.sh` and the 38 tool scripts around it belonged to
a separate app-builder *product* that would get its own repository, and that the harness would
then discover them there at rung 2. **That was wrong, and the evidence was in the tree.**

`.claude/skills/build-product-v2/SKILL.md` invokes `scripts/state-init.sh`,
`scripts/state-set.sh`, `scripts/state-decide.sh`, `scripts/route-failure.sh` and
`scripts/quality-gates.sh` as **relative paths in the working tree**, and `quality-gates.sh`
reads `state/state.json` from that same tree. Nothing copies them anywhere. Sixteen scripts are
invoked by live skills.

So the harness *is* the app-builder, it works on many repositories, and `scripts/` is its own
runtime rather than a tenant. There is no single destination to relocate to, and relocation was
never the right verb. **D1 is superseded by D2.**

What survives from the first draft is the part that was about the ladder rather than about
ownership: the harness must keep being able to meet a repository's own gate tooling (§19.1), and
this repository must not have its own gates confused with a target's — which was #96, and is
done.

## What "the shell" actually is here

101 shell files, and only 21 of them are in scope. The classification is by **who calls it**,
established by grepping the live skills rather than by reading names:

| Class | Files | Who calls it today | Exit |
|---|---:|---|---|
| **PR-pipeline and scout stages** — `agent-inbox.sh`, `agent-pr-reviewer.sh`, `agent-pr-fixer.sh`, `agent-pr-merger.sh`, `agent-pipeline.sh`, `agent-triage-failure.sh`, `agent-scout.sh`, and the three `*-setup.sh` | 10 | systemd timers on the host; nothing in the package, no live skill | **Ported.** Deleted once the cutover is proven and the rollback is re-based (S4) |
| **Their tests** — `agent-*.test.sh` | 11 | nothing; CI never invokes them | **Retired with what they test** (S4) |
| **The app-builder's runtime** — `quality-gates.sh`, `state-init.sh`, `state-set.sh`, `state-decide.sh`, `route-failure.sh`, `verify-loop.sh`, `adversarial-loop.sh`, `run-e2e.sh`, `iteration-*.sh`, `release-train.sh`, `coverage.sh`, … | 80 | `build-product-v2` and 15 other live skills, in whatever tree the harness is building | **Stays.** Never legacy; the Python engine replaced the PR loop, not the product builder |

Four references from the live set back into the retirable one were checked individually and are
**comments and citations**, not invocations: `shellcheck-gate.sh`'s baseline notes,
`release-train.sh:661`'s "callers of this pattern", and `red-baseline.sh`'s history. Deleting the
stages does not break them.

One real coupling exists and is a deliverable of S4 rather than a blocker: the `iterate` skill
reads `ITERATE_MODE`, and `agent-inbox.sh` is the only thing that sets it to `single-issue`.
Whatever drives an inbox build after the deletion has to set it.

## What §19.1 does and does not settle

`quality/adapters/shell.py` says keeping `quality-gates.sh` is *"not a migration compromise, it
is the permanent design (§19.1)"*, and under D2 that is simply true — it is the app-builder's own
gate runner for the trees it builds, not a compromise about anything.

§19.1's first line is still the load-bearing one: *"The repository owns its gates. The harness
discovers, orders, runs, and interprets them."* It settles two things and neither of them is
about `scripts/`:

* a **target** repository's gate tooling is discovered and called, never reimplemented — which is
  why the ladder, `ShellGateAdapter` and `providers/deploy/script.py` are permanent;
* **this** repository's gates are its own, which is why they are now declared at rung 1 (#96).
  Before that, the ladder found the app-builder's runtime in the app-builder's own tree and
  reported 22 gates that gate *products*, not the harness. That was never a tenant — it was the
  tool's runtime being indistinguishable from a target's, in the one tree where both are present.

So the principle is not in tension with retirement, because retirement is now a smaller thing:

> **The Python engine replaced the PR loop. Phase 8 deletes what it replaced, and nothing else.**

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

- No `agent-*.sh` and no `agent-*.test.sh` in this repository — 21 files, the ones the Python
  engine replaced.
- `scripts/` still exists and is still live: `build-product-v2` and fifteen other skills call it,
  in whatever tree the harness is building.
- `.harness/gates.yaml` declares this repository's own gates; `agent gates discover .` reports
  rung 1 rather than the app-builder's product gates. **Done (#96).**
- `ENTRY_POINTS` still names `scripts/quality-gates.sh` — the ladder, for any repository the
  harness works on, including the ones it builds.
- `ShellGateAdapter` and `providers/deploy/script.py` unchanged and unretired.
- The stages exist only at the tag `shell-final`, restorable in one command.
- `agent retire check` refuses to call the orchestrator retired while any precondition is unmet.

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

### S2 — ~~Relocate the spine~~ · superseded by D2

**Void.** There is nothing to relocate: the spine is the app-builder's own runtime, invoked by
live skills in the tree being built. What was built for this step keeps its value pointed
*outward* rather than inward, which is where it was always more useful:

- **`agent gates adopt`** (#97) reads any repository's shell spine into a proposed
  `.harness/gates.yaml`. For a repository the harness is asked to work on — one that has
  `make check` or its own `quality-gates.sh` — this is how it gets a declaration without anybody
  retyping the contract.
- **`GateSpineComparator`** (#98) proves such a declaration is not weaker than the spine it
  replaces, per gate, with the disqualifying set fixed before the run.

Both landed. Neither is now on Phase 8's critical path; both are tools for target repositories.

### S3 — One repository actually runs on Python

`profile.engine: python` for a real target, driven by `agent tick` on a timer, with the shell
timer installed and disabled — §24 Phase 4's rule, unchanged.

**Gate:** #91's thirty compared PRs, #94's seven unattended days, and ≥1 release cycle where
every merged MR was produced by the Python path. This is Phase 7's exit criteria doing double
duty; no new evidence is invented for Phase 8.

### S4 — The stages and their tests go

Delete the 10 `agent-*.sh` stages and the 11 `agent-*.test.sh`. Everything else in `scripts/`
stays — it is live.

Two package-side deletions retire with them, and both are worth naming because leaving them is
the more expensive mistake:

* **`shadow_runner`'s verdict scraper.** `VERDICT_MARKERS` and `_shell_decision` read the shell
  reviewer's verdict off a pull request — the log-scraping W13 exists to end. Its own docstring
  sets the terms: *"It disappears when the shell reviewer does."* The two-reviewer form added for
  #91 needs no shell.
* **`HarnessConfig.shell_env()` and `SHELL_ENV_NAMES`.** The Phase 0 beachhead: one schema, two
  engines, no drift about `PR_MAX_ROUNDS`. One engine cannot disagree with itself.

And one integration point, which is the only live thread between the two sets: the `iterate`
skill reads `ITERATE_MODE`, set to `single-issue` by `agent-inbox.sh` and by nothing else.
Whatever drives an inbox build after the deletion must set it, or `iterate` silently runs its
cold-start path against a single issue.

**Gate:** the suite is green with the stages gone; `ITERATE_MODE` has a setter; every incident
citation in a docstring survives — deleting the script must not delete the reason.

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

### S6 — Say so

`agent retire check` exits zero. Update `docs/runbooks/migration.md` (the rollback is the tag),
`README.md` (Phase 8 status), and 0001's Q2 row — which closes differently than the first draft
assumed: the coupling was never a tenant, and what fixed the discovery confusion was declaring
this repository's own gates.

**Gate:** a repository whose PR loop is Python end to end, whose product-building runtime is
still shell and still live, and which can still be rolled back.

## What must not change

Stated because retirement is exactly the moment these get quietly taken as well:

- **`ShellGateAdapter` stays.** A target repo with `quality-gates.sh` is normal and supported.
- **Rung 2 stays in the ladder.** Removing it would make the harness demand `.harness/gates.yaml`
  from every repository, which is inventing rather than discovering.
- **`providers/deploy/script.py` stays.** Its docstring already draws this line: wrapping is *"what
  lets them be replaced one at a time, or never"* — and never is a legitimate answer.
- **Rung 5 stays a hard escalation.** No repository merges ungated because a spine moved.

## D1 — superseded

**Superseded by D2 on 2026-08-02.** Recorded here rather than deleted, because a decision that
quietly disappears is indistinguishable from one that was never made.

D1 asked where the app-builder's spine should go and answered "its own repository". The premise
was wrong: there is no separate app-builder. The harness *is* it, `scripts/` is its runtime, and
it will be used on many repositories rather than one.

## D2 — the app-builder's runtime stays; only the PR loop retires

Decided 2026-08-02. The harness is the app-builder and works on other repositories; the 80 live
scripts are how it builds in a tree, and they were never what the Python engine replaced. Phase 8
retires the 10 PR-pipeline and scout stages plus their 11 tests, and stops there.

Two consequences worth stating as commitments:

* **"no `*.sh` in this repository" is not the end state**, and any check that asserts it is
  wrong. What can be asserted is narrower and truer: no `agent-*.sh`, and no package file
  reaching for a script outside the ladder (#102).
* **`agent gates adopt` and `GateSpineComparator` point outward.** They were built for a
  relocation that is not happening, and they are more useful where they now apply — every
  repository the harness is asked to work on that already has a gate spine.

## The original D1 argument, kept for the record

**Where does the app-builder's spine go? Its own repository.** Decided 2026-08-01, superseded
2026-08-02.

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
| S2 | #97 — gates: `agent gates adopt` (landed; now a tool for target repos) |
| S2 | #98 — gates: `GateSpineComparator` (landed; now a tool for target repos) |
| — | #99 — Relocate the spine · **closed, void under D2** |
| S3 | #100 — Drive one repository on the Python engine for a full release cycle |
| S4 | #101 — Delete the orchestrator stages, the shell test suite and the verdict scraper |
| S4 | #102 — contracts: no package file may reference a `.sh` path outside the ladder |
| S5 | #103 — Re-base the rollback: the `shell-final` tag, the drill, and `MR_ONLY` |
| S6 | #104 — `agent retire check`, and the deletion |
