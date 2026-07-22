#!/usr/bin/env python3
import argparse
import csv
import json
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

import pyarrow.parquet as pq


DEFAULT_QUERY_PATH = (
    Path(__file__).resolve().parents[2]
    / "common/testing/queries/tpch/queries.json"
)
REFERENCE_SUFFIX = (
    "projects/presto_routing/reference_results/"
    "tpch_sf1000_pr314_all/reference_results/q18.parquet"
)
DEFAULT_REFERENCE_CANDIDATES = [
    Path("/raid/khubert/home") / REFERENCE_SUFFIX,
    Path("/home/khubert") / REFERENCE_SUFFIX,
    Path.home() / REFERENCE_SUFFIX,
]
DEFAULT_SESSIONS = [
    "default_filter_factor_enabled=false",
    "joins_not_null_inference_strategy=NONE",
    "hive.file_splittable=true",
    "hive.max_split_size=1GB",
    "hive.max_initial_split_size=1GB",
]
OLD_DEFAULT_SESSIONS = []


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Run TPC-H Q18 repeatedly through presto-cli and compare each "
            "result with a saved DuckDB parquet reference."
        )
    )
    parser.add_argument("-n", "--iterations", type=int, default=50)
    parser.add_argument("--catalog", default="hive")
    parser.add_argument("--schema", default="tpch_sf1000_pr314")
    parser.add_argument("--container", default="presto-coordinator")
    parser.add_argument("--queries-json", type=Path, default=DEFAULT_QUERY_PATH)
    parser.add_argument(
        "--reference",
        type=Path,
        default=None,
        help="DuckDB reference parquet. Defaults to the known host/container reference locations.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output directory. Defaults to q18_correctness_runs/<UTC timestamp>.",
    )
    parser.add_argument(
        "--session-property",
        action="append",
        default=[],
        help="Additional presto-cli --session key=value. Can be repeated.",
    )
    parser.add_argument(
        "--no-default-session-properties",
        action="store_true",
        help="Do not include the GPU investigation session properties by default.",
    )
    parser.add_argument(
        "--ordered",
        action="store_true",
        help="Also require exact output order to match the reference.",
    )
    return parser.parse_args()


def load_query(path: Path) -> str:
    queries = json.loads(path.read_text())
    return queries["Q18"].strip().rstrip(";")


def load_reference(path: Path):
    table = pq.read_table(path).to_pandas()
    table.columns = [
        "c_name",
        "c_custkey",
        "o_orderkey",
        "o_orderdate",
        "o_totalprice",
        "sum_l_quantity",
    ]
    table["o_orderdate"] = table["o_orderdate"].astype(str)
    rows = []
    for row in table.itertuples(index=False, name=None):
        rows.append(
            (
                row[0],
                int(row[1]),
                int(row[2]),
                row[3],
                float(row[4]),
                float(row[5]),
            )
        )
    return rows


def resolve_reference(explicit_path):
    if explicit_path is not None:
        return explicit_path
    for candidate in DEFAULT_REFERENCE_CANDIDATES:
        if candidate.exists():
            return candidate
    candidates = "\n  ".join(str(path) for path in DEFAULT_REFERENCE_CANDIDATES)
    raise FileNotFoundError(
        "Could not find q18.parquet reference. Checked:\n  " + candidates)


def parse_presto_cli_output(output: str):
    rows = []
    query_id = None
    for line in output.splitlines():
        if line.startswith("Running "):
            query_id = line.split()[1].strip()
            continue
        if not line.startswith('"'):
            continue
        fields = next(csv.reader([line]))
        if len(fields) != 6:
            raise ValueError(f"Unexpected Q18 row width {len(fields)}: {line}")
        rows.append(
            (
                fields[0],
                int(fields[1]),
                int(fields[2]),
                fields[3],
                float(fields[4]),
                float(fields[5]),
            )
        )
    return query_id, rows


def compare_rows(actual, expected, require_order):
    actual_counter = Counter(actual)
    expected_counter = Counter(expected)
    missing = list((expected_counter - actual_counter).elements())
    extra = list((actual_counter - expected_counter).elements())
    ordered_mismatch = require_order and actual == expected
    return missing, extra, ordered_mismatch


def write_diff(path: Path, missing, extra):
    with path.open("w") as out:
        out.write("missing_from_actual\n")
        for row in missing:
            out.write(repr(row) + "\n")
        out.write("\nextra_in_actual\n")
        for row in extra:
            out.write(repr(row) + "\n")


def main():
    args = parse_args()
    if args.iterations <= 0:
        raise SystemExit("--iterations must be > 0")

    query = load_query(args.queries_json)
    reference = resolve_reference(args.reference)
    expected = load_reference(reference)

    timestamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out_dir = args.out or (Path("q18_correctness_runs") / timestamp)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "q18.sql").write_text(query + "\n")

    session_props = []
    if not args.no_default_session_properties:
        session_props.extend(DEFAULT_SESSIONS)
    session_props.extend(args.session_property)

    base_cmd = [
        "docker",
        "exec",
        "-i",
        args.container,
        "presto-cli",
        "--catalog",
        args.catalog,
        "--schema",
        args.schema,
    ]
    for prop in session_props:
        base_cmd.extend(["--session", prop])
    base_cmd.extend(["--execute", query])

    summary_rows = []
    failures = 0

    print(f"Output: {out_dir}")
    print(f"Reference: {reference}")
    print(f"Reference rows: {len(expected)}")
    print(f"Session properties: {session_props}")
    sys.stdout.flush()

    for iteration in range(1, args.iterations + 1):
        started = time.monotonic()
        proc = subprocess.run(base_cmd, text=True, capture_output=True)
        elapsed_ms = int((time.monotonic() - started) * 1000)

        raw_path = out_dir / f"q18_run_{iteration:03d}.out"
        raw_path.write_text(proc.stdout + proc.stderr)

        if proc.returncode != 0:
            failures += 1
            print(f"FAIL {iteration:03d}: presto-cli exited {proc.returncode} ({elapsed_ms} ms)")
            summary_rows.append([iteration, "", "ERROR", elapsed_ms, proc.returncode, "", ""])
            continue

        try:
            query_id, actual = parse_presto_cli_output(proc.stdout)
        except Exception as exc:
            failures += 1
            print(f"FAIL {iteration:03d}: could not parse output: {exc}")
            summary_rows.append([iteration, "", "PARSE_ERROR", elapsed_ms, 0, "", ""])
            continue

        missing, extra, ordered_ok = compare_rows(actual, expected, args.ordered)
        if missing or extra:
            failures += 1
            diff_path = out_dir / f"q18_run_{iteration:03d}.diff"
            write_diff(diff_path, missing, extra)
            print(
                f"FAIL {iteration:03d}: {query_id} rows={len(actual)} "
                f"missing={len(missing)} extra={len(extra)} ({elapsed_ms} ms)"
            )
            summary_rows.append(
                [
                    iteration,
                    query_id or "",
                    "MISMATCH",
                    elapsed_ms,
                    0,
                    len(missing),
                    len(extra),
                ]
            )
        elif args.ordered and not ordered_ok:
            failures += 1
            print(f"FAIL {iteration:03d}: {query_id} row set matches, order differs ({elapsed_ms} ms)")
            summary_rows.append([iteration, query_id or "", "ORDER_MISMATCH", elapsed_ms, 0, 0, 0])
        else:
            print(f"PASS {iteration:03d}: {query_id} rows={len(actual)} ({elapsed_ms} ms)")
            summary_rows.append([iteration, query_id or "", "PASS", elapsed_ms, 0, 0, 0])
        sys.stdout.flush()

    with (out_dir / "summary.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["iteration", "query_id", "status", "elapsed_ms", "returncode", "missing", "extra"])
        writer.writerows(summary_rows)

    if failures:
        print(f"FAILED: {failures}/{args.iterations} iteration(s). See {out_dir}")
        return 1

    print(f"PASSED: {args.iterations}/{args.iterations} iteration(s). See {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
