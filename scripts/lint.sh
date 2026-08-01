#!/usr/bin/env bash
# lint.sh — lint every half of skillforge.
#   backend  → ruff check (config in backend/pyproject.toml)
#   frontend → npm run lint (eslint src)
#   mobile   → npm run lint (eslint . — mobile/eslint.config.mjs)
# gate_lint (scripts/quality-gates.sh) prefers this over the bare root linter.
#
# Exit: 0 all clean | 1 a linter failed | 77 nothing to lint.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

fail=0
checked=0

if [[ -f backend/pyproject.toml ]] && command -v ruff >/dev/null 2>&1; then
  checked=$((checked + 1))
  echo "lint: backend (ruff)"
  if ( cd backend && ruff check . ); then echo "  ✓ backend"; else echo "  ✗ backend — ruff failed"; fail=1; fi
fi

if [[ -f frontend/package.json ]] && jq -e '.scripts.lint // empty' frontend/package.json >/dev/null 2>&1; then
  checked=$((checked + 1))
  echo "lint: frontend (eslint)"
  if ( cd frontend && npm run --silent lint ); then echo "  ✓ frontend"; else echo "  ✗ frontend — eslint failed"; fail=1; fi
fi

# mobile/ is a separate workspace with its own eslint flat config (SDK 54 RN app).
# It's linted here — the repo typecheck/unit gates already cover it, but lint never
# did (issue #1970). eslint exits non-zero on ERRORS only (the config keeps most
# stylistic rules at 'warn'), so warnings don't fail the gate.
if [[ -f mobile/package.json ]] && jq -e '.scripts.lint // empty' mobile/package.json >/dev/null 2>&1; then
  checked=$((checked + 1))
  echo "lint: mobile (eslint)"
  if ( cd mobile && npm run --silent lint ); then echo "  ✓ mobile"; else echo "  ✗ mobile — eslint failed"; fail=1; fi
fi

# extensions/vscode ships its own eslint flat config; it was linted by nothing
# before #2023.
if [[ -f extensions/vscode/package.json ]] && jq -e '.scripts.lint // empty' extensions/vscode/package.json >/dev/null 2>&1; then
  checked=$((checked + 1))
  echo "lint: vscode extension (eslint)"
  if ( cd extensions/vscode && npm run --silent lint ); then echo "  ✓ vscode extension"; else echo "  ✗ vscode extension — eslint failed"; fail=1; fi
fi

# scripts/ — the harness itself. Every other surface above had a linter; the ~20k lines
# of shell that GATE those surfaces and push to `main` unattended had none (issue #2387).
# Ratcheted against scripts/shellcheck-baseline.txt so the 81 pre-existing findings don't
# block work, but no new one can land. Exits 77 when shellcheck isn't installed; that is a
# skip on a dev box and a FAIL on any tier that requires `lint`, which is the right shape —
# see REQUIRED_BY_TIER in quality-gates.sh.
if [[ -x scripts/shellcheck-gate.sh ]]; then
  checked=$((checked + 1))
  echo "lint: scripts/ (shellcheck, ratcheted)"
  sc_out="$(bash scripts/shellcheck-gate.sh 2>&1)"; sc_rc=$?
  printf '%s\n' "$sc_out"
  case "$sc_rc" in
    0)  echo "  ✓ scripts";;
    77) echo "  ⏭ scripts — shellcheck not installed";  checked=$((checked - 1));;
    *)  echo "  ✗ scripts — shellcheck regression"; fail=1;;
  esac
fi

if [[ "$checked" -eq 0 ]]; then echo "no linters available"; exit 77; fi
exit "$fail"
