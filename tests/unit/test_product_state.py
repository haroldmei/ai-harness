"""The product build's state, ported off `jq` (#106).

The corpus in `tests/fixtures/product-state/` was produced by running the *shell* scripts —
`state-init.sh`, then three `state-set.sh` calls — and freezing the timestamps. Every assertion
about format here is against that recording, because the skills read these files with `jq` and
the format is an interface rather than an implementation detail.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ai_harness.kernel.clock import FrozenClock
from ai_harness.product.shards import PathError, Shard, parse, shard_for
from ai_harness.product.state import ProductState, StateError, assign, dumps

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures/product-state"


def _state(tmp_path: Path) -> ProductState:
    return ProductState(directory=tmp_path / "state", clock=FrozenClock())


def _frozen(text: str) -> str:
    import re

    return re.sub(r'"20[0-9-]*T[0-9:]*Z"', '"FROZEN"', text)


# ── routing ──────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        (".testing.gate_attempts", Shard.TESTING),
        ('.testing.gate_attempts."e2e"', Shard.TESTING),
        (".open_issues", Shard.FINDINGS),
        (".open_issues[0].title", Shard.FINDINGS),
        (".release_train.last_cut", Shard.RELEASE_TRAIN),
        (".axis", Shard.PRODUCT),
        (".kpi_targets.activation", Shard.PRODUCT),
        (".scale_tier", Shard.STATE),
        (".ml.feasibility.verdict", Shard.STATE),
    ],
)
def test_every_path_resolves_to_exactly_one_shard(path: str, expected: Shard):
    assert shard_for(path) is expected


def test_the_namespace_stays_at_its_original_key_path():
    """#1699's crucial invariant: only the FILE changes, never the path.

    `.testing.gate_attempts."e2e"` addresses the same place before and after sharding, which is
    what let call sites migrate one at a time.
    """
    segments = parse('.testing.gate_attempts."e2e"')
    assert [s.key for s in segments] == ["testing", "gate_attempts", "e2e"]


def test_a_path_is_parsed_not_executed():
    # The shell rejects these before they reach jq, because a jq path is an expression language
    # and this one comes from a caller.
    for hostile in (
        '.foo | .bar = "x"',
        ".foo; rm -rf /",
        ".foo $(whoami)",
        ".foo`id`",
        ".foo\nbar",
    ):
        with pytest.raises(PathError, match=r"unsafe|cannot parse"):
            parse(hostile)


def test_a_whole_document_write_is_refused():
    # `.` = replace the state rather than change a field in it.
    with pytest.raises(PathError, match=r"bare '\.'"):
        parse(".")


def test_a_path_must_start_with_a_concrete_field():
    with pytest.raises(PathError):
        parse("[0]")
    with pytest.raises(PathError):
        parse("foo")
    assert parse(".foo[0].bar")[1].index == 0


# ── the format is an interface ───────────────────────────────────────────────────


def test_init_reproduces_the_shell_byte_for_byte(tmp_path):
    state = _state(tmp_path)
    state.init("a test product")
    state.set(".scale_tier", "preview")
    state.set('.testing.gate_attempts."e2e"', 3)
    state.set(".axis", "speed")

    for name in ("state.json", "product.json", "testing.json", "findings.json", "signals.json"):
        produced = _frozen((state.directory / name).read_text())
        recorded = (FIXTURES / name).read_text()
        assert produced == recorded, f"{name} diverged from the shell's output"


def test_the_index_is_thinned_and_stamped(tmp_path):
    state = _state(tmp_path)
    index = state.init("x")

    # Sharded namespaces are lifted OUT of the index; a reader that still finds them there
    # cannot tell whether `.open_issues` being absent means "none" or "look in findings.json".
    for lifted in ("testing", "open_issues", "axis", "kpi_targets", "product_idea"):
        assert lifted not in index
    assert index["schema_version"] == 2
    assert index["pointers"]["findings"] == "state/findings.json"


def test_dumps_matches_jq_defaults():
    assert dumps({"a": 1}) == '{\n  "a": 1\n}\n'
    assert dumps({}) == "{}\n"
    # jq emits UTF-8 rather than escapes, and an escaped accent is a different byte sequence for
    # anything diffing the file.
    assert dumps({"k": "café"}) == '{\n  "k": "café"\n}\n'


# ── behaviour ────────────────────────────────────────────────────────────────────


def test_an_existing_value_survives_a_re_init(tmp_path):
    state = _state(tmp_path)
    state.init("first idea")
    state.set(".scale_tier", "scale")

    state.init("second idea")
    # Defaults fill what is missing; they never overwrite what a build already decided.
    assert state.get(".scale_tier") == "scale"


def test_migration_is_idempotent_and_an_existing_shard_wins(tmp_path):
    state = _state(tmp_path)
    state.init("x")
    state.set('.testing.gate_attempts."unit"', 7)

    state.migrate()
    state.migrate()
    # A stage that wrote after the first migration must not be clobbered by a second one
    # lifting a stale copy out of the index.
    assert state.get('.testing.gate_attempts."unit"') == 7


def test_set_creates_intermediates_the_way_jq_assignment_does(tmp_path):
    state = _state(tmp_path)
    state.init("x")
    state.set(".ml.feasibility.verdict", "go")
    assert state.get(".ml.feasibility.verdict") == "go"

    assert assign({}, parse(".a.b.c"), 1) == {"a": {"b": {"c": 1}}}
    # jq extends an array with nulls up to an assigned index.
    assert assign({}, parse(".xs[2]"), "z") == {"xs": [None, None, "z"]}


def test_a_write_before_init_is_refused_with_the_reason(tmp_path):
    with pytest.raises(StateError, match="init"):
        _state(tmp_path).set(".scale_tier", "toy")


def test_decide_writes_both_places_that_read_it(tmp_path):
    state = _state(tmp_path)
    state.init("x")
    line = state.decide("analyse", "ship the wedge", "the ICP is narrow enough")

    assert line.startswith("- [2026-01-01] analyse: ship the wedge — because")
    assert line in state.decisions_md.read_text()
    recorded = state.get(".decisions")
    assert recorded[-1] == {
        "date": "2026-01-01",
        "phase": "analyse",
        "decision": "ship the wedge",
        "reason": "the ICP is narrow enough",
    }


def test_show_merges_every_shard_without_writing(tmp_path):
    state = _state(tmp_path)
    state.init("x")
    state.set(".axis", "speed")
    state.set('.testing.gate_attempts."e2e"', 1)

    before = (state.directory / "state.json").read_text()
    merged = state.show()
    assert merged["axis"] == "speed"
    assert merged["testing"]["gate_attempts"]["e2e"] == 1
    assert merged["scale_tier"] == "launch"
    assert (state.directory / "state.json").read_text() == before


def test_concurrent_sets_do_not_lose_an_update(tmp_path):
    """`state-set.sh` takes a flock per shard for exactly this reason, and so does this.

    A set is a read-modify-write: `mv` makes the replacement atomic and does nothing about two
    callers racing between the read and the write.
    """
    import concurrent.futures

    state = _state(tmp_path)
    state.init("x")

    def write(index: int) -> None:
        ProductState(directory=state.directory, clock=FrozenClock()).set(
            f'.phase_status."phase{index}"', "done"
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(write, range(24)))

    recorded = json.loads((state.directory / "state.json").read_text())["phase_status"]
    assert len(recorded) == 24


def test_a_partial_write_is_never_observable(tmp_path):
    state = _state(tmp_path)
    state.init("x")
    original = (state.directory / "state.json").read_text()

    class Unserialisable:
        pass

    with pytest.raises(TypeError):
        state.set(".broken", Unserialisable())  # type: ignore[arg-type]

    assert (state.directory / "state.json").read_text() == original
    assert not list(state.directory.glob(".state.json.*"))  # no leaked temp file
