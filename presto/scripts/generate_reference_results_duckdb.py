#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

import argparse
import json
import re
import time
from pathlib import Path


TPCH_TABLES = (
    "customer",
    "lineitem",
    "nation",
    "orders",
    "part",
    "partsupp",
    "region",
    "supplier",
)


def quote_ident(identifier):
    return '"' + identifier.replace('"', '""') + '"'


def quote_string(value):
    return "'" + value.replace("'", "''") + "'"


def get_repo_root():
    return Path(__file__).resolve().parents[2]


def parse_query_ids(query_ids, available_queries):
    if not query_ids:
        return sorted(available_queries, key=lambda query_id: int(query_id[1:]))

    result = []
    for value in re.split(r"[,\s]+", query_ids.strip()):
        if not value:
            continue
        query_id = value.upper()
        if not query_id.startswith("Q"):
            query_id = f"Q{query_id}"
        if query_id not in available_queries:
            raise ValueError(f"Unknown query id '{value}'. Available queries: {', '.join(sorted(available_queries))}")
        result.append(query_id)
    return result


def load_queries(queries_file, scale_factor):
    with open(queries_file) as file:
        queries = json.load(file)

    # Match the Presto integration-test query transformations so generated
    # reference files can be consumed directly by run_integ_test.sh -r.
    if "Q11" in queries:
        queries["Q11"] = queries["Q11"].format(SF_FRACTION=f"{0.0001 / scale_factor:.12f}")
    if "Q15" in queries:
        queries["Q15"] = queries["Q15"].replace(" AS supplier_no", "").replace("supplier_no", "l_suppkey")

    return queries


def load_scale_factor(data_dir):
    metadata_file = data_dir / "metadata.json"
    if not metadata_file.is_file():
        raise FileNotFoundError(f"Expected metadata file at {metadata_file}")
    with open(metadata_file) as file:
        metadata = json.load(file)
    return float(metadata["scale_factor"])


def parquet_files_for_table(data_dir, table):
    table_dir = data_dir / table
    if not table_dir.is_dir():
        raise FileNotFoundError(f"Expected table directory at {table_dir}")
    files = sorted(table_dir.rglob("*.parquet"))
    if not files:
        raise FileNotFoundError(f"No parquet files found under {table_dir}")
    return files


def create_parquet_views(conn, data_dir):
    for table in TPCH_TABLES:
        files = parquet_files_for_table(data_dir, table)
        file_list = ", ".join(quote_string(str(path)) for path in files)
        conn.execute(
            f"""
            CREATE OR REPLACE VIEW {quote_ident(table)} AS
            SELECT * FROM read_parquet([{file_list}], hive_partitioning = false)
            """
        )
        print(f"Registered {table}: {len(files)} parquet file(s)")


def configure_duckdb(conn, args):
    if args.memory_limit:
        conn.execute(f"SET memory_limit = {quote_string(args.memory_limit)}")
    if args.temp_dir:
        args.temp_dir.mkdir(parents=True, exist_ok=True)
        conn.execute(f"SET temp_directory = {quote_string(str(args.temp_dir))}")
    if args.threads:
        conn.execute(f"PRAGMA threads={args.threads}")


def write_reference_results(conn, queries, query_ids, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    timings_ms = {}
    for query_id in query_ids:
        output_file = output_dir / f"{query_id.lower()}.parquet"
        if output_file.exists():
            output_file.unlink()

        print(f"Writing {query_id} -> {output_file}")
        start_time_ns = time.perf_counter_ns()
        conn.sql(queries[query_id]).write_parquet(str(output_file))
        elapsed_ms = (time.perf_counter_ns() - start_time_ns) / 1_000_000.0
        timings_ms[query_id] = round(elapsed_ms, 2)
        print(f"Finished {query_id} in {timings_ms[query_id]} ms")

    return timings_ms


def write_timing_summary(output_dir, data_dir, queries_file, scale_factor, query_ids, timings_ms, total_elapsed_ms):
    timing_file = output_dir / "reference_result_timings.json"
    timing_summary = {
        "context": {
            "data_dir": str(data_dir),
            "queries_file": str(queries_file),
            "scale_factor": scale_factor,
            "query_count": len(query_ids),
        },
        "raw_times_ms": timings_ms,
        "total_time_ms": round(total_elapsed_ms, 2),
    }
    with open(timing_file, "w") as file:
        json.dump(timing_summary, file, indent=2)
        file.write("\n")
    print(f"Timing summary written to {timing_file}")


def main():
    repo_root = get_repo_root()
    default_queries_file = repo_root / "common/testing/queries/tpch/queries.json"

    parser = argparse.ArgumentParser(
        description=(
            "Generate TPC-H reference result parquet files using DuckDB only. "
            "The output directory is suitable for run_integ_test.sh --reference-results-dir."
        )
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        required=True,
        help="TPC-H dataset directory containing customer/, lineitem/, metadata.json, etc.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Directory where q1.parquet, q2.parquet, ... reference files will be written.",
    )
    parser.add_argument(
        "--queries",
        help='Optional comma- or space-separated query list, for example "2,3,20". Default is all queries.',
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
    args = parser.parse_args()

    try:
        import duckdb
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "Error: missing Python dependency 'duckdb'. Install it with: python -m pip install duckdb==1.3.2"
        ) from exc

    data_dir = args.data_dir.resolve()
    output_dir = args.output_dir.resolve()

    scale_factor = load_scale_factor(data_dir)
    queries = load_queries(args.queries_file, scale_factor)
    query_ids = parse_query_ids(args.queries, set(queries))

    conn = duckdb.connect()
    total_start_time_ns = time.perf_counter_ns()
    configure_duckdb(conn, args)
    create_parquet_views(conn, data_dir)
    timings_ms = write_reference_results(conn, queries, query_ids, output_dir)
    total_elapsed_ms = (time.perf_counter_ns() - total_start_time_ns) / 1_000_000.0
    write_timing_summary(output_dir, data_dir, args.queries_file, scale_factor, query_ids, timings_ms, total_elapsed_ms)

    print(f"Reference results written to {output_dir}")
    print(f"Total elapsed time: {round(total_elapsed_ms, 2)} ms")


if __name__ == "__main__":
    main()
