#!/usr/bin/env bash
# Hermetic regression suite for scripts/i18n-check.sh — the i18n gate (#2394).
#
# The gate exists to FAIL on drift, so the assertions that matter are the failing ones.
# Every case builds synthetic catalogs in a temp dir and points the gate at them via the
# I18N_WEB_DIR / I18N_MOBILE_DIR / I18N_SRC_ROOTS seam. The suite never asserts against the
# REAL catalogs: those change every time a key lands, which would make this a tripwire for
# unrelated work rather than a test of the gate.
#
#   Run: bash scripts/i18n-check.test.sh    (exit 0 = all pass, 77 = skipped — python3/node absent)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/i18n-check.sh"

# Ambient lane configuration (AGENT_SLOT, QG_*, …) changes what a suite observes —
# agent-inbox.test.sh was green on lane 0 and red on lanes 1-2 for exactly that reason
# (#2387). Scrub before asserting anything.
# shellcheck source=scripts/lib/test-env.sh
source "$ROOT/scripts/lib/test-env.sh"
test_env_scrub

# The seam vars are what this suite drives; an inherited value would silently retarget
# every case at the real catalogs.
unset I18N_WEB_DIR I18N_MOBILE_DIR I18N_SRC_ROOTS

PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null || { echo "i18n-check.test: python3 absent — skipping"; exit 77; }
command -v node >/dev/null || { echo "i18n-check.test: node absent — skipping"; exit 77; }

TMP="$(mktemp -d -t skillforge-i18ntest-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── fixtures ───────────────────────────────────────────────────────────
# A minimal but realistic catalog set: one plural group (so the plural check has something
# to chew on) plus a couple of flat keys, and the index.ts the gate scrapes its canonical
# locale list out of.
mkcatalogs() { # <dir> <locale…>
  local dir="$1"; shift
  mkdir -p "$dir"
  local loc
  for loc in "$@"; do
    cat > "$dir/$loc.json" <<'JSON'
{
  "common": { "save": "Save", "cancel": "Cancel" },
  "auth": { "waiting_one": "1 second", "waiting_other": "{{count}} seconds" }
}
JSON
  done
  # Mirrors the shape of the real frontend/src/i18n/index.ts — supportedLngs is the list
  # i18next initialises with, and the gate treats it as the canonical locale set.
  {
    printf 'i18n.init({\n  fallbackLng: "en",\n  supportedLngs: ['
    printf "'%s', " "$@"
    printf '],\n});\n'
  } > "$dir/index.ts"
}

# Mutate one JSON catalog with a python expression over `d`.
mutate() { # <file> <python-stmt>
  python3 - "$1" "$2" <<'PY'
import json, sys
path, stmt = sys.argv[1], sys.argv[2]
d = json.load(open(path))
exec(stmt)
json.dump(d, open(path, "w"))
PY
}

floor_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hardcoded_floor"))' "$1" 2>/dev/null; }
count_of() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get(sys.argv[2], [])))' "$1" "$2" 2>/dev/null; }

WEB="$TMP/web"; MOBILE="$TMP/mobile"; SRC="$TMP/src"
mkcatalogs "$WEB" en es fr de pt ar zh
mkcatalogs "$MOBILE" en es fr de pt
mkdir -p "$SRC"
: > "$SRC/Clean.tsx"

BASE="$TMP/baseline.json"

run() { # run the gate against the fixtures; sets OUT and RC
  OUT="$(I18N_WEB_DIR="$WEB" I18N_MOBILE_DIR="$MOBILE" I18N_SRC_ROOTS="$SRC" \
        bash "$CHECK" --baseline "$BASE" "$@" 2>&1)"
  RC=$?
}

echo "i18n-check.sh — catalog parity"

# Seed the baseline once so the ratchets are settled, then assert the steady state.
run >/dev/null 2>&1
run
if [[ $RC -eq 0 ]]; then ok "in-sync catalogs → exit 0"
else bad "in-sync catalogs → expected exit 0, got $RC"$'\n'"$OUT"; fi

# 1) THE acceptance criterion: a deliberately removed key fails the gate.
cp "$WEB/es.json" "$TMP/es.bak"
mutate "$WEB/es.json" 'del d["common"]["cancel"]'
run
if [[ $RC -eq 1 ]]; then ok "removed key → exit 1"
else bad "removed key → expected exit 1, got $RC"$'\n'"$OUT"; fi
if grep -q "common.cancel" <<<"$OUT"; then ok "removed key → names the missing key"
else bad "removed key → does not name common.cancel"$'\n'"$OUT"; fi
if grep -q "web/es" <<<"$OUT"; then ok "removed key → names the offending catalog"
else bad "removed key → does not name web/es"$'\n'"$OUT"; fi
cp "$TMP/es.bak" "$WEB/es.json"

# 2) An EXTRA key is drift too — a stale key nobody removed from one locale.
mutate "$WEB/fr.json" 'd["common"]["ghost"] = "Fantome"'
run
if [[ $RC -eq 1 ]] && grep -q "common.ghost" <<<"$OUT"; then ok "extra key → exit 1, named"
else bad "extra key → expected exit 1 naming common.ghost, got $RC"$'\n'"$OUT"; fi
mutate "$WEB/fr.json" 'del d["common"]["ghost"]'

# 3) Mobile is covered too, not just web — this is the class that actually drifted (69 keys
#    across de/es/fr/pt, the gap #2397 exists to close).
cp "$MOBILE/de.json" "$TMP/de.bak"
mutate "$MOBILE/de.json" 'del d["common"]["save"]'
run
if [[ $RC -eq 1 ]] && grep -q "mobile/de" <<<"$OUT"; then ok "mobile drift → detected (the #2397 class)"
else bad "mobile drift → not detected, got $RC"$'\n'"$OUT"; fi
cp "$TMP/de.bak" "$MOBILE/de.json"

# 4) A catalog on disk but outside supportedLngs must not silently become supported.
cp "$WEB/en.json" "$WEB/it.json"
run
if [[ $RC -eq 1 ]] && grep -qi "canonical locale set" <<<"$OUT"; then ok "undeclared catalog → exit 1"
else bad "undeclared catalog → expected exit 1, got $RC"$'\n'"$OUT"; fi
rm -f "$WEB/it.json"

# 5) …and the converse: a locale declared in supportedLngs with no catalog on disk.
cp "$WEB/index.ts" "$TMP/index.bak"
sed -i "s/supportedLngs: \[/supportedLngs: ['it', /" "$WEB/index.ts"
run
if [[ $RC -eq 1 ]] && grep -q "no catalog file" <<<"$OUT"; then ok "declared-but-absent locale → exit 1"
else bad "declared-but-absent locale → expected exit 1, got $RC"$'\n'"$OUT"; fi
cp "$TMP/index.bak" "$WEB/index.ts"

echo "i18n-check.sh — parity ratchet (the #2397 drift)"

# 6) Pre-existing drift is BASELINED, not failed — a gate that lands red on day one is a
#    gate someone disables, and the 69-key mobile gap is #2397's to fix, not this gate's.
rm -f "$BASE"
mutate "$MOBILE/es.json" 'del d["common"]["save"]'
mutate "$MOBILE/fr.json" 'del d["common"]["save"]'
run
if [[ $RC -eq 0 ]] && grep -q "mobile/es:common.save" "$BASE" 2>/dev/null; then
  ok "seeding run → records the drift, exit 0"
else bad "seeding run → expected exit 0 with the drift recorded, got $RC"$'\n'"$OUT"; fi
run
if [[ $RC -eq 0 ]] && grep -q "2 known parity gap" <<<"$OUT"; then
  ok "baselined drift → exit 0 and still REPORTED every run"
else bad "baselined drift → expected exit 0 naming the known gaps, got $RC"$'\n'"$OUT"; fi

# 7) The ratchet forgives only what it knows: NEW drift on top of baselined drift fails.
mutate "$MOBILE/pt.json" 'del d["common"]["save"]'
run
if [[ $RC -eq 1 ]] && grep -q "mobile/pt:common.save" <<<"$OUT"; then
  ok "new drift atop baselined drift → exit 1"
else bad "new drift atop baselined drift → expected exit 1, got $RC"$'\n'"$OUT"; fi

# 8) A failing run must NOT rewrite the ratchet — otherwise the first red run launders
#    itself into the baseline and the gate never fails twice for the same reason.
BEFORE="$(count_of "$BASE" parity_exceptions)"
run
if [[ "$(count_of "$BASE" parity_exceptions)" == "$BEFORE" ]]; then
  ok "red run → baseline left untouched ($BEFORE entries)"
else bad "red run → rewrote the baseline ($BEFORE → $(count_of "$BASE" parity_exceptions))"; fi
mutate "$MOBILE/pt.json" 'd["common"]["save"] = "Salvar"'

# 9) Fixing a baselined gap tightens the list automatically, so the gain cannot be given
#    back — this is how #2397 shrinks the exception list to zero key by key.
mutate "$MOBILE/es.json" 'd["common"]["save"] = "Guardar"'
run
if [[ $RC -eq 0 && "$(count_of "$BASE" parity_exceptions)" == "1" ]]; then
  ok "fixed gap → exception list tightens 2 → 1"
else bad "fixed gap → expected a tightened list of 1, got rc=$RC n=$(count_of "$BASE" parity_exceptions)"$'\n'"$OUT"; fi
mutate "$MOBILE/fr.json" 'd["common"]["save"] = "Enregistrer"'
run >/dev/null 2>&1

echo "i18n-check.sh — locale-set resolution"

# 10) The locale set is scraped from index.ts. A scraper that returns [] when it cannot
#     parse reports "all good" about catalogs it never looked at — that is how the
#     store-listing guard passed on unchecked copy (#2408). It must FAIL instead.
cp "$WEB/index.ts" "$TMP/index.bak"
echo 'i18n.init({ fallbackLng: "en" });' > "$WEB/index.ts"
run
if [[ $RC -eq 1 ]] && grep -q "refusing to guess" <<<"$OUT"; then
  ok "unparseable supportedLngs → exit 1 (never an empty set)"
else bad "unparseable supportedLngs → expected exit 1, got $RC"$'\n'"$OUT"; fi

# 11) Same for a catalog dir with no index.ts at all.
rm -f "$WEB/index.ts"
run
if [[ $RC -eq 1 ]] && grep -q "no index.ts" <<<"$OUT"; then ok "no index.ts → exit 1"
else bad "no index.ts → expected exit 1, got $RC"$'\n'"$OUT"; fi
cp "$TMP/index.bak" "$WEB/index.ts"

# ── the shared-constant spelling (#2393) ───────────────────────────────
# #2393 hoisted the locale tags into ONE canonical constant so web/mobile/translator could
# stop drifting to 7/5/12, and both index.ts files became `supportedLngs: [...LOCALES]`.
# A literal-only parser matches that bracket, finds no quotes, and yields []. These cases
# pin the resolver that follows the identifier to its declaration — the same wall the
# store-listing guard hit first (#2408).

# 11a) The tags in a const declared in the same file.
cat > "$WEB/index.ts" <<'TS'
const LOCALES = ['en', 'es', 'fr', 'de', 'pt', 'ar', 'zh'] as const;
i18n.init({ fallbackLng: "en", supportedLngs: [...LOCALES] });
TS
run
if [[ $RC -eq 0 ]]; then ok "supportedLngs: [...LOCAL_CONST] → resolved, exit 0"
else bad "supportedLngs: [...LOCAL_CONST] → expected exit 0, got $RC"$'\n'"$OUT"; fi

# 11b) …and through a relative import, which is the shape a per-app constants file takes.
printf "export const LOCALES = ['en', 'es', 'fr', 'de', 'pt', 'ar', 'zh'];\n" > "$WEB/locales.ts"
cat > "$WEB/index.ts" <<'TS'
import { LOCALES } from './locales';
i18n.init({ fallbackLng: "en", supportedLngs: [...LOCALES] });
TS
run
if [[ $RC -eq 0 ]]; then ok "relative import → resolved, exit 0"
else bad "relative import → expected exit 0, got $RC"$'\n'"$OUT"; fi
rm -f "$WEB/locales.ts"

# 11c) The REAL shape: a bare workspace specifier resolved via package.json, through a
#      barrel re-export, with an aliased binding — and web and mobile naming DIFFERENT
#      constants. If resolution leaked across files (mobile picking up web's 7), the parity
#      check would fail on ar/zh having no mobile catalog, so exit 0 also proves per-file
#      resolution rather than one global answer.
PKGS="$TMP/pkgs"; mkdir -p "$PKGS/api-client/src"
printf '{ "name": "@skillforge/api-client", "main": "./src/index.ts" }\n' > "$PKGS/api-client/package.json"
cat > "$PKGS/api-client/src/locales.ts" <<'TS'
export const SUPPORTED_LOCALES = ['en', 'es', 'fr', 'de', 'pt', 'ar', 'zh'] as const;
export const MOBILE_LOCALES = ['en', 'es', 'fr', 'de', 'pt'] as const;
TS
printf "export { SUPPORTED_LOCALES, MOBILE_LOCALES } from './locales';\n" > "$PKGS/api-client/src/index.ts"
cat > "$WEB/index.ts" <<'TS'
import { SUPPORTED_LOCALES as WEB_LOCALES } from '@skillforge/api-client';
i18n.init({ fallbackLng: "en", supportedLngs: [...WEB_LOCALES] });
TS
cp "$MOBILE/index.ts" "$TMP/mobile-index.bak"
cat > "$MOBILE/index.ts" <<'TS'
import { MOBILE_LOCALES } from '@skillforge/api-client';
i18n.init({ fallbackLng: "en", supportedLngs: [...MOBILE_LOCALES] });
TS
OUT="$(I18N_WEB_DIR="$WEB" I18N_MOBILE_DIR="$MOBILE" I18N_SRC_ROOTS="$SRC" \
      I18N_PACKAGES_ROOT="$PKGS" bash "$CHECK" --baseline "$BASE" 2>&1)"; RC=$?
if [[ $RC -eq 0 ]]; then ok "bare specifier + barrel + alias → resolved per-file, exit 0"
else bad "bare specifier + barrel + alias → expected exit 0, got $RC"$'\n'"$OUT"; fi

# 11d) A DERIVED list must fail closed, not silently report the list it derives FROM.
#      `ALL.filter(…)` starts with an identifier too; following it would return ALL's 7 tags
#      for a set that ships 5 — confidently wrong, and worse than not answering.
cat > "$WEB/index.ts" <<'TS'
const ALL = ['en', 'es', 'fr', 'de', 'pt', 'ar', 'zh'] as const;
const SHIPPED = ALL.filter((l) => l !== 'zh');
i18n.init({ fallbackLng: "en", supportedLngs: [...SHIPPED] });
TS
run
if [[ $RC -eq 1 ]] && grep -q "refusing to guess" <<<"$OUT"; then
  ok "derived list → exit 1 (never the list it derives from)"
else bad "derived list → expected exit 1, got $RC"$'\n'"$OUT"; fi

# 11e) An import that resolves to nothing on disk is unreadable, not empty.
cat > "$WEB/index.ts" <<'TS'
import { LOCALES } from '@nope/not-installed';
i18n.init({ fallbackLng: "en", supportedLngs: [...LOCALES] });
TS
run
if [[ $RC -eq 1 ]] && grep -q "refusing to guess" <<<"$OUT"; then
  ok "unresolvable import → exit 1 (fails closed)"
else bad "unresolvable import → expected exit 1, got $RC"$'\n'"$OUT"; fi

cp "$TMP/index.bak" "$WEB/index.ts"
cp "$TMP/mobile-index.bak" "$MOBILE/index.ts"
rm -rf "$PKGS"

echo "i18n-check.sh — plural forms"

# 12) Arabic needs 6 CLDR categories; a fresh baseline records the shortfall rather than
#     failing (the #2401 ratchet), but the violation must be RECORDED, not lost.
rm -f "$BASE"; run >/dev/null 2>&1
if grep -q '"web/ar:auth.waiting' "$BASE" 2>/dev/null; then ok "arabic shortfall → baselined for #2401"
else bad "arabic shortfall → not recorded in baseline"$'\n'"$(cat "$BASE" 2>/dev/null)"; fi

# 13) Once baselined, the same shortfall must NOT fail — a gate that lands red gets disabled.
run
if [[ $RC -eq 0 ]]; then ok "baselined plural shortfall → exit 0"
else bad "baselined plural shortfall → expected exit 0, got $RC"$'\n'"$OUT"; fi

# 14) A NEW incomplete plural group DOES fail — the ratchet only forgives what it knows.
for loc in en es fr de pt ar zh; do
  mutate "$WEB/$loc.json" 'd["auth"]["retries_one"] = "1 retry"; d["auth"]["retries_other"] = "{{count}} retries"'
done
run
if [[ $RC -eq 1 ]] && grep -q "retries" <<<"$OUT"; then ok "new incomplete plural group → exit 1"
else bad "new incomplete plural group → expected exit 1, got $RC"$'\n'"$OUT"; fi

# 15) --update re-baselines it (the documented escape hatch).
run --update
if [[ $RC -eq 0 ]]; then ok "--update → re-baselines and passes"
else bad "--update → expected exit 0, got $RC"$'\n'"$OUT"; fi

# 16) A lone `_other` is an ENUM member, not a plural group. This is the false-positive
#     class that gets a gate switched off (mobile ships discussions.reason_other = "Other"
#     alongside reason_spam).
rm -f "$BASE"
for loc in en es fr de pt ar zh; do
  mutate "$WEB/$loc.json" 'd["report"] = {"reason_spam": "Spam", "reason_other": "Other"}'
done
run >/dev/null 2>&1
if ! grep -q "report.reason" "$BASE" 2>/dev/null; then ok "lone _other enum → not treated as a plural"
else bad "lone _other enum → false-positived as a plural group"$'\n'"$(cat "$BASE")"; fi

echo "i18n-check.sh — hardcoded-string ratchet"

# 17) Seeds at the measured count when no floor exists.
rm -f "$BASE"
cat > "$SRC/Page.tsx" <<'TSX'
export function Page() {
  return <div><h1>Welcome to the dashboard</h1></div>;
}
TSX
run >/dev/null 2>&1
FLOOR="$(floor_of "$BASE")"
if [[ "$FLOOR" == "1" ]]; then ok "seeds the floor at the measured count ($FLOOR)"
else bad "expected seeded floor 1, got $FLOOR"; fi

# 18) THE ratchet: adding a new hardcoded string fails the gate.
cat > "$SRC/Another.tsx" <<'TSX'
export function Another() {
  return <div><p>Another untranslated sentence here</p></div>;
}
TSX
run
if [[ $RC -eq 1 ]] && grep -q "ratchet only moves DOWN" <<<"$OUT"; then ok "new hardcoded string → exit 1"
else bad "new hardcoded string → expected exit 1, got $RC"$'\n'"$OUT"; fi

# 19) Removing hardcoded strings tightens the floor automatically, locking the gain in.
rm -f "$SRC/Another.tsx" "$SRC/Page.tsx"
run
if [[ $RC -eq 0 && "$(floor_of "$BASE")" == "0" ]]; then ok "removing strings → floor tightens to 0"
else bad "expected pass with tightened floor 0, got rc=$RC floor=$(floor_of "$BASE")"$'\n'"$OUT"; fi

# 20) A string already behind t() must not be counted — otherwise the gate punishes
#     correctly-translated code and nobody trusts the number.
cat > "$SRC/Translated.tsx" <<'TSX'
export function Translated() {
  return <div><h1>{t('page.title', 'Welcome to the dashboard')}</h1></div>;
}
TSX
run
if [[ $RC -eq 0 ]]; then ok "t()-wrapped copy → not counted"
else bad "t()-wrapped copy → wrongly counted, rc=$RC"$'\n'"$OUT"; fi
rm -f "$SRC/Translated.tsx"

# 21) The detector is deliberately conservative: a single-word label, a test id and a URL
#     are the noise classes that get a gate disabled, so none of them may count.
cat > "$SRC/Noise.tsx" <<'TSX'
export function Noise() {
  return (
    <div data-testid="user-profile-card">
      <a href="https://example.com/docs">Docs</a>
      <span className="text-sm font-medium">42</span>
    </div>
  );
}
TSX
run
if [[ $RC -eq 0 ]]; then ok "test ids / urls / single words → not counted"
else bad "conservative detector → false-positived, rc=$RC"$'\n'"$OUT"; fi
rm -f "$SRC/Noise.tsx"

echo "i18n-check.sh — failure modes"

# 22) Fail CLOSED on an unreadable baseline: an empty ratchet forgives everything, which is
#     exactly how a gate silently stops gating.
echo 'not json {{{' > "$BASE"
run
if [[ $RC -eq 1 ]]; then ok "unreadable baseline → exit 1 (fails closed)"
else bad "unreadable baseline → expected exit 1, got $RC"$'\n'"$OUT"; fi
rm -f "$BASE"

# 23) A missing catalog dir is "cannot measure" (77), not a silent pass.
OUT="$(I18N_WEB_DIR="$TMP/nope" I18N_MOBILE_DIR="$MOBILE" I18N_SRC_ROOTS="$SRC" \
      bash "$CHECK" --baseline "$BASE" 2>&1)"; RC=$?
if [[ $RC -eq 77 ]]; then ok "absent catalog dir → exit 77 (skip, not pass)"
else bad "absent catalog dir → expected exit 77, got $RC"$'\n'"$OUT"; fi

# 24) node genuinely absent → 77, not a pass. PATH is SUBSTITUTED, not prepended: prepending
#     leaves the host's real node on the tail and the absence is never simulated at all
#     (#2387, M7). Everything the runner needs to REACH its node check is kept reachable —
#     bash, python3, dirname, mkdir — so the failure is unambiguously about node and not
#     about the stub PATH having removed the interpreter out from under it.
STUB="$TMP/stub"; mkdir -p "$STUB"
OUT="$(PATH="$(test_env_stub_path "$STUB" bash python3 dirname mkdir)" \
      I18N_WEB_DIR="$WEB" I18N_MOBILE_DIR="$MOBILE" I18N_SRC_ROOTS="$SRC" \
      bash "$CHECK" --baseline "$BASE" 2>&1)"; RC=$?
if [[ $RC -eq 77 ]] && grep -q "node required" <<<"$OUT"; then ok "node absent → exit 77"
else bad "node absent → expected exit 77, got $RC"$'\n'"$OUT"; fi

# 25) An unknown --only is a caller mistake, not a reason to check nothing and pass.
run --only pluralz
if [[ $RC -eq 2 ]]; then ok "unknown --only → exit 2"
else bad "unknown --only → expected exit 2, got $RC"$'\n'"$OUT"; fi

echo "i18n-check.sh — parity/plural interaction (pr-review findings)"

# A fresh catalog pair + baseline, isolated from the accumulated mutations of $WEB/$BASE
# above, so these interaction assertions aren't at the mercy of earlier tests' leftover state.
WEB2="$TMP/web2"; BASE2="$TMP/baseline2.json"
mkcatalogs "$WEB2" en es fr de pt ar zh
run2() { OUT="$(I18N_WEB_DIR="$WEB2" I18N_MOBILE_DIR="$MOBILE" I18N_SRC_ROOTS="$SRC" \
        bash "$CHECK" --baseline "$BASE2" 2>&1)"; RC=$?; }

# Seed: every locale carries only auth.waiting_one/_other, so ar (needs all 6 CLDR
# categories) is short 4 — zero/two/few/many — baselined as a known #2401 gap.
run2 >/dev/null 2>&1
if grep -q '"web/ar:auth.waiting:few,many,two,zero"' "$BASE2" 2>/dev/null; then
  ok "seed: ar's 4-category plural shortfall baselined for the interaction tests"
else bad "seed: ar plural shortfall not baselined as expected"$'\n'"$(cat "$BASE2" 2>/dev/null)"; fi

# 26) Parity and the plural check must not contradict each other: a locale gaining a CLDR
#     category beyond en's _one/_other (real progress toward #2401 — Arabic adding
#     _two/_zero) must not register as parity drift. Parity owns the base key path; the
#     plural check owns per-category completeness.
mutate "$WEB2/ar.json" 'd["auth"]["waiting_two"] = "two"; d["auth"]["waiting_zero"] = "zero"'
run2
if [[ $RC -eq 0 ]] && ! grep -q "FAIL parity" <<<"$OUT"; then
  ok "ar adding _two/_zero (beyond en) → not flagged as parity drift"
else bad "ar adding _two/_zero → expected exit 0 with no parity FAIL, got $RC"$'\n'"$OUT"; fi

# 27) The same fix only PARTIALLY closes ar's shortfall (still missing few/many) — that
#     partial progress must not read as a NEW plural violation, and the ratchet must
#     auto-tighten the stored category list (4 → 2) rather than staying stuck on the
#     original string, which is what pushed the #2401 fixer toward --update instead of
#     landing the improvement.
if ! grep -q "FAIL plurals" <<<"$OUT"; then
  ok "ar's partial plural fix (2 of 4 categories closed) → not flagged as a NEW violation"
else bad "ar's partial plural fix → wrongly flagged as new"$'\n'"$OUT"; fi
if grep -q '"web/ar:auth.waiting:few,many"' "$BASE2" 2>/dev/null; then
  ok "ratchet auto-tightens the stored category list (4 categories → 2)"
else bad "ratchet did not tighten the category list"$'\n'"$(cat "$BASE2" 2>/dev/null)"; fi

echo "i18n-check.sh — absent catalog set (pr-review finding)"

# 28) A configured catalog dir that VANISHES after a baseline is established must hard-fail,
#     never silently pass while corrupting the ratchet — deleting/moving a catalog dir must
#     not read as "nothing to see here" about drift it never looked at (the #2408 class).
#     Establish a real baseline first so this run is NOT a seeding run (recording=False),
#     which is the state the reported false PASS depended on.
rm -f "$BASE"; run >/dev/null 2>&1
BEFORE_BASE="$(cat "$BASE")"
OUT="$(I18N_WEB_DIR="$WEB" I18N_MOBILE_DIR="$TMP/mobile-gone-does-not-exist" I18N_SRC_ROOTS="$SRC" \
      bash "$CHECK" --baseline "$BASE" 2>&1)"; RC=$?
if [[ $RC -eq 1 ]]; then ok "vanished mobile catalog dir → exit 1 (hard failure, not a silent skip)"
else bad "vanished mobile catalog dir → expected exit 1, got $RC"$'\n'"$OUT"; fi
if [[ "$(cat "$BASE")" == "$BEFORE_BASE" ]]; then
  ok "vanished mobile catalog dir → baseline left byte-for-byte untouched (no laundering)"
else bad "vanished mobile catalog dir → corrupted the baseline"$'\n'"before: $BEFORE_BASE"$'\n'"after: $(cat "$BASE")"; fi

echo "i18n-check.sh — absent hardcoded source roots (pr-review finding)"

# 29) Every configured I18N_SRC_ROOTS entry missing (renamed/moved, e.g. frontend/src/app
#     typo'd) must hard-fail rather than silently measuring zero files and reporting a
#     green PASS — the exact #2408 class this file already fails closed for catalog dirs.
#     A false PASS here also feeds the auto-tighten step, which would zero out the
#     committed floor and wedge every later honest run until someone --update'd it back.
#     Establish a real baseline first so this is NOT a seeding run.
rm -f "$BASE"; run >/dev/null 2>&1
BEFORE_FLOOR="$(floor_of "$BASE")"
BEFORE_BASE="$(cat "$BASE")"
OUT="$(I18N_WEB_DIR="$WEB" I18N_MOBILE_DIR="$MOBILE" \
      I18N_SRC_ROOTS="$TMP/src-gone-does-not-exist" \
      bash "$CHECK" --baseline "$BASE" 2>&1)"; RC=$?
if [[ $RC -eq 1 ]] && grep -q "none of the configured source roots exist" <<<"$OUT"; then
  ok "all hardcoded source roots absent → exit 1 (hard failure, not a 0-hit PASS)"
else bad "all hardcoded source roots absent → expected exit 1, got $RC"$'\n'"$OUT"; fi
if [[ "$(cat "$BASE")" == "$BEFORE_BASE" ]]; then
  ok "all hardcoded source roots absent → baseline untouched (floor not zeroed, was $BEFORE_FLOOR)"
else bad "all hardcoded source roots absent → corrupted the baseline"$'\n'"before: $BEFORE_BASE"$'\n'"after: $(cat "$BASE")"; fi

# 30) Only SOME configured roots missing must still measure normally — the hard failure is
#     for "none resolve", not "not all resolve".
OUT="$(I18N_WEB_DIR="$WEB" I18N_MOBILE_DIR="$MOBILE" \
      I18N_SRC_ROOTS="$TMP/src-partial-does-not-exist:$SRC" \
      bash "$CHECK" --baseline "$BASE" 2>&1)"; RC=$?
if [[ $RC -eq 0 ]]; then ok "one of several hardcoded source roots existing → measures normally"
else bad "one of several source roots existing → expected exit 0, got $RC"$'\n'"$OUT"; fi

echo "i18n-check.sh — hardcoded floor seeding message on --only (pr-review finding)"

# 31) `--only hardcoded` with no floor recorded must not claim it seeded one: seeding
#     requires a FULL run (see SEEDED_FIELDS/`seeding` above), so a --only pass never
#     writes the baseline. The message must say a seed did NOT happen instead of claiming
#     one that didn't.
rm -f "$BASE"
run --only hardcoded
if [[ $RC -eq 0 ]] && ! grep -q "seeding at" <<<"$OUT" \
      && grep -q "not seeding on a --only run" <<<"$OUT"; then
  ok "--only hardcoded, no floor → message does not claim a seed that didn't happen"
else bad "--only hardcoded seeding message wrong, rc=$RC"$'\n'"$OUT"; fi
if [[ ! -f "$BASE" ]]; then ok "--only hardcoded, no floor → baseline file not written"
else bad "--only hardcoded, no floor → baseline file unexpectedly written"$'\n'"$(cat "$BASE")"; fi

printf '\ni18n-check.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
