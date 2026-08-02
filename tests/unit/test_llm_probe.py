"""Capabilities are measured, not declared (#83)."""

from __future__ import annotations

import json

import httpx

from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.llm.serving.probe import ProbeCache, ProbeResult, check_window, probe

BASE = "http://127.0.0.1:8000/v1"


class Server:
    """A vLLM-shaped server with switchable support for each capability."""

    def __init__(
        self,
        *,
        guided: bool = True,
        honours_schema: bool = True,
        tokenizer: bool = True,
        window: int | None = 65536,
    ) -> None:
        self.guided = guided
        self.honours_schema = honours_schema
        self.tokenizer = tokenizer
        self.window = window
        self.generations = 0

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self.handle))

    def handle(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.endswith("/models"):
            card: dict[str, object] = {"id": "qwen3-coder-30b", "revision": "a" * 40}
            if self.window is not None:
                card["max_model_len"] = self.window
            return httpx.Response(200, json={"data": [card]})
        if path.endswith("/tokenize"):
            if not self.tokenizer:
                return httpx.Response(404, json={"error": "not found"})
            return httpx.Response(200, json={"count": 2, "tokens": [1, 2]})

        self.generations += 1
        body = json.loads(request.content)
        if "response_format" in body and not self.guided:
            return httpx.Response(400, json={"message": "response_format is not supported"})
        text = '{"ok": true}' if self.honours_schema else "Sure! Here is the JSON you wanted."
        return httpx.Response(
            200, json={"choices": [{"message": {"content": text}, "finish_reason": "stop"}]}
        )


async def test_a_capable_server_is_believed_only_after_it_demonstrates_the_capability():
    server = Server()
    async with server.client() as client:
        result = (await probe(base_url=BASE, model="qwen3-coder-30b", client=client)).unwrap()

    assert result.guided_decoding is True
    assert result.capabilities().native_structured_output is True
    assert result.max_model_len == 65536
    assert result.tokenizer_available is True
    # At most one generating call per model per revision.
    assert server.generations == 1


async def test_an_absent_capability_degrades_loudly_and_names_the_flag():
    server = Server(guided=False)
    async with server.client() as client:
        result = (await probe(base_url=BASE, model="qwen3-coder-30b", client=client)).unwrap()

    assert result.guided_decoding is False
    assert result.capabilities().native_structured_output is False
    # The extraction ladder still works; the operator is told what would make it unnecessary.
    assert any("--guided-decoding-backend" in note for note in result.notes)


async def test_a_schema_accepted_and_ignored_counts_as_absent():
    server = Server(honours_schema=False)
    async with server.client() as client:
        result = (await probe(base_url=BASE, model="qwen3-coder-30b", client=client)).unwrap()

    assert result.guided_decoding is False
    assert any("accepted and ignored" in note or "did not honour" in note for note in result.notes)


async def test_a_missing_tokenizer_endpoint_is_named_because_counting_depends_on_it():
    server = Server(tokenizer=False)
    async with server.client() as client:
        result = (await probe(base_url=BASE, model="qwen3-coder-30b", client=client)).unwrap()

    assert result.tokenizer_available is False
    assert any("characters/4" in note for note in result.notes)


async def test_an_unreachable_server_is_an_environment_failure_at_startup():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        outcome = await probe(base_url=BASE, model="qwen3-coder-30b", client=client)

    assert outcome.category is ErrorCategory.ENVIRONMENT


def test_prefix_caching_is_observed_rather_than_asserted():
    result = ProbeResult(model="m", base_url=BASE)
    assert result.prefix_caching is None  # not yet observed is not the same as absent
    assert result.capabilities().prompt_caching is False

    result.observe(cache_read_tokens=0)
    assert result.prefix_caching is None
    result.observe(cache_read_tokens=7800)
    assert result.prefix_caching is True
    assert result.capabilities().prompt_caching is True


def test_a_smaller_served_window_than_planned_fails_with_both_numbers():
    result = ProbeResult(model="m", base_url=BASE, max_model_len=8192)
    outcome = check_window(result, required=65536)
    assert outcome.is_err
    error = outcome.error
    assert error is not None
    assert error.details == {"served": 8192, "required": 65536}

    assert check_window(
        ProbeResult(model="m", base_url=BASE, max_model_len=65536), required=65536
    ).is_ok
    # A server that will not say is not a server that agrees.
    assert check_window(ProbeResult(model="m", base_url=BASE), required=1024).is_err


def test_the_cache_is_keyed_on_the_revision_so_new_weights_are_a_new_answer(tmp_path):
    cache = ProbeCache(tmp_path / "probe-cache.json")
    cache.store(ProbeResult(model="m", base_url=BASE, revision="a" * 40, guided_decoding=True))

    hit = cache.load(base_url=BASE, model="m", revision="a" * 40)
    assert hit is not None and hit.guided_decoding is True
    assert cache.load(base_url=BASE, model="m", revision="b" * 40) is None
    assert cache.load(base_url="http://elsewhere/v1", model="m", revision="a" * 40) is None


def test_an_unwritable_cache_is_a_slower_startup_not_a_failed_one(tmp_path):
    blocker = tmp_path / "file.json"
    blocker.write_text("i am a file, not a directory")
    unwritable = blocker / "nested.json"
    ProbeCache(unwritable).store(ProbeResult(model="m", base_url=BASE))  # must not raise
    assert ProbeCache(unwritable).load(base_url=BASE, model="m", revision="") is None


def test_the_engine_takes_its_capabilities_from_the_cached_probe(tmp_path):
    from pathlib import Path

    from ai_harness.config import HarnessConfig
    from ai_harness.llm.serving.models import load_registry
    from ai_harness.wiring import build_local_engine, probe_cache_path

    root = Path(__file__).resolve().parents[2]
    config = HarnessConfig(repo_path=root, state_dir=tmp_path)
    config.roster.implementer_model = "qwen3-coder-30b"

    unprobed = build_local_engine(config)
    assert unprobed.capabilities.native_structured_output is False

    # The pin comes from the committed registry rather than a literal: the cache is keyed on
    # (server, model, **revision**) precisely so that new weights get a new answer, and a test
    # that hard-codes a digest stops testing that the moment the pin moves — which is the one
    # event the keying exists for.
    pinned = load_registry(root=root).get("qwen3-coder-30b").revision

    ProbeCache(probe_cache_path(config)).store(
        ProbeResult(
            model="qwen3-coder-30b",
            base_url="http://127.0.0.1:8000/v1",
            revision=pinned,
            guided_decoding=True,
            prefix_caching=True,
            max_model_len=32768,
        )
    )
    probed = build_local_engine(config)
    assert probed.capabilities.native_structured_output is True
    assert probed.capabilities.prompt_caching is True
    # The smaller of what was planned and what is actually served wins.
    assert probed.max_model_len == 32768
