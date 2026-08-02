# Conformance baselines

What a model, with a given prompt, does when asked for structured output. Regenerate with
`agent serving conformance <model>`; commit the result, because the point of a baseline is that
the *next* run is compared to it rather than merely observed (#90, Q13).

`first pass` is the fraction that validated with **zero repairs**. It is the number that decides
whether guided decoding is worth its flags: a repair is a full re-generation, so at 30 tok/s each
one is tens of seconds, not cents.

`rungs` says who did the work. All-`raw` means the model emitted clean JSON. A tail on
`bracket_scan` means it wrapped the answer in prose and the extraction ladder carried it — which
still works, and still costs the tokens of the prose.

## Scripted baseline (no hardware required)

The pathological corpus, replayed. This is a test of the *harness*, not of any model, and it runs
in CI — the local rows below are the ones that need a served model.

| model | template | guided | cases | first pass | valid | repairs/call | refused | rungs |
|---|---|---|---:|---:|---:|---:|---:|---|
| scripted | reviewer-v1-local | no | 12 | 58% | 58% | 0.83 | 42% | bracket_scan:1, fenced:1, raw:5 |

Those numbers are the corpus's, by construction: it is a library of the shapes that broke the
shell harness, so a high refusal rate there is the corpus doing its job.

## Local models

**Not yet measured.** These rows need the serving stack up with pinned weights (#81), and the
measurement is the empirical half of #90. Run:

```
agent serving probe qwen3-coder-30b        # is guided decoding actually on?
agent serving conformance qwen3-coder-30b --out docs/measurements/conformance.md
agent serving conformance devstral-24b --out docs/measurements/conformance.md
```

| model | template | guided | cases | first pass | valid | repairs/call | refused | rungs |
|---|---|---|---:|---:|---:|---:|---:|---|
| qwen3-coder-30b | implementer-v2-local | ? | — | — | — | — | — | — |
| devstral-24b | reviewer-v1-local | ? | — | — | — | — | — | — |

### What the numbers have to clear

- **first pass ≥ 95%** with guided decoding on. Below that, the repair loop is carrying the
  roster and every REVIEW round costs minutes it should not.
- **refused ≤ 1%.** A refusal escalates, and a model that escalates one call in a hundred can
  still run unattended; one in ten cannot.
- The same measurement **without** guided decoding is recorded too, because it is what the
  fallback path actually costs when a server comes back up with different flags.

## Conformance — qwen3-coder-30b

| model | template | guided | cases | first pass | valid | repairs/call | refused | rungs |
|---|---|---|---:|---:|---:|---:|---:|---|
| qwen3-coder-30b | planner-v1-local | yes | 3 | 100% | 100% | 0.00 | 0% | raw:3 |

`first pass` is the fraction that validated with zero repairs — the number that decides whether guided decoding earns its flags. A repair is a full re-generation, so at 30 tok/s `repairs/call` is wall-clock, not cents.
