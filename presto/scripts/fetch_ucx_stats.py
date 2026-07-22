#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import time
import urllib.request
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


DEFAULT_NEEDLES = (
    "ucx",
    "peakbytes",
    "peakqueued",
    "peakreserved",
    "peakinflight",
    "receivehighwater",
    "receivelowwater",
    "receivedtable",
    "bytesqueued",
    "bytesinflight",
    "bytesreserved",
    "rttperrequest",
)

KNOWN_METRICS = (
    "ucxExchangeClient.peakBytes",
    "ucxExchangeClient.peakQueuedBytes",
    "ucxExchangeClient.peakReservedBytes",
    "ucxExchangeClient.peakInFlightBytes",
    "ucxExchangeClient.queuedBytes",
    "ucxExchangeClient.reservedBytes",
    "ucxExchangeClient.inFlightBytes",
    "ucxExchangeClient.retainedBytes",
    "ucxExchangeClient.receiveHighWaterBytes",
    "ucxExchangeClient.receiveLowWaterBytes",
    "ucxExchangeClient.receivePipelineTableLimit",
    "ucxExchangeClient.numReceivedTables",
    "ucxExchangeClient.peakQueuedTables",
    "ucxExchangeClient.inFlightTables",
    "ucxExchangeClient.averageReceivedTableBytes",
    "ucxExchangeSource.numPackedColumns",
    "ucxExchangeSource.totalBytes",
    "ucxExchangeSource.rttPerRequest",
    "ucxCpuRowExchangeClient.peakBytes",
    "ucxCpuRowExchangeClient.numReceivedPayloads",
    "ucxCpuRowExchangeClient.peakQueuedPayloads",
    "ucxCpuRowExchangeClient.maxQueuedPayloads",
    "ucxCpuRowExchangeClient.averageReceivedPayloadBytes",
    "ucxCpuRowExchangeSource.numPayloads",
    "ucxCpuRowExchangeSource.totalBytes",
    "ucxCpuRowExchangeSource.rttPerRequest",
)

TIME_UNITS_TO_NANOS = {
    "ns": 1,
    "us": 1_000,
    "ms": 1_000_000,
    "s": 1_000_000_000,
    "m": 60_000_000_000,
    "h": 3_600_000_000_000,
}

OPERATOR_TIME_FIELDS = (
    "addInputWall",
    "blockedWall",
    "finishWall",
    "getOutputWall",
    "isBlockedWall",
)

OPERATOR_NUMERIC_FIELDS = (
    "addInputCalls",
    "finishCalls",
    "getOutputCalls",
    "inputDataSizeInBytes",
    "inputPositions",
    "outputDataSizeInBytes",
    "outputPositions",
    "rawInputDataSizeInBytes",
    "rawInputPositions",
    "totalDrivers",
)

OPERATOR_MAX_FIELDS = (
    "peakSystemMemoryReservationInBytes",
    "peakTotalMemoryReservationInBytes",
    "peakUserMemoryReservationInBytes",
)


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Fetch UCX exchange runtime stats from Presto query/task JSON and "
            "write a compact timestamped capture directory."
        )
    )
    parser.add_argument(
        "--coordinator",
        default="http://localhost:8080",
        help="Coordinator base URL.",
    )
    parser.add_argument(
        "--query-id",
        action="append",
        default=[],
        help="Query ID to capture. Can be repeated or comma-separated.",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Capture all queries returned by /v1/query instead of TPC-H-looking queries.",
    )
    parser.add_argument(
        "--latest",
        type=int,
        default=0,
        help="Only capture the latest N selected queries.",
    )
    parser.add_argument(
        "--include-raw",
        action="store_true",
        help="Also write raw query and task JSON files. This can be large.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output directory. Defaults to ucx_stats_runs/<UTC timestamp>.",
    )
    parser.add_argument(
        "--task-url-mode",
        choices=("auto", "original", "docker-ip"),
        default="auto",
        help=(
            "How to fetch worker task URLs. auto/docker-ip rewrites "
            "localhost:100NN or presto-native-worker-gpu-N URLs to the "
            "container IP discovered with docker inspect. original uses the "
            "coordinator-provided URL unchanged."
        ),
    )
    parser.add_argument(
        "--worker-container-prefix",
        default="presto-native-worker-gpu-",
        help="Container name prefix for split GPU worker containers.",
    )
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument(
        "--max-print",
        type=int,
        default=40,
        help="Maximum metric rows to print to stdout.",
    )
    return parser.parse_args()


def get_json(url, timeout):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.load(response)


def worker_id_from_url(url, worker_container_prefix):
    parts = urlsplit(url)
    host = parts.hostname or ""
    if host.startswith(worker_container_prefix):
        suffix = host[len(worker_container_prefix) :]
        if suffix.isdigit():
            return int(suffix)

    # In split-worker GPU runs, worker N's HTTP port is 100<N>0.
    if host in ("localhost", "127.0.0.1") and parts.port is not None:
        if parts.port >= 10000 and (parts.port - 10000) % 10 == 0:
            return (parts.port - 10000) // 10

    return None


def docker_container_ip(container_name):
    try:
        result = subprocess.run(
            [
                "docker",
                "inspect",
                "-f",
                "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                container_name,
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None

    # docker inspect can concatenate IPs if a container is attached to multiple
    # networks. Pick the first IPv4-looking address.
    match = re.search(r"\d+\.\d+\.\d+\.\d+", result.stdout)
    return match.group(0) if match else None


class TaskUrlResolver:
    def __init__(self, mode, worker_container_prefix):
        self.mode = mode
        self.worker_container_prefix = worker_container_prefix
        self.container_ip_cache = {}

    def resolve(self, url):
        if self.mode == "original":
            return url

        worker_id = worker_id_from_url(url, self.worker_container_prefix)
        if worker_id is None:
            return url

        container_names = [
            f"{self.worker_container_prefix}{worker_id}",
            self.worker_container_prefix.rstrip("-"),
        ]
        container_ip = None
        for container_name in container_names:
            if container_name not in self.container_ip_cache:
                self.container_ip_cache[container_name] = docker_container_ip(
                    container_name
                )
            container_ip = self.container_ip_cache[container_name]
            if container_ip:
                break

        if not container_ip:
            return url

        parts = urlsplit(url)
        netloc = f"{container_ip}:{parts.port}" if parts.port else container_ip
        return urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))


def collect_task_urls(obj, out):
    if isinstance(obj, dict):
        for value in obj.values():
            collect_task_urls(value, out)
    elif isinstance(obj, list):
        for value in obj:
            collect_task_urls(value, out)
    elif isinstance(obj, str) and "/v1/task/" in obj:
        out.add(obj)


def walk_matches(obj, path, needles, out):
    if isinstance(obj, dict):
        for key, value in obj.items():
            key_text = str(key)
            lower = key_text.lower()
            if any(needle in lower for needle in needles):
                out.append({"path": f"{path}.{key_text}", "value": value})
            walk_matches(value, f"{path}.{key_text}", needles, out)
    elif isinstance(obj, list):
        for index, value in enumerate(obj):
            walk_matches(value, f"{path}[{index}]", needles, out)


def metric_name(path):
    for metric in KNOWN_METRICS:
        if metric in path:
            return metric
    return None


def metric_number(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value
    if not isinstance(value, dict):
        return None

    # RuntimeMetric JSON usually has sum/count/min/max. Keep the full value in
    # matches.json; use sum for a stable compact roll-up here.
    for key in ("sum", "value", "max", "count"):
        candidate = value.get(key)
        if isinstance(candidate, (int, float)) and not isinstance(candidate, bool):
            return candidate
    return None


def parse_duration_nanos(value):
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z]+)\s*", value)
    if not match:
        return None
    multiplier = TIME_UNITS_TO_NANOS.get(match.group(2))
    if multiplier is None:
        return None
    return int(float(match.group(1)) * multiplier)


def unit_for(value):
    if isinstance(value, dict):
        return value.get("unit", "")
    return ""


def collect_stage_operator_summaries(stage, out):
    if not isinstance(stage, dict):
        return
    execution_info = stage.get("latestAttemptExecutionInfo") or {}
    stats = execution_info.get("stats") or {}
    for summary in stats.get("operatorSummaries") or []:
        if isinstance(summary, dict):
            out.append(summary)
    for sub_stage in stage.get("subStages") or []:
        collect_stage_operator_summaries(sub_stage, out)


def summarize_operators(query_info):
    summaries = []
    collect_stage_operator_summaries(query_info.get("outputStage"), summaries)
    rollup = defaultdict(
        lambda: {
            "samples": 0,
            "planNodeIds": [],
            "timeNanos": {field: 0 for field in OPERATOR_TIME_FIELDS},
            "numeric": {field: 0 for field in OPERATOR_NUMERIC_FIELDS},
            "max": {field: None for field in OPERATOR_MAX_FIELDS},
        }
    )

    for summary in summaries:
        operator_type = summary.get("operatorType") or "(unknown)"
        item = rollup[operator_type]
        item["samples"] += 1
        plan_node_id = summary.get("planNodeId")
        if plan_node_id is not None:
            item["planNodeIds"].append(str(plan_node_id))

        for field in OPERATOR_TIME_FIELDS:
            nanos = parse_duration_nanos(summary.get(field))
            if nanos is not None:
                item["timeNanos"][field] += nanos

        for field in OPERATOR_NUMERIC_FIELDS:
            value = summary.get(field)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                item["numeric"][field] += value

        for field in OPERATOR_MAX_FIELDS:
            value = summary.get(field)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                previous = item["max"][field]
                item["max"][field] = value if previous is None else max(previous, value)

    result = {}
    for operator_type, item in sorted(rollup.items()):
        item["planNodeIds"] = sorted(set(item["planNodeIds"]))
        item["totalWallNanos"] = sum(item["timeNanos"].values())
        result[operator_type] = item
    return result


def select_queries(queries, query_ids, capture_all, latest):
    if query_ids:
        wanted = set()
        for item in query_ids:
            wanted.update(part for part in item.split(",") if part)
        selected = [query for query in queries if query.get("queryId") in wanted]
    elif capture_all:
        selected = list(queries)
    else:
        selected = [
            query
            for query in queries
            if "--tpch_Q" in query.get("query", "")
            or "tpch" in query.get("query", "").lower()
        ]

    selected.sort(key=lambda query: query.get("queryId", ""))
    if latest > 0:
        selected = selected[-latest:]
    return selected


def summarize_matches(matches):
    rollup = defaultdict(
        lambda: {
            "samples": 0,
            "numeric_sum": 0,
            "numeric_max": None,
            "unit": "",
        }
    )
    for match in matches:
        name = metric_name(match["path"])
        if not name:
            continue
        value = metric_number(match["value"])
        item = rollup[name]
        item["samples"] += 1
        item["unit"] = item["unit"] or unit_for(match["value"])
        if value is not None:
            item["numeric_sum"] += value
            item["numeric_max"] = value if item["numeric_max"] is None else max(
                item["numeric_max"], value
            )
    return dict(sorted(rollup.items()))


def write_text_summary(path, capture):
    lines = []
    lines.append(f"Output: {capture['output']}")
    lines.append(f"Coordinator: {capture['coordinator']}")
    lines.append(f"Task URL mode: {capture['taskUrlMode']}")
    lines.append("")
    lines.append("Queries:")
    for query in capture["queries"]:
        text = query.get("query", "").replace("\n", " ")[:100]
        lines.append(f"  {query['queryId']} {query.get('state')} {text}")
    lines.append("")

    for query_id, query_capture in capture["captures"].items():
        lines.append(f"=== {query_id} ===")
        lines.append(f"taskUrls={len(query_capture['taskUrls'])}")
        if query_capture["taskFetchFailures"]:
            lines.append("taskFetchFailures:")
            for failure in query_capture["taskFetchFailures"]:
                fetch_url = failure.get("fetchUrl")
                via = f" via {fetch_url}" if fetch_url and fetch_url != failure["url"] else ""
                lines.append(f"  {failure['url']}{via} {failure['error']}")
        lines.append(f"matches={len(query_capture['matches'])}")
        if query_capture["operatorRollup"]:
            lines.append("operator rollup:")
            ranked_operators = sorted(
                query_capture["operatorRollup"].items(),
                key=lambda item: item[1]["totalWallNanos"],
                reverse=True,
            )
            for name, item in ranked_operators[:12]:
                numeric = item["numeric"]
                time_nanos = item["timeNanos"]
                lines.append(
                    f"  {name}: samples={item['samples']} "
                    f"wallMs={item['totalWallNanos'] / 1_000_000:.2f} "
                    f"blockedMs={time_nanos['blockedWall'] / 1_000_000:.2f} "
                    f"getOutputMs={time_nanos['getOutputWall'] / 1_000_000:.2f} "
                    f"inputRows={numeric['inputPositions']} "
                    f"outputRows={numeric['outputPositions']} "
                    f"inputBytes={numeric['inputDataSizeInBytes']}"
                )
        lines.append("metric rollup:")
        for name, item in query_capture["metricRollup"].items():
            unit = f" {item['unit']}" if item["unit"] else ""
            max_value = item["numeric_max"]
            lines.append(
                f"  {name}: samples={item['samples']} "
                f"sum={item['numeric_sum']}{unit} max={max_value}{unit}"
            )
        lines.append("")

    path.write_text("\n".join(lines) + "\n")


def main():
    args = parse_args()
    timestamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out_dir = args.out or (Path("ucx_stats_runs") / timestamp)
    out_dir.mkdir(parents=True, exist_ok=True)

    needles = tuple(needle.lower() for needle in DEFAULT_NEEDLES)
    task_url_resolver = TaskUrlResolver(
        args.task_url_mode, args.worker_container_prefix
    )
    queries = get_json(f"{args.coordinator}/v1/query", args.timeout)
    selected = select_queries(queries, args.query_id, args.all, args.latest)

    capture = {
        "output": str(out_dir),
        "coordinator": args.coordinator,
        "taskUrlMode": args.task_url_mode,
        "queries": [
            {
                "queryId": query.get("queryId"),
                "state": query.get("state"),
                "query": query.get("query", ""),
            }
            for query in selected
        ],
        "captures": {},
    }

    for query in selected:
        query_id = query["queryId"]
        query_info = get_json(f"{args.coordinator}/v1/query/{query_id}", args.timeout)
        if args.include_raw:
            (out_dir / f"query_{query_id}.json").write_text(
                json.dumps(query_info, indent=2, sort_keys=True)
            )

        matches = []
        walk_matches(query_info, f"query:{query_id}", needles, matches)

        task_urls = set()
        collect_task_urls(query_info, task_urls)

        task_failures = []
        resolved_task_urls = []
        for index, url in enumerate(sorted(task_urls)):
            fetch_url = task_url_resolver.resolve(url)
            resolved_task_urls.append({"url": url, "fetchUrl": fetch_url})
            try:
                task_info = get_json(fetch_url, args.timeout)
            except Exception as exc:
                task_failures.append(
                    {"url": url, "fetchUrl": fetch_url, "error": repr(exc)}
                )
                continue
            if args.include_raw:
                (out_dir / f"task_{query_id}_{index:03d}.json").write_text(
                    json.dumps(task_info, indent=2, sort_keys=True)
                )
            walk_matches(task_info, f"task:{query_id}:{fetch_url}", needles, matches)

        capture["captures"][query_id] = {
            "taskUrls": sorted(task_urls),
            "resolvedTaskUrls": resolved_task_urls,
            "taskFetchFailures": task_failures,
            "matches": matches,
            "operatorRollup": summarize_operators(query_info),
            "metricRollup": summarize_matches(matches),
        }

    (out_dir / "matches.json").write_text(json.dumps(capture, indent=2, sort_keys=True))
    summary = {
        "output": str(out_dir),
        "coordinator": args.coordinator,
        "taskUrlMode": args.task_url_mode,
        "queryIds": [query["queryId"] for query in capture["queries"]],
        "captures": {
            query_id: {
                "taskUrls": len(query_capture["taskUrls"]),
                "taskFetchFailures": query_capture["taskFetchFailures"],
                "matches": len(query_capture["matches"]),
                "operatorRollup": query_capture["operatorRollup"],
                "metricRollup": query_capture["metricRollup"],
            }
            for query_id, query_capture in capture["captures"].items()
        },
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
    write_text_summary(out_dir / "summary.txt", capture)

    print(f"Output: {out_dir}")
    print(f"Queries: {', '.join(summary['queryIds']) or '(none)'}")
    printed = 0
    for query_id, item in summary["captures"].items():
        print(
            f"{query_id}: tasks={item['taskUrls']} "
            f"matches={item['matches']} failures={len(item['taskFetchFailures'])}"
        )
        for name, operator in sorted(
            item["operatorRollup"].items(),
            key=lambda entry: entry[1]["totalWallNanos"],
            reverse=True,
        )[:5]:
            numeric = operator["numeric"]
            time_nanos = operator["timeNanos"]
            print(
                f"  op {name}: wallMs={operator['totalWallNanos'] / 1_000_000:.2f} "
                f"blockedMs={time_nanos['blockedWall'] / 1_000_000:.2f} "
                f"getOutputMs={time_nanos['getOutputWall'] / 1_000_000:.2f} "
                f"inputRows={numeric['inputPositions']} "
                f"outputRows={numeric['outputPositions']}"
            )
        for name, metric in item["metricRollup"].items():
            if printed >= args.max_print:
                continue
            unit = f" {metric['unit']}" if metric["unit"] else ""
            print(
                f"  {name}: samples={metric['samples']} "
                f"sum={metric['numeric_sum']}{unit} "
                f"max={metric['numeric_max']}{unit}"
            )
            printed += 1
    if printed >= args.max_print:
        print(f"... stdout truncated at --max-print={args.max_print}; see summary.txt")


if __name__ == "__main__":
    main()
