"""Issue #5 — ids, fingerprints and redaction."""

from __future__ import annotations

import subprocess
from pathlib import Path

from ai_harness.kernel.fingerprint import cluster_signature, fingerprint, normalise
from ai_harness.kernel.ids import artefact_id, idempotency_key, new_run_id, repo_key, repo_key_for
from ai_harness.kernel.redaction import MASK, Redactor, redact


def test_repo_key_is_stable_and_path_resolved(tmp_path: Path) -> None:
    a = tmp_path / "checkout" / ".git"
    a.mkdir(parents=True)
    link = tmp_path / "link"
    link.symlink_to(tmp_path / "checkout")
    assert repo_key(a) == repo_key(link / ".git")
    assert len(repo_key(a)) == 12


def test_two_checkouts_do_not_share_a_namespace(tmp_path: Path) -> None:
    (tmp_path / "one" / ".git").mkdir(parents=True)
    (tmp_path / "two" / ".git").mkdir(parents=True)
    assert repo_key(tmp_path / "one" / ".git") != repo_key(tmp_path / "two" / ".git")


def test_repo_key_for_a_real_repository(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    key = repo_key_for(tmp_path)
    assert key is not None and len(key) == 12
    assert repo_key_for(tmp_path.parent) != key or repo_key_for(tmp_path.parent) is None


def test_idempotency_keys_ignore_argument_order_and_empties() -> None:
    assert idempotency_key("review", run="r1", round=2) == idempotency_key(
        "review", round=2, run="r1"
    )
    assert idempotency_key("review", run="r1", round=None) == "review:run=r1"


def test_run_and_artefact_ids() -> None:
    assert len(new_run_id()) == 32
    assert artefact_id("diff", b"abc") == artefact_id("diff", b"abc")
    assert artefact_id("diff", b"abc") != artefact_id("diff", b"abd")


def test_fingerprint_survives_paths_times_and_worker_ids() -> None:
    a = "/tmp/agent-inbox-abc/worktrees/issue-3/backend/app/svc.py:118: AssertionError at 12:01:02"
    b = "/tmp/agent-inbox-zzz/worktrees/issue-9/backend/app/svc.py:204: AssertionError at 23:44:10"
    fa, fb = fingerprint(a, scope="unit"), fingerprint(b, scope="unit")
    assert fa is not None and fb is not None
    assert fa.signature == fb.signature


def test_fingerprint_distinguishes_unrelated_failures() -> None:
    fa = fingerprint("AssertionError: expected 200 got 500", scope="unit")
    fb = fingerprint("ImportError: cannot import name 'Widget'", scope="unit")
    assert fa is not None and fb is not None and fa.signature != fb.signature


def test_degenerate_signatures_are_refused() -> None:
    """A signature with no distinguishing content would match everything and exhaust its cap."""
    assert fingerprint("", scope="unit") is None
    assert fingerprint("   ", scope="unit") is None
    assert fingerprint("12:01:02", scope="unit") is None
    assert fingerprint("/tmp/x/y.log", scope="unit") is None


def test_cluster_signature_collapses_subsets_of_one_breakage() -> None:
    """#2381→#2385: each lane saw a different subset, so per-failure ids never matched."""
    assert cluster_signature("unit", ["a::t1", "a::t2"]) == cluster_signature(
        "unit", ["a::t2", "a::t1"]
    )
    assert cluster_signature("unit", ["a::t1"]) != cluster_signature("unit", ["a::t1", "a::t2"])


def test_normalise_is_idempotent() -> None:
    once = normalise("FAILED /srv/app/x.py:12:4 in 3.2s")
    assert normalise(once) == once


def test_redaction_masks_token_shapes() -> None:
    text = "using ghp_" + "A" * 36 + " and Bearer abcdefghijklmnop"
    out = redact(text)
    assert "ghp_" not in out and "abcdefghijklmnop" not in out and MASK in out


def test_redaction_masks_known_values_that_match_no_shape() -> None:
    r = Redactor(["hunter2-not-a-recognisable-shape"])
    assert "hunter2" not in r.text("password is hunter2-not-a-recognisable-shape")


def test_redaction_masks_structures_by_key() -> None:
    r = Redactor()
    out = r.value({"api_key": "x" * 40, "nested": {"note": "AKIA" + "B" * 16}})
    assert out["api_key"] == MASK
    assert MASK in out["nested"]["note"]


def test_redaction_masks_urls_with_inline_credentials() -> None:
    assert "s3cret" not in redact("postgres://user:s3cret@db:5432/app")
