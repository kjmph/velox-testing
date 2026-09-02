# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

import pytest

from common.testing.performance_benchmarks import common_fixtures
from common.testing.performance_benchmarks.benchmark_keys import BenchmarkKeys
from common.testing.performance_benchmarks.conftest import (
    CACHE_MODE_COLD_EVERY_ITERATION,
    CACHE_MODE_COLD_ONCE,
    CACHE_MODE_DEFAULT,
    _aggregate_headers,
    _aggregate_keys,
    _cache_mode,
    compute_aggregate_timings,
)


def _results(timings):
    return {
        BenchmarkKeys.RAW_TIMES_KEY: {"Q1": timings},
    }


def test_compute_aggregate_timings_preserves_default_hot_semantics():
    results = _results([100, 20, 40])

    compute_aggregate_timings(results)

    assert results[BenchmarkKeys.AGGREGATE_TIMES_KEY]["Q1"] == (30, 20, 40, 30.0, 28.28, 100)
    assert results[BenchmarkKeys.AGGREGATE_TIMES_SUM_KEY] == [30, 20, 40, 30.0, 28.28, 100]


def test_compute_aggregate_timings_uses_every_cold_sample():
    results = _results([100, 20, 40])

    compute_aggregate_timings(results, cache_mode=CACHE_MODE_COLD_EVERY_ITERATION)

    assert results[BenchmarkKeys.AGGREGATE_TIMES_KEY]["Q1"] == (53.33, 20, 100, 40, 43.09)
    assert results[BenchmarkKeys.AGGREGATE_TIMES_SUM_KEY] == [53.33, 20, 100, 40, 43.09]


def test_compute_aggregate_timings_reports_one_cold_sample_directly():
    results = _results([75])

    compute_aggregate_timings(results, cache_mode=CACHE_MODE_COLD_ONCE)

    assert results[BenchmarkKeys.AGGREGATE_TIMES_KEY]["Q1"] == (75,)
    assert results[BenchmarkKeys.AGGREGATE_TIMES_SUM_KEY] == [75]


def test_cold_once_preserves_hot_aggregates_and_relabels_first_sample():
    results = _results([100, 20, 40])

    compute_aggregate_timings(results, cache_mode=CACHE_MODE_COLD_ONCE)

    assert results[BenchmarkKeys.AGGREGATE_TIMES_KEY]["Q1"] == (30, 20, 40, 30.0, 28.28, 100)
    assert _aggregate_headers(iterations=5, cache_mode=CACHE_MODE_COLD_ONCE) == [
        "Avg Hot(ms)",
        "Min Hot(ms)",
        "Max Hot(ms)",
        "Median Hot(ms)",
        "GMean Hot(ms)",
        "Cold(ms)",
    ]
    assert _aggregate_keys(iterations=5, cache_mode=CACHE_MODE_COLD_ONCE) == [
        BenchmarkKeys.AVG_KEY,
        BenchmarkKeys.MIN_KEY,
        BenchmarkKeys.MAX_KEY,
        BenchmarkKeys.MEDIAN_KEY,
        BenchmarkKeys.GMEAN_KEY,
        BenchmarkKeys.COLD_KEY,
    ]


def test_cold_every_iteration_labels_never_describe_samples_as_hot_or_lukewarm():
    headers = _aggregate_headers(iterations=5, cache_mode=CACHE_MODE_COLD_EVERY_ITERATION)

    assert headers == [
        "Avg Cold(ms)",
        "Min Cold(ms)",
        "Max Cold(ms)",
        "Median Cold(ms)",
        "GMean Cold(ms)",
    ]
    assert all("Hot" not in header and "Lukewarm" not in header for header in headers)
    assert _aggregate_headers(iterations=1, cache_mode=CACHE_MODE_COLD_EVERY_ITERATION) == ["Cold(ms)"]


def test_cold_json_keys_remain_comparable_for_multiple_samples():
    assert _aggregate_keys(iterations=5, cache_mode=CACHE_MODE_COLD_EVERY_ITERATION) == [
        BenchmarkKeys.AVG_KEY,
        BenchmarkKeys.MIN_KEY,
        BenchmarkKeys.MAX_KEY,
        BenchmarkKeys.MEDIAN_KEY,
        BenchmarkKeys.GMEAN_KEY,
    ]
    assert _aggregate_keys(iterations=1, cache_mode=CACHE_MODE_COLD_EVERY_ITERATION) == [BenchmarkKeys.COLD_KEY]


def test_default_labels_and_keys_are_unchanged():
    assert _aggregate_headers(iterations=5, cache_mode=CACHE_MODE_DEFAULT) == [
        "Avg Hot(ms)",
        "Min Hot(ms)",
        "Max Hot(ms)",
        "Median Hot(ms)",
        "GMean Hot(ms)",
        "Lukewarm(ms)",
    ]
    assert _aggregate_keys(iterations=5, cache_mode=CACHE_MODE_DEFAULT) == [
        BenchmarkKeys.AVG_KEY,
        BenchmarkKeys.MIN_KEY,
        BenchmarkKeys.MAX_KEY,
        BenchmarkKeys.MEDIAN_KEY,
        BenchmarkKeys.GMEAN_KEY,
        BenchmarkKeys.LUKEWARM_KEY,
    ]


class _Config:
    def __init__(self, options):
        self.options = options

    def getoption(self, name, default=None):
        return self.options.get(name, default)


def test_cache_mode_defaults_safely_when_options_are_not_registered():
    assert _cache_mode(_Config({})) == CACHE_MODE_DEFAULT


def test_cache_mode_distinguishes_cold_once_and_every_iteration():
    assert _cache_mode(_Config({"--cold": True})) == CACHE_MODE_COLD_ONCE
    assert _cache_mode(_Config({"--cold-every-iteration": True})) == CACHE_MODE_COLD_EVERY_ITERATION


def test_cache_mode_rejects_ambiguous_cold_flags():
    with pytest.raises(pytest.UsageError, match="mutually exclusive"):
        _cache_mode(_Config({"--cold": True, "--cold-every-iteration": True}))


@pytest.mark.parametrize("cold_option", ["--cold", "--cold-every-iteration"])
def test_controlled_memory_cold_modes_preserve_os_page_cache(monkeypatch, capsys, cold_option):
    drops = []
    monkeypatch.setattr(common_fixtures, "drop_cache", lambda: drops.append(True))
    request = type("Request", (), {"config": _Config({cold_option: True, "--skip-drop-cache": False})})()

    common_fixtures.drop_cache_once.__wrapped__(request)

    assert drops == []
    assert "controlled memory-cold mode preserves the OS page cache" in capsys.readouterr().out


def test_default_mode_retains_legacy_system_cache_drop(monkeypatch):
    drops = []
    monkeypatch.setattr(common_fixtures, "drop_cache", lambda: drops.append(True))
    request = type("Request", (), {"config": _Config({"--skip-drop-cache": False})})()

    common_fixtures.drop_cache_once.__wrapped__(request)

    assert drops == [True]
