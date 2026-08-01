"""Anchored edits: a fifth of the tokens, the same whole-file semantics (#88)."""

from __future__ import annotations

import pytest
from hypothesis import given
from hypothesis import strategies as st

from ai_harness.agents.edits import (
    WHOLE_FILE_THRESHOLD_LINES,
    AnchoredEdit,
    EditError,
    apply_anchor,
    prefers_whole_file,
)

FILE = """\
import os


def handle(request):
    if request.method == "GET":
        return {"ok": True}
    return {"ok": False}


def other(request):
    return {"ok": False}
"""


def test_an_anchor_produces_the_whole_file_the_broker_will_be_given():
    edit = AnchoredEdit(
        path="app.py",
        anchor='    if request.method == "GET":\n        return {"ok": True}',
        replacement='    if request.method in ("GET", "HEAD"):\n        return {"ok": True}',
        intent="accept HEAD",
    )
    result = apply_anchor(FILE, edit)

    assert 'in ("GET", "HEAD")' in result.content
    assert result.content.startswith("import os")  # the rest of the file is untouched
    assert result.content.count("def ") == 2
    # The measurement that says this was worth doing: the model typed the anchor and the
    # replacement rather than the file, and the difference is what the GPU did not have to
    # generate at 30 tok/s.
    typed = len(edit.anchor) + len(edit.replacement)
    assert result.saved_characters == len(FILE) - typed
    assert typed < len(FILE)


def test_an_anchor_that_is_not_there_is_refused_with_what_was_tried():
    with pytest.raises(EditError) as raised:
        apply_anchor(FILE, AnchoredEdit(path="app.py", anchor="def missing():", replacement="x"))
    assert raised.value.occurrences == 0
    assert raised.value.path == "app.py"


def test_an_ambiguous_anchor_is_refused_rather_than_guessed():
    # 'return {"ok": False}' appears twice. Picking one would be an edit landing somewhere the
    # model did not mean -- the half-applied patch whole-file writes exist to prevent.
    with pytest.raises(EditError) as raised:
        apply_anchor(
            FILE, AnchoredEdit(path="app.py", anchor='    return {"ok": False}', replacement="")
        )
    assert raised.value.occurrences == 2
    assert "extend it until it is unique" in str(raised.value)


def test_a_whitespace_anchor_cannot_be_constructed():
    with pytest.raises(ValueError, match="matches everywhere"):
        AnchoredEdit(path="a.py", anchor="   \n  ", replacement="x")


def test_small_files_stay_whole_because_restating_them_is_cheaper():
    assert prefers_whole_file("line\n" * 10)
    assert prefers_whole_file("line\n" * (WHOLE_FILE_THRESHOLD_LINES - 1))
    assert not prefers_whole_file("line\n" * (WHOLE_FILE_THRESHOLD_LINES + 10))


@given(
    prefix=st.text(alphabet="abc\n ", max_size=50),
    anchor=st.text(alphabet="xyz", min_size=3, max_size=10),
    suffix=st.text(alphabet="def\n ", max_size=50),
    replacement=st.text(alphabet="pq\n", max_size=20),
)
def test_rematerialising_equals_what_a_whole_file_write_would_have_produced(
    prefix: str, anchor: str, suffix: str, replacement: str
):
    """The round-trip property: an anchored edit is a whole-file write, expressed shorter."""
    current = prefix + anchor + suffix
    if current.count(anchor) != 1:
        return  # ambiguity is refused, and that is asserted elsewhere

    result = apply_anchor(current, AnchoredEdit(path="f", anchor=anchor, replacement=replacement))
    assert result.content == prefix + replacement + suffix


async def test_the_broker_still_receives_whole_files(tmp_path):
    from ai_harness.agents.implementer import ImplementationOutput, Implementer
    from ai_harness.llm.client import LLMClient
    from ai_harness.llm.engines.scripted import ScriptedLLM
    from ai_harness.policies.engine import PolicyEngine
    from ai_harness.schemas.policy import Policy
    from ai_harness.tools.broker import ToolBroker
    from ai_harness.tools.registry import ToolRegistry

    (tmp_path / "app.py").write_text(FILE)

    seen: list[dict[str, object]] = []

    async def write(path: str, content: str):
        from ai_harness.kernel.outcome import Outcome

        seen.append({"path": path, "content": content})
        (tmp_path / path).write_text(content)
        return Outcome.ok(path)

    broker = ToolBroker(
        registry=ToolRegistry(), policy=PolicyEngine(Policy()), workspace=tmp_path
    ).handle("fs.write", write)
    implementer = Implementer(
        client=LLMClient(engine=ScriptedLLM()),
        model="qwen3-coder-30b",
        broker=broker,
        workspace=tmp_path,
    )

    output = ImplementationOutput(
        summary="accept HEAD",
        anchored_edits=[
            AnchoredEdit(
                path="app.py",
                anchor='        return {"ok": True}',
                replacement='        return {"ok": True, "head": True}',
            )
        ],
    )
    applied = await implementer._apply(output)

    assert applied.is_ok
    # One whole-file write, not a patch: containment, policy and the audit trail are unchanged.
    assert len(seen) == 1
    assert seen[0]["path"] == "app.py"
    assert str(seen[0]["content"]).startswith("import os")
    assert '"head": True' in str(seen[0]["content"])


async def test_a_bad_anchor_writes_nothing_at_all(tmp_path):
    from ai_harness.agents.implementer import ImplementationOutput, Implementer
    from ai_harness.kernel.outcome import ErrorCategory
    from ai_harness.llm.client import LLMClient
    from ai_harness.llm.engines.scripted import ScriptedLLM
    from ai_harness.policies.engine import PolicyEngine
    from ai_harness.schemas.policy import Policy
    from ai_harness.tools.broker import ToolBroker
    from ai_harness.tools.registry import ToolRegistry

    (tmp_path / "app.py").write_text(FILE)
    written: list[str] = []

    async def write(path: str, content: str):
        from ai_harness.kernel.outcome import Outcome

        written.append(path)
        return Outcome.ok(path)

    implementer = Implementer(
        client=LLMClient(engine=ScriptedLLM()),
        model="qwen3-coder-30b",
        broker=ToolBroker(
            registry=ToolRegistry(), policy=PolicyEngine(Policy()), workspace=tmp_path
        ).handle("fs.write", write),
        workspace=tmp_path,
    )

    outcome = await implementer._apply(
        ImplementationOutput(
            summary="two hunks, one of them wrong",
            anchored_edits=[
                AnchoredEdit(
                    path="app.py", anchor="import os", replacement="import os\nimport sys"
                ),
                AnchoredEdit(path="app.py", anchor="def nope():", replacement="x"),
            ],
        )
    )

    assert outcome.category is ErrorCategory.VALIDATION
    # All or nothing: two of three hunks applied is the tree nobody can reason about.
    assert written == []
    assert (tmp_path / "app.py").read_text() == FILE


def test_the_template_id_moved_because_the_contract_did():
    from ai_harness.agents.implementer import TEMPLATE_ID

    # Q13: a prompt change is a deployment, so the version a regression belongs to is nameable.
    assert TEMPLATE_ID == "implementer-v2"
    from ai_harness.agents.base import PROMPTS

    assert (PROMPTS / "implementer-v1.md").exists()  # the rollback stays on disk
    assert "anchored_edits" in (PROMPTS / "implementer-v2.md").read_text()
