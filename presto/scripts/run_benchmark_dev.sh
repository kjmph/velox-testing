#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOGS_DIR="${LOGS_DIR:-${SCRIPT_DIR}/presto_logs}"
export LOGS_DIR

# shellcheck source=presto_connection_defaults.sh
source "${SCRIPT_DIR}/presto_connection_defaults.sh"

print_help() {
  cat << EOF

Usage: $0 [OPTIONS]

Runs Presto benchmarks like run_benchmark.sh, but keeps a persistent Python
virtual environment in .venv-bench by default and never deletes it on exit.

OPTIONS:
    -h, --help              Show this help message.
    -b, --benchmark-type    Type of benchmark to run. Only "tpch" and "tpcds" are currently supported.
    -q, --queries           Comma-separated query numbers. Defaults to all benchmark queries.
    --queries-file          Path to a custom JSON query definition file. Defaults to the canonical
                            common/testing/queries/<benchmark>/queries.json.
    -H, --hostname          Hostname of the Presto coordinator.
    --port                  Port number of the Presto coordinator.
    -u, --user              User who queries will be executed as.
    -s, --schema-name       Name of the schema containing the benchmark tables.
    -f, --scale-factor      Scale factor of the benchmark data.
    -o, --output-dir        Directory for benchmark output files.
    -i, --iterations        Number of query run iterations. Default is 5.
    -t, --tag               Output tag. Must contain only alphanumeric and underscore characters.
    --session-property      Presto session property as key=value. May be repeated.
    -p, --profile           Enable profiling of benchmark queries.
    --skip-drop-cache       Skip dropping system caches before each benchmark query.
    --skip-analyze-check    Skip checking that ANALYZE TABLE has been run on all tables.
    -m, --metrics           Collect detailed metrics from Presto REST API after each query.
    -v, --verbose           Print debug logs for worker/engine detection.

ENVIRONMENT:
    PRESTO_BENCH_VENV_DIR   Override the persistent venv directory.

EOF
}

BENCHMARK_TYPE=""
SCHEMA_NAME=""
SCALE_FACTOR=""
QUERIES=""
QUERIES_FILE=""
HOST_NAME=""
PORT=""
USER_NAME=""
OUTPUT_DIR=""
ITERATIONS=""
TAG=""
PROFILE=false
SKIP_DROP_CACHE=false
SKIP_ANALYZE_CHECK=false
METRICS=false
SESSION_PROPERTIES=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      print_help
      exit 0
      ;;
    -b|--benchmark-type)
      BENCHMARK_TYPE=${2:?Error: --benchmark-type requires a value}
      shift 2
      ;;
    -q|--queries)
      QUERIES=${2:?Error: --queries requires a value}
      shift 2
      ;;
    --queries-file)
      QUERIES_FILE=${2:?Error: --queries-file requires a value}
      shift 2
      ;;
    -H|--hostname)
      HOST_NAME=${2:?Error: --hostname requires a value}
      shift 2
      ;;
    --port)
      PORT=${2:?Error: --port requires a value}
      shift 2
      ;;
    -u|--user)
      USER_NAME=${2:?Error: --user requires a value}
      shift 2
      ;;
    -s|--schema-name)
      SCHEMA_NAME=${2:?Error: --schema-name requires a value}
      shift 2
      ;;
    -f|--scale-factor)
      SCALE_FACTOR=${2:?Error: --scale-factor requires a value}
      shift 2
      ;;
    -o|--output-dir)
      OUTPUT_DIR=${2:?Error: --output-dir requires a value}
      shift 2
      ;;
    -i|--iterations)
      ITERATIONS=${2:?Error: --iterations requires a value}
      shift 2
      ;;
    -t|--tag)
      TAG=${2:?Error: --tag requires a value}
      shift 2
      ;;
    --session-property)
      SESSION_PROPERTY=${2:?Error: --session-property requires key=value}
      if [[ ${SESSION_PROPERTY} != *=* || ${SESSION_PROPERTY} == =* ]]; then
        echo "Error: --session-property must be key=value, got '${SESSION_PROPERTY}'" >&2
        exit 1
      fi
      SESSION_PROPERTIES+=("${SESSION_PROPERTY}")
      shift 2
      ;;
    -p|--profile)
      PROFILE=true
      shift
      ;;
    --skip-drop-cache)
      SKIP_DROP_CACHE=true
      shift
      ;;
    --skip-analyze-check)
      SKIP_ANALYZE_CHECK=true
      shift
      ;;
    -m|--metrics)
      METRICS=true
      shift
      ;;
    -v|--verbose)
      export PRESTO_BENCHMARK_DEBUG=1
      shift
      ;;
    *)
      echo "Error: Unknown argument $1" >&2
      print_help
      exit 1
      ;;
  esac
done

if [[ -z ${BENCHMARK_TYPE} || ! ${BENCHMARK_TYPE} =~ ^tpc(h|ds)$ ]]; then
  echo "Error: A valid benchmark type (tpch or tpcds) is required." >&2
  print_help
  exit 1
fi

if [[ -z ${SCHEMA_NAME} ]]; then
  echo "Error: A schema name must be set." >&2
  print_help
  exit 1
fi

set_presto_coordinator_defaults

PYTEST_ARGS=(--schema-name "$SCHEMA_NAME")

[[ -n ${SCALE_FACTOR} ]] && PYTEST_ARGS+=(--scale-factor "$SCALE_FACTOR")
[[ -n ${QUERIES} ]] && PYTEST_ARGS+=(--queries "$QUERIES")
[[ -n ${QUERIES_FILE} ]] && PYTEST_ARGS+=(--queries-file "$QUERIES_FILE")
[[ -n ${HOST_NAME} ]] && PYTEST_ARGS+=(--hostname "$HOST_NAME")
[[ -n ${PORT} ]] && PYTEST_ARGS+=(--port "$PORT")
[[ -n ${USER_NAME} ]] && PYTEST_ARGS+=(--user "$USER_NAME")
[[ -n ${OUTPUT_DIR} ]] && PYTEST_ARGS+=(--output-dir "$OUTPUT_DIR")
[[ -n ${ITERATIONS} ]] && PYTEST_ARGS+=(--iterations "$ITERATIONS")
for SESSION_PROPERTY in "${SESSION_PROPERTIES[@]}"; do
  PYTEST_ARGS+=(--session-property "$SESSION_PROPERTY")
done

if [[ -n ${TAG} ]]; then
  if [[ ! ${TAG} =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo "Error: Invalid --tag value. Tags must contain only alphanumeric and underscore characters." >&2
    exit 1
  fi
  PYTEST_ARGS+=(--tag "$TAG")
fi

if [[ "${PROFILE}" == "true" ]]; then
  PYTEST_ARGS+=(--profile --profile-script-path "$(readlink -f "${SCRIPT_DIR}/profiler_functions.sh")")
fi

[[ "${METRICS}" == "true" ]] && PYTEST_ARGS+=(--metrics)
[[ "${SKIP_DROP_CACHE}" == "true" ]] && PYTEST_ARGS+=(--skip-drop-cache)
[[ "${SKIP_ANALYZE_CHECK}" == "true" ]] && PYTEST_ARGS+=(--skip-analyze-check)

# shellcheck source=../../scripts/dev_python_env.sh
source "${REPO_ROOT}/scripts/dev_python_env.sh"

TEST_DIR="$(readlink -f "${SCRIPT_DIR}/../testing")"
VENV_DIR="${PRESTO_BENCH_VENV_DIR:-${SCRIPT_DIR}/.venv-bench}"
dev_python_activate "$VENV_DIR" "${TEST_DIR}/requirements.txt"
if [[ "${PRESTO_BENCHMARK_DEBUG:-}" == "1" || "${DEBUG:-}" == "1" ]]; then
  echo "Using benchmark Python: $(python -c 'import sys; print(sys.executable)')"
fi

# shellcheck source=common_functions.sh
source "${SCRIPT_DIR}/common_functions.sh"
wait_for_worker_node_registration "$HOST_NAME" "$PORT"

if [[ -z "${PRESTO_IMAGE_TAG:-}" ]]; then
  export PRESTO_IMAGE_TAG="${USER:-latest}"
fi
echo "Using PRESTO_IMAGE_TAG: $PRESTO_IMAGE_TAG"

BENCHMARK_TEST_DIR="${TEST_DIR}/performance_benchmarks"
python -m pytest -q -s "${BENCHMARK_TEST_DIR}/${BENCHMARK_TYPE}_test.py" "${PYTEST_ARGS[@]}"
