#!/usr/bin/env bash
# typecheck.sh — type-check both halves of skillforge.
#   backend  → mypy (strict, configured in backend/pyproject.toml) filtered through
#              mypy-baseline against backend/mypy-baseline.txt so only NEW type errors fail
#   frontend → tsc --noEmit
# gate_typecheck (scripts/quality-gates.sh) calls this so a type error in either
# half fails the gate instead of silently skipping.
#
# Exit: 0 all clean | 1 a checker failed | 77 nothing to check.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

# ── Backend interpreter resolution (#2149) ────────────────────────────────
# The type checker MUST run on the SAME interpreter that runs the app and the
# tests. This script used to call a bare `mypy`, which resolves to whatever is
# first on PATH — on the dev host that is ~/.local/bin/mypy with a
# `#!/usr/bin/python3` shebang, i.e. Python 3.10, while the app targets 3.12.
# The gate therefore type-checked 3.10 semantics: every 3.12-only construct got
# a false verdict, and PEP 695 generic syntax (`def f[T: Bound](...)`) was a hard
# SYNTAX error that aborted the whole run before any checking. Worse, it put
# `typecheck` and `lint` in direct contradiction — ruff `target-version = py312`
# *requires* PEP 695 via UP047, and the 3.10 mypy *forbids* it, so no source
# spelling satisfied both. Invoking `"$PY" -m mypy` makes the checking
# interpreter the active conda/venv one by construction.
PY="${PYTHON:-python}"
command -v "$PY" >/dev/null 2>&1 || PY=python3

# The mypy target from backend/pyproject.toml `[tool.mypy] python_version`.
# Single source of truth — the guard below compares the live interpreter to it
# rather than hard-coding "3.12" here, so bumping pyproject moves the gate too.
backend_mypy_target() {
  sed -n 's/^[[:space:]]*python_version[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' \
    backend/pyproject.toml | head -1
}

# Fail LOUDLY when the interpreter that would run mypy is not the interpreter the
# code targets, instead of silently type-checking the wrong Python. Returns 0 when
# the toolchain is coherent, 1 (with an explanation on stdout) when it is not.
check_backend_interpreter() {
  local target actual mypy_ver probe
  target="$(backend_mypy_target)"
  [[ -n "$target" ]] || target="3.12"

  # Ask the interpreter itself which mypy it imports. Because the probe runs
  # *inside* $PY, a successful answer is proof that mypy and the active
  # interpreter are the same Python — they cannot disagree by construction.
  if ! probe="$("$PY" -c 'import sys, mypy.version; print("%d.%d %s" % (sys.version_info[0], sys.version_info[1], mypy.version.__version__))' 2>/dev/null)"; then
    echo "  ✗ backend — mypy is not importable from the active interpreter ($PY)."
    echo "    Refusing to fall back to a bare \`mypy\` on PATH: it may run a different"
    echo "    Python than the app (this is exactly issue #2149). Install the backend dev"
    echo "    extras into the active env:  $PY -m pip install -e 'backend[dev]'"
    return 1
  fi
  actual="${probe%% *}"
  mypy_ver="${probe#* }"

  # Compare MAJOR.MINOR only, field by field — `python_version` may legitimately be
  # written "3.12" or "3.12.1", and a bare `${v#*.}` on the latter yields "12.1",
  # which is not an integer and would make the `-lt` below blow up rather than judge.
  local a_maj a_min t_maj t_min
  a_maj="${actual%%.*}"; a_min="${actual#*.}"; a_min="${a_min%%.*}"
  t_maj="${target%%.*}"; t_min="${target#*.}"; t_min="${t_min%%.*}"
  [[ "$t_min" == "$t_maj" ]] && t_min=0   # target had no minor component at all

  if [[ "$a_maj" != "$t_maj" || "$a_min" -lt "$t_min" ]]; then
    echo "  ✗ backend — interpreter/target mismatch: mypy runs on Python $actual but"
    echo "    backend/pyproject.toml [tool.mypy] python_version = $target."
    echo "    A checker older than the target cannot parse the syntax the app uses"
    echo "    (PEP 695 generics are a syntax error before 3.12) and gives false"
    echo "    assurance on every newer construct. Activate the $target env or set"
    echo "    PYTHON=/path/to/python$target. See issue #2149."
    return 1
  fi

  echo "  · mypy $mypy_ver on Python $actual (target $target) via '$PY -m mypy'"
  return 0
}

# `--check-interpreter` runs only the guard above and exits with its verdict.
# This is the test seam: the unit test drives it with PYTHON= pointed at a
# too-old interpreter and asserts the gate fails loudly rather than checking
# the wrong Python.
if [[ "${1:-}" == "--check-interpreter" ]]; then
  check_backend_interpreter; exit $?
fi

fail=0
checked=0

if [[ -f backend/pyproject.toml ]]; then
  checked=$((checked + 1))
  echo "typecheck: backend (mypy)"
  # backend mypy carries a large pre-existing strict baseline (backend/mypy-baseline.txt).
  # When mypy-baseline is available we filter those known errors out so only NEW type
  # errors fail the gate; otherwise the unfiltered run is the verdict. mypy's output is
  # captured via command substitution (its non-zero exit is expected and intentionally
  # ignored) so that under `set -o pipefail` the gate's verdict comes from the
  # mypy-baseline filter, not from mypy's always-non-zero exit.
  if ! check_backend_interpreter; then
    fail=1
  elif (
        cd backend
        # mypy-baseline only filters TEXT LINES, so its own interpreter is irrelevant;
        # prefer the module in the active env (it is a declared dev dep) and fall back to
        # a `mypy-baseline` shim elsewhere on PATH.
        if "$PY" -c 'import mypy_baseline' 2>/dev/null; then
          baseline_filter=("$PY" -m mypy_baseline)
        elif command -v mypy-baseline >/dev/null 2>&1; then
          baseline_filter=(mypy-baseline)
        else
          baseline_filter=()
        fi
        if [[ ${#baseline_filter[@]} -gt 0 && -f mypy-baseline.txt ]]; then
          out="$("$PY" -m mypy app 2>/dev/null)"
          # --allow-unsynced: fail ONLY on NEW errors above the baseline; do not fail when a
          # baselined error is no longer present (resolved, or absent due to mypy run-to-run
          # nondeterminism). Keeps the gate green on cleanups instead of demanding a re-sync.
          printf '%s\n' "$out" | "${baseline_filter[@]}" filter --allow-unsynced
        else
          "$PY" -m mypy app
        fi
      ); then echo "  ✓ backend"; else echo "  ✗ backend — mypy failed (new errors above baseline)"; fail=1; fi
fi

if [[ -f frontend/package.json ]]; then
  checked=$((checked + 1))
  echo "typecheck: frontend (tsc --noEmit)"
  if ( cd frontend && npx --no-install tsc --noEmit ); then echo "  ✓ frontend"; else echo "  ✗ frontend — tsc failed"; fail=1; fi

  # #1971: the app tsconfig (include:["src"], exclude:["src/tests/**"]) never typechecked the
  # ~280 vitest test files, and tests/e2e/** + playwright.config.ts were outside it entirely — so
  # test-file type errors were gated by NEITHER tsc NOR vitest (the default `test` script doesn't
  # run vitest --typecheck). Typecheck them here via dedicated project configs so type errors land
  # in the typecheck gate, not mixed into unit results.
  if [[ -f frontend/tsconfig.test.json ]]; then
    echo "typecheck: frontend tests (tsc --noEmit -p tsconfig.test.json)"
    if ( cd frontend && npx --no-install tsc --noEmit -p tsconfig.test.json ); then echo "  ✓ frontend tests"; else echo "  ✗ frontend tests — tsc failed"; fail=1; fi
  fi
  if [[ -f frontend/tsconfig.e2e.json ]]; then
    echo "typecheck: frontend e2e (tsc --noEmit -p tsconfig.e2e.json)"
    if ( cd frontend && npx --no-install tsc --noEmit -p tsconfig.e2e.json ); then echo "  ✓ frontend e2e"; else echo "  ✗ frontend e2e — tsc failed"; fail=1; fi
  fi
fi

# ── api-client ────────────────────────────────────────────────────────────
if [[ -f packages/api-client/package.json ]]; then
  checked=$((checked + 1))
  echo "typecheck: api-client (tsc --noEmit)"
  if ( cd packages/api-client && npx --no-install tsc --noEmit ); then echo "  ✓ api-client"; else echo "  ✗ api-client — tsc failed"; fail=1; fi
fi

# ── mobile ────────────────────────────────────────────────────────────────
if [[ -f mobile/package.json ]]; then
  checked=$((checked + 1))
  echo "typecheck: mobile (tsc --noEmit -p tsconfig.typecheck.json)"
  # tsconfig.typecheck.json pins react → mobile's @types/react (v19); the pin
  # can't live in tsconfig.json because Metro applies its "paths" at runtime.
  if ( cd mobile && npx --no-install tsc --noEmit -p tsconfig.typecheck.json ); then echo "  ✓ mobile"; else echo "  ✗ mobile — tsc failed"; fail=1; fi
fi

# ── extensions/vscode ─────────────────────────────────────────────────────
# The extension is a shipped surface backing FR-VSCODE-001/002/003 that was
# outside every gate (#2023). tsconfig.json covers src (minus tests, which must
# not land in out/); tsconfig.test.json covers the test files as well.
if [[ -f extensions/vscode/package.json ]]; then
  checked=$((checked + 1))
  echo "typecheck: vscode extension (tsc --noEmit)"
  if ( cd extensions/vscode && npx --no-install tsc --noEmit -p tsconfig.json ); then echo "  ✓ vscode extension"; else echo "  ✗ vscode extension — tsc failed"; fail=1; fi

  if [[ -f extensions/vscode/tsconfig.test.json ]]; then
    echo "typecheck: vscode extension tests (tsc --noEmit -p tsconfig.test.json)"
    if ( cd extensions/vscode && npx --no-install tsc --noEmit -p tsconfig.test.json ); then echo "  ✓ vscode extension tests"; else echo "  ✗ vscode extension tests — tsc failed"; fail=1; fi
  fi
fi

if [[ "$checked" -eq 0 ]]; then echo "no typecheckers available"; exit 77; fi
exit "$fail"
