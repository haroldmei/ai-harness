# Runbook — the self-hosted roster

For the operator of one box with one card. Everything here is reversible, and the rollback is one
line of configuration (L8).

## Before anything

```
agent doctor
```

Read-only. It fixes nothing on purpose — a diagnostic that repairs things is a diagnostic people
are afraid to run. What each failure means:

| check | what it means | what to do |
|---|---|---|
| `gpu` FAIL | no driver, or the card is not visible from this environment | install the NVIDIA driver; under WSL check that `nvidia-smi` works in the shell you run the harness from |
| `thermals` warn | something is limiting the clocks | the box will generate slower than the rate every timeout was derived from. Check airflow and the power limit, then re-run `agent serving bench` |
| `serving:<model>` warn | that model's server is not up | normal for the model that is not resident (L2). If *neither* is up, start one |
| `vram:<model>` warn | not enough free memory for that model | stop the other model's unit first. Two 4-bit models do not fit 24 GB |

## Starting the stack

```
agent serving ls                       # what this box can serve, and whether it fits
agent serving args qwen3-coder-30b --explain   # the flags, and the arithmetic behind them
agent serving unit qwen3-coder-30b > ~/.config/systemd/user/ai-harness-serve-qwen3-coder-30b.service
systemctl --user daemon-reload
systemctl --user start ai-harness-serve-qwen3-coder-30b
agent serving check qwen3-coder-30b    # reachable, pinned revision, and a token came back
```

`check` demands a returned token, not a bound port. vLLM accepts connections while it is still
loading, and that window is long enough for a worker to claim a run against a model that cannot
answer yet.

## Measuring this box (do this once, and after any driver or model change)

```
agent serving bench qwen3-coder-30b --out docs/measurements/serving.md
agent serving probe qwen3-coder-30b            # is guided decoding actually on?
agent serving conformance qwen3-coder-30b --out docs/measurements/conformance.md
```

Every timeout, ceiling and pacing default derives from the bench numbers. Until it runs, they
derive from `selfhost.md`'s pessimistic 30 tok/s, which is a planning bound rather than a
measurement — the primary model is a mixture-of-experts with ~3B active parameters, so the real
figure may be several times higher.

## Swapping models

Do not do it by hand while a run is in flight. The residency lease serialises swaps, and a
hand-typed `systemctl start` is the one path it cannot see — which is why each unit `Conflicts`
with the others.

```
systemctl --user stop ai-harness-serve-qwen3-coder-30b
systemctl --user start ai-harness-serve-devstral-24b
```

Eviction before load, in that order: starting the second model while the first still holds 17 GB
is the OOM the ordering exists to prevent.

## Upgrading a model

A model upgrade changes the behaviour of every agent at once. It is a deployment.

1. update `revision` in `.harness/models.yaml` — a digest, never a tag;
2. `agent serving check <model>` — it refuses a server serving anything else;
3. `agent serving probe <model>` — the capability cache is keyed on the revision, so new weights
   get a new answer rather than the old one;
4. `agent serving conformance <model>` — compare against the committed baseline before trusting it;
5. commit both the pin and the new numbers.

## Falling back to the cloud, and back again

Fallback is opt-in per model and counted. In `.harness/config.yaml`:

```yaml
roster:
  engines:
    qwen3-coder-30b: local
    devstral-24b: local
  fallback_engine: anthropic
  fallback_models: ["devstral-24b"]
  max_fallbacks_per_run: 3
```

When it fires it is on the span and in the MR evidence block, and the third one in a run
escalates rather than spending more. A run whose evidence block says "hosted fallback" was not
free, and the block says so out loud.

## Rollback

```yaml
roster:
  engine: claude-cli
  engines: {}
```

That is the whole rollback (L8). Nothing else needs to change: the states, the queue, the store
and the gates are the same on either roster. Rehearse it before the soak, not after it.

## During a soak

- `agent cost --days 1` — local and hosted split, with GPU-seconds beside dollars.
- `agent ls --status running` — what is in flight.
- `agent doctor` — after any suspend/resume, which is the most common way a driver comes back wrong.
- Watch `model_swaps_total` and `model_swap_seconds`: swap time is not thinking time, and if it
  approaches review time then L2's co-residency alternative deserves re-opening with evidence.

## What is still open

The empirical halves of [#91](https://github.com/haroldmei/ai-harness/issues/91) (thirty real PRs
compared) and [#94](https://github.com/haroldmei/ai-harness/issues/94) (seven days unattended).
Both need served weights and calendar time; the code they need is in place, and the numbers they
produce belong in `docs/measurements/`.
