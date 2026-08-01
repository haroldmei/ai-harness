"""The anti-weakening check (§19.5) — the one finding that is never negotiable.

*Removing a test to make a change pass is the single most damaging thing an autonomous agent
can do to a codebase, and it is indistinguishable from legitimate refactoring without a human
looking.* The reviewer prompt asks about it, but a prompt is a second line of defence: this runs
on **every** diff before ``REVIEW``, and any non-empty field parks the run for approval
**regardless of whether the gates are green**.

Detection is deliberately conservative in one direction only. A false positive costs a human
thirty seconds; a false negative ships a codebase with its tests quietly removed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from ai_harness.schemas.gates import GateIntegrityCheck

_TEST_FILE = re.compile(r"(^|/)(tests?/|test_|.*_test\.|.*\.test\.|.*\.spec\.)")

_TEST_DEF = re.compile(r"^\s*(?:async\s+)?def\s+(test_\w+)|^\s*(?:it|test)\s*\(\s*['\"]([^'\"]+)")
_SKIP_ADDED = re.compile(
    r"@(?:pytest\.mark\.)?(?:skip|skipif|xfail)\b"
    r"|\b(?:it|test|describe)\.(?:skip|todo)\b"
    r"|\bt\.Skip\(",
)
_ASSERT = re.compile(r"\bassert\b|\bexpect\s*\(|\brequire\.|\bassert\.\w+\(")

_LOOSENED = (
    (re.compile(r"fail[_-]under\s*[=:]\s*(\d+)"), "coverage floor"),
    (re.compile(r"--cov-fail-under[= ](\d+)"), "coverage floor"),
    (re.compile(r"strict\s*[=:]\s*false", re.I), "strict mode disabled"),
    (
        re.compile(r"(?:noqa|eslint-disable|type:\s*ignore|#\s*pragma:\s*no cover)"),
        "check suppressed",
    ),
    (re.compile(r"timeout\s*[=:]\s*(\d+)"), "timeout raised"),
    (re.compile(r"continue-on-error\s*:\s*true"), "CI failure ignored"),
)

_CI_PATHS = (".github/workflows/", ".gitlab-ci.yml", "azure-pipelines", "Jenkinsfile", ".circleci/")
_CONFIG_PATHS = (
    "pyproject.toml",
    "setup.cfg",
    "tox.ini",
    ".coveragerc",
    "package.json",
    "jest.config",
    "vitest.config",
    ".eslintrc",
    "eslint.config",
    "mypy.ini",
    ".ruff.toml",
    "ruff.toml",
)


@dataclass(frozen=True, slots=True)
class Hunk:
    """One file's changes, split into what left and what arrived."""

    path: str
    added: list[str]
    removed: list[str]

    @property
    def is_test(self) -> bool:
        return bool(_TEST_FILE.search(self.path))

    @property
    def is_ci(self) -> bool:
        return any(marker in self.path for marker in _CI_PATHS)

    @property
    def is_config(self) -> bool:
        return any(self.path.endswith(marker) or marker in self.path for marker in _CONFIG_PATHS)


def parse_diff(diff: str) -> list[Hunk]:
    """Split a unified diff into per-file added/removed lines."""
    hunks: list[Hunk] = []
    path = ""
    added: list[str] = []
    removed: list[str] = []

    def flush() -> None:
        if path:
            hunks.append(Hunk(path=path, added=list(added), removed=list(removed)))

    for line in diff.splitlines():
        if line.startswith("diff --git "):
            flush()
            parts = line.split(" b/")
            path = parts[-1].strip() if len(parts) > 1 else ""
            added, removed = [], []
        elif line.startswith("+++") or line.startswith("---"):
            continue
        elif line.startswith("+"):
            added.append(line[1:])
        elif line.startswith("-"):
            removed.append(line[1:])
    flush()
    return hunks


def check(diff: str) -> GateIntegrityCheck:
    """Run every detector over a diff. Any non-empty field is blocking."""
    deleted: list[str] = []
    skipped: list[str] = []
    weakened: list[str] = []
    loosened: list[str] = []
    ci_modified = False

    for hunk in parse_diff(diff):
        if hunk.is_ci and (hunk.added or hunk.removed):
            ci_modified = True

        if hunk.is_test:
            deleted += [
                f"{hunk.path}::{name}"
                for name in _test_names(hunk.removed) - _test_names(hunk.added)
            ]
            skipped += [
                f"{hunk.path}: {line.strip()[:80]}"
                for line in hunk.added
                if _SKIP_ADDED.search(line)
            ]
            added_assertions = sum(1 for line in hunk.added if _ASSERT.search(line))
            removed_assertions = sum(1 for line in hunk.removed if _ASSERT.search(line))
            if removed_assertions > added_assertions:
                weakened.append(
                    f"{hunk.path}: {removed_assertions - added_assertions} fewer assertion(s)"
                )

        if hunk.is_config or hunk.is_ci:
            loosened += _loosened(hunk)

    return GateIntegrityCheck(
        deleted_tests=sorted(set(deleted)),
        skipped_tests=sorted(set(skipped)),
        weakened_assertions=sorted(set(weakened)),
        loosened_config=sorted(set(loosened)),
        ci_modified=ci_modified,
    )


def _test_names(lines: list[str]) -> set[str]:
    names: set[str] = set()
    for line in lines:
        match = _TEST_DEF.search(line)
        if match:
            names.add(match.group(1) or match.group(2))
    return names


def _loosened(hunk: Hunk) -> list[str]:
    findings: list[str] = []
    for pattern, label in _LOOSENED:
        for line in hunk.added:
            match = pattern.search(line)
            if not match:
                continue
            if label in ("coverage floor", "timeout raised"):
                # A number changing is only a loosening if it moved the wrong way.
                previous = _previous_number(pattern, hunk.removed)
                current = _number(match)
                if previous is None or current is None:
                    continue
                worse = current < previous if label == "coverage floor" else current > previous
                if not worse:
                    continue
                findings.append(f"{hunk.path}: {label} {previous} → {current}")
            else:
                findings.append(f"{hunk.path}: {label} ({line.strip()[:60]})")
    return findings


def _previous_number(pattern: re.Pattern[str], removed: list[str]) -> int | None:
    for line in removed:
        match = pattern.search(line)
        if match:
            return _number(match)
    return None


def _number(match: re.Match[str]) -> int | None:
    for group in match.groups():
        if group and group.isdigit():
            return int(group)
    return None
