#!/usr/bin/env bash
# route-failure.sh — map a quality-gate or dogfood failure to the owning skill.
#
# Reads:
#   --gate <name>    the gate that failed (typecheck|lint|unit|mutation|...)
#   --area <path>    the file path or module that failed (optional; helps disambiguate)
#
# Emits:
#   <owner_skill>    the skill name the orchestrator should re-spawn
#
# This is a dumb router. Smart routing belongs in the orchestrator — this
# script is the lookup table the failure-routing matrix in
# build-product-v2 SKILL.md describes.

set -euo pipefail

GATE=""
AREA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gate) GATE="$2"; shift 2;;
    --area) AREA="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -z "$GATE" ]] && { echo "ERROR: --gate required" >&2; exit 2; }

route() {
  case "$GATE" in
    typecheck|lint)
      # blame the area if known
      case "$AREA" in
        *src/app/*|*src/components/*|*src/pages/*) echo "frontend-developer";;
        *src/lib/*|*src/api/*|*src/server/*)        echo "backend-developer";;
        *prisma/*|*migrations/*)                    echo "db-migrator";;
        *)                                           echo "frontend-developer";; # default
      esac;;

    unit)
      case "$AREA" in
        *components*|*pages*|*frontend*) echo "frontend-developer";;
        *jobs*|*queues*)                  echo "background-jobs";;
        *db*|*prisma*|*migrations*)       echo "db-migrator";;
        *)                                 echo "backend-developer";;
      esac;;

    mutation)
      # Mutation failures mean tests are too weak — adversarial-tester adds stronger ones.
      echo "adversarial-tester";;

    integration)
      echo "backend-developer";;

    contract)
      # OpenAPI / API drift
      echo "backend-developer";;

    e2e)
      # Could be either; default to frontend, the orchestrator can override
      # using the dogfood-style bug owner field.
      echo "frontend-developer";;

    coverage)
      # A coverage threshold shortfall is missing tests, not broken behaviour —
      # the same owner that writes the red-before-green tests elsewhere.
      echo "adversarial-tester";;

    i18n)
      # Catalog key parity, plural forms and the hardcoded-string ratchet (#2394).
      # Every failure mode is a copy/catalog change in frontend or mobile — a missing
      # translation key, an incomplete plural group, or a literal that needs wrapping
      # in t(). That is the frontend developer's work, not the backend's, even when the
      # offending catalog is mobile's.
      echo "frontend-developer";;

    mobile-e2e)
      # A Maestro flow against the app on a booted emulator. The failing assertion is
      # about mobile/ app source, not the web frontend.
      echo "frontend-developer";;

    mobile-perf)
      # Startup/interaction budgets measured from SKILLFORGE_PERF markers.
      echo "perf-tester";;

    docs-refs)
      # A doc naming a scripts/… path that moved (or a script sourcing a missing lib).
      # Fixing it means correcting the reference or the ALLOW_MISSING list.
      echo "api-docs";;

    iteration-immutable)
      # An existing docs/iterations/ file was modified, or the generated index was
      # hand-edited. The fix is to restore it and regenerate.
      echo "api-docs";;

    migration-drift)
      # Models and alembic revisions disagree structurally.
      echo "db-migrator";;

    quarantine)
      # A quarantined test is overdue for repair or re-admission.
      echo "adversarial-tester";;

    a11y)
      echo "ux-designer";;

    lighthouse)
      echo "perf-tester";;

    visual)
      echo "frontend-developer";;

    seed-integrity)
      # Manifest-vs-filesystem mismatch, missing scripts, empty seed,
      # or non-idempotent seed all belong to db-migrator.
      echo "db-migrator";;

    repro-tests)
      # An open bug has no committed reproducing test — the adversarial tester
      # owns writing the red-before-green repro before the implementer fixes.
      echo "adversarial-tester";;

    wedge-coverage)
      # A wedge-critical file has no test — the e2e tester owns wedge-workflow
      # coverage (adversarial-tester deepens it afterward).
      echo "e2e-tester";;

    journey-coverage)
      # A catalogued user journey has no e2e spec — the e2e tester writes it
      # (and adds/updates the row in state/artifacts/journeys.json).
      echo "e2e-tester";;

    # Dogfood verdicts
    dogfood-cosmetic)  echo "frontend-developer";;
    dogfood-structural) echo "ux-designer";;
    dogfood-architecture) echo "designer";;
    dogfood-empty-seed) echo "db-migrator";;

    # Security
    security-critical) echo "security-auditor";;
    security-secrets)  echo "env-manager";;

    # ML statistical gates (ml-quality-gates.sh) and feasibility
    feasibility)         echo "decision-framer";;   # decision can't be supported by the data — re-frame or kill
    data-quality)        echo "data-quality-gate";;
    leakage)             echo "feature-engineer";;  # the leak is built in the feature pipeline
    beats-baseline)      echo "model-developer";;
    calibration)         echo "model-developer";;
    slice-fairness)      echo "fairness-auditor";;
    backtest-stability)  echo "feature-engineer";;  # instability is usually a splitting / point-in-time problem
    drift)               echo "retrain-loop";;

    # Deploy / canary
    canary-pipeline)   echo "cicd";;
    canary-infra)      echo "deployer";;
    canary-build)      echo "frontend-developer";;

    *)
      echo "ERROR: unknown gate '$GATE'" >&2
      exit 1;;
  esac
}

route
