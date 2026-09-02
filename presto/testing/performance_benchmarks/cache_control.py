# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

"""Control native-worker caches for repeatable Presto benchmarks."""

from __future__ import annotations

from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse, urlunparse

import requests

from .metrics_collector import WorkerUriResolver

_CLEAR_MEMORY_CACHE_PATH = "/v1/operation/server/clearCache?type=memory"
_CLEAR_MEMORY_CACHE_SUCCESS = "Cleared memory cache"
_TERMINAL_QUERY_STATES = frozenset({"FINISHED", "FAILED"})


class CacheControlError(RuntimeError):
    """Raised when worker cache state cannot be established safely."""


@dataclass(frozen=True)
class CacheClearResult:
    """Result of one synchronous cluster-wide memory-cache clear."""

    worker_uris: tuple[str, ...]


def clear_worker_memory_caches(
    hostname: str,
    port: int,
    *,
    timeout_seconds: float = 60.0,
    require_idle: bool = True,
    max_workers: int = 32,
    http_get: Callable[..., Any] | None = None,
    resolver: WorkerUriResolver | None = None,
) -> CacheClearResult:
    """Synchronously clear the in-memory AsyncDataCache on every worker.

    Worker addresses come from the coordinator's ``/v1/node`` view. Before
    changing cache state, the function optionally verifies that every query in
    the coordinator's ``/v1/query`` view is terminal. This matters because the
    native clear operation evicts unpinned cache entries; an active query may
    retain pins and make a nominally cold benchmark only partly cold.

    Cache clears are issued concurrently, but this function does not return
    until every worker has replied. Any discovery, liveness, HTTP, or response
    validation failure raises ``CacheControlError``. The native endpoint
    returns HTTP 200 for some no-op responses, so the exact success body is
    required as well as a successful HTTP status.
    """

    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be greater than zero")
    if max_workers <= 0:
        raise ValueError("max_workers must be greater than zero")

    get = http_get or requests.get
    coordinator_uri = _coordinator_uri(hostname, port)

    if require_idle:
        _require_idle_cluster(coordinator_uri, get, timeout_seconds)

    nodes = _get_json(
        get,
        f"{coordinator_uri}/v1/node",
        timeout_seconds,
        "worker discovery",
    )
    advertised_worker_uris = _parse_worker_uris(nodes)
    uri_resolver = resolver or WorkerUriResolver()
    resolved_worker_uris = _resolve_worker_uris(advertised_worker_uris, uri_resolver)

    errors: list[tuple[str, str]] = []
    worker_count = min(max_workers, len(resolved_worker_uris))
    with ThreadPoolExecutor(max_workers=worker_count, thread_name_prefix="presto-cache-clear") as executor:
        futures = {
            executor.submit(
                _clear_worker_memory_cache,
                worker_uri,
                get,
                timeout_seconds,
            ): worker_uri
            for worker_uri in resolved_worker_uris
        }
        for future in as_completed(futures):
            worker_uri = futures[future]
            try:
                future.result()
            except Exception as error:  # Aggregate all workers deterministically.
                errors.append((worker_uri, str(error)))

    if errors:
        details = "\n".join(f"  {worker_uri}: {message}" for worker_uri, message in sorted(errors))
        raise CacheControlError(f"Failed to clear native-worker memory caches:\n{details}")

    # Catch a query that is still active after worker discovery or the clear
    # requests. This narrows the race window, but an exclusive cluster remains
    # required because this API cannot lock out other query submissions.
    if require_idle:
        _require_idle_cluster(coordinator_uri, get, timeout_seconds)

    return CacheClearResult(worker_uris=resolved_worker_uris)


def _coordinator_uri(hostname: str, port: int) -> str:
    if not hostname or not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        raise ValueError("hostname and a valid TCP port are required")
    rendered_host = hostname
    if ":" in hostname and not hostname.startswith("["):
        rendered_host = f"[{hostname}]"
    return f"http://{rendered_host}:{port}"


def _require_idle_cluster(
    coordinator_uri: str,
    get: Callable[..., Any],
    timeout_seconds: float,
) -> None:
    queries = _get_json(
        get,
        f"{coordinator_uri}/v1/query",
        timeout_seconds,
        "active-query check",
    )
    if not isinstance(queries, list):
        raise CacheControlError("Active-query check returned a non-list response")

    active_queries: list[tuple[str, str]] = []
    for index, query in enumerate(queries):
        if not isinstance(query, dict):
            raise CacheControlError(f"Active-query check returned a malformed entry at index {index}")
        query_id = query.get("queryId")
        state = query.get("state")
        if not isinstance(query_id, str) or not query_id or not isinstance(state, str) or not state:
            raise CacheControlError(f"Active-query check returned a malformed entry at index {index}")
        normalized_state = state.upper()
        if normalized_state not in _TERMINAL_QUERY_STATES:
            active_queries.append((query_id, normalized_state))

    if active_queries:
        details = ", ".join(f"{query_id} ({state})" for query_id, state in sorted(active_queries))
        raise CacheControlError("Refusing to clear native-worker memory caches while queries are active: " + details)


def _get_json(
    get: Callable[..., Any],
    url: str,
    timeout_seconds: float,
    operation: str,
) -> Any:
    try:
        response = get(url, timeout=timeout_seconds)
        response.raise_for_status()
        return response.json()
    except Exception as error:
        raise CacheControlError(f"Failed {operation} via {url}: {error}") from error


def _parse_worker_uris(nodes: Any) -> tuple[str, ...]:
    if not isinstance(nodes, list):
        raise CacheControlError("Worker discovery returned a non-list response")
    if not nodes:
        raise CacheControlError("Worker discovery returned no workers")

    worker_uris: set[str] = set()
    for index, node in enumerate(nodes):
        if not isinstance(node, dict):
            raise CacheControlError(f"Worker discovery returned a malformed entry at index {index}")
        uri = node.get("uri")
        if not isinstance(uri, str) or not uri:
            raise CacheControlError(f"Worker discovery entry at index {index} has no valid uri")
        try:
            worker_uris.add(_normalize_worker_uri(uri))
        except ValueError as error:
            raise CacheControlError(f"Worker discovery entry at index {index} has an invalid uri: {error}") from error

    return tuple(sorted(worker_uris))


def _resolve_worker_uris(
    worker_uris: tuple[str, ...],
    resolver: WorkerUriResolver,
) -> tuple[str, ...]:
    resolved: set[str] = set()
    failures: list[tuple[str, str]] = []
    for worker_uri in worker_uris:
        try:
            resolved.add(_normalize_worker_uri(resolver.resolve(worker_uri)))
        except Exception as error:
            failures.append((worker_uri, str(error)))

    if failures:
        details = "\n".join(f"  {worker_uri}: {message}" for worker_uri, message in sorted(failures))
        raise CacheControlError(f"Failed to resolve native-worker URIs:\n{details}")
    if not resolved:
        raise CacheControlError("Worker URI resolution returned no workers")
    return tuple(sorted(resolved))


def _normalize_worker_uri(uri: str) -> str:
    parsed = urlparse(uri)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError(f"unsupported scheme in {uri!r}")
    if not parsed.hostname or parsed.port is None:
        raise ValueError(f"host and port are required in {uri!r}")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError(f"user information is not allowed in {uri!r}")
    if parsed.query or parsed.fragment or parsed.params:
        raise ValueError(f"query, fragment, and path parameters are not allowed in {uri!r}")

    path = parsed.path.rstrip("/")
    if path not in {"", "/v1/status"}:
        raise ValueError(f"unexpected path {parsed.path!r} in {uri!r}")

    return urlunparse((parsed.scheme, parsed.netloc, "", "", "", ""))


def _clear_worker_memory_cache(
    worker_uri: str,
    get: Callable[..., Any],
    timeout_seconds: float,
) -> None:
    endpoint = f"{worker_uri}{_CLEAR_MEMORY_CACHE_PATH}"
    try:
        response = get(endpoint, timeout=timeout_seconds)
        response.raise_for_status()
    except Exception as error:
        raise CacheControlError(f"request to {endpoint} failed: {error}") from error

    body = response.text.strip()
    if body != _CLEAR_MEMORY_CACHE_SUCCESS:
        raise CacheControlError(
            f"request to {endpoint} returned unexpected response {body!r}; expected {_CLEAR_MEMORY_CACHE_SUCCESS!r}"
        )
