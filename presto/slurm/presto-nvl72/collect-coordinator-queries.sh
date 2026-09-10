#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Collect retained Presto query JSON from a live Slurm benchmark coordinator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source ./defaults.env

PORT="${PORT:-${CLUSTER_DEFAULT_PORT:-9200}}"
OUT_DIR="${OUT_DIR:-result_dir/coordinator_queries}"
JOB_ID=""
SERVER=""

usage() {
    cat <<EOF
Usage: $0 <job_id> [-o output_dir] [-p port]
       $0 --server http://host:port [-o output_dir]

Fetches the coordinator's retained /v1/query list and one full
/v1/query/<query_id> JSON file per query into output_dir.

Defaults:
  output_dir: ${OUT_DIR}
  port:       ${PORT}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir)
            [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value" >&2; exit 2; }
            OUT_DIR="$2"
            shift 2
            ;;
        -p|--port)
            [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value" >&2; exit 2; }
            PORT="$2"
            shift 2
            ;;
        --server)
            [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value" >&2; exit 2; }
            SERVER="${2%/}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -z "${JOB_ID}" ]]; then
                JOB_ID="$1"
            else
                echo "Unexpected argument: $1" >&2
                usage >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [[ -z "${JOB_ID}" && -z "${SERVER}" ]]; then
    usage >&2
    exit 2
fi

if [[ -n "${JOB_ID}" ]]; then
    NODELIST="$(squeue -j "${JOB_ID}" -h -o '%N' | awk 'NR==1{print $1}')"
    if [[ -z "${NODELIST}" || "${NODELIST}" == "(null)" ]]; then
        echo "Could not find allocated nodes for job ${JOB_ID}. Is it still running?" >&2
        exit 1
    fi

    COORD="$(scontrol show hostnames "${NODELIST}" | head -1)"
    if [[ -z "${COORD}" ]]; then
        echo "Could not resolve coordinator node from node list: ${NODELIST}" >&2
        exit 1
    fi

    SERVER="http://${COORD}:${PORT}"
fi

mkdir -p "${OUT_DIR}/queries"

[[ -n "${JOB_ID}" ]] && echo "Job:         ${JOB_ID}"
[[ -n "${COORD:-}" ]] && echo "Coordinator: ${COORD}"
echo "Server:      ${SERVER}"
echo "Output:      ${OUT_DIR}"

fetch_from_coord() {
    local path="$1"
    if [[ -n "${JOB_ID}" ]]; then
        srun --jobid "${JOB_ID}" -w "${COORD}" --ntasks=1 --overlap \
            bash -lc "curl -fsS --max-time 30 '${SERVER}${path}'"
    else
        curl -fsS --max-time 30 "${SERVER}${path}"
    fi
}

echo "Fetching coordinator query list..."
fetch_from_coord "/v1/query" > "${OUT_DIR}/queries.json"
fetch_from_coord "/v1/info" > "${OUT_DIR}/info.json" || true
fetch_from_coord "/v1/node" > "${OUT_DIR}/nodes.json" || true

mapfile -t QUERY_IDS < <(
    python3 - "${OUT_DIR}/queries.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

for query in data:
    query_id = query.get("queryId")
    if query_id:
        print(query_id)
PY
)

if [[ "${#QUERY_IDS[@]}" -eq 0 ]]; then
    echo "No retained queries found in ${OUT_DIR}/queries.json"
    exit 0
fi

echo "Fetching ${#QUERY_IDS[@]} full query JSON file(s)..."
for query_id in "${QUERY_IDS[@]}"; do
    if fetch_from_coord "/v1/query/${query_id}" > "${OUT_DIR}/queries/${query_id}.json"; then
        echo "  ${query_id}"
    else
        echo "  ${query_id} (failed to fetch)" >&2
        rm -f "${OUT_DIR}/queries/${query_id}.json"
    fi
done

python3 - "${OUT_DIR}" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
summary_rows = [
    [
        "query_id",
        "state",
        "error_type",
        "error_name",
        "elapsed",
        "execution",
        "query_preview",
    ]
]

for path in sorted((out / "queries").glob("*.json")):
    with path.open() as f:
        query = json.load(f)

    stats = query.get("queryStats") or {}
    error_code = query.get("errorCode") or {}
    sql = (query.get("query") or "").replace("\n", " ")
    if len(sql) > 180:
        sql = sql[:177] + "..."

    summary_rows.append(
        [
            query.get("queryId", path.stem),
            query.get("state", ""),
            query.get("errorType", ""),
            error_code.get("name", ""),
            stats.get("elapsedTime", ""),
            stats.get("executionTime", ""),
            sql,
        ]
    )

    operators = stats.get("operatorSummaries") or []
    if operators:
        operators_dir = out / "operator_summaries"
        operators_dir.mkdir(exist_ok=True)
        with (operators_dir / f"{query.get('queryId', path.stem)}.operators.json").open("w") as f:
            json.dump(operators, f, indent=2)

with (out / "summary.tsv").open("w") as f:
    for row in summary_rows:
        f.write("\t".join(str(value) for value in row) + "\n")
PY

echo "Wrote:"
echo "  ${OUT_DIR}/queries.json"
echo "  ${OUT_DIR}/queries/*.json"
echo "  ${OUT_DIR}/operator_summaries/*.operators.json"
echo "  ${OUT_DIR}/summary.tsv"
