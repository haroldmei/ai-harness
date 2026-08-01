#!/usr/bin/env bash
# i18n-check.sh — catalog key parity, CLDR plural completeness, and a hardcoded-string
# ratchet across the web and mobile locale catalogs (#2394).
#
# Why this exists
# ---------------
# NOTHING enforced i18n. The web catalogs were in sync by discipline alone (all 7 at
# exactly 310 keys), and mobile proved discipline does not hold: `mobile/src/i18n/en.json`
# carries 838 keys while de/es/fr/pt carry 769 — a 69-key drift nobody noticed. Every key
# in that gap renders as an English fallback on a non-English device. This gate is what
# makes that class of drift impossible to LAND, and it has to precede the #2398 UI
# extraction or that 138-file sweep reopens the gap as fast as it closes it.
#
# Three checks:
#
#   1. PARITY — every catalog in a locale set has exactly the key paths of its `en` base.
#      Web and mobile are separate sets with separate locale lists; both are covered.
#
#      RATCHETED against `parity_exceptions` in the baseline, for the same reason
#      typecheck ratchets against mypy-baseline: the 69-key mobile drift is real, it is
#      #2397's job to fix, and a gate that lands red on day one is a gate someone
#      disables. So the drift is enumerated key-by-key in the baseline — which is what
#      PROVES the detector sees it — reported on every run, and forgiven. Anything NOT in
#      that list fails. The list only ever shrinks: when #2397 translates a key, the next
#      run drops it from the baseline automatically, so the gain cannot be given back.
#
#   2. PLURALS — a key that forms a plural group must carry every CLDR category its locale
#      requires. Categories come from `Intl.PluralRules` at runtime rather than a hardcoded
#      table, so they cannot go stale (Arabic needs 6, Chinese needs 1).
#
#      Also ratcheted: the shipped ar/es/fr/pt catalogs carry English-shaped `_one/_other`
#      plurals today and fixing that is #2401's job. Known shortfalls are baselined; NEW
#      ones fail.
#
#   3. HARDCODED RATCHET — count of user-facing literals in frontend/src/{app,components}
#      that are not behind `t()`. Seeded at the measured number and allowed only to go
#      DOWN, exactly like scripts/coverage.sh ratchets the coverage floor via
#      state/artifacts/coverage-floor.json.
#
#      The detector deliberately UNDER-counts (see _detect_hardcoded below). A noisy gate
#      gets switched off, so it counts only strings that are unambiguously prose:
#      multi-word, letter-bearing, in JSX text or a copy-bearing attribute, on a line that
#      is not already calling t(). Real hardcoded strings it misses stay missed — the
#      ratchet still works, it just starts lower.
#
# Locale sets are SCRAPED from each catalog dir's index.ts `supportedLngs`, not hardcoded
# here — the app's own list is the only one that can't drift from what actually ships. If
# the scrape finds nothing the gate FAILS rather than returning an empty set: a scraper
# that quietly returns [] reports "all good" about a thing it never looked at, which is how
# the store-listing guard passed on unchecked copy (#2408).
#
# Usage:
#   scripts/i18n-check.sh                 # run all three checks against the committed baseline
#   scripts/i18n-check.sh --update        # re-baseline plurals + parity + floor (say why in the PR)
#   scripts/i18n-check.sh --json FILE     # also write a machine-readable report
#   scripts/i18n-check.sh --only parity   # run one check (parity|plurals|hardcoded)
#   scripts/i18n-check.sh --baseline F    # use an alternate baseline file
#
# Test seam (scripts/i18n-check.test.sh): I18N_WEB_DIR / I18N_MOBILE_DIR / I18N_SRC_ROOTS
# point the checks at synthetic fixtures, so the suite runs in ~1s against catalogs it
# controls rather than asserting against the real ones — which change every time a key
# lands, and would make this suite a tripwire for unrelated work. I18N_PACKAGES_ROOT does
# the same for the workspace dir a bare import specifier resolves against.
#
# Exit: 0 all checks pass | 1 a check failed | 77 cannot measure (no python3/node/catalogs)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "FATAL: cannot cd to repo root ${ROOT}" >&2; exit 2; }

export LC_ALL=C LC_NUMERIC=C

BASELINE_FILE="state/artifacts/i18n-baseline.json"
JSON_OUT=""
UPDATE=0
ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)   UPDATE=1; shift;;
    --json)     JSON_OUT="$2"; shift 2;;
    --only)     ONLY="$2"; shift 2;;
    --baseline) BASELINE_FILE="$2"; shift 2;;
    -h|--help)  sed -n '2,60p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

case "${ONLY:-}" in
  ""|parity|plurals|hardcoded) ;;
  *) echo "i18n-check: unknown --only '$ONLY' (parity|plurals|hardcoded)" >&2; exit 2;;
esac

command -v python3 >/dev/null || { echo "i18n-check: python3 required"; exit 77; }
command -v node >/dev/null || { echo "i18n-check: node required (Intl.PluralRules)"; exit 77; }

WEB_DIR="${I18N_WEB_DIR:-frontend/src/i18n}"
MOBILE_DIR="${I18N_MOBILE_DIR:-mobile/src/i18n}"
SRC_ROOTS="${I18N_SRC_ROOTS:-frontend/src/app:frontend/src/components}"
[[ -d "$WEB_DIR" ]] || { echo "i18n-check: no web catalog dir ($WEB_DIR)"; exit 77; }

mkdir -p "$(dirname "$BASELINE_FILE")"

# The whole analysis is one python3 pass so parity/plurals/hardcoded share the catalog
# parse. Human report goes to stderr, JSON summary to stdout.
REPORT_JSON="$(
python3 - "$BASELINE_FILE" "$UPDATE" "$ONLY" "$WEB_DIR" "$MOBILE_DIR" "$SRC_ROOTS" <<'PYEOF'
import json, os, re, subprocess, sys
from pathlib import Path

baseline_file, update_flag, only = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
web_dir, mobile_dir, src_roots = sys.argv[4], sys.argv[5], sys.argv[6].split(":")
# Where a bare specifier like "@skillforge/api-client" is looked up when following
# `supportedLngs: [...MOBILE_LOCALES]` to its declaration (see declared_locales below).
# The workspace's own packages/ only — never node_modules.
packages_root = Path(os.environ.get("I18N_PACKAGES_ROOT", "packages")).resolve()


def want(check: str) -> bool:
    return not only or only == check


def err(msg: str = "") -> None:
    print(msg, file=sys.stderr)


CLDR_SUFFIXES = ("zero", "one", "two", "few", "many", "other")


def plural_group_bases(keys):
    """Base key paths that carry >=2 CLDR suffixes in `keys` — a real plural group.

    A lone `_other` is almost always an enum member (mobile ships
    `discussions.reason_other` = "Other" next to `reason_spam`), so a base only counts once
    two or more distinct suffixes show up under it. Mirrors the detection used by the plural
    check itself so the two never drift apart.
    """
    groups = {}
    for key in keys:
        base, _, suffix = key.rpartition("_")
        if suffix in CLDR_SUFFIXES and base:
            groups.setdefault(base, set()).add(suffix)
    return {base for base, suffixes in groups.items() if len(suffixes) >= 2}


def collapse_plural_members(keys, group_bases):
    """Collapse every `<base>_<suffix>` member of a known plural group down to `<base>`.

    Parity must never compare individual CLDR categories: a locale needing MORE categories
    than `en` (Arabic's `_few/_many/_two/_zero`) would otherwise register as `extra` keys at
    the exact moment the plural check demands them, so closing #2401's gap could never pass
    parity. The plural check owns per-category completeness; parity only owns the base path.
    """
    collapsed = set()
    for key in keys:
        base, _, suffix = key.rpartition("_")
        if suffix in CLDR_SUFFIXES and base in group_bases:
            collapsed.add(base)
        else:
            collapsed.add(key)
    return collapsed


# ── canonical locale sets ──────────────────────────────────────────────
# Scraped from each catalog dir's own index.ts rather than hardcoded here. That file is
# what i18next actually initialises with, so it is the only list that cannot disagree with
# what ships. A locale declared there without a catalog on disk, or a catalog on disk not
# declared there, are both hard failures — that is the whole point of having one source.
#
# The declaration is no longer always a literal. #2393 hoisted the tags into ONE canonical
# constant (backend/app/core/locales.py, mirrored for TS in packages/api-client/src/locales.ts)
# so web/mobile/translator could stop drifting to 7/5/12, and both index.ts files became
#
#     supportedLngs: [...MOBILE_LOCALES],
#
# A literal-only parser matches that outer bracket, finds no quotes inside, and yields an
# empty set. So this resolver FOLLOWS the identifier — through local consts, imports and
# barrel re-exports — the same way mobile/src/__tests__/support/store-assets.ts does for the
# store-listing guard, which hit this exact wall first (#2408). Two rules carry over from
# there, and they matter more than the regexes:
#   1. Resolve the constant. One shared list is the better design, so the guard follows it.
#   2. Never return an empty set. A scraper that cannot read its subject must say THAT, not
#      quietly assert the app speaks no languages — the failure #2408 cost a day to diagnose.
# node_modules is deliberately never searched: the locale set is first-party, and a guard
# satisfiable by a dependency's file is a guard satisfiable by the wrong file.
SUPPORTED_RE = re.compile(r"(?<![\w$])supportedLngs\s*:\s*(\[[^\]]*\]|[A-Za-z_$][\w$.]*)")
LOCALE_RE = re.compile(r"['\"]([A-Za-z]{2}(?:-[A-Za-z0-9]+)?)['\"]")
IDENT_RE = re.compile(r"[A-Za-z_$][\w$]*")
MODULE_EXTS = (".ts", ".tsx", ".mts", ".js")


def _read_text(path: Path):
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def _package_entry(pkg_dir: Path):
    """A first-party package's entry point, from its package.json."""
    try:
        manifest = json.loads((pkg_dir / "package.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, ValueError):
        return None  # malformed manifest — fall back to the conventional layout
    for field in ("main", "module", "types"):
        value = manifest.get(field)
        if isinstance(value, str):
            entry = (pkg_dir / value).resolve()
            if entry.is_file():
                return entry
    return None


def _resolve_module(from_file: Path, spec: str):
    """Resolve a module specifier to a file on disk, TS-style. None if not found."""
    bases = []
    if spec.startswith("."):
        bases.append((from_file.parent / spec).resolve())
    else:
        # "@skillforge/api-client" → <packages_root>/api-client
        pkg_dir = (packages_root / re.sub(r"^@[^/]+/", "", spec)).resolve()
        entry = _package_entry(pkg_dir)
        if entry:
            return entry
        bases.extend([pkg_dir, pkg_dir / "src"])
    for base in bases:
        candidates = [base]
        candidates += [Path(f"{base}{ext}") for ext in MODULE_EXTS]
        candidates += [base / f"index{ext}" for ext in MODULE_EXTS]
        for candidate in candidates:
            if candidate.is_file():
                return candidate
    return None


def _exported_name_of(clause: str, local: str):
    """Given `{ a, b as c }`, the name `c` is exported under: here, `b`."""
    for part in clause.split(","):
        match = re.match(r"^(?:type\s+)?([\w$]+)(?:\s+as\s+([\w$]+))?$", part.strip())
        if not match:
            continue
        source, alias = match.group(1), match.group(2)
        if (alias or source) == local:
            return source
    return None


def _resolve_tag_constant(path: Path, ident: str, seen: set):
    """The quoted tags bound to `ident`, following the declaration wherever it lives.

    Returns [] when it cannot be found — the caller turns that into a loud failure.
    """
    visit = f"{path}::{ident}"
    if visit in seen:
        return []  # cyclic barrels are a real shape
    seen.add(visit)

    body = _read_text(path)
    if body is None:
        return []
    name = re.escape(ident)

    # `export const IDENT = ['en', …] as const` (with or without a type annotation)
    literal = re.search(rf"(?:export\s+)?const\s+{name}\b[^=\n]*=\s*\[([^\]]*)\]", body)
    if literal:
        tags = LOCALE_RE.findall(literal.group(1))
        if tags:
            return tags

    # `const IDENT = OTHER` — one constant aliasing another, and ONLY that. The whole
    # right-hand side has to be the identifier: `const MOBILE = ALL.filter((l) => l !== 'ar')`
    # also starts with an identifier, and following it would return ALL's tags — the derived
    # list's contents, confidently wrong. Fall through and let the caller fail loudly instead.
    alias = re.search(rf"(?:export\s+)?const\s+{name}\b[^=\n]*=\s*([^;\n]+)", body)
    if alias:
        rhs = re.sub(r"\s+as\s+const\s*$", "", alias.group(1)).strip()
        if re.fullmatch(r"[A-Za-z_$][\w$]*", rhs):
            tags = _resolve_tag_constant(path, rhs, seen)
            if tags:
                return tags

    # `import { IDENT } from '…'` / `export { IDENT } from '…'` (incl. aliases)
    for clause, spec in re.findall(
        r"(?:import|export)\s*(?:type\s*)?\{([^}]*)\}\s*from\s*['\"]([^'\"]+)['\"]", body
    ):
        exported = _exported_name_of(clause, ident)
        if not exported:
            continue
        target = _resolve_module(path, spec)
        if target:
            tags = _resolve_tag_constant(target, exported, seen)
            if tags:
                return tags

    # `export * from '…'`
    for spec in re.findall(r"export\s*\*\s*from\s*['\"]([^'\"]+)['\"]", body):
        target = _resolve_module(path, spec)
        if target:
            tags = _resolve_tag_constant(target, ident, seen)
            if tags:
                return tags

    return []


def declared_locales(directory: Path):
    """Return (locales, error). Never returns an empty list silently — see #2408."""
    index = directory / "index.ts"
    if not index.exists():
        return None, f"no index.ts in {directory} — cannot resolve the canonical locale set"
    body = _read_text(index)
    if body is None:
        return None, f"cannot read {index} — refusing to guess"
    match = SUPPORTED_RE.search(body)
    if not match:
        return None, f"no `supportedLngs: [...]` found in {index} — refusing to guess"
    expr = match.group(1)

    locales = LOCALE_RE.findall(expr)
    if locales:
        return locales, None

    seen: set = set()
    for ident in IDENT_RE.findall(expr):
        tags = _resolve_tag_constant(index, ident, seen)
        if tags:
            return tags, None

    return None, (
        f"`supportedLngs: {expr}` in {index} parsed to an empty set — refusing to guess. "
        "Teach declared_locales() the new spelling rather than letting this gate report the "
        "app as supporting no locales."
    )


def flatten(obj, prefix=""):
    for key, value in obj.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            yield from flatten(value, path)
        else:
            yield path


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


baseline = {}
if os.path.exists(baseline_file):
    try:
        baseline = load(baseline_file)
    except (json.JSONDecodeError, OSError):
        # Fail closed: an unreadable baseline must not silently forgive everything. That
        # is exactly how a ratcheted gate stops gating without anyone noticing.
        err("i18n-check: baseline unreadable — refusing to run with an empty ratchet")
        print(json.dumps({"status": "fail", "reason": "unreadable baseline"}))
        sys.exit(0)

failures = []
report = {"parity": {}, "plurals": {}, "hardcoded": {}}

SEEDED_FIELDS = ("parity_exceptions", "plural_violations", "hardcoded_floor")
# Seed only on a FULL run: a --only pass measures one dimension, and writing a baseline
# from it would record "no drift" for the two dimensions it never looked at.
seeding = not only and any(field not in baseline for field in SEEDED_FIELDS)
# A run that is establishing the ratchet REPORTS what it found rather than failing on it —
# there is no prior number to have regressed from. Same shape as coverage.sh seeding its
# floor. After this run the numbers are committed and every later run is judged against them.
recording = update_flag or seeding

catalog_sets = []
for name, directory in (("web", web_dir), ("mobile", mobile_dir)):
    path = Path(directory)
    if not path.is_dir():
        # A missing catalog set is a HARD failure, never a silent skip: a scraper that
        # reports "nothing to see" about a dir it never looked at is exactly the #2408 class
        # (the store-listing guard passing on unchecked copy), and silently skipping here
        # would also let the auto-tighten step below zero out parity_exceptions for a set
        # that was never actually compared this run.
        failures.append(f"{name}: catalog dir {directory} does not exist")
        report["parity"][name] = "absent"
        continue
    locales, error = declared_locales(path)
    if error:
        failures.append(f"{name}: {error}")
        report["parity"][name] = "unresolvable"
        continue
    catalog_sets.append({"name": name, "dir": path, "locales": locales})

# ── 1. parity ──────────────────────────────────────────────────────────
# Exceptions are "<set>/<locale>:<key>" and record a key KNOWN to be missing/extra today.
known_parity = set(baseline.get("parity_exceptions", []))
current_parity = []      # every drifted key seen this run, same format
catalog_keys = {}

for cset in catalog_sets:
    directory, name = cset["dir"], cset["name"]

    on_disk = sorted(p.stem for p in directory.glob("*.json"))
    undeclared = [loc for loc in on_disk if loc not in cset["locales"]]
    if undeclared and want("parity"):
        failures.append(
            f"{name}: catalog(s) on disk but not in the canonical locale set: "
            f"{', '.join(undeclared)} — add them to {directory}/index.ts supportedLngs first"
        )

    base_path = directory / "en.json"
    if not base_path.exists():
        failures.append(f"{name}: no en.json base catalog in {directory}")
        continue
    base_keys = set(flatten(load(base_path)))
    catalog_keys[name] = {"en": base_keys}
    group_bases = plural_group_bases(base_keys)
    cset["group_bases"] = group_bases
    parity_base_keys = collapse_plural_members(base_keys, group_bases)

    set_report = {"base_key_count": len(base_keys), "locales": {}}
    for locale in cset["locales"]:
        if locale == "en":
            set_report["locales"]["en"] = {"missing": 0, "extra": 0}
            continue
        path = directory / f"{locale}.json"
        if not path.exists():
            failures.append(f"{name}/{locale}: declared in index.ts but no catalog file ({path})")
            continue
        keys = set(flatten(load(path)))
        catalog_keys[name][locale] = keys
        # Plural-suffixed members collapse to their base before comparing — a locale
        # carrying MORE CLDR categories than en (Arabic's _few/_two/_zero) is progress, not
        # a parity gap; see collapse_plural_members.
        parity_keys = collapse_plural_members(keys, group_bases)
        missing = sorted(parity_base_keys - parity_keys)
        extra = sorted(parity_keys - parity_base_keys)
        set_report["locales"][locale] = {"missing": len(missing), "extra": len(extra)}
        current_parity.extend(f"{name}/{locale}:{k}" for k in missing + extra)
    report["parity"][name] = set_report

if want("parity"):
    current = set(current_parity)
    new_drift = sorted(current - known_parity)
    fixed_drift = sorted(known_parity - current)
    report["parity"]["_ratchet"] = {
        "total": len(current),
        "baselined": len(known_parity),
        "new": len(new_drift),
        "fixed": len(fixed_drift),
    }
    if current:
        # Report the baselined drift on EVERY run. A forgiven failure that prints nothing
        # is indistinguishable from no failure, and this one is 276 keys of shipped English
        # on four non-English catalogs — it should stay visible until #2397 clears it.
        err(f"i18n-check: {len(current & known_parity)} known parity gap(s) baselined "
            f"(awaiting #2397); {len(fixed_drift)} fixed since the last baseline")
    if new_drift and not recording:
        failures.append(
            f"parity: {len(new_drift)} NEW key(s) out of sync with the en base "
            "(<set>/<locale>:<key>)"
        )
        for entry in new_drift[:20]:
            err(f"    parity   {entry}")
        if len(new_drift) > 20:
            err(f"    … and {len(new_drift) - 20} more")

# ── 2. plurals ─────────────────────────────────────────────────────────
def cldr_categories(locales):
    """Ask the runtime, not a hardcoded table — CLDR data changes."""
    script = (
        "const out={};"
        f"for (const l of {json.dumps(locales)}) "
        "out[l]=new Intl.PluralRules(l).resolvedOptions().pluralCategories;"
        "console.log(JSON.stringify(out));"
    )
    proc = subprocess.run(["node", "-e", script], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return json.loads(proc.stdout)


def parse_plural_baseline(entries):
    """`<set>/<locale>:<base>:<cats>` entries → {`<set>/<locale>:<base>`: frozenset(cats)}."""
    parsed = {}
    for entry in entries:
        key, _, cats = entry.rpartition(":")
        parsed[key] = frozenset(c for c in cats.split(",") if c)
    return parsed


def format_plural_baseline(violations):
    return sorted(f"{key}:{','.join(sorted(cats))}" for key, cats in violations.items())


plural_violations = {}   # "<set>/<locale>:<base>" -> frozenset(missing CLDR categories)
if want("plurals"):
    all_locales = sorted({loc for c in catalog_sets for loc in c["locales"]})
    categories = cldr_categories(all_locales) if all_locales else {}
    if categories is None:
        failures.append("plurals: could not resolve CLDR categories via node")
    else:
        for cset in catalog_sets:
            name = cset["name"]
            if name not in catalog_keys or "en" not in catalog_keys[name]:
                continue
            base_keys = catalog_keys[name]["en"]
            group_bases = cset.get("group_bases") or plural_group_bases(base_keys)

            for locale in cset["locales"]:
                keys = catalog_keys[name].get(locale)
                if keys is None:
                    continue
                required = set(categories.get(locale, ["other"]))
                for base in sorted(group_bases):
                    present = {s for s in CLDR_SUFFIXES if f"{base}_{s}" in keys}
                    absent = required - present
                    if absent:
                        plural_violations[f"{name}/{locale}:{base}"] = frozenset(absent)

    known_plural = parse_plural_baseline(baseline.get("plural_violations", []))
    # A baselined shortfall stays forgiven as long as the locale hasn't gone BACKWARDS —
    # closing some but not all of a group's missing categories is progress, not a new
    # violation, and must not read as one. Keying the baseline by string (old behaviour)
    # made a partial fix's category list a different string than the baselined one and
    # reported it NEW, which is exactly backwards for a ratchet.
    new_violations = sorted(
        f"{key}:{','.join(sorted(missing))}"
        for key, missing in plural_violations.items()
        if not missing.issubset(known_plural.get(key, frozenset()))
    )
    fixed = sorted(set(known_plural) - set(plural_violations))
    report["plurals"] = {
        "total": len(plural_violations),
        "baselined": len(known_plural),
        "new": len(new_violations),
        "fixed": len(fixed),
    }
    if new_violations and not recording:
        failures.append(
            f"plurals: {len(new_violations)} NEW incomplete plural group(s) "
            "(<set>/<locale>:<key>:<missing-categories>)"
        )
        for violation in new_violations[:15]:
            err(f"    plural   {violation}")
        if len(new_violations) > 15:
            err(f"    … and {len(new_violations) - 15} more")

# ── 3. hardcoded-string ratchet ────────────────────────────────────────
# Deliberately conservative. A literal is counted only when ALL of these hold:
#   * it is JSX text or one of a few copy-bearing attributes,
#   * it has >=2 whitespace-separated words and at least one letter,
#   * its line does not already route through t(...) / <Trans>,
#   * it is not a URL / path / import / className / test id / template expression.
# Everything ambiguous is skipped, so the number under-reports real hardcoding by design.
JSX_TEXT = re.compile(r">\s*([A-Z][^<>{}\n]{3,})<")
ATTR_TEXT = re.compile(
    r'\b(?:placeholder|title|aria-label|alt|label)\s*=\s*"([^"{}\n]{4,})"'
)
NON_COPY = re.compile(r"^(?:https?://|/|\./|\.\./|#|[a-z0-9_-]+$)")


def _detect_hardcoded():
    roots = [Path(r) for r in src_roots if r]
    hits = 0
    per_file = {}
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.tsx")):
            try:
                # NB: not named `source` — scripts/docs-script-refs.sh greps shell files
                # for a leading `source `/`. ` and would read that as a sourced-library
                # directive inside this heredoc.
                text_body = path.read_text(encoding="utf-8")
            except OSError:
                continue
            count = 0
            for line in text_body.splitlines():
                stripped = line.strip()
                if stripped.startswith("//") or stripped.startswith("*"):
                    continue
                # A line already calling t() is doing the right thing; skipping it keeps
                # the count honest rather than punishing interpolated copy.
                if "t(" in line or "Trans" in line:
                    continue
                for match in list(JSX_TEXT.findall(line)) + list(ATTR_TEXT.findall(line)):
                    text = match.strip()
                    if NON_COPY.match(text):
                        continue
                    if "{" in text or "}" in text:
                        continue
                    if not re.search(r"[A-Za-z]", text):
                        continue
                    if len(text.split()) < 2:
                        continue
                    count += 1
            if count:
                per_file[str(path)] = count
                hits += count
    return hits, per_file


hardcoded_count = None
if want("hardcoded"):
    if not any(Path(r).is_dir() for r in src_roots if r):
        # Same #2408 class as the missing-catalog-dir check above: a detector that measured
        # zero files because every configured root is absent must not report a green PASS,
        # and hardcoded_count staying None (rather than 0) keeps it out of the floor
        # comparison and the auto-tighten step below, so a wedged/renamed root can never
        # zero out the committed floor.
        failures.append(
            f"hardcoded: none of the configured source roots exist ({', '.join(src_roots)})"
        )
        report["hardcoded"] = {
            "count": None,
            "floor": baseline.get("hardcoded_floor"),
            "worst_files": [],
        }
    else:
        hardcoded_count, per_file = _detect_hardcoded()
        floor = baseline.get("hardcoded_floor")
        report["hardcoded"] = {
            "count": hardcoded_count,
            "floor": floor,
            "worst_files": sorted(per_file.items(), key=lambda kv: -kv[1])[:5],
        }
        if floor is None:
            if recording:
                err(f"i18n-check: no hardcoded floor recorded — seeding at {hardcoded_count}")
            else:
                # `recording` is false on a --only run without an existing baseline (seeding
                # requires a full run — see SEEDED_FIELDS above), so nothing gets written
                # here. Say so instead of claiming a seed that didn't happen.
                err(
                    f"i18n-check: no hardcoded floor recorded — {hardcoded_count} unbaselined, "
                    "not seeding on a --only run (run the full gate or pass --update)"
                )
        elif hardcoded_count > floor and not recording:
            failures.append(
                f"hardcoded: {hardcoded_count} user-facing literals not behind t() "
                f"(floor {floor}) — the ratchet only moves DOWN"
            )
            for path, count in sorted(per_file.items(), key=lambda kv: -kv[1])[:5]:
                err(f"    hardcoded {count:4d}  {path}")

# ── baseline write ─────────────────────────────────────────────────────
COMMENT = (
    "Generated by scripts/i18n-check.sh (#2394). parity_exceptions are the KNOWN key gaps "
    "awaiting #2397 and plural_violations the KNOWN-BAD plural groups awaiting #2401; both "
    "lists and hardcoded_floor only ever shrink on a normal run. Re-baseline with "
    "scripts/i18n-check.sh --update and say why in the PR."
)

if recording:
    new_baseline = dict(baseline)
    if want("parity"):
        new_baseline["parity_exceptions"] = sorted(set(current_parity))
    if want("plurals"):
        new_baseline["plural_violations"] = format_plural_baseline(plural_violations)
    if want("hardcoded") and hardcoded_count is not None:
        previous = baseline.get("hardcoded_floor")
        new_baseline["hardcoded_floor"] = (
            hardcoded_count if previous is None or update_flag else min(previous, hardcoded_count)
        )
    new_baseline["_comment"] = COMMENT
    with open(baseline_file, "w", encoding="utf-8") as fh:
        json.dump(new_baseline, fh, indent=2, sort_keys=True)
        fh.write("\n")
    err(f"i18n-check: baseline written to {baseline_file}")
elif not failures:
    # Auto-tighten when real work removes drift, so the gain is locked in without a manual
    # --update (same spirit as coverage.sh's ratchet). Every edit here makes the gate
    # STRICTER — entries are only ever dropped, the floor only ever lowered — so it can
    # never launder a regression into the baseline. Skipped when the run already failed,
    # so a red run never rewrites the ratchet it just tripped.
    tightened = []
    if want("parity"):
        shrunk = sorted(known_parity & set(current_parity))
        if len(shrunk) < len(known_parity):
            baseline["parity_exceptions"] = shrunk
            tightened.append(f"parity {len(known_parity)} → {len(shrunk)}")
    if want("plurals"):
        # Every surviving key's current missing-category set is a SUBSET of what's
        # baselined (guaranteed — a superset would already be in `failures` above), so
        # replacing the stored category list with the current, smaller one is always a
        # tightening. A fully-closed group (no longer in `plural_violations`) drops
        # entirely rather than lingering with an empty category list.
        known = parse_plural_baseline(baseline.get("plural_violations", []))
        shrunk = {key: plural_violations[key] for key in known if key in plural_violations}
        if shrunk != known:
            baseline["plural_violations"] = format_plural_baseline(shrunk)
            tightened.append(f"plurals {len(known)} → {len(shrunk)}")
    if want("hardcoded") and hardcoded_count is not None:
        floor = baseline.get("hardcoded_floor")
        if floor is not None and hardcoded_count < floor:
            baseline["hardcoded_floor"] = hardcoded_count
            tightened.append(f"hardcoded floor {floor} → {hardcoded_count}")
    if tightened:
        baseline["_comment"] = COMMENT
        with open(baseline_file, "w", encoding="utf-8") as fh:
            json.dump(baseline, fh, indent=2, sort_keys=True)
            fh.write("\n")
        err(f"i18n-check: ratchet tightened ({'; '.join(tightened)})")

for failure in failures:
    err(f"  FAIL {failure}")

print(json.dumps({
    "status": "fail" if failures else "pass",
    "failures": failures,
    "report": report,
}))
PYEOF
)"
PY_STATUS=$?

if [[ $PY_STATUS -ne 0 || -z "$REPORT_JSON" ]]; then
  echo "i18n-check: analysis failed (python3 exit $PY_STATUS)"
  exit 1
fi

if [[ -n "$JSON_OUT" ]]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  printf '%s\n' "$REPORT_JSON" > "$JSON_OUT"
fi

STATUS="$(printf '%s' "$REPORT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","fail"))' 2>/dev/null)"

if [[ "$STATUS" == "pass" ]]; then
  echo "i18n-check: PASS (catalog parity, plural ratchet, hardcoded ratchet)"
  exit 0
fi

echo "i18n-check: FAIL"
exit 1
