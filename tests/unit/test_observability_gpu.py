"""GPU and serving telemetry, and the preflight that refuses before a claim (#93)."""

from __future__ import annotations

import httpx

from ai_harness.cli.commands.doctor import diagnose
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


async def test_the_doctor_names_a_remedy_for_every_failure():
    async with _down() as client:
        diagnosis = await diagnose(ModelRegistry(gpu=GPU, models=[SPEC]), client=client)

    assert diagnosis.checks
    for check in diagnosis.checks:
        if not check.ok:
            # A doctor that prints "FAIL: gpu" has only told the operator that they now have to
            # go and find out.
            assert check.remedy, f"{check.name} failed without saying what to do"


async def test_a_server_that_is_not_up_is_a_warning_and_not_a_dead_box():
    async with _down() as client:
        diagnosis = await diagnose(ModelRegistry(gpu=GPU, models=[SPEC]), client=client)
    serving = next(c for c in diagnosis.checks if c.name.startswith("serving:"))

    assert serving.fatal is False
    # A model that is not currently resident is the *normal* state on a one-card box (L2), so it
    # must not read as "this host is broken".
    assert diagnosis.healthy or not any(c.fatal and not c.ok for c in diagnosis.checks)
