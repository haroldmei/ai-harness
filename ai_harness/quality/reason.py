"""Why did this gate fail — the diagnostic line, never ``tail -n1``.

Invariant 17. ``lib/gate-reason.sh`` was extracted after three divergent implementations, one
of which was ``tail -n1``. That one reported a *passing* line as the reason a gate failed:

    unit  fail  see …/unit.log —  ✓ release-train guards

and that string is not cosmetic — it lands in escalation issue bodies, in PR comments, and in
the brief handed to the auto-fixer, so the fixer was being told to fix a passing check.

The regexes below are transcribed **verbatim** from the shell library, including the split
into STRONG and BROAD sets and the structured-log noise filter. The split exists because the
broad set is deliberately generous (``Error:``, ``Traceback``, ``AssertionError``) which is
right for an excerpt and wrong for picking a headline: a *passing* backend test emitted one
line of structured stderr containing ``Traceback``, thousands of lines before the real
failure, and that became the reported reason.

The ordering is: noise filter → strong → broad → tail. Every tier is noise-filtered.
"""

from __future__ import annotations

import re

GATE_FAILURE_LINE_RE = re.compile(
    r"^E[ \t]+|^(FAILED|ERROR)[ \t]|^[ \t]*(FAILED|ERROR)[ \t]|error(\[[A-Za-z0-9-]+\])?:|Error:"
    r"|Traceback \(most recent call last\)|AssertionError|^\s*✗"
    r"|^[^:]+:[0-9]+:[0-9]+: [a-zA-Z]+[0-9]+|^[^:]+:[0-9]+: error:"
    r"|genuine Docker starvation|never became usable after|Cannot connect to the Docker daemon"
    r"|no space left on device|Connection refused.*5432|ReaperException"
    r"|Resource temporarily unavailable|Cannot allocate memory",
    re.MULTILINE,
)

GATE_FAILURE_STRONG_RE = re.compile(
    r"^[ \t]*✗|^E[ \t]+|^[ \t]*(FAILED|ERROR)[ \t]|AssertionError"
    r"|^[^:]+:[0-9]+:[0-9]+: [a-zA-Z]+[0-9]+|^[^:]+:[0-9]+: error:"
    r"|genuine Docker starvation|never became usable after|Cannot connect to the Docker daemon"
    r"|no space left on device|Connection refused.*5432|ReaperException"
    r"|Resource temporarily unavailable|Cannot allocate memory",
    re.MULTILINE,
)

GATE_REASON_NOISE_RE = re.compile(r'"level"\s*:\s*"(warning|info|debug)"')
"""A runner that logs JSON puts its severity in the record. ``error`` records may BE the failure."""

_ENVIRONMENT_RE = re.compile(
    r"genuine Docker starvation|Cannot connect to the Docker daemon|no space left on device"
    r"|Resource temporarily unavailable|Cannot allocate memory|ReaperException"
    r"|never became usable after|Connection refused.*5432",
    re.IGNORECASE,
)

NO_DIAGNOSTIC = "no diagnostic line in log"
"""A distinct, reportable outcome: better than confidently reporting the wrong line."""


def _clean(text: str) -> list[str]:
    return [line for line in text.splitlines() if not GATE_REASON_NOISE_RE.search(line)]


def _dedup(lines: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if line not in seen:
            seen.add(line)
            out.append(line)
    return out


def reason_lines(text: str, max_lines: int = 40) -> list[str]:
    """The diagnostic excerpt: strong matches, else broad matches, else a blind tail."""
    cleaned = _clean(text)
    strong = _dedup([line for line in cleaned if GATE_FAILURE_STRONG_RE.search(line)])
    if strong:
        return strong[:max_lines]
    broad = _dedup([line for line in cleaned if GATE_FAILURE_LINE_RE.search(line)])
    if broad:
        return broad[:max_lines]
    return cleaned[-max_lines:]


def reason_summary(text: str) -> str:
    """One line, for a summary table or a ``<gate>:<status>:<reason>`` record.

    Colons are stripped for the same reason the shell strips them: the record is
    colon-delimited and a colon in the reason shifts every field after it.
    """
    lines = reason_lines(text, max_lines=1)
    if not lines:
        return NO_DIAGNOSTIC
    line = lines[0].split("\n")[0].replace(":", " ").replace("\r", "")
    line = re.sub(r"\s+", " ", line).strip()
    return line or NO_DIAGNOSTIC


def looks_environmental(text: str) -> bool:
    """Invariant 10: *"the tooling could not run" is a third outcome*.

    Used by triage to keep an unavailable Docker daemon or a full disk from being reported as
    a code defect — which is how a merge queue once wedged accusing an innocent ``main``.
    """
    return bool(_ENVIRONMENT_RE.search(text))


# ── failing-test extraction, per runner ──────────────────────────────────────────
#
# W6: ~40 ad-hoc regexes parse runner output across the shell harness, and a misparse burns
# the fix budget on an innocent test (#2124 spent every retry on a test passing 15/15 on main).
# Here each runner is a small, independently testable extractor, and an unrecognised runner
# returns *nothing* rather than a wrong answer.

_PYTEST_ID = re.compile(r"^(?:FAILED|ERROR)\s+(\S+?::\S+?)(?:\s|$)", re.MULTILINE)
_PYTEST_SHORT = re.compile(r"^_{5,}\s+(\S+)\s+_{5,}$", re.MULTILINE)
# The ×, ✗, ● and › characters below are literally what these runners emit; ruff's
# ambiguous-character rule is suppressed rather than "corrected", since correcting them
# would stop the patterns matching anything at all.
_VITEST_ID = re.compile(
    r"^\s*(?:×|✗|FAIL)\s+(\S+\.[jt]sx?)\s*[>›]\s*(.+?)(?:\s+\d+ms)?$",  # noqa: RUF001
    re.MULTILINE,
)
_JEST_ID = re.compile(r"^\s*●\s+(.+?)\s*$", re.MULTILINE)
_PLAYWRIGHT_ID = re.compile(
    r"^\s*\d+\)\s+(\S+\.spec\.[jt]s):\d+:\d+\s+›\s+(.+?)\s*$",  # noqa: RUF001
    re.MULTILINE,
)
_GO_ID = re.compile(r"^--- FAIL: (\S+)", re.MULTILINE)


def failing_test_ids(text: str) -> list[str]:
    """Normalised ids of the tests that failed, across the runners this harness sees.

    The ids feed the baseline (§19.4), so stability matters more than prettiness: the same
    failure must produce the same id on another host, in another worktree, on another day.
    """
    ids: list[str] = []
    ids += _PYTEST_ID.findall(text)
    ids += _PYTEST_SHORT.findall(text)
    ids += [f"{file}::{name.strip()}" for file, name in _VITEST_ID.findall(text)]
    ids += [f"{file}::{name.strip()}" for file, name in _PLAYWRIGHT_ID.findall(text)]
    ids += [m.strip() for m in _JEST_ID.findall(text)]
    ids += _GO_ID.findall(text)
    return _dedup([normalise_test_id(i) for i in ids if i.strip()])


def normalise_test_id(test_id: str) -> str:
    """Strip host-specific prefixes and parameterisation noise, keep the identity."""
    cleaned = test_id.strip()
    cleaned = re.sub(r"^(?:\./|/[\w./-]*?/)(?=[\w-]+/)", "", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned)
    return cleaned
