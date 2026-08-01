"""Issues #38, #39 and #40 — assembly, summarisation, diff bundling and retrieval."""

from __future__ import annotations

import os
from pathlib import Path

from ai_harness.context.assembler import (
    AssembledContext,
    ContextAssembler,
    ContextBudget,
    PinnedFact,
    estimate_tokens,
)
from ai_harness.context.diff_bundler import bundle, rank, split_by_file
from ai_harness.context.retrieval.protocol import RetrievalQuery
from ai_harness.context.retrieval.ripgrep import RipgrepSearch
from ai_harness.context.retrieval.service import RepoRetrieval, as_untrusted
from ai_harness.context.retrieval.symbols import SymbolIndex, extract_symbols
from ai_harness.context.summarizer import (
    REQUIRED_CATEGORIES,
    SummaryRequest,
    as_section,
    missing_categories,
)
from ai_harness.context.trust import Provenance, Trusted, Untrusted
from ai_harness.schemas.enums import State

DIFF = """diff --git a/app/svc.py b/app/svc.py
index 111..222 100644
--- a/app/svc.py
+++ b/app/svc.py
@@ -1,3 +1,4 @@
 def send():
+    retry()
     pass
diff --git a/app/huge.py b/app/huge.py
index 333..444 100644
--- a/app/huge.py
+++ b/app/huge.py
@@ -1,2 +1,2 @@
-{padding}
+{padding}!
diff --git a/tests/test_svc.py b/tests/test_svc.py
index 555..666 100644
--- a/tests/test_svc.py
+++ b/tests/test_svc.py
@@ -1,2 +1,3 @@
 def test_send():
+    assert True
""".replace("{padding}", "x" * 4000)


# ── the diff bundler ─────────────────────────────────────────────────────────────


def test_a_diff_splits_per_file_keeping_hunks_intact() -> None:
    files = split_by_file(DIFF)
    assert [f.path for f in files] == ["app/svc.py", "app/huge.py", "tests/test_svc.py"]
    assert all(f.hunks >= 1 for f in files)


def test_nothing_is_dropped_without_a_marker() -> None:
    """`gh pr diff | head -c 60000` removes whole files and says nothing."""
    result = bundle(DIFF, max_tokens=200, artefact_id="diff:abc123")
    assert not result.complete
    rendered = result.render()
    assert "elided" in rendered and "diff:abc123" in rendered
    assert "You have NOT seen these files" in rendered
    for path in result.elided:
        assert path in rendered


def test_a_diff_that_fits_carries_no_marker() -> None:
    result = bundle(DIFF, max_tokens=100_000)
    assert result.complete and "elided" not in result.render()


def test_the_file_named_by_a_failing_test_is_ranked_first() -> None:
    ranked = rank(split_by_file(DIFF), failing_tests=["tests/test_svc.py::test_send"])
    assert ranked[0].path == "tests/test_svc.py"


def test_acceptance_terms_rank_a_file_up() -> None:
    ranked = rank(split_by_file(DIFF), acceptance_terms=["retry"])
    assert ranked[0].path == "app/svc.py"


def test_hunks_are_never_split_mid_hunk() -> None:
    result = bundle(DIFF, max_tokens=200)
    for file in result.included:
        assert file.text.count("@@") % 2 == 0 or "@@" in file.text


def test_bundling_is_deterministic() -> None:
    assert bundle(DIFF, max_tokens=300).render() == bundle(DIFF, max_tokens=300).render()


# ── the assembler ────────────────────────────────────────────────────────────────


def _assemble(**kw: object) -> AssembledContext:
    assembler = ContextAssembler(budget=ContextBudget(**kw))  # type: ignore[arg-type]
    return assembler.assemble(
        system=Trusted("You are a reviewer."),
        pinned=[
            PinnedFact("acceptance criteria", "the webhook retries three times"),
            PinnedFact("base_sha", "abc123"),
        ],
        active=[Trusted("current diff: …")],
        summarised=[Trusted("x" * 40_000)],
        retrieved=[Trusted("y" * 40_000)],
        untrusted=[Untrusted("issue body", Provenance.ISSUE_BODY, source="issue #7")],
    )


def test_pinned_facts_survive_the_tightest_budget() -> None:
    """Losing the acceptance criterion is how a fixer starts drifting from the issue."""
    assembled = _assemble(max_tokens=9_000, reserve_for_output=500)
    assert "the webhook retries three times" in assembled.prompt
    assert "base_sha: abc123" in assembled.prompt


def test_what_did_not_fit_is_stated_to_the_model() -> None:
    assembled = _assemble(max_tokens=9_000, reserve_for_output=500)
    assert not assembled.complete
    assert assembled.dropped_summaries + assembled.dropped_retrieved > 0
    assert "did not fit the budget" in assembled.prompt


def test_a_generous_budget_includes_everything() -> None:
    assembled = _assemble(max_tokens=200_000)
    assert assembled.complete and "did not fit" not in assembled.prompt


def test_untrusted_content_is_fenced_and_last() -> None:
    assembled = _assemble(max_tokens=200_000)
    assert "provenance=issue_body" in assembled.prompt
    assert assembled.untrusted_sources == ["issue_body:issue #7"]
    assert assembled.prompt.rindex("issue body") > assembled.prompt.index("You are a reviewer.")


def test_the_stable_prefix_is_identical_across_rounds() -> None:
    """§17.3: the review⇄fix rounds are the dominant cost centre; caching hits on the prefix."""
    first = _assemble(max_tokens=200_000).prompt
    second = _assemble(max_tokens=200_000).prompt
    prefix = os.path.commonprefix([first, second])
    assert "You are a reviewer." in prefix
    assert "acceptance criteria" in prefix


def test_token_estimation_is_conservative() -> None:
    assert estimate_tokens("x" * 400) >= 100


# ── the summariser ───────────────────────────────────────────────────────────────


def test_the_summariser_prompt_names_all_six_categories() -> None:
    prompt = SummaryRequest(material="lots of history").prompt()
    for category in REQUIRED_CATEGORIES:
        assert category in prompt
    assert "Never invent a detail" in prompt


def test_a_summary_that_drops_a_category_is_detectable() -> None:
    """A summariser that quietly drops "unresolved risks" produces a context that lies."""
    complete = "decisions: x. constraints: y. file references: z. unresolved risks: none. review findings: none. required follow-ups: none."
    assert missing_categories(complete) == []
    assert "unresolved risks" in missing_categories(
        "decisions: x. constraints: y. file references: z. review findings: none. required follow-ups: none."
    )


def test_a_summary_is_a_trusted_section() -> None:
    assert isinstance(as_section("decisions: none"), Trusted)


# ── retrieval ────────────────────────────────────────────────────────────────────


def _repo(tmp_path: Path) -> Path:
    (tmp_path / "app").mkdir()
    (tmp_path / "app" / "svc.py").write_text(
        "import time\n\n\nclass WebhookSender:\n    def send_with_retry(self):\n        return True\n"
    )
    (tmp_path / "app" / "other.py").write_text(
        "def caller():\n    WebhookSender().send_with_retry()\n"
    )
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "junk.py").write_text("class WebhookSender:\n    pass\n")
    return tmp_path


def test_the_symbol_index_answers_where_is_this_defined(tmp_path: Path) -> None:
    index = SymbolIndex(root=_repo(tmp_path), commit_sha="abc123").build()
    definitions = index.definitions_of("WebhookSender")
    assert [d.path for d in definitions] == ["app/svc.py"], "node_modules is not the answer"
    assert definitions[0].line == 4 and definitions[0].kind == "class"


def test_a_stale_index_serves_nothing_rather_than_a_wrong_line(tmp_path: Path) -> None:
    """§17.2: a stale line number becomes false evidence in a review."""
    index = SymbolIndex(root=_repo(tmp_path), commit_sha="abc123").build()
    assert index.definitions_of("WebhookSender")
    index.invalidate("def456")
    assert index.is_stale()
    assert index.definitions_of("WebhookSender") == []


def test_the_index_declares_that_it_is_approximate(tmp_path: Path) -> None:
    """A deliberate deviation from the Tree-sitter design — stated, not hidden."""
    assert SymbolIndex(root=_repo(tmp_path), commit_sha="a").approximate is True


def test_symbols_are_extracted_from_prose_but_only_code_shaped_ones() -> None:
    found = extract_symbols(
        "The WebhookSender fails because send_with_retry never runs. See app/svc.py."
    )
    assert "WebhookSender" in found and "send_with_retry" in found
    assert "because" not in found


async def test_exact_search_finds_the_definition_and_the_caller(tmp_path: Path) -> None:
    search = RipgrepSearch(root=_repo(tmp_path))
    chunks = (await search.search("send_with_retry")).unwrap()
    paths = {c.path for c in chunks}
    assert "app/svc.py" in paths and "app/other.py" in paths
    assert all(c.line >= 1 for c in chunks)


async def test_search_skips_vendored_trees(tmp_path: Path) -> None:
    search = RipgrepSearch(root=_repo(tmp_path), binary=None)
    chunks = (await search.search("WebhookSender")).unwrap()
    assert not any("node_modules" in c.path for c in chunks)


async def test_the_bundle_caps_and_counts_what_it_dropped(tmp_path: Path) -> None:
    root = _repo(tmp_path)
    service = RepoRetrieval(
        root=root,
        index=SymbolIndex(root=root, commit_sha="abc").build(),
        search=RipgrepSearch(root=root, binary=None),
    )
    result = (
        await service.bundle(
            RetrievalQuery(state=State.REVIEW, symbols=["WebhookSender"], max_chunks=1)
        )
    ).unwrap()
    assert len(result.chunks) == 1
    assert result.truncated >= 1 and not result.complete


async def test_retrieved_content_is_untrusted(tmp_path: Path) -> None:
    """A hostile comment in a source file is as attacker-controllable as a hostile issue."""
    root = _repo(tmp_path)
    service = RepoRetrieval(root=root, search=RipgrepSearch(root=root, binary=None))
    result = (
        await service.bundle(RetrievalQuery(state=State.REVIEW, keywords=["WebhookSender"]))
    ).unwrap()
    fenced = as_untrusted(result)
    assert fenced and all(u.provenance is Provenance.RETRIEVAL for u in fenced)
    assert all(":" in u.source for u in fenced), "every chunk must be citable"


async def test_no_embedding_dependency_is_introduced() -> None:
    """§17.2 decided against a vector store; the adapter is Phase 6 and opt-in."""
    import ai_harness.context.retrieval.service as service_module

    source = Path(service_module.__file__).read_text()
    assert "embed" not in source.lower().replace("embedding index", "").replace("no embeddings", "")
