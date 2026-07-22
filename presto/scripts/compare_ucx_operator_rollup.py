#!/usr/bin/env python3
import argparse
import importlib.util
import json
from pathlib import Path


def load_fetch_ucx_stats():
    script = Path(__file__).with_name("fetch_ucx_stats.py")
    spec = importlib.util.spec_from_file_location("fetch_ucx_stats", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare operator rollups across two UCX stats run directories."
    )
    parser.add_argument("left", type=Path)
    parser.add_argument("right", type=Path)
    parser.add_argument("--left-label", default="left")
    parser.add_argument("--right-label", default="right")
    parser.add_argument(
        "--include-first",
        action="store_true",
        help="Include the first/lukewarm query in averages.",
    )
    parser.add_argument("--top", type=int, default=12)
    return parser.parse_args()


def load_run(path, stats_module):
    rows = []
    for query_path in sorted(path.glob("query_*.json")):
        with query_path.open() as stream:
            query = json.load(stream)
        execution_nanos = stats_module.parse_duration_nanos(
            query.get("queryStats", {}).get("executionTime")
        )
        rows.append(
            {
                "queryId": query.get("queryId"),
                "executionNanos": execution_nanos or 0,
                "operators": stats_module.summarize_operators(query),
            }
        )
    return rows


def average_run(rows, include_first):
    selected = rows if include_first or len(rows) <= 1 else rows[1:]
    operators = {}
    for row in selected:
        for name, item in row["operators"].items():
            entry = operators.setdefault(
                name,
                {
                    "wall": 0,
                    "blocked": 0,
                    "getOutput": 0,
                    "inputRows": 0,
                    "outputRows": 0,
                    "samples": 0,
                },
            )
            entry["wall"] += item["totalWallNanos"]
            entry["blocked"] += item["timeNanos"]["blockedWall"]
            entry["getOutput"] += item["timeNanos"]["getOutputWall"]
            entry["inputRows"] += item["numeric"]["inputPositions"]
            entry["outputRows"] += item["numeric"]["outputPositions"]
            entry["samples"] += 1

    for entry in operators.values():
        samples = entry.pop("samples")
        for key in entry:
            entry[key] /= samples

    execution = (
        sum(row["executionNanos"] for row in selected) / len(selected)
        if selected
        else 0
    )
    return execution, operators


def print_run(label, rows, execution, operators, top):
    print(f"\n== {label} ==")
    print(f"queries: {len(rows)}")
    print(
        "executionMs: "
        + ", ".join(f"{row['executionNanos'] / 1_000_000:.1f}" for row in rows)
    )
    print(f"avgExecutionMs: {execution / 1_000_000:.1f}")
    for name, item in sorted(
        operators.items(), key=lambda entry: entry[1]["wall"], reverse=True
    )[:top]:
        print(
            f"  {name:28s} "
            f"wallMs={item['wall'] / 1_000_000:9.1f} "
            f"blockedMs={item['blocked'] / 1_000_000:9.1f} "
            f"getOutputMs={item['getOutput'] / 1_000_000:8.1f} "
            f"inputRows={item['inputRows'] / 1_000_000:8.1f}M "
            f"outputRows={item['outputRows'] / 1_000_000:8.1f}M"
        )


def main():
    args = parse_args()
    stats_module = load_fetch_ucx_stats()
    left_rows = load_run(args.left, stats_module)
    right_rows = load_run(args.right, stats_module)
    left_execution, left_operators = average_run(left_rows, args.include_first)
    right_execution, right_operators = average_run(right_rows, args.include_first)

    print_run(args.left_label, left_rows, left_execution, left_operators, args.top)
    print_run(args.right_label, right_rows, right_execution, right_operators, args.top)

    print(f"\n== {args.left_label} - {args.right_label} avg wallMs ==")
    all_names = set(left_operators) | set(right_operators)
    for name in sorted(
        all_names,
        key=lambda item: left_operators.get(item, {}).get("wall", 0)
        - right_operators.get(item, {}).get("wall", 0),
        reverse=True,
    )[: args.top]:
        left_wall = left_operators.get(name, {}).get("wall", 0) / 1_000_000
        right_wall = right_operators.get(name, {}).get("wall", 0) / 1_000_000
        print(
            f"  {name:28s} "
            f"{args.left_label}={left_wall:9.1f} "
            f"{args.right_label}={right_wall:9.1f} "
            f"diff={left_wall - right_wall:9.1f}"
        )


if __name__ == "__main__":
    main()
