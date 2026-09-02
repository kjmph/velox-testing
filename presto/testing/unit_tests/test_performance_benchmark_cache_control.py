# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import threading
from typing import Any

import pytest
import requests

from presto.testing.performance_benchmarks.cache_control import (
    CacheControlError,
    clear_worker_memory_caches,
)


class FakeResponse:
    def __init__(self, *, json_data: Any = None, text: str = "", status_code: int = 200):
        self._json_data = json_data
        self.text = text
        self.status_code = status_code

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise requests.HTTPError(f"HTTP {self.status_code}")

    def json(self) -> Any:
        if isinstance(self._json_data, Exception):
            raise self._json_data
        return self._json_data


class RecordingGet:
    def __init__(self, routes: dict[str, FakeResponse | Exception]):
        self.routes = routes
        self.calls: list[tuple[str, float]] = []
        self._lock = threading.Lock()

    def __call__(self, url: str, *, timeout: float) -> FakeResponse:
        with self._lock:
            self.calls.append((url, timeout))
        outcome = self.routes[url]
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class MappingResolver:
    def __init__(self, mapping: dict[str, str] | None = None):
        self.mapping = mapping or {}

    def resolve(self, uri: str) -> str:
        return self.mapping.get(uri, uri)


def coordinator_routes(nodes: Any, queries: Any | None = None) -> dict[str, FakeResponse | Exception]:
    if queries is None:
        queries = [
            {"queryId": "finished", "state": "FINISHED"},
            {"queryId": "failed", "state": "FAILED"},
        ]
    return {
        "http://coordinator:8080/v1/query": FakeResponse(json_data=queries),
        "http://coordinator:8080/v1/node": FakeResponse(json_data=nodes),
    }


def clear_url(worker_uri: str) -> str:
    return f"{worker_uri}/v1/operation/server/clearCache?type=memory"


def test_clears_all_unique_workers_and_strips_status_path() -> None:
    routes = coordinator_routes(
        [
            {"uri": "http://worker-b:7778/v1/status"},
            {"uri": "http://worker-a:7777"},
            {"uri": "http://worker-a:7777/v1/status/"},
        ]
    )
    routes.update(
        {
            clear_url("http://10.0.0.1:7777"): FakeResponse(text="  Cleared memory cache\n"),
            clear_url("http://10.0.0.2:7778"): FakeResponse(text="Cleared memory cache"),
        }
    )
    get = RecordingGet(routes)
    resolver = MappingResolver(
        {
            "http://worker-a:7777": "http://10.0.0.1:7777",
            "http://worker-b:7778": "http://10.0.0.2:7778",
        }
    )

    result = clear_worker_memory_caches(
        "coordinator",
        8080,
        timeout_seconds=7,
        http_get=get,
        resolver=resolver,
    )

    assert result.worker_uris == ("http://10.0.0.1:7777", "http://10.0.0.2:7778")
    clear_calls = sorted(url for url, _ in get.calls if "clearCache" in url)
    assert clear_calls == [
        clear_url("http://10.0.0.1:7777"),
        clear_url("http://10.0.0.2:7778"),
    ]
    assert all(timeout == 7 for _, timeout in get.calls)


def test_deduplicates_after_worker_uri_resolution() -> None:
    routes = coordinator_routes(
        [
            {"uri": "http://worker-a:7777"},
            {"uri": "http://10.0.0.1:7777/v1/status"},
        ]
    )
    routes[clear_url("http://10.0.0.1:7777")] = FakeResponse(text="Cleared memory cache")
    get = RecordingGet(routes)

    result = clear_worker_memory_caches(
        "coordinator",
        8080,
        http_get=get,
        resolver=MappingResolver({"http://worker-a:7777": "http://10.0.0.1:7777"}),
    )

    assert result.worker_uris == ("http://10.0.0.1:7777",)
    assert [url for url, _ in get.calls].count(clear_url("http://10.0.0.1:7777")) == 1


def test_refuses_to_clear_while_queries_are_active() -> None:
    routes = coordinator_routes(
        [{"uri": "http://worker:7777"}],
        queries=[
            {"queryId": "query-z", "state": "RUNNING"},
            {"queryId": "query-a", "state": "QUEUED"},
            {"queryId": "query-done", "state": "FINISHED"},
        ],
    )
    get = RecordingGet(routes)

    with pytest.raises(CacheControlError) as error:
        clear_worker_memory_caches(
            "coordinator",
            8080,
            http_get=get,
            resolver=MappingResolver(),
        )

    assert str(error.value).endswith("query-a (QUEUED), query-z (RUNNING)")
    assert [url for url, _ in get.calls] == ["http://coordinator:8080/v1/query"]


def test_rejects_query_that_races_with_cache_clear() -> None:
    query_checks = iter(
        [
            FakeResponse(json_data=[]),
            FakeResponse(json_data=[{"queryId": "racing-query", "state": "RUNNING"}]),
        ]
    )
    routes = coordinator_routes([{"uri": "http://worker:7777"}], queries=[])
    routes[clear_url("http://worker:7777")] = FakeResponse(text="Cleared memory cache")
    recording_get = RecordingGet(routes)

    def get(url: str, *, timeout: float) -> FakeResponse:
        if url == "http://coordinator:8080/v1/query":
            recording_get.calls.append((url, timeout))
            return next(query_checks)
        return recording_get(url, timeout=timeout)

    with pytest.raises(CacheControlError, match=r"racing-query \(RUNNING\)"):
        clear_worker_memory_caches(
            "coordinator",
            8080,
            http_get=get,
            resolver=MappingResolver(),
        )

    assert [url for url, _ in recording_get.calls].count(clear_url("http://worker:7777")) == 1


@pytest.mark.parametrize(
    ("nodes", "expected"),
    [
        ([], "returned no workers"),
        ({}, "returned a non-list response"),
        (["worker"], "malformed entry at index 0"),
        ([{}], "entry at index 0 has no valid uri"),
        ([{"uri": "worker:7777"}], "unsupported scheme"),
        ([{"uri": "http://worker:7777/unexpected"}], "unexpected path"),
    ],
)
def test_rejects_empty_or_malformed_worker_discovery(nodes: Any, expected: str) -> None:
    get = RecordingGet(coordinator_routes(nodes))

    with pytest.raises(CacheControlError, match=expected):
        clear_worker_memory_caches(
            "coordinator",
            8080,
            http_get=get,
            resolver=MappingResolver(),
        )

    assert not any("clearCache" in url for url, _ in get.calls)


@pytest.mark.parametrize(
    "queries",
    [
        {},
        ["query"],
        [{"queryId": "query"}],
        [{"state": "FINISHED"}],
    ],
)
def test_rejects_malformed_active_query_response(queries: Any) -> None:
    get = RecordingGet(coordinator_routes([{"uri": "http://worker:7777"}], queries=queries))

    with pytest.raises(CacheControlError, match="Active-query check returned"):
        clear_worker_memory_caches(
            "coordinator",
            8080,
            http_get=get,
            resolver=MappingResolver(),
        )

    assert not any("clearCache" in url for url, _ in get.calls)


def test_requires_exact_success_body_even_for_http_200() -> None:
    routes = coordinator_routes(
        [
            {"uri": "http://worker-z:7779"},
            {"uri": "http://worker-a:7777"},
        ]
    )
    routes.update(
        {
            clear_url("http://worker-z:7779"): FakeResponse(text="No memory cache set on server"),
            clear_url("http://worker-a:7777"): FakeResponse(text="cleared memory cache"),
        }
    )
    get = RecordingGet(routes)

    with pytest.raises(CacheControlError) as error:
        clear_worker_memory_caches(
            "coordinator",
            8080,
            http_get=get,
            resolver=MappingResolver(),
        )

    message = str(error.value)
    assert "http://worker-a:7777:" in message
    assert "http://worker-z:7779:" in message
    assert message.index("http://worker-a:7777:") < message.index("http://worker-z:7779:")
    assert "No memory cache set on server" in message


def test_aggregates_http_failures_in_worker_uri_order() -> None:
    routes = coordinator_routes(
        [
            {"uri": "http://worker-z:7779"},
            {"uri": "http://worker-a:7777"},
        ]
    )
    routes.update(
        {
            clear_url("http://worker-z:7779"): requests.Timeout("timed out"),
            clear_url("http://worker-a:7777"): FakeResponse(status_code=503),
        }
    )
    get = RecordingGet(routes)

    with pytest.raises(CacheControlError) as error:
        clear_worker_memory_caches(
            "coordinator",
            8080,
            http_get=get,
            resolver=MappingResolver(),
        )

    message = str(error.value)
    assert message.index("http://worker-a:7777:") < message.index("http://worker-z:7779:")
    assert "HTTP 503" in message
    assert "timed out" in message


def test_can_skip_idle_check_explicitly() -> None:
    routes = {
        "http://coordinator:8080/v1/node": FakeResponse(json_data=[{"uri": "http://worker:7777"}]),
        clear_url("http://worker:7777"): FakeResponse(text="Cleared memory cache"),
    }
    get = RecordingGet(routes)

    clear_worker_memory_caches(
        "coordinator",
        8080,
        require_idle=False,
        http_get=get,
        resolver=MappingResolver(),
    )

    assert "http://coordinator:8080/v1/query" not in {url for url, _ in get.calls}
