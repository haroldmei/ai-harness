"""GPU and serving telemetry, and the preflight that refuses before a claim (#93)."""

from __future__ import annotations

from pathlib import Path

import httpx

from ai_harness.cli.commands.doctor import diagnose
from ai_harness.llm.serving.cache import hub_cache_root
from ai_harness.llm.serving.models import GpuSpec, ModelRegistry, ModelSpec
from ai_harness.observability.gpu import (
    GpuReading,
    ServingMetrics,
    parse_prometheus,
    read_gpu,
    read_serving,
)
from ai_harness.observability.metrics import Metrics

VLLM_METRICS = """\
# HELP vllm:num_requests_waiting Number of requests waiting.
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting{model_name="qwen3-coder-30b"} 2.0
vllm:num_requests_running{model_name="qwen3-coder-30b"} 1.0
vllm:gpu_cache_usage_perc{model_name="qwen3-coder-30b"} 0.43
vllm:gpu_prefix_cache_hit_rate{model_name="qwen3-coder-30b"} 0.81
vllm:time_to_first_token_seconds_sum{model_name="qwen3-coder-30b"} 40.0
vllm:time_to_first_token_seconds_count{model_name="qwen3-coder-30b"} 10.0
vllm:num_preemptions_total{model_name="qwen3-coder-30b"} 3.0
something_else{model_name="qwen3-coder-30b"} 999.0
"""


def test_an_idle_card_is_not_a_throttled_one():
    # nvidia-smi's low bit means GpuIdle. Reporting a healthy idle box as thermally limited is
    # the kind of false alarm that teaches people to ignore the real one.
    idle = GpuReading(available=True, throttle_reason="0x0000000000000001")
    assert not idle.throttling
    assert idle.throttle_names == "gpu idle"

    thermal = GpuReading(available=True, throttle_reason="0x0000000000000040")
    assert thermal.throttling
    assert "hw thermal slowdown" in thermal.throttle_names

    assert not GpuReading(available=True, throttle_reason="Not Active").throttling


def test_free_memory_is_none_rather_than_zero_when_nothing_was_read():
    # Zero would read as "the card is full", which is a different and much worse claim than
    # "we did not look".
    assert GpuReading().memory_free_mb is None
    assert GpuReading(memory_total_mb=24564, memory_used_mb=17000).memory_free_mb == 7564


async def test_a_box_without_nvidia_smi_gets_a_note_and_not_an_exception():
    reading = await read_gpu(binary="definitely-not-a-real-binary")
    assert reading.available is False
    assert "not on PATH" in reading.note


def test_the_serving_series_worth_having_are_extracted_and_the_rest_ignored():
    values = parse_prometheus(VLLM_METRICS)
    assert values["serving_queue_depth"] == 2.0
    assert values["serving_kv_cache_usage"] == 0.43
    assert values["serving_prefix_cache_hit_rate"] == 0.81
    assert "something_else" not in values

    metrics = ServingMetrics(values=values, available=True)
    assert metrics.mean_ttft_s == 4.0


async def test_an_absent_metrics_endpoint_is_a_note_not_a_failure():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        metrics = await read_serving("http://127.0.0.1:8000/v1", client=client)

    assert metrics.available is False
    assert metrics.values == {}
    assert "exposed no metrics" in metrics.note


def test_the_gpu_lands_on_the_exporter_that_already_exists():
    metrics = Metrics()
    metrics.record_gpu(
        GpuReading(
            available=True,
            utilisation_pct=97.0,
            memory_used_mb=18000,
            memory_total_mb=24564,
            temperature_c=71.0,
            power_w=380.0,
            throttle_reason="0x0000000000000001",
        )
    )
    rendered = metrics.render_prometheus()
    assert "gpu_utilisation_pct" in rendered
    assert "gpu_throttling" in rendered

    # An unread card produces no series at all: a zero would be a claim we cannot make.
    empty = Metrics()
    empty.record_gpu(GpuReading(note="no nvidia-smi"))
    assert empty.snapshot() == {}


def test_serving_and_swap_numbers_are_recorded_where_the_others_are():
    metrics = Metrics()
    metrics.record_serving(
        ServingMetrics(values=parse_prometheus(VLLM_METRICS), available=True),
        model="qwen3-coder-30b",
    )
    metrics.record_swap(from_model="qwen3-coder-30b", to_model="devstral-24b", seconds=31.0)

    snapshot = metrics.snapshot()
    assert any("serving_prefix_cache_hit_rate" in key for key in snapshot)
    assert any("serving_ttft_seconds_mean" in key for key in snapshot)
    rendered = metrics.render_prometheus()
    assert "model_swaps_total" in rendered


# ── the preflight ────────────────────────────────────────────────────────────────

GPU = GpuSpec(vram_gb=24.0, reserve_gb=1.0)
SPEC = ModelSpec(
    name="qwen3-coder-30b",
    repo_id="q",
    revision="a" * 40,
    weights_gb=17.5,
    kv_bytes_per_token=49152,
    native_max_model_len=262144,
    port=8000,
)


def _down() -> httpx.AsyncClient:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


async def test_the_doctor_names_a_remedy_for_every_failure(tmp_path):
    async with _down() as client:
        diagnosis = await diagnose(
            ModelRegistry(gpu=GPU, models=[SPEC]), client=client, hub_cache=tmp_path
        )

    assert diagnosis.checks
    for check in diagnosis.checks:
        if not check.ok:
            # A doctor that prints "FAIL: gpu" has only told the operator that they now have to
            # go and find out.
            assert check.remedy, f"{check.name} failed without saying what to do"


async def test_a_server_that_is_not_up_is_a_warning_and_not_a_dead_box(tmp_path):
    async with _down() as client:
        diagnosis = await diagnose(
            ModelRegistry(gpu=GPU, models=[SPEC]), client=client, hub_cache=tmp_path
        )
    serving = next(c for c in diagnosis.checks if c.name.startswith("serving:"))

    assert serving.fatal is False
    # A model that is not currently resident is the *normal* state on a one-card box (L2), so it
    # must not read as "this host is broken".
    assert not any(c.fatal and not c.ok for c in diagnosis.checks if c.name.startswith("serving:"))


# ── the two conditions that fail a start before the model is ever loaded ─────────
#
# Both were live on this host and neither was checked: `systemctl start` exited 203/EXEC in
# under a second while `agent doctor` reported the box healthy. A preflight that misses the two
# things that actually prevent a start is a preflight that has to be run twice — once, and then
# again after reading the journal.


def _snapshot(cache: Path, repo_id: str, revision: str) -> Path:
    directory = cache / f"models--{repo_id.replace('/', '--')}" / "snapshots" / revision
    directory.mkdir(parents=True)
    (directory / "model.safetensors").write_text("weights")
    return directory


async def test_a_vllm_that_cannot_be_located_is_fatal_and_names_the_path_trap(tmp_path):
    registry = ModelRegistry(gpu=GPU, models=[SPEC], vllm_bin="not-a-real-binary-anywhere")
    async with _down() as client:
        diagnosis = await diagnose(
            registry, client=client, root=tmp_path, hub_cache=tmp_path / "hub"
        )

    check = next(c for c in diagnosis.checks if c.name == "vllm")
    assert not check.ok and check.fatal
    # The remedy has to name the *reason* a working shell command fails as a unit, or the
    # operator installs vLLM, sees it on PATH, and gets 203/EXEC a second time.
    assert "203/EXEC" in check.remedy
    assert not diagnosis.healthy


async def test_a_relative_vllm_is_resolved_against_the_repository_and_reported_absolute(tmp_path):
    binary = tmp_path / ".venv-vllm" / "bin" / "vllm"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\n")
    registry = ModelRegistry(gpu=GPU, models=[SPEC], vllm_bin=".venv-vllm/bin/vllm")

    async with _down() as client:
        diagnosis = await diagnose(
            registry, client=client, root=tmp_path, hub_cache=tmp_path / "hub"
        )

    check = next(c for c in diagnosis.checks if c.name == "vllm")
    # Absolute, because that is what systemd requires of ExecStart — reporting the relative
    # form would look correct and still render a unit that cannot start.
    assert check.ok and check.detail == str(binary.resolve())


async def test_unfetched_weights_are_a_failure_that_names_the_exact_download(tmp_path):
    async with _down() as client:
        diagnosis = await diagnose(
            ModelRegistry(gpu=GPU, models=[SPEC]),
            client=client,
            root=tmp_path,
            hub_cache=tmp_path / "hub",
        )

    check = next(c for c in diagnosis.checks if c.name == f"weights:{SPEC.name}")
    assert not check.ok and check.fatal
    # The full digest, not the abbreviation the detail line shows: the remedy is meant to be
    # pasted, and `hf download --revision a2b3c4d5e6f7` fetches a different thing than the pin.
    assert f"--revision {SPEC.revision}" in check.remedy
    assert "HF_HUB_OFFLINE=1" in check.remedy


async def test_weights_cached_under_the_full_sha_satisfy_a_shortened_pin(tmp_path):
    cache = tmp_path / "hub"
    _snapshot(cache, SPEC.repo_id, SPEC.revision)
    short = SPEC.model_copy(update={"revision": SPEC.revision[:12]})

    async with _down() as client:
        diagnosis = await diagnose(
            ModelRegistry(gpu=GPU, models=[short]), client=client, root=tmp_path, hub_cache=cache
        )

    check = next(c for c in diagnosis.checks if c.name == f"weights:{short.name}")
    # `check_revision` accepts a short digest for the same commit, so the cache lookup must too —
    # otherwise a pin an operator shortened by hand reads as "not downloaded".
    assert check.ok


async def test_an_empty_snapshot_directory_is_not_evidence_of_weights(tmp_path):
    cache = tmp_path / "hub"
    (cache / f"models--{SPEC.repo_id}" / "snapshots" / SPEC.revision).mkdir(parents=True)

    async with _down() as client:
        diagnosis = await diagnose(
            ModelRegistry(gpu=GPU, models=[SPEC]), client=client, root=tmp_path, hub_cache=cache
        )

    # An interrupted download leaves the directory behind. "The folder exists" is the same class
    # of evidence as "npm ci exited 0" — it is not the thing anyone meant to check.
    assert not next(c for c in diagnosis.checks if c.name == f"weights:{SPEC.name}").ok


def test_the_hub_cache_follows_the_hub_s_own_precedence(tmp_path):
    assert hub_cache_root({"HF_HUB_CACHE": str(tmp_path / "explicit")}) == tmp_path / "explicit"
    assert hub_cache_root({"HF_HOME": str(tmp_path / "home")}) == tmp_path / "home" / "hub"
    assert hub_cache_root({"XDG_CACHE_HOME": str(tmp_path)}) == tmp_path / "huggingface" / "hub"
