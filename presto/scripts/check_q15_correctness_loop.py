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
    "tpch_sf1000_pr314_all/reference_results/q15.parquet"
)
DEFAULT_REFERENCE_CANDIDATES = [
    Path("/raid/khubert/home") / REFERENCE_SUFFIX,
    Path("/home/khubert") / REFERENCE_SUFFIX,
    Path.home() / REFERENCE_SUFFIX,
]


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Run TPC-H Q15 repeatedly through presto-cli and compare each "
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
        help="Output directory. Defaults to q15_correctness_runs/<UTC timestamp>.",
    )
    parser.add_argument(
        "--session-property",
        action="append",
        default=[],
        help="Additional presto-cli --session key=value. Can be repeated.",
    )
    parser.add_argument(
        "--ordered",
        action="store_true",
        help="Also require exact output order to match the reference.",
    )
    parser.add_argument(
        "--float-abs-tolerance",
        type=float,
        default=1e-6,
        help=(
            "Absolute tolerance for Q15 DOUBLE total_revenue comparison. "
            "Use 0 to require exact floating-point equality."
        ),
    )
    parser.add_argument(
        "--original-query",
        action="store_true",
        help=(
            "Run Q15 exactly as defined in queries.json instead of applying "
            "the compatibility rewrite for coordinators that do not allow "
            "GROUP BY on the CTE SELECT alias."
        ),
    )
    return parser.parse_args()


def load_query(path: Path, original_query: bool) -> str:
    queries = json.loads(path.read_text())
    query = queries["Q15"].strip().rstrip(";")
    if original_query:
        return query
    # Match presto/testing/common/fixtures.py: some coordinators do not allow
    # grouping by the CTE SELECT alias used in the canonical query JSON.
    return query.replace(" AS supplier_no", "").replace("supplier_no", "l_suppkey")


def load_reference(path: Path):
    table = pq.read_table(path).to_pandas()
    table = table[
        ["s_suppkey", "s_name", "s_address", "s_phone", "total_revenue"]
    ]
    rows = []
    for row in table.itertuples(index=False, name=None):
        rows.append(
            (
                int(row[0]),
                row[1],
                row[2],
                row[3],
                float(row[4]),
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
        "Could not find q15.parquet reference. Checked:\n  " + candidates)


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
        if len(fields) != 5:
            raise ValueError(f"Unexpected Q15 row width {len(fields)}: {line}")
        rows.append(
            (
                int(fields[0]),
                fields[1],
                fields[2],
                fields[3],
                float(fields[4]),
            )
        )
    return query_id, rows


def row_key(row):
    return row[:4]


def rows_match(actual, expected, float_abs_tolerance):
    return (
        row_key(actual) == row_key(expected)
        and abs(actual[4] - expected[4]) <= float_abs_tolerance
    )


def compare_rows(actual, expected, require_order, float_abs_tolerance):
    if require_order:
        missing = []
        extra = []
        if len(actual) != len(expected):
            missing = expected
            extra = actual
        else:
            for actual_row, expected_row in zip(actual, expected):
                if not rows_match(actual_row, expected_row, float_abs_tolerance):
                    missing.append(expected_row)
                    extra.append(actual_row)
        order_mismatch = False
        return missing, extra, order_mismatch

    unmatched_expected = list(expected)
    extra = []
    for actual_row in actual:
        match_index = next(
            (
                index
                for index, expected_row in enumerate(unmatched_expected)
                if rows_match(actual_row, expected_row, float_abs_tolerance)
            ),
            None,
        )
        if match_index is None:
            extra.append(actual_row)
        else:
            del unmatched_expected[match_index]

    missing = unmatched_expected
    order_mismatch = False
    return missing, extra, order_mismatch


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

    query = load_query(args.queries_json, args.original_query)
    reference = resolve_reference(args.reference)
    expected = load_reference(reference)

    timestamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out_dir = args.out or (Path("q15_correctness_runs") / timestamp)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "q15.sql").write_text(query + "\n")

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
    for prop in args.session_property:
        base_cmd.extend(["--session", prop])
    base_cmd.extend(["--execute", query])

    summary_rows = []
    failures = 0

    print(f"Output: {out_dir}")
    print(f"Reference: {reference}")
    print(f"Reference rows: {len(expected)}")
    print(f"Session properties: {args.session_property}")
    print(f"Query mode: {'original' if args.original_query else 'rewritten'}")
    sys.stdout.flush()

    for iteration in range(1, args.iterations + 1):
        started = time.monotonic()
        proc = subprocess.run(base_cmd, text=True, capture_output=True)
        elapsed_ms = int((time.monotonic() - started) * 1000)

        raw_path = out_dir / f"q15_run_{iteration:03d}.out"
        raw_path.write_text(proc.stdout + proc.stderr)

        if proc.returncode != 0:
            failures += 1
            print(
                f"FAIL {iteration:03d}: presto-cli exited "
                f"{proc.returncode} ({elapsed_ms} ms)"
            )
            summary_rows.append(
                [iteration, "", "ERROR", elapsed_ms, proc.returncode, "", ""])
            continue

        try:
            query_id, actual = parse_presto_cli_output(proc.stdout)
        except Exception as exc:
            failures += 1
            print(f"FAIL {iteration:03d}: could not parse output: {exc}")
            summary_rows.append(
                [iteration, "", "PARSE_ERROR", elapsed_ms, 0, "", ""])
            continue

        missing, extra, order_mismatch = compare_rows(
            actual, expected, args.ordered, args.float_abs_tolerance)
        if missing or extra:
            failures += 1
            diff_path = out_dir / f"q15_run_{iteration:03d}.diff"
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
        elif order_mismatch:
            failures += 1
            print(
                f"FAIL {iteration:03d}: {query_id} row set matches, "
                f"order differs ({elapsed_ms} ms)"
            )
            summary_rows.append(
                [iteration, query_id or "", "ORDER_MISMATCH", elapsed_ms, 0, 0, 0])
        else:
            print(
                f"PASS {iteration:03d}: {query_id} "
                f"rows={len(actual)} ({elapsed_ms} ms)"
            )
            summary_rows.append(
                [iteration, query_id or "", "PASS", elapsed_ms, 0, 0, 0])
        sys.stdout.flush()

    with (out_dir / "summary.csv").open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "iteration",
                "query_id",
                "status",
                "elapsed_ms",
                "returncode",
                "missing",
                "extra",
            ]
        )
        writer.writerows(summary_rows)

    if failures:
        print(f"FAILED: {failures}/{args.iterations} iteration(s). See {out_dir}")
        return 1

    print(f"PASSED: {args.iterations}/{args.iterations} iteration(s). See {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
