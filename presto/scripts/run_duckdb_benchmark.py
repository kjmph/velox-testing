#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

import argparse
import json
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path

from generate_reference_results_duckdb import (
    create_parquet_views,
    load_queries,
    load_scale_factor,
    parse_query_ids,
    quote_string,
)


def get_repo_root():
    return Path(__file__).resolve().parents[2]


def configure_duckdb(conn, args):
    if args.memory_limit:
        conn.execute(f"SET memory_limit = {quote_string(args.memory_limit)}")
    if args.temp_dir:
        args.temp_dir.mkdir(parents=True, exist_ok=True)
        conn.execute(f"SET temp_directory = {quote_string(str(args.temp_dir))}")
    if args.threads:
        conn.execute(f"PRAGMA threads={args.threads}")


def get_output_dir(args):
    output_dir = args.output_dir
    if args.tag:
        output_dir = output_dir / args.tag
    return output_dir.resolve()


def run_query_iterations(conn, query, iterations):
    timings = []
    for _ in range(iterations):
        start_time_ns = time.perf_counter_ns()
        conn.sql(query).fetchall()
        timings.append(round((time.perf_counter_ns() - start_time_ns) / 1_000_000.0, 2))
    return timings


def compute_aggregate_timings(raw_times, iterations):
    if iterations > 1:
        aggregate_keys = ["avg", "min", "max", "median", "geometric_mean", "lukewarm"]
    else:
        aggregate_keys = ["lukewarm"]

    aggregate_times = {key: {} for key in aggregate_keys}

    for query_id, timings in raw_times.items():
        if timings is None or any(timing is None for timing in timings):
            continue

        first_iteration = timings[0]
        if iterations > 1:
            hot_timings = timings[1:]
            stats = (
                round(statistics.mean(hot_timings), 2),
                min(hot_timings),
                max(hot_timings),
                statistics.median(hot_timings),
                round(statistics.geometric_mean(hot_timings), 2),
                first_iteration,
            )
        else:
            stats = (first_iteration,)

        for index, key in enumerate(aggregate_keys):
            aggregate_times[key][query_id] = stats[index]

    return aggregate_times


def write_text_summary(output_dir, benchmark_result, iterations):
    lines = []
    lines.append("------------------------------------------------ tpch DuckDB Benchmark Summary ------------------------------------------------")
    lines.append("")
    lines.append(f"Iterations Count: {iterations}")
    lines.append(f"Dataset Name: {benchmark_result['context']['dataset_name']}")
    if benchmark_result["context"].get("tag"):
        lines.append(f"Tag: {benchmark_result['context']['tag']}")
    lines.append("")

    raw_times = benchmark_result["tpch"]["raw_times_ms"]
    aggregate_times = benchmark_result["tpch"]["agg_times_ms"]
    if iterations > 1:
        headers = [
            ("avg", "Avg Hot(ms)"),
            ("min", "Min Hot(ms)"),
            ("max", "Max Hot(ms)"),
            ("median", "Median Hot(ms)"),
            ("geometric_mean", "GMean Hot(ms)"),
            ("lukewarm", "Lukewarm(ms)"),
        ]
    else:
        headers = [("lukewarm", "Lukewarm(ms)")]

    width = max(len(label) for _, label in headers) + 2
    header = " Query ID "
    for _, label in headers:
        header += f"|{label:^{width}}"
    lines.append("-" * len(header))
    lines.append(header)
    lines.append("-" * len(header))

    for query_id in sorted(raw_times, key=lambda name: int(name[1:])):
        line = f"{query_id:^10}"
        for key, _ in headers:
            value = aggregate_times[key].get(query_id)
            line += f"|{str(value if value is not None else 'NULL'):^{width}}"
        lines.append(line)

    output_file = output_dir / "benchmark_result.txt"
    output_file.write_text("\n".join(lines) + "\n")


def write_benchmark_result(output_dir, args, scale_factor, raw_times, failed_queries, duckdb_version):
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    result = {
        "context": {
            "iterations_count": args.iterations,
            "dataset_name": args.data_dir.name,
            "data_dir": str(args.data_dir.resolve()),
            "benchmark": ["tpch"],
            "timestamp": timestamp,
            "engine": args.engine,
            "kind": args.kind,
            "scale_factor": scale_factor,
            "worker_count": 1,
            "node_count": 1,
            "gpu_count": 0,
            "duckdb_version": duckdb_version,
            "image_digest": args.identifier_hash or f"duckdb-{duckdb_version}",
        },
        "tpch": {
            "agg_times_ms": compute_aggregate_timings(raw_times, args.iterations),
            "raw_times_ms": raw_times,
            "failed_queries": failed_queries,
        },
    }

    if args.tag:
        result["context"]["tag"] = args.tag
    if args.threads:
        result["context"]["threads"] = args.threads
    if args.memory_limit:
        result["context"]["memory_limit"] = args.memory_limit
    if args.temp_dir:
        result["context"]["temp_dir"] = str(args.temp_dir.resolve())

    with open(output_dir / "benchmark_result.json", "w") as file:
        json.dump(result, file, indent=2, allow_nan=False)
        file.write("\n")

    write_text_summary(output_dir, result, args.iterations)


def validate_args(args):
    if args.iterations < 1:
        raise ValueError("--iterations must be at least 1")
    if args.tag and not args.tag.replace("_", "").isalnum():
        raise ValueError("--tag must contain only alphanumeric and underscore characters")


def main():
    repo_root = get_repo_root()
    default_queries_file = repo_root / "common/testing/queries/tpch/queries.json"

    parser = argparse.ArgumentParser(
        description="Run TPC-H benchmarks with DuckDB and write benchmark_result.json compatible with post_results.py."
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        required=True,
        help="TPC-H dataset directory containing customer/, lineitem/, metadata.json, etc.",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        default=Path("benchmark_output"),
        help='Directory for benchmark_result.json and benchmark_result.txt. Default: "benchmark_output".',
    )
    parser.add_argument(
        "-q",
        "--queries",
        help='Optional comma- or space-separated query list, for example "2,3,20". Default is all queries.',
    )
    parser.add_argument(
        "-i",
        "--iterations",
        type=int,
        default=5,
        help="Number of query run iterations. Default: 5.",
    )
    parser.add_argument(
        "-t",
        "--tag",
        help="Optional tag. When set, results are written under output-dir/tag.",
    )
    parser.add_argument(
        "--queries-file",
        type=Path,
        default=default_queries_file,
        help=f"Query JSON file to use. Default: {default_queries_file}",
    )
    parser.add_argument(
        "--memory-limit",
        help='Optional DuckDB memory limit, for example "256GB". DuckDB can spill to --temp-dir when needed.',
    )
    parser.add_argument(
        "--temp-dir",
        type=Path,
        help="Optional DuckDB temporary directory for spilling large queries.",
    )
    parser.add_argument(
        "--threads",
        type=int,
        help="Optional DuckDB worker thread count.",
    )
    parser.add_argument(
        "--engine",
        default="duckdb",
        help='Engine name to write into benchmark_result.json context. Default: "duckdb".',
    )
    parser.add_argument(
        "--kind",
        default="cpu",
        help='Engine kind to write into benchmark_result.json context. Default: "cpu".',
    )
    parser.add_argument(
        "--identifier-hash",
        help="Optional identifier stored as context.image_digest so post_results.py can use it by default. "
        "Default: duckdb-<version>.",
    )
    args = parser.parse_args()
    validate_args(args)

    try:
        import duckdb
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "Error: missing Python dependency 'duckdb'. Install it with: python -m pip install duckdb==1.3.2"
        ) from exc

    scale_factor = load_scale_factor(args.data_dir)
    queries = load_queries(args.queries_file, scale_factor)
    query_ids = parse_query_ids(args.queries, set(queries))
    output_dir = get_output_dir(args)

    conn = duckdb.connect()
    configure_duckdb(conn, args)
    create_parquet_views(conn, args.data_dir.resolve())

    raw_times = {}
    failed_queries = {}
    for query_id in query_ids:
        print(f"Running {query_id} ({args.iterations} iteration(s))")
        try:
            timings = run_query_iterations(conn, queries[query_id], args.iterations)
            raw_times[query_id] = timings
            print(f"Finished {query_id}: {timings}")
        except Exception as exc:
            raw_times[query_id] = [None] * args.iterations
            failed_queries[query_id] = f"{type(exc).__name__}: {exc}"
            print(f"Failed {query_id}: {failed_queries[query_id]}")

    write_benchmark_result(output_dir, args, scale_factor, raw_times, failed_queries, duckdb.__version__)
    print(f"Benchmark results written to {output_dir}")

    if failed_queries:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
