"""The serving registry, its arithmetic, and the health contract (#81)."""

from __future__ import annotations

import httpx
import pytest

from ai_harness.deploy.units import render_serving, resolve_binary, serving_unit_name
from ai_harness.kernel.outcome import ErrorCategory
from ai_harness.llm.serving.bench import BenchPoint, BenchResult
from ai_harness.llm.serving.health import HealthClient
from ai_harness.llm.serving.models import (
    GpuSpec,
    ModelRegistry,
    ModelSpec,
    RegistryError,
    check_revision,
    load_registry,
)

GPU = GpuSpec(name="RTX 4090", vram_gb=24.0, reserve_gb=1.0)

QWEN = ModelSpec(
    name="qwen3-coder-30b",
    repo_id="Qwen/Qwen3-Coder-30B-A3B-Instruct-AWQ",
    revision="a" * 40,
    weights_gb=17.5,
    kv_bytes_per_token=49152,
    native_max_model_len=262144,
    cap_max_model_len=65536,
    port=8000,
    roles=("implementer",),
)

DEVSTRAL = ModelSpec(
    name="devstral-24b",
    repo_id="mistralai/Devstral-Small-2507-AWQ",
    revision="b" * 40,
    weights_gb=14.0,
    kv_bytes_per_token=81920,
    native_max_model_len=131072,
    cap_max_model_len=32768,
    port=8001,
    roles=("reviewer",),
)


def test_the_window_comes_from_the_cache_the_model_and_the_operator():
    plan = QWEN.plan(GPU)
    # 24 − 1 reserved − 17.5 weights − 1.5 activations = 4 GB of KV, ÷ 49 152 B ⇒ ~87k tokens,
    # so the binding constraint here is the operator's cap, not the card.
    assert plan.max_model_len == 65536
    assert any("operator cap" in line for line in plan.workings)
    assert 0 < plan.utilisation <= 0.97


def test_a_model_that_does_not_fit_says_so_with_both_sides_of_the_inequality():
    huge = QWEN.model_copy(update={"weights_gb": 21.0})
    registry = ModelRegistry(gpu=GPU, models=[huge])
    problems = registry.unservable()
    assert problems and "below the" in problems[0][1]
    assert not huge.fits(GPU)


def test_the_cache_binds_when_it_is_smaller_than_the_cap():
    # A hypothetical dense model with a fat KV cache: the card decides, not the operator.
    dense = QWEN.model_copy(update={"kv_bytes_per_token": 400_000, "cap_max_model_len": None})
    plan = dense.plan(GPU)
    assert plan.max_model_len == 10240
    assert any("tokens the cache can hold" in line for line in plan.workings)


def test_the_argv_pins_the_revision_and_binds_to_loopback():
    argv = QWEN.plan(GPU).argv()
    assert "--revision" in argv and argv[argv.index("--revision") + 1] == "a" * 40
    assert argv[argv.index("--host") + 1] == "127.0.0.1"
    assert "--enable-prefix-caching" in argv
    assert QWEN.plan(GPU).base_url == "http://127.0.0.1:8000/v1"


def test_duplicate_names_and_shared_ports_are_refused():
    with pytest.raises(Exception, match="duplicate"):
        ModelRegistry(gpu=GPU, models=[QWEN, QWEN])
    with pytest.raises(Exception, match="port"):
        ModelRegistry(gpu=GPU, models=[QWEN, DEVSTRAL.model_copy(update={"port": 8000})])


def test_an_unreported_revision_is_a_failure_not_a_pass():
    outcome = check_revision(QWEN, None)
    assert outcome.is_err
    assert outcome.category is ErrorCategory.ENVIRONMENT

    assert check_revision(QWEN, "a" * 40).is_ok
    assert check_revision(QWEN, "a" * 12).is_ok  # a short digest of the same commit
    assert check_revision(QWEN, "c" * 40).is_err


def test_the_committed_registry_loads_and_fits_the_card():
    registry = load_registry(root=_repo_root())
    assert {m.name for m in registry.models} == {"qwen3-coder-30b", "devstral-24b"}
    assert registry.unservable() == []
    # L1's pairing: the two roles that must not share a model are served by different ones.
    assert registry.for_role("implementer")[0].name != registry.for_role("reviewer")[0].name


def test_a_missing_registry_names_the_file():
    with pytest.raises(RegistryError, match="cannot read"):
        load_registry(_repo_root() / "nowhere.yaml")


def test_the_unit_conflicts_with_every_other_model():
    registry = ModelRegistry(gpu=GPU, models=[QWEN, DEVSTRAL])
    name, service = render_serving(
        registry.plan("qwen3-coder-30b"), working_dir="/srv/repo", conflicts=("devstral-24b",)
    )
    assert name == serving_unit_name("qwen3-coder-30b")
    assert f"Conflicts={serving_unit_name('devstral-24b')}.service" in service
    # Pinned weights must not be able to download something nobody reviewed.
    assert "HF_HUB_OFFLINE=1" in service
    assert "--max-model-len 65536" in service


def test_a_relative_binary_is_resolved_against_the_repository(tmp_path):
    binary = tmp_path / ".venv-vllm" / "bin" / "vllm"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\n")

    resolved = resolve_binary(".venv-vllm/bin/vllm", root=tmp_path)
    assert resolved == str(binary.resolve())

    service = render_serving(
        ModelRegistry(gpu=GPU, models=[QWEN]).plan("qwen3-coder-30b"),
        working_dir=str(tmp_path),
        vllm_bin=resolved or "vllm",
    )[1]
    # systemd requires an absolute ExecStart and a *user* unit's PATH has neither conda nor a
    # virtualenv on it, so a bare name here is a unit that exits 203/EXEC before it reads a flag.
    assert f"ExecStart={binary.resolve()} serve" in service
    # And the binary's own directory joins PATH, because vLLM shells out by name to the tools
    # beside it. An absolute ExecStart alone gets as far as loading the weights and then dies on
    # `FileNotFoundError: 'ninja'` — a broken PATH wearing a broken model's clothes.
    assert f"Environment=PATH={binary.parent.resolve()}:" in service


def test_a_binary_that_is_nowhere_resolves_to_nothing_rather_than_to_itself(tmp_path):
    # Not the bare name back: "I could not find it" and "here it is" are different answers, and
    # returning the input would render a unit that looks resolved and is not.
    assert resolve_binary("no-such-binary-anywhere", root=tmp_path, which=lambda _: None) is None
    assert resolve_binary("bin/absent", root=tmp_path) is None


# ── the health contract ──────────────────────────────────────────────────────────


def _client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_a_server_holding_a_different_model_is_an_environment_failure():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"data": [{"id": "devstral-24b"}]})

    async with _client(handler) as client:
        outcome = await HealthClient(base_url="http://127.0.0.1:8000/v1", client=client).check(QWEN)
    assert outcome.is_err
    assert "not 'qwen3-coder-30b'" in (outcome.error.message if outcome.error else "")


async def test_a_wrong_revision_refuses_before_anything_is_claimed():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"data": [{"id": QWEN.name, "revision": "c" * 40}]})

    async with _client(handler) as client:
        outcome = await HealthClient(base_url="http://127.0.0.1:8000/v1", client=client).check(QWEN)
    assert outcome.is_err
    assert outcome.category is ErrorCategory.ENVIRONMENT


async def test_readiness_is_a_returned_token_not_a_bound_port():
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path.endswith("/models"):
            return httpx.Response(
                200,
                json={"data": [{"id": QWEN.name, "revision": "a" * 40, "max_model_len": 65536}]},
            )
        return httpx.Response(200, json={"choices": [{"message": {"content": "y"}}]})

    async with _client(handler) as client:
        outcome = await HealthClient(base_url="http://127.0.0.1:8000/v1", client=client).ready(QWEN)

    health = outcome.unwrap()
    assert health.ready and health.max_model_len == 65536
    assert calls[-1].endswith("/chat/completions")


async def test_a_loaded_but_silent_model_is_not_ready():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/models"):
            return httpx.Response(200, json={"data": [{"id": QWEN.name, "revision": "a" * 40}]})
        return httpx.Response(200, json={"choices": []})

    async with _client(handler) as client:
        outcome = await HealthClient(base_url="http://127.0.0.1:8000/v1", client=client).ready(QWEN)
    assert outcome.is_err


async def test_an_absent_server_names_the_remedy_rather_than_the_traceback():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    async with _client(handler) as client:
        outcome = await HealthClient(base_url="http://127.0.0.1:8000/v1", client=client).check()
    assert outcome.is_err
    assert outcome.error is not None and outcome.error.remedy


# ── the benchmark's arithmetic ───────────────────────────────────────────────────


def test_the_conservative_rate_is_the_slowest_point_not_the_average():
    result = BenchResult(
        model="qwen3-coder-30b",
        base_url="http://127.0.0.1:8000/v1",
        points=[
            BenchPoint(1000, 1000, 256, ttft_s=0.5, total_s=8.5),
            BenchPoint(32000, 32000, 256, ttft_s=4.0, total_s=20.0),
        ],
    )
    # The 1k point prefills at 2 000 tok/s and the 32k point at 8 000; the conservative figure
    # is the slower of the two, because a timeout derived from the faster one fires on the
    # prompts worth not losing.
    assert result.decode_tps == pytest.approx(256 / 16.0)
    assert result.prefill_tps == pytest.approx(2000.0)
    assert "decode tok/s" in result.as_markdown()


def _repo_root():
    from pathlib import Path

    return Path(__file__).resolve().parents[2]
