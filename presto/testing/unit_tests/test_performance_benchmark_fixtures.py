# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

from types import SimpleNamespace

import pytest

from common.testing.performance_benchmarks.benchmark_keys import BenchmarkKeys
from presto.testing.performance_benchmarks import common_fixtures


class _Config:
    def __init__(self, tmp_path, *, cold=False, cold_every_iteration=False, metrics=False):
        self.options = {
            "--iterations": 3,
            "--profile": False,
            "--profile-script-path": None,
            "--metrics": metrics,
            "--cold": cold,
            "--cold-every-iteration": cold_every_iteration,
            "--output-dir": str(tmp_path),
            "--hostname": "coordinator",
            "--port": 8080,
        }

    def getoption(self, name):
        return self.options[name]


class _Cursor:
    def __init__(self, events):
        self.events = events
        self.stats = {"elapsedTimeMillis": 17}
        self.description = [("result",)]

    def execute(self, _query):
        self.events.append("execute")
        return self

    def fetchall(self):
        return [(1,)]


def _request(tmp_path, *, cold=False, cold_every_iteration=False, metrics=False):
    return SimpleNamespace(
        config=_Config(tmp_path, cold=cold, cold_every_iteration=cold_every_iteration, metrics=metrics),
        node=SimpleNamespace(obj=SimpleNamespace(BENCHMARK_TYPE="tpch")),
    )


@pytest.mark.parametrize(
    ("cold", "cold_every_iteration", "expected_events"),
    [
        (False, False, ["execute", "execute", "execute"]),
        (True, False, ["clear", "execute", "execute", "execute"]),
        (False, True, ["clear", "execute", "clear", "execute", "clear", "execute"]),
    ],
)
def test_benchmark_cache_clear_order(
    monkeypatch,
    tmp_path,
    cold,
    cold_every_iteration,
    expected_events,
):
    events = []

    def clear_worker_memory_caches(*, hostname, port):
        assert (hostname, port) == ("coordinator", 8080)
        events.append("clear")
        return SimpleNamespace(worker_uris=("http://worker:7777",))

    monkeypatch.setattr(common_fixtures, "clear_worker_memory_caches", clear_worker_memory_caches)
    monkeypatch.setattr(
        common_fixtures.pd,
        "DataFrame",
        lambda *_args, **_kwargs: SimpleNamespace(to_parquet=lambda *_args, **_kwargs: None),
    )

    benchmark_results = {}
    run_query = common_fixtures.benchmark_query.__wrapped__(
        _request(tmp_path, cold=cold, cold_every_iteration=cold_every_iteration),
        _Cursor(events),
        {"Q6": "SELECT 1"},
        benchmark_results,
    )

    run_query("Q6")

    assert events == expected_events
    assert benchmark_results["tpch"][BenchmarkKeys.RAW_TIMES_KEY]["Q6"] == [17, 17, 17]


def test_cache_clear_failure_prevents_query_execution(monkeypatch, tmp_path):
    events = []

    def fail_clear(**_kwargs):
        events.append("clear")
        raise RuntimeError("cache clear failed")

    monkeypatch.setattr(common_fixtures, "clear_worker_memory_caches", fail_clear)
    benchmark_results = {}
    run_query = common_fixtures.benchmark_query.__wrapped__(
        _request(tmp_path, cold=True),
        _Cursor(events),
        {"Q6": "SELECT 1"},
        benchmark_results,
    )

    with pytest.raises(RuntimeError, match="cache clear failed"):
        run_query("Q6")

    assert events == ["clear"]
    assert benchmark_results["tpch"][BenchmarkKeys.RAW_TIMES_KEY]["Q6"] is None


class _FailedQueryError(RuntimeError):
    error_type = "INTERNAL_ERROR"
    error_name = "GENERIC_INTERNAL_ERROR"

    def __init__(self, query_id):
        super().__init__("query failed")
        self.query_id = query_id


class _FailingCursor(_Cursor):
    def __init__(self, events, query_id="failed-query-id"):
        super().__init__(events)
        self.query_id = query_id
        self._query = SimpleNamespace(query_id=None)

    def execute(self, _query):
        self.events.append("execute")
        self._query.query_id = self.query_id
        raise _FailedQueryError(self.query_id)


def test_failed_query_collects_metrics_before_reraising(monkeypatch, tmp_path):
    events = []
    cursor = _FailingCursor(events)

    def collect_metrics(**kwargs):
        events.append(("metrics", kwargs))

    monkeypatch.setattr(common_fixtures, "collect_metrics", collect_metrics)
    benchmark_results = {}
    run_query = common_fixtures.benchmark_query.__wrapped__(
        _request(tmp_path, metrics=True),
        cursor,
        {"Q18": "SELECT 1"},
        benchmark_results,
    )

    with pytest.raises(_FailedQueryError, match="query failed"):
        run_query("Q18")

    assert events == [
        "execute",
        (
            "metrics",
            {
                "query_id": "failed-query-id",
                "query_name": "Q18",
                "hostname": "coordinator",
                "port": 8080,
                "output_dir": str(tmp_path),
            },
        ),
    ]
    assert benchmark_results["tpch"][BenchmarkKeys.FAILED_QUERIES_KEY]["Q18"] == (
        "INTERNAL_ERROR: GENERIC_INTERNAL_ERROR"
    )


def test_failed_query_metrics_error_does_not_mask_query_error(monkeypatch, tmp_path, capsys):
    cursor = _FailingCursor([])

    def fail_metrics(**_kwargs):
        raise OSError("metrics endpoint unavailable")

    monkeypatch.setattr(common_fixtures, "collect_metrics", fail_metrics)
    run_query = common_fixtures.benchmark_query.__wrapped__(
        _request(tmp_path, metrics=True),
        cursor,
        {"Q18": "SELECT 1"},
        {},
    )

    with pytest.raises(_FailedQueryError, match="query failed"):
        run_query("Q18")

    assert "Failed to collect diagnostics for failed query failed-query-id" in capsys.readouterr().out
