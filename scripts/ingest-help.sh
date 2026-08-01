#!/usr/bin/env bash
# ingest-help.sh — repo-root wrapper for backend/scripts/ingest_help.py (#2126, S1-2).
#
# The ingester lives under backend/ because it imports app.models.help_corpus and
# app.services.rag_service (the ONE chunker — docs/55 §3.1). But everyone who runs it
# is standing at the repo root looking at docs/help/, so this is the entrypoint that
# CI, the Makefile and a human all call:
#
#   scripts/ingest-help.sh --check      # validate the corpus; no DB, no DATABASE_URL
#   scripts/ingest-help.sh --dry-run    # plan against the DB, then roll back
#   scripts/ingest-help.sh              # apply (everything, including S1-3 fixtures)
#   scripts/ingest-help.sh --exclude-sample   # apply real content only — what the
#                                             # merge-to-main hook runs, so the
#                                             # placeholder corpus (#2127) never
#                                             # reaches real users
#
# All arguments are passed through verbatim; see `--help` for the full surface.
# Exit 0 = clean, 1 = invalid corpus or a failed ingest.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/backend" || { echo "ingest-help: no backend/ under $ROOT" >&2; exit 1; }

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "ingest-help: no python interpreter on PATH" >&2; exit 1; }

# The script resolves the default corpus root from its own location (backend/../docs/help),
# so it does not matter that we just cd'd into backend/.
exec "$PY" scripts/ingest_help.py "$@"
