# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import prestodb
import pytest

from common.testing.performance_benchmarks.benchmark_keys import BenchmarkKeys
from common.testing.performance_benchmarks.profiler_utils import start_profiler, stop_profiler

from ..integration_tests.analyze_tables import check_tables_analyzed
from .cache_control import clear_worker_memory_caches
from .metrics_collector import collect_metrics
from .run_context import gather_run_context


def session_properties_from_config(config):
    properties = {}
    for item in config.getoption("--session-property") or []:
        if "=" not in item:
            pytest.exit(f"--session-property must be key=value, got {item!r}", returncode=1)
        key, value = item.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            pytest.exit(f"--session-property must have a non-empty key, got {item!r}", returncode=1)
        properties[key] = value
    return properties


@pytest.fixture(scope="session", autouse=True)
def run_context_collector(request):
    """Gather Presto-specific run context and attach it to the session.

    The common pytest_sessionfinish merges session.run_context into the
    benchmark_result.json context section.
    """
    hostname = request.config.getoption("--hostname")
    port = request.config.getoption("--port")
    user = request.config.getoption("--user")
    schema_name = request.config.getoption("--schema-name")
    scale_factor = request.config.getoption("--scale-factor")

    ctx = gather_run_context(
        hostname=hostname,
        port=port,
        user=user,
        schema_name=schema_name,
        scale_factor=scale_factor,
    )
    session_properties = session_properties_from_config(request.config)
    if session_properties:
        ctx["session_properties"] = session_properties
    cold = request.config.getoption("--cold")
    cold_every_iteration = request.config.getoption("--cold-every-iteration")
    if cold or cold_every_iteration:
        if ctx.get("engine") == "presto-java":
            pytest.exit(
                "Cold cache modes require native Presto workers with the Velox cache-control API.", returncode=1
            )
        ctx["cache_mode"] = "memory-cold-every-iteration" if cold_every_iteration else "memory-cold-first-iteration"
    ctx["timestamp"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    yield ctx
    request.session.run_context = ctx


@pytest.fixture(scope="session", autouse=True)
def verify_tables_analyzed(request):
    """Session-scoped setup that verifies ANALYZE TABLE has been run on all tables."""
    if request.config.getoption("--skip-analyze-check"):
        print("[Analyze] Skipping analyze check (--skip-analyze-check flag set).")
        return
    hostname = request.config.getoption("--hostname")
    port = request.config.getoption("--port")
    user = request.config.getoption("--user")
    schema = request.config.getoption("--schema-name")
    conn = prestodb.dbapi.connect(host=hostname, port=port, user=user, catalog="hive", schema=schema)
    cursor = conn.cursor()
    try:
        check_tables_analyzed(cursor, schema)
    except RuntimeError as e:
        pytest.exit(str(e), returncode=1)
    finally:
        cursor.close()
        conn.close()


@pytest.fixture(scope="module")
def presto_cursor(request):
    hostname = request.config.getoption("--hostname")
    port = request.config.getoption("--port")
    user = request.config.getoption("--user")
    schema = request.config.getoption("--schema-name")
    session_properties = session_properties_from_config(request.config)
    conn = prestodb.dbapi.connect(
        host=hostname,
        port=port,
        user=user,
        catalog="hive",
        schema=schema,
        session_properties=session_properties,
    )
    return conn.cursor()


@pytest.fixture(scope="module")
def benchmark_query(request, presto_cursor, benchmark_queries, benchmark_result_collector):
    iterations = request.config.getoption("--iterations")
    profile = request.config.getoption("--profile")
    profile_script_path = request.config.getoption("--profile-script-path")
    metrics = request.config.getoption("--metrics")
    cold = request.config.getoption("--cold")
    cold_every_iteration = request.config.getoption("--cold-every-iteration")
    benchmark_type = request.node.obj.BENCHMARK_TYPE
    bench_output_dir = request.config.getoption("--output-dir")
    hostname = request.config.getoption("--hostname")
    port = request.config.getoption("--port")

    if profile:
        assert profile_script_path is not None
        profile_output_dir_path = Path(f"{bench_output_dir}/profiles/{benchmark_type}")
        profile_output_dir_path.mkdir(parents=True, exist_ok=True)

    benchmark_result_collector[benchmark_type] = {
        BenchmarkKeys.RAW_TIMES_KEY: {},
        BenchmarkKeys.FAILED_QUERIES_KEY: {},
    }

    benchmark_dict = benchmark_result_collector[benchmark_type]
    raw_times_dict = benchmark_dict[BenchmarkKeys.RAW_TIMES_KEY]
    assert raw_times_dict == {}

    failed_queries_dict = benchmark_dict[BenchmarkKeys.FAILED_QUERIES_KEY]
    assert failed_queries_dict == {}

    def benchmark_query_function(query_id):
        profile_output_file_path = None
        try:
            if cold:
                clear_result = clear_worker_memory_caches(hostname=hostname, port=port)
                print(
                    f"[Cache] {benchmark_type} {query_id}: cleared "
                    f"{len(clear_result.worker_uris)} native-worker memory cache(s) before iteration 1/{iterations}."
                )
            if profile:
                # Base path without .nsys-rep extension: {dir}/{query_id}
                profile_output_file_path = f"{profile_output_dir_path.absolute()}/{query_id}"
                start_profiler(profile_script_path, profile_output_file_path)
            result = []
            for iteration_num in range(iterations):
                if cold_every_iteration:
                    clear_result = clear_worker_memory_caches(hostname=hostname, port=port)
                    print(
                        f"[Cache] {benchmark_type} {query_id} iteration {iteration_num + 1}/{iterations}: "
                        f"cleared {len(clear_result.worker_uris)} native-worker memory cache(s)."
                    )
                cursor = presto_cursor.execute(
                    "--" + str(benchmark_type) + "_" + str(query_id) + "--" + "\n" + benchmark_queries[query_id]
                )
                result.append(cursor.stats["elapsedTimeMillis"])

                # Save query results to Parquet (only on first iteration)
                if iteration_num == 0:
                    rows = cursor.fetchall()
                    columns = [desc[0] for desc in cursor.description]
                    df = pd.DataFrame(rows, columns=columns)

                    # Save to Parquet format to match expected results
                    results_dir = Path(f"{bench_output_dir}/query_results")
                    results_dir.mkdir(parents=True, exist_ok=True)
                    parquet_path = results_dir / f"{query_id.lower()}.parquet"
                    df.to_parquet(parquet_path, index=False)

                # Collect metrics after each query iteration if enabled
                if metrics:
                    presto_query_id = cursor._query.query_id
                    if presto_query_id:
                        collect_metrics(
                            query_id=presto_query_id,
                            query_name=str(query_id),
                            hostname=hostname,
                            port=port,
                            output_dir=bench_output_dir,
                        )
            raw_times_dict[query_id] = result
        except Exception as e:
            error_type = getattr(e, "error_type", type(e).__name__)
            error_name = getattr(e, "error_name", str(e))
            failed_queries_dict[query_id] = f"{error_type}: {error_name}"
            raw_times_dict[query_id] = None
            raise
        finally:
            if profile and profile_output_file_path is not None:
                stop_profiler(profile_script_path, profile_output_file_path)

    return benchmark_query_function
