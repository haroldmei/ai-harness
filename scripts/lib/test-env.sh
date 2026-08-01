#!/usr/bin/env bash
# test-env.sh — scrub lane/host harness configuration out of a shell test's environment.
#
# Why this exists (issue #2387)
# -----------------------------
# `scripts/*.test.sh` describe themselves as hermetic, and they are with respect to the
# things they thought to stub: git remotes, `gh`, `claude`, the network. They are NOT
# hermetic with respect to the ENVIRONMENT they inherit, and the agent lanes run them
# from a systemd unit whose whole job is to export harness configuration:
#
#     AGENT_SLOT=1  AGENT_GATES_CMD=…  AGENT_LOGDIR=/tmp/skillforge-agent-inbox-lane1  …
#
# `agent-inbox.test.sh` was red on lanes 1 and 2 and green on lane 0 for exactly this
# reason: the suite asserts the default single-lane claim order, agent-inbox.sh rotates
# its candidate list by `AGENT_SLOT`, and the ambient `AGENT_SLOT=1` rotated it. The
# suite reported "issues are not sorted by createdAt" — a production-bug-shaped message
# for what was purely inherited state. Measured: 83 passed / 3 failed with the lane env,
# 86 passed / 0 failed under `AGENT_SLOT=0`.
#
# That mattered little while 28 of 32 suites were run by nothing. Now that `unit.sh`
# runs all of them, a host-dependent suite is a host-dependent GATE — the `unit` gate
# would pass on lane 0 and fail on lanes 1 and 2 for the same commit.
#
# What is scrubbed, and what is deliberately not
# ----------------------------------------------
# Scrubbed: the prefixes a LANE exports to configure the running harness. A test that
# wants any of these sets it explicitly (every suite already does — `run_runner` passes
# AGENT_ROOT/AGENT_GH/… as an explicit command prefix), so removing the ambient value
# can only remove accidental coupling, never intended configuration.
#
# NOT scrubbed: PATH, HOME, TMPDIR, CI, and anything else describing the machine rather
# than the harness. Suites legitimately need those, and `env -i` would break every one.
#
# Note this only removes ambient *harness* config. It does not make a suite independent
# of ambient TOOLS — see the `PATH` note in the stub-substitution helper below.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"
#   test_env_scrub
#
# NOTE ON `set -`: this file is a LIBRARY and deliberately sets NO shell options. A sourced lib
# runs in the CALLER's shell, so a `set -e` here would silently abort every "collector" script
# (the gate and agent stages) at its first *tolerated* failure — the ones that must survive a
# failing step in order to report, classify or clean up. Signal failure with return codes only.
# This is a deliberate design choice, not an oversight: do not "fix" it by adding `set -e`.
# See "Shell-option classes" in docs/AGENT-HARNESS.md (#2390).

# Prefixes exported by the agent lane units (deploy/systemd/skillforge-agent-*.service)
# and by the harness scripts themselves.
#
# REQUIRED_GATES is here because the release cuts export it to NARROW the required-gate set
# (cut-mobile-release.sh sets "typecheck lint unit", cut-release.sh "typecheck lint unit e2e"),
# and `env VAR=… scripts/quality-gates.sh` leaks it down the whole subprocess tree:
# quality-gates.sh → unit.sh → the shell-suite pool → any CHILD quality-gates.sh a suite spawns.
# quality-gates.sh:137 lets it override REQUIRED_BY_TIER, so quality-gates.test.sh's #1971
# fail-closed cases saw a required set without contract/migration-drift, `--skip` degraded to a
# benign SKIP, and 4 assertions failed — but ONLY when the gate ran inside a cut. The release
# train's own transience recheck calls quality-gates.sh directly (no cut wrapper, no leak), so it
# always came back green and every attempt was misfiled as "transient": a 20-attempt loop that
# could never converge. Same class as the AGENT_SLOT leak in #2387.
TEST_ENV_SCRUB_PREFIXES="${TEST_ENV_SCRUB_PREFIXES:-AGENT_ PIPELINE_ PR_ MERGER_ MERGE_STUCK_ QG_ SLOT_ RELEASE_TRAIN_ REARM_ ADV_ VERIFY_ REQUIRED_GATES}"

# test_env_scrub — unset every ambient variable matching a scrub prefix.
# Idempotent; safe to call under `set -u`.
test_env_scrub() {
  local v p
  for v in $(compgen -e 2>/dev/null); do
    for p in $TEST_ENV_SCRUB_PREFIXES; do
      case "$v" in
        "$p"*) unset "$v" 2>/dev/null || true; break;;
      esac
    done
  done
}

# test_env_stub_path — put a stub directory in front of a MINIMAL PATH.
#
# The bug this replaces (issue #2387, M7): six suites built a stub dir and then did
#     PATH="$STUB:$PATH"
# which PREPENDS. That is correct for "make `gh` resolve to my stub" and silently wrong
# for "assert the script aborts when `maestro` is absent" — the host's real binary is
# still on the tail of PATH, so the absence is never actually simulated.
# `cut-mobile-release.test.sh` asserted "no maestro → abort" and passed or failed purely
# on whether the developer happened to have ~/.maestro/bin/maestro installed.
#
# Measured on this host: 12/12 with ~/.maestro/bin off PATH, 11/12 with it on. A gate whose
# result depends on the developer's shell profile is not a gate.
#
# Substituting makes absence mean absence. Naming the tools to KEEP — rather than hardcoding
# /usr/bin:/bin — is what makes it usable: these suites still need the real git, jq, node and
# npx, which on this host live under nvm and conda paths no fixed list would guess. A tool the
# caller does not name stays unreachable, which is the entire point.
test_env_stub_path() { # <stub-dir> [tool-to-keep-reachable…]
  local stub="$1"; shift
  local dirs="$stub" t p d
  for t in "$@"; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    d="$(dirname "$p")"
    # A tool that already resolves INTO the stub dir must not drag its real dir back in.
    [ "$d" = "$stub" ] && continue
    case ":$dirs:" in *":$d:"*) ;; *) dirs="$dirs:$d";; esac
  done
  printf '%s\n' "$dirs"
}
