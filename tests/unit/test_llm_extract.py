"""Issue #9 — the extraction ladder. Every rung must parse."""

from __future__ import annotations

from ai_harness.llm.extract import Rung, extract_json, extract_object


def test_raw_json_is_the_first_rung() -> None:
    result = extract_json('{"verdict": "approve"}')
    assert result.rung is Rung.RAW and result.value == {"verdict": "approve"}


def test_fenced_json_is_unwrapped() -> None:
    result = extract_object('```json\n{"verdict": "approve"}\n```')
    assert result.rung is Rung.FENCED and result.value["verdict"] == "approve"


def test_prose_wrapped_json_is_recovered_by_the_bracket_scan() -> None:
    text = 'Here is my review:\n{"verdict": "request_changes"}\nHope that helps!'
    result = extract_object(text)
    assert result.rung is Rung.BRACKET_SCAN
    assert result.value["verdict"] == "request_changes"


def test_a_lone_brace_is_not_an_answer() -> None:
    """#2419: a sed range returned '{'. Non-empty, so the raw fallback never ran."""
    result = extract_object("{")
    assert not result.found and result.value is None


def test_truncated_json_is_not_an_answer() -> None:
    assert not extract_object('{"verdict": "appr').found


def test_braces_inside_strings_do_not_close_the_object() -> None:
    text = 'noise {"summary": "use {} sparingly, prefer [] here", "verdict": "comment"} noise'
    result = extract_object(text)
    assert result.found
    assert result.value["summary"] == "use {} sparingly, prefer [] here"


def test_escaped_quotes_survive_the_scan() -> None:
    text = 'blah {"summary": "he said \\"no\\"", "verdict": "comment"} blah'
    assert extract_object(text).value["summary"] == 'he said "no"'


def test_the_longest_balanced_candidate_wins() -> None:
    text = 'prefix {"outer": {"inner": 1}, "verdict": "comment"} suffix'
    assert extract_object(text).value["outer"] == {"inner": 1}


def test_a_bare_scalar_is_not_an_object() -> None:
    """Accepting 42 because it parses is the same class of bug as accepting '{'."""
    assert extract_json("42").found
    assert not extract_object("42").found


def test_a_list_is_rejected_when_an_object_is_required() -> None:
    assert not extract_object("[1, 2, 3]").found


def test_pretty_printed_bare_object() -> None:
    assert extract_object('{\n  "verdict": "approve",\n  "summary": "fine"\n}').found


def test_nothing_parseable_reports_how_many_candidates_were_tried() -> None:
    result = extract_object("no json here at all")
    assert not result.found and result.candidates_tried >= 1
