#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# ==============================================================================
# Presto TPC-H Benchmark Launcher
# ==============================================================================
# Submits a Presto TPC-H benchmark job to Slurm.  Cluster-specific values
# (partition, time limits, image names, etc.) are read from ~/.cluster_config.env
# (or the path in $CLUSTER_CONFIG).  See cluster_config.env.example.
#
# Usage:
#   ./launch-run.sh -n|--nodes <count> -s|--scale-factor <sf>
#                  [-i|--iterations <n>] [--cpu] [-g|--num-workers-per-node <n>]
#                  [-w|--worker-image <name>] [-c|--coord-image <name>]
#                  [-o|--output-path <dir>] [-q|--queries <filter>]
#                  [--queries-file <path>]
#                  [--dedicated-coordinator]
#                  [--verify-cpu-ucx]
#                  [--legacy-cpu-numa]
#                  [--disable-gds] [-m|--metrics] [-p|--profile] [--perf]
#                  [additional sbatch options]
# ==============================================================================

set -e

# Change to script directory
cd "$(dirname "$0")"

source ./defaults.env
source ./launcher_common.sh

NODES_SPEC=""
NODE_COUNTS=()
SCALE_FACTOR=""
NUM_ITERATIONS="2"
EXTRA_ARGS=()
NUM_GPUS_PER_NODE=""   # resolved from cluster config after arg parsing
USE_NUMA=""            # resolved from cluster config after arg parsing
VARIANT_TYPE=""        # set by --cpu; resolved from cluster config after arg parsing
WORKER_IMAGE=""        # resolved from cluster config after arg parsing; override with -w
COORD_IMAGE=""         # resolved from cluster config after arg parsing; override with -c
OUTPUT_PATH=""
SCRIPT_DIR="$PWD"
# WORKER_ENV_FILE defaults to ${SCRIPT_DIR}/worker.env via launcher_common.sh.
# Override with --worker-env-file <path> below.
ENABLE_GDS=1
ENABLE_METRICS=0
ENABLE_NSYS=0
ENABLE_PERF=0
NSYS_WORKER_IDS="0"
PROFILE_ITERATIONS=""    # comma-separated iter indices; empty = combined per query
NSYS_LAUNCH_OPTS="-t nvtx,cuda"   # trace flags passed to `nsys launch`
PERF_WORKER_ID=0
PERF_FREQUENCY="${PERF_FREQUENCY:-19}"
PERF_EVENT="${PERF_EVENT:-cpu-clock:u}"
PERF_CALL_GRAPH="${PERF_CALL_GRAPH:-dwarf,8192}"
PERF_USER_REGS="${PERF_USER_REGS:-auto}"
PERF_NOFILE_LIMIT="${PERF_NOFILE_LIMIT:-65536}"
PERF_THREADS_PER_SHARD="${PERF_THREADS_PER_SHARD:-128}"
PERF_RECORD_STOP_TIMEOUT="${PERF_RECORD_STOP_TIMEOUT:-120}"
PERF_POSTPROCESS="${PERF_POSTPROCESS:-0}"
PERF_FINALIZE_TIMEOUT="${PERF_FINALIZE_TIMEOUT:-0}"
QUERIES=""
QUERIES_FILE=""
CONFIG_OVERRIDES=""
# Deliberately CLI-only. A stale exported VERIFY_CPU_UCX must not silently turn
# verification on in a later run; --verify-cpu-ucx below is the only enabler.
VERIFY_CPU_UCX=0
LEGACY_CPU_NUMA=0
DEDICATED_COORDINATOR=0
SWEEP_INTER_RUN_SLEEP="${SWEEP_INTER_RUN_SLEEP:-90}"

# Set only while a submitted job may still be queued or running. The SIGINT
# handler uses these globals to offer a safe cancellation before the launcher
# exits instead of silently orphaning the Slurm job.
ACTIVE_JOB_ID=""
ACTIVE_RUN_INDEX=""
ACTIVE_WORKER_NODES=""
ACTIVE_ALLOCATED_NODES=""
ACTIVE_RESULT_DIR=""

usage() {
    cat <<EOF
Usage: $0 -n <nodes> -s <sf> [OPTIONS] [-- <additional sbatch options>]

Submits a Presto TPC-H benchmark job to Slurm.

Required:
  -n, --nodes <count[,count...]>  Worker-node count, or a comma-separated
                                  sweep run sequentially (e.g. 1,2,4,8)
  -s, --scale-factor <sf>      TPC-H scale factor (e.g. 100, 1000, 3000)

Options:
  -i, --iterations <n>         Iterations per query (default: ${NUM_ITERATIONS})
  -g, --num-workers-per-node <n>  Override workers per node from cluster config
  -w, --worker-image <name>    Override worker image from cluster config
  -c, --coord-image <name>     Override coordinator image from cluster config
  -o, --output-path <dir>      Copy results into this directory after the run
  -q, --queries <list>         Comma-separated query filter (e.g. "1,6,21")
      --queries-file <path>    Custom JSON query file passed to run_benchmark.sh
      --worker-env-file <path> Override worker.env (default: ./worker.env)
      --dedicated-coordinator  Allocate one additional node for the coordinator.
                               Slurm selects it automatically as the first host;
                               each -n count remains worker hosts only.
      --verify-cpu-ucx         Assert every CPU UCX listener is ready before
                               queries; for multi-worker runs, also assert that
                               a query uses CPU UCX replacement operators.
                               Enables UCX diagnostics.
      --config-overrides <s>   Semicolon-separated property overrides applied
                               after generate_configs (e.g.
                               "task.max-drivers-per-task=8;cudf.batch_size_min_threshold=200000")
      --cpu                    Use CPU partition/images (overrides cluster default)
      --gpu                    Use GPU partition/images (overrides cluster default)
      --numa                   Enable NUMA pinning for workers
      --no-numa                Disable NUMA pinning for workers
      --legacy-cpu-numa        Reproduce the old one-worker CPU NUMA mismatch:
                               bind execution/memory to node 0 while sizing the
                               worker for the full host. CPU -g 1 only.
      --disable-gds            Disable GPU Direct Storage
  -m, --metrics                Enable metrics collection
  -p, --profile                Enable nsys profiling
      --perf                   Sample worker 0 with host perf during each
                               selected query/profile iteration. Captures raw
                               perf.data plus a portable symfs under
                               result_dir_<jobid>/profiles/perf/worker_0/.
      --perf-frequency <hz>    Sampling frequency (default: ${PERF_FREQUENCY})
      --perf-event <event>     perf event (default: ${PERF_EVENT})
      --perf-call-graph <mode> perf call-graph mode (default: ${PERF_CALL_GRAPH})
      --perf-user-regs <regs>  Registers passed to perf --user-regs, or
                               'auto'/'perf-default' (default: ${PERF_USER_REGS})
      --perf-nofile-limit <n>  Minimum host perf soft nofile limit
                               (default: ${PERF_NOFILE_LIMIT})
      --perf-threads-per-shard <n>
                               Maximum target TIDs assigned to one perf
                               recorder (default: ${PERF_THREADS_PER_SHARD})
      --perf-record-stop-timeout <seconds>
                               Maximum time for perf record to flush and stop
                               after a query (default:
                               ${PERF_RECORD_STOP_TIMEOUT})
      --perf-postprocess       Generate reports and flamegraphs after all raw
                               captures are published. By default this expensive
                               work is deferred to process-perf-captures.sh.
      --perf-finalize-timeout <seconds>
                               Maximum wait for post-suite artifact publication;
                               0 uses the Slurm job time limit (default:
                               ${PERF_FINALIZE_TIMEOUT})
      --nsys-worker-ids <list> Worker IDs to profile: comma list (e.g. "0,3,5") or
                               'all' to profile every worker (default: ${NSYS_WORKER_IDS})
      --nsys-worker-id <n>     Alias for --nsys-worker-ids accepting a single ID
      --profile-iterations <list>
                               Comma-separated 0-based iteration indices to
                               profile separately (e.g. "1" to skip iteration
                               0, or "0,1" to capture both). Applies to nsys
                               and perf. When unset, one capture spans every
                               iteration of each selected query.
      --nsys-launch-opts <str> Options passed to \`nsys launch\` controlling
                               what is traced. Default: "-t nvtx,cuda".
                               Examples:
                                 "-t nvtx,cuda,osrt"       (add OS runtime)
                                 "-t nvtx,ucx,osrt --sample=process-tree --backtrace=dwarf"
                                 "-t nvtx,cuda --gpu-metrics-device=all"
                                 "-t nvtx,cuda --cuda-memory-usage=true"
  -h, --help                   Show this help message and exit

Any arguments after -- are passed directly to sbatch.
Node/GPU allocation overrides (--nodes/-N, --gres, and --gpus/-G)
are rejected there; use this launcher's -n and -g options so prompts and
recorded allocation metadata remain accurate.

Cluster config (~/.cluster_config.env or \$CLUSTER_CONFIG) supplies partition,
account, time limits, image names, and per-variant defaults. See
cluster_config.env.example.

Before submission, the launcher compares each requested allocation (including
the extra dedicated coordinator) with currently IDLE eligible nodes. A scalar
shortfall prompts before queueing; a comma-separated sweep skips that entry.
Ctrl-C while a job is live offers to cancel it before exiting.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--nodes)               requires_value "$1" "${2:-}"; NODES_SPEC="$2"; shift 2 ;;
        -s|--scale-factor)        requires_value "$1" "${2:-}"; SCALE_FACTOR="$2"; shift 2 ;;
        -i|--iterations)          requires_value "$1" "${2:-}"; NUM_ITERATIONS="$2"; shift 2 ;;
        -g|--num-workers-per-node) requires_value "$1" "${2:-}"; NUM_GPUS_PER_NODE="$2"; shift 2 ;;
        -w|--worker-image)        requires_value "$1" "${2:-}"; WORKER_IMAGE="$2"; shift 2 ;;
        -c|--coord-image)         requires_value "$1" "${2:-}"; COORD_IMAGE="$2"; shift 2 ;;
        -o|--output-path)         requires_value "$1" "${2:-}"; OUTPUT_PATH="$2"; shift 2 ;;
        -q|--queries)             requires_value "$1" "${2:-}"; QUERIES="$2"; shift 2 ;;
        --queries-file)           requires_value "$1" "${2:-}"; QUERIES_FILE="$2"; shift 2 ;;
        --worker-env-file)        requires_value "$1" "${2:-}"; WORKER_ENV_FILE="$2"; shift 2 ;;
        --dedicated-coordinator)  DEDICATED_COORDINATOR=1; shift ;;
        --verify-cpu-ucx)         VERIFY_CPU_UCX=1; shift ;;
        --config-overrides)       requires_value "$1" "${2:-}"; CONFIG_OVERRIDES="$2"; shift 2 ;;
        --nsys-worker-id)         requires_value "$1" "${2:-}"; NSYS_WORKER_IDS="$2"; shift 2 ;;
        --nsys-worker-ids)        requires_value "$1" "${2:-}"; NSYS_WORKER_IDS="$2"; shift 2 ;;
        --profile-iterations)     requires_value "$1" "${2:-}"; PROFILE_ITERATIONS="$2"; shift 2 ;;
        --nsys-launch-opts)
            # Can't use requires_value here — it disallows dash-prefixed values,
            # but valid nsys flags like "-t nvtx,ucx --sample=process-tree" start with -.
            [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value" >&2; exit 1; }
            NSYS_LAUNCH_OPTS="$2"; shift 2 ;;
        --cpu)         VARIANT_TYPE="cpu"; shift ;;
        --gpu)         VARIANT_TYPE="gpu"; shift ;;
        --numa)        USE_NUMA="1"; shift ;;
        --no-numa)     USE_NUMA="0"; shift ;;
        --legacy-cpu-numa)
            LEGACY_CPU_NUMA=1
            USE_NUMA=1
            shift
            ;;
        --disable-gds) ENABLE_GDS=0; shift ;;
        -m|--metrics)  ENABLE_METRICS=1; shift ;;
        -p|--profile)  ENABLE_NSYS=1; shift ;;
        --perf)        ENABLE_PERF=1; shift ;;
        --perf-frequency) requires_value "$1" "${2:-}"; PERF_FREQUENCY="$2"; shift 2 ;;
        --perf-event)     requires_value "$1" "${2:-}"; PERF_EVENT="$2"; shift 2 ;;
        --perf-call-graph)
            [[ -n "${2:-}" ]] || { echo "Error: $1 requires a value" >&2; exit 1; }
            PERF_CALL_GRAPH="$2"; shift 2 ;;
        --perf-user-regs)
            requires_value "$1" "${2:-}"
            PERF_USER_REGS="$2"; shift 2 ;;
        --perf-nofile-limit)
            requires_value "$1" "${2:-}"
            PERF_NOFILE_LIMIT="$2"; shift 2 ;;
        --perf-threads-per-shard)
            requires_value "$1" "${2:-}"
            PERF_THREADS_PER_SHARD="$2"; shift 2 ;;
        --perf-record-stop-timeout)
            requires_value "$1" "${2:-}"
            PERF_RECORD_STOP_TIMEOUT="$2"; shift 2 ;;
        --perf-postprocess) PERF_POSTPROCESS=1; shift ;;
        --perf-finalize-timeout)
            requires_value "$1" "${2:-}"
            PERF_FINALIZE_TIMEOUT="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        --) shift; break ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done
# Arguments after an explicit -- are always raw sbatch options. Unknown options
# before -- retain the launcher's historical pass-through behavior above.
EXTRA_ARGS+=("$@")

# -n/-g are the launcher-owned resource interfaces. Raw Slurm node/GPU
# overrides would make the actual allocation disagree with prompts, worker
# topology, and metadata.
for raw_sbatch_arg in "${EXTRA_ARGS[@]}"; do
    case "${raw_sbatch_arg}" in
        --nodes|--nodes=*|-N|-N?*|--gres|--gres=*|--gpus|--gpus=*|--gpus-per-node|--gpus-per-node=*|-G|-G?*)
            echo "Error: raw sbatch resource option '${raw_sbatch_arg}' is not allowed; use -n and -g so allocation metadata remains accurate" >&2
            exit 1
            ;;
    esac
done
unset raw_sbatch_arg

[[ -z "${NODES_SPEC}"  ]] && { echo "Error: -n|--nodes is required (see --help)" >&2; exit 1; }
[[ -z "${SCALE_FACTOR}" ]] && { echo "Error: -s|--scale-factor is required (see --help)" >&2; exit 1; }
if ! parse_positive_integer_csv "${NODES_SPEC}" NODE_COUNTS; then
    echo "Error: -n|--nodes must be a positive integer or comma-separated list of positive integers; got '${NODES_SPEC}'" >&2
    echo "       Examples: -n 13  or  -n 1,2,4,8" >&2
    exit 1
fi
SWEEP_MODE=0
(( ${#NODE_COUNTS[@]} > 1 )) && SWEEP_MODE=1
if ! [[ "${DEDICATED_COORDINATOR}" =~ ^[01]$ ]]; then
    echo "Error: DEDICATED_COORDINATOR must be 0 or 1; got '${DEDICATED_COORDINATOR}'" >&2
    exit 1
fi
if [[ -n "${PROFILE_ITERATIONS}" ]] && ! [[ "${PROFILE_ITERATIONS}" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    echo "Error: --profile-iterations expects a comma-separated list of 0-based ints; got '${PROFILE_ITERATIONS}'" >&2
    exit 1
fi
if [[ "${ENABLE_NSYS}" == "1" && "${ENABLE_PERF}" == "1" ]]; then
    echo "Error: --profile (nsys) and --perf must run in separate jobs" >&2
    exit 1
fi
if [[ "${PERF_POSTPROCESS}" == "1" && "${ENABLE_PERF}" != "1" ]]; then
    echo "Error: --perf-postprocess requires --perf" >&2
    exit 1
fi
if ! [[ "${PERF_FREQUENCY}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --perf-frequency must be a positive integer; got '${PERF_FREQUENCY}'" >&2
    exit 1
fi
if ! [[ "${PERF_NOFILE_LIMIT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --perf-nofile-limit must be a positive integer; got '${PERF_NOFILE_LIMIT}'" >&2
    exit 1
fi
if ! [[ "${PERF_THREADS_PER_SHARD}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --perf-threads-per-shard must be a positive integer; got '${PERF_THREADS_PER_SHARD}'" >&2
    exit 1
fi
if ! [[ "${PERF_RECORD_STOP_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --perf-record-stop-timeout must be a positive integer; got '${PERF_RECORD_STOP_TIMEOUT}'" >&2
    exit 1
fi
if ! [[ "${PERF_POSTPROCESS}" =~ ^[01]$ ]]; then
    echo "Error: PERF_POSTPROCESS must be 0 or 1; got '${PERF_POSTPROCESS}'" >&2
    exit 1
fi
if ! [[ "${PERF_FINALIZE_TIMEOUT}" =~ ^[0-9]+$ ]]; then
    echo "Error: --perf-finalize-timeout must be a non-negative integer; got '${PERF_FINALIZE_TIMEOUT}'" >&2
    exit 1
fi
if ! [[ "${SWEEP_INTER_RUN_SLEEP}" =~ ^[0-9]+$ ]]; then
    echo "Error: SWEEP_INTER_RUN_SLEEP must be a non-negative integer; got '${SWEEP_INTER_RUN_SLEEP}'" >&2
    exit 1
fi
if [[ -n "${PROFILE_ITERATIONS}" ]]; then
    IFS=',' read -ra _profile_iteration_list <<< "${PROFILE_ITERATIONS}"
    for _profile_iteration in "${_profile_iteration_list[@]}"; do
        if (( _profile_iteration >= NUM_ITERATIONS )); then
            echo "Error: profile iteration ${_profile_iteration} is outside -i ${NUM_ITERATIONS} (indices are 0-based)" >&2
            exit 1
        fi
    done
    unset _profile_iteration _profile_iteration_list
fi

echo "Submitting Presto TPC-H benchmark job..."
echo ""

# Resolve variant-specific cluster values now that VARIANT_TYPE is known.
# Default falls through CLUSTER_DEFAULT_VARIANT (set in ~/.cluster_config.env)
# to "gpu" so existing GPU-cluster users see no change.
VARIANT_TYPE="${VARIANT_TYPE:-${CLUSTER_DEFAULT_VARIANT:-gpu}}"
resolve_cluster_variant "${VARIANT_TYPE}"
: "${NUM_GPUS_PER_NODE:=${CLUSTER_NUM_WORKERS_PER_NODE:-}}"
: "${USE_NUMA:=${CLUSTER_USE_NUMA:-0}}"

if [[ ! "${LEGACY_CPU_NUMA}" =~ ^[01]$ ]]; then
    echo "Error: LEGACY_CPU_NUMA must be 0 or 1; got '${LEGACY_CPU_NUMA}'" >&2
    exit 1
fi
if [[ "${LEGACY_CPU_NUMA}" == "1" ]]; then
    [[ "${VARIANT_TYPE}" == "cpu" ]] || {
        echo "Error: --legacy-cpu-numa requires --cpu" >&2
        exit 1
    }
    [[ "${USE_NUMA}" == "1" ]] || {
        echo "Error: --legacy-cpu-numa conflicts with --no-numa" >&2
        exit 1
    }
    [[ "${NUM_GPUS_PER_NODE}" == "1" ]] || {
        echo "Error: --legacy-cpu-numa is intentionally limited to -g 1" >&2
        exit 1
    }
    echo "WARNING: legacy CPU NUMA reproduction enabled."
    echo "         The worker will bind to CPU/DRAM node 0 but retain full-host"
    echo "         CPU and memory sizing. This intentionally oversubscribes its affinity."
fi

# GDS is a GPU-only data path. CPU launches should not require --disable-gds
# and should never expose cufile settings to a CPU worker image.
if [[ "${VARIANT_TYPE}" == "cpu" ]]; then
    ENABLE_GDS=0
fi

if [[ "${VERIFY_CPU_UCX}" == "1" ]]; then
    [[ "${VARIANT_TYPE}" == "cpu" ]] || { echo "Error: --verify-cpu-ucx requires --cpu" >&2; exit 1; }
    export UCX_LOG_LEVEL="${UCX_LOG_LEVEL:-info}"
    export UCX_PROTO_INFO="${UCX_PROTO_INFO:-y}"
fi

# Keep the requested profiler selector intact. In a node-count sweep, "all"
# expands to a different worker-ID range for each individual run.
NSYS_WORKER_IDS_REQUESTED="${NSYS_WORKER_IDS}"

if [[ "${SWEEP_MODE}" == "1" ]]; then
    echo "Node-count sweep enabled: ${NODES_SPEC} worker nodes (sequential runs)."
fi
if [[ "${DEDICATED_COORDINATOR}" == "1" ]]; then
    echo "Dedicated coordinator enabled: every run requests one node in addition to its worker-node count."
fi

# Validate required values before submitting
VTYPE_UPPER="${VARIANT_TYPE^^}"
[[ -z "${WORKER_IMAGE}" ]]           && { echo "Error: worker image not set — set CLUSTER_${VTYPE_UPPER}_DEFAULT_WORKER_IMAGE in cluster_config.env or pass -w"; exit 1; }
[[ -z "${COORD_IMAGE}" ]]            && { echo "Error: coordinator image not set — set CLUSTER_${VTYPE_UPPER}_DEFAULT_COORD_IMAGE in cluster_config.env or pass -c"; exit 1; }
[[ -z "${CLUSTER_CPUS_PER_TASK}" ]]  && { echo "Error: CLUSTER_${VTYPE_UPPER}_CPUS_PER_TASK not set in cluster_config.env"; exit 1; }
[[ -z "${CLUSTER_TIME_BENCHMARK}" ]] && { echo "Error: CLUSTER_${VTYPE_UPPER}_TIME_BENCHMARK not set in cluster_config.env"; exit 1; }
[[ -z "${NUM_GPUS_PER_NODE}" ]]      && { echo "Error: CLUSTER_${VTYPE_UPPER}_NUM_WORKERS_PER_NODE not set in cluster_config.env or pass -g"; exit 1; }
[[ -z "${CLUSTER_DEFAULT_PORT}" ]]   && { echo "Error: CLUSTER_${VTYPE_UPPER}_DEFAULT_PORT not set in cluster_config.env"; exit 1; }

# Build sbatch arguments sourced from cluster config
build_cluster_sbatch_args "${CLUSTER_TIME_BENCHMARK}"

# Pre-flight: verify prerequisites before queueing the job.
ANALYZE_HINT="./launch-analyze-tables.sh -s ${SCALE_FACTOR}"
preflight_file "${WORKER_ENV_FILE}" "worker environment" \
    "Set WORKER_ENV_FILE or pass --worker-env-file <path>"
WORKER_ENV_FILE="$(canonicalize_file_path "${WORKER_ENV_FILE}")"

if [[ -n "${QUERIES_FILE}" ]]; then
    preflight_file "${QUERIES_FILE}" "queries JSON"
    QUERIES_FILE="$(canonicalize_file_path "${QUERIES_FILE}")"
    if [[ "${QUERIES_FILE}" != "${VT_ROOT}/"* ]]; then
        echo "Error: --queries-file must be inside ${VT_ROOT} so it is available in the CLI container." >&2
        echo "       Got: ${QUERIES_FILE}" >&2
        exit 1
    fi
    if ! python3 -m json.tool "${QUERIES_FILE}" >/dev/null 2>&1; then
        echo "Error: queries file is not valid JSON: ${QUERIES_FILE}" >&2
        exit 1
    fi
    QUERIES_FILE="/workspace/${QUERIES_FILE#"${VT_ROOT}/"}"
fi
preflight_image_roles "${WORKER_IMAGE}" "${COORD_IMAGE}"
preflight_image "${WORKER_IMAGE}" \
    "Pull it (see ./pull_ghcr_image.sh) or override with -w <name>"
preflight_image "${COORD_IMAGE}" \
    "Pull it (see ./pull_ghcr_image.sh) or override with -c <name>"
preflight_dir "${DATA}" "TPC-H data" \
    "./launch-gen-data.sh -s ${SCALE_FACTOR} -o ${DATA}"
preflight_metastore "${SCALE_FACTOR}" "${ANALYZE_HINT}"

# NODELIST is unset by default -- Slurm picks any eligible nodes. Preserve the
# requested constraint separately: the allocation monitor must not overwrite it
# with the hostname expression returned for one sweep entry.
REQUESTED_NODELIST="${NODELIST:-}"
EFFECTIVE_PARTITION="${CLUSTER_DEFAULT_PARTITION:-}"

# Slurm options after -- may override the configured partition or nodelist.
# Reflect those two common overrides in the best-effort idle-node preflight.
for ((arg_i = 0; arg_i < ${#EXTRA_ARGS[@]}; arg_i++)); do
    case "${EXTRA_ARGS[$arg_i]}" in
        --partition=*) EFFECTIVE_PARTITION="${EXTRA_ARGS[$arg_i]#*=}" ;;
        --partition|-p)
            if ((arg_i + 1 < ${#EXTRA_ARGS[@]})); then
                EFFECTIVE_PARTITION="${EXTRA_ARGS[$((arg_i + 1))]}"
            fi
            ;;
        -p?*) EFFECTIVE_PARTITION="${EXTRA_ARGS[$arg_i]#-p}" ;;
        --nodelist=*) REQUESTED_NODELIST="${EXTRA_ARGS[$arg_i]#*=}" ;;
        --nodelist|-w)
            if ((arg_i + 1 < ${#EXTRA_ARGS[@]})); then
                REQUESTED_NODELIST="${EXTRA_ARGS[$((arg_i + 1))]}"
            fi
            ;;
        -w?*) REQUESTED_NODELIST="${EXTRA_ARGS[$arg_i]#-w}" ;;
    esac
done
unset arg_i

NODELIST_ARG=()
[[ -n "${REQUESTED_NODELIST}" ]] && NODELIST_ARG=(--nodelist="${REQUESTED_NODELIST}")
GRES_ARGS=()
[[ "${VARIANT_TYPE}" == "gpu" ]] && GRES_ARGS=(--gres="gpu:${NUM_GPUS_PER_NODE}")

# Values containing commas or shell punctuation are inherited through
# --export=ALL rather than embedded in sbatch's comma-delimited export string.
[[ -n "${QUERIES}" ]] && export QUERIES
[[ -n "${QUERIES_FILE}" ]] && export QUERIES_FILE
[[ -n "${PROFILE_ITERATIONS}" ]] && export PROFILE_ITERATIONS
export NSYS_LAUNCH_OPTS
export PERF_FREQUENCY PERF_EVENT PERF_CALL_GRAPH PERF_USER_REGS
export PERF_NOFILE_LIMIT PERF_THREADS_PER_SHARD PERF_RECORD_STOP_TIMEOUT
export PERF_POSTPROCESS PERF_FINALIZE_TIMEOUT
[[ -n "${CONFIG_OVERRIDES}" ]] && export CONFIG_OVERRIDES

LATEST_RESULT_POINTER="${SCRIPT_DIR}/latest_result_dir.txt"
LATEST_RESULT_MANIFEST="${SCRIPT_DIR}/latest_result_dirs.tsv"
MANIFEST_DIR="${SCRIPT_DIR}/run_manifests"
MANIFEST_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${MANIFEST_DIR}"
LAUNCH_MANIFEST="${MANIFEST_DIR}/benchmark_${MANIFEST_STAMP}_$$.tsv"

declare -a MANIFEST_ALLOCATED MANIFEST_IDLE MANIFEST_STATUS MANIFEST_JOB_ID
declare -a MANIFEST_RESULT_DIR MANIFEST_JOB_STATE MANIFEST_EXIT_CODE MANIFEST_REASON
for run_i in "${!NODE_COUNTS[@]}"; do
    MANIFEST_ALLOCATED[$run_i]=$((${NODE_COUNTS[$run_i]} + DEDICATED_COORDINATOR))
    MANIFEST_IDLE[$run_i]="unknown"
    MANIFEST_STATUS[$run_i]="not_started"
    MANIFEST_JOB_ID[$run_i]="-"
    MANIFEST_RESULT_DIR[$run_i]="-"
    MANIFEST_JOB_STATE[$run_i]="-"
    MANIFEST_EXIT_CODE[$run_i]="-"
    MANIFEST_REASON[$run_i]="-"
done
unset run_i

tsv_value() {
    local value="${1:-}"
    value="${value//$'\t'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "${value}"
}

render_launch_manifest() {
    local tmp="${LAUNCH_MANIFEST}.tmp.$$"
    local latest_tmp="${LATEST_RESULT_MANIFEST}.tmp.$$"
    local i
    {
        printf 'run_index\tworker_nodes\tallocated_nodes\tdedicated_coordinator\tidle_nodes_at_check\tstatus\tjob_id\tresult_dir\tjob_state\texit_code\treason\n'
        for i in "${!NODE_COUNTS[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$((i + 1))" \
                "${NODE_COUNTS[$i]}" \
                "${MANIFEST_ALLOCATED[$i]}" \
                "${DEDICATED_COORDINATOR}" \
                "$(tsv_value "${MANIFEST_IDLE[$i]}")" \
                "$(tsv_value "${MANIFEST_STATUS[$i]}")" \
                "$(tsv_value "${MANIFEST_JOB_ID[$i]}")" \
                "$(tsv_value "${MANIFEST_RESULT_DIR[$i]}")" \
                "$(tsv_value "${MANIFEST_JOB_STATE[$i]}")" \
                "$(tsv_value "${MANIFEST_EXIT_CODE[$i]}")" \
                "$(tsv_value "${MANIFEST_REASON[$i]}")"
        done
    } > "${tmp}"
    mv -f "${tmp}" "${LAUNCH_MANIFEST}"
    cp "${LAUNCH_MANIFEST}" "${latest_tmp}"
    mv -f "${latest_tmp}" "${LATEST_RESULT_MANIFEST}"
}

write_result_launch_metadata() {
    local i="$1"
    local result_dir="${MANIFEST_RESULT_DIR[$i]}"
    [[ -n "${result_dir}" && "${result_dir}" != "-" ]] || return 0

    mkdir -p "${result_dir}"
    local metadata_tmp="${result_dir}/launch_metadata.tsv.tmp.$$"
    {
        printf 'field\tvalue\n'
        printf 'run_index\t%s\n' "$((i + 1))"
        printf 'worker_nodes\t%s\n' "${NODE_COUNTS[$i]}"
        printf 'allocated_nodes\t%s\n' "${MANIFEST_ALLOCATED[$i]}"
        printf 'dedicated_coordinator\t%s\n' "${DEDICATED_COORDINATOR}"
        printf 'idle_nodes_at_check\t%s\n' "$(tsv_value "${MANIFEST_IDLE[$i]}")"
        printf 'status\t%s\n' "$(tsv_value "${MANIFEST_STATUS[$i]}")"
        printf 'job_id\t%s\n' "$(tsv_value "${MANIFEST_JOB_ID[$i]}")"
        printf 'result_dir\t%s\n' "$(tsv_value "${MANIFEST_RESULT_DIR[$i]}")"
        printf 'job_state\t%s\n' "$(tsv_value "${MANIFEST_JOB_STATE[$i]}")"
        printf 'exit_code\t%s\n' "$(tsv_value "${MANIFEST_EXIT_CODE[$i]}")"
        printf 'reason\t%s\n' "$(tsv_value "${MANIFEST_REASON[$i]}")"
        printf 'invocation_manifest\t%s\n' "$(tsv_value "${LAUNCH_MANIFEST}")"
    } > "${metadata_tmp}"
    mv -f "${metadata_tmp}" "${result_dir}/launch_metadata.tsv"
}

mark_unstarted_runs_interrupted() {
    local i
    for i in "${!NODE_COUNTS[@]}"; do
        if [[ "${MANIFEST_STATUS[$i]}" == "not_started" ]]; then
            MANIFEST_STATUS[$i]="not_run"
            MANIFEST_REASON[$i]="launcher interrupted before submission"
        fi
    done
}

capture_interrupted_job_accounting() {
    local run_index="$1"
    local job_id="$2"
    local row=""
    local attempt

    for attempt in {1..5}; do
        row="$(sacct -j "${job_id}" -X -n -P -o State,ExitCode 2>/dev/null | head -n 1)"
        [[ -n "${row}" ]] && break
        sleep 1
    done
    if [[ -n "${row}" ]]; then
        MANIFEST_JOB_STATE[$run_index]="${row%%|*}"
        MANIFEST_EXIT_CODE[$run_index]="${row##*|}"
    fi
}

handle_launcher_interrupt() {
    trap - INT
    set +e
    echo "" >&2
    echo "Interrupt received." >&2

    if [[ -n "${ACTIVE_JOB_ID}" ]]; then
        local prompt_rc=1
        if prompt_yes_no "Cancel Slurm job ${ACTIVE_JOB_ID} (${ACTIVE_WORKER_NODES} worker nodes) before exiting?"; then
            prompt_rc=0
        else
            prompt_rc=$?
        fi

        if (( prompt_rc == 0 )); then
            if scancel "${ACTIVE_JOB_ID}"; then
                echo "Cancellation requested for job ${ACTIVE_JOB_ID}; waiting briefly for it to leave squeue..." >&2
                MANIFEST_STATUS[$ACTIVE_RUN_INDEX]="interrupted_cancel_requested"
                MANIFEST_REASON[$ACTIVE_RUN_INDEX]="Ctrl-C; scancel accepted"
                local poll
                for poll in {1..30}; do
                    [[ -z "$(squeue -h -j "${ACTIVE_JOB_ID}" 2>/dev/null)" ]] && break
                    sleep 1
                done
                if [[ -n "$(squeue -h -j "${ACTIVE_JOB_ID}" 2>/dev/null)" ]]; then
                    echo "Warning: job ${ACTIVE_JOB_ID} is still visible in squeue after 30 seconds." >&2
                    MANIFEST_REASON[$ACTIVE_RUN_INDEX]="Ctrl-C; scancel accepted but job remained in squeue after 30s"
                fi
                capture_interrupted_job_accounting "${ACTIVE_RUN_INDEX}" "${ACTIVE_JOB_ID}"
            else
                echo "Warning: scancel failed for job ${ACTIVE_JOB_ID}." >&2
                MANIFEST_STATUS[$ACTIVE_RUN_INDEX]="interrupted_cancel_failed"
                MANIFEST_REASON[$ACTIVE_RUN_INDEX]="Ctrl-C; scancel failed"
            fi
        elif (( prompt_rc == 2 )); then
            echo "No controlling terminal is available; leaving job ${ACTIVE_JOB_ID} running." >&2
            echo "Cancel it explicitly with: scancel ${ACTIVE_JOB_ID}" >&2
            MANIFEST_STATUS[$ACTIVE_RUN_INDEX]="interrupted_left_running"
            MANIFEST_REASON[$ACTIVE_RUN_INDEX]="Ctrl-C; no controlling terminal for cancellation prompt"
        else
            echo "Leaving job ${ACTIVE_JOB_ID} running. Cancel it with: scancel ${ACTIVE_JOB_ID}" >&2
            MANIFEST_STATUS[$ACTIVE_RUN_INDEX]="interrupted_left_running"
            MANIFEST_REASON[$ACTIVE_RUN_INDEX]="Ctrl-C; user declined cancellation"
        fi
        write_result_launch_metadata "${ACTIVE_RUN_INDEX}"
    elif [[ -n "${ACTIVE_RUN_INDEX}" && "${MANIFEST_STATUS[$ACTIVE_RUN_INDEX]}" == "not_started" ]]; then
        MANIFEST_STATUS[$ACTIVE_RUN_INDEX]="interrupted_before_submission"
        MANIFEST_REASON[$ACTIVE_RUN_INDEX]="Ctrl-C before job submission"
    fi

    mark_unstarted_runs_interrupted
    render_launch_manifest
    echo "Invocation manifest: ${LAUNCH_MANIFEST}" >&2
    exit 130
}
trap handle_launcher_interrupt INT

render_launch_manifest

RUNS_SUBMITTED=0
RUNS_SKIPPED=0
OVERALL_FAILURE=0
SWEEP_COOLDOWN_PENDING=0

run_one_node_count() {
    local run_index="$1"
    local nodes_count="${NODE_COUNTS[$run_index]}"
    local allocated_nodes_count="${MANIFEST_ALLOCATED[$run_index]}"
    local idle_nodes=""
    local idle_check_ok=0

    ACTIVE_RUN_INDEX="${run_index}"
    ACTIVE_WORKER_NODES="${nodes_count}"
    ACTIVE_ALLOCATED_NODES="${allocated_nodes_count}"
    ACTIVE_RESULT_DIR=""

    # A completed Slurm job can leave its nodes in COMPLETING briefly while
    # deterministic UCX worker ports are still being released. Wait before the
    # next sweep availability snapshot; checking first could falsely skip the
    # entry because the previous allocation's nodes are not IDLE yet.
    if [[ "${SWEEP_MODE}" == "1" && "${SWEEP_COOLDOWN_PENDING}" == "1" ]]; then
        SWEEP_COOLDOWN_PENDING=0
        if [[ "${SWEEP_INTER_RUN_SLEEP}" -gt 0 ]]; then
            echo "Waiting ${SWEEP_INTER_RUN_SLEEP}s for UCX worker ports and Slurm nodes to be released before -n ${nodes_count}..."
            sleep "${SWEEP_INTER_RUN_SLEEP}"
        fi
    fi

    if idle_nodes="$(count_idle_slurm_nodes "${EFFECTIVE_PARTITION}" "${REQUESTED_NODELIST}")"; then
        idle_check_ok=1
        MANIFEST_IDLE[$run_index]="${idle_nodes}"
    else
        MANIFEST_IDLE[$run_index]="unknown"
    fi

    if (( idle_check_ok == 0 )); then
        echo "Warning: unable to determine the number of IDLE nodes in partition '${EFFECTIVE_PARTITION:-<default>}'." >&2
        if [[ "${SWEEP_MODE}" == "1" ]]; then
            echo "Skipping -n ${nodes_count}; sweep mode never queues when availability cannot be verified." >&2
            MANIFEST_STATUS[$run_index]="skipped"
            MANIFEST_REASON[$run_index]="idle-node availability check failed"
            RUNS_SKIPPED=$((RUNS_SKIPPED + 1))
            OVERALL_FAILURE=1
            render_launch_manifest
            ACTIVE_RUN_INDEX=""
            return 0
        fi
        local prompt_rc=1
        if prompt_yes_no "Node availability is unknown. Submit -n ${nodes_count} anyway and allow it to wait in Slurm?"; then
            prompt_rc=0
        else
            prompt_rc=$?
        fi
        if (( prompt_rc != 0 )); then
            MANIFEST_STATUS[$run_index]="declined"
            if (( prompt_rc == 2 )); then
                MANIFEST_REASON[$run_index]="availability unknown; no controlling terminal for confirmation"
            else
                MANIFEST_REASON[$run_index]="availability unknown; user declined queued submission"
            fi
            render_launch_manifest
            ACTIVE_RUN_INDEX=""
            OVERALL_FAILURE=1
            return 0
        fi
    elif (( idle_nodes < allocated_nodes_count )); then
        local allocation_description="${nodes_count} worker nodes"
        [[ "${DEDICATED_COORDINATOR}" == "1" ]] && allocation_description+=" + 1 dedicated coordinator"
        echo "Only ${idle_nodes} IDLE eligible nodes are visible; -n ${nodes_count} requires ${allocated_nodes_count} total (${allocation_description})." >&2
        if [[ "${SWEEP_MODE}" == "1" ]]; then
            echo "Skipping -n ${nodes_count}; sweep mode does not queue resource-short runs." >&2
            MANIFEST_STATUS[$run_index]="skipped"
            MANIFEST_REASON[$run_index]="insufficient idle nodes: required ${allocated_nodes_count}, available ${idle_nodes}"
            RUNS_SKIPPED=$((RUNS_SKIPPED + 1))
            render_launch_manifest
            ACTIVE_RUN_INDEX=""
            return 0
        fi
        local prompt_rc=1
        if prompt_yes_no "Submit anyway and allow the job to wait in Slurm?"; then
            prompt_rc=0
        else
            prompt_rc=$?
        fi
        if (( prompt_rc != 0 )); then
            MANIFEST_STATUS[$run_index]="declined"
            if (( prompt_rc == 2 )); then
                MANIFEST_REASON[$run_index]="insufficient idle nodes; no controlling terminal for confirmation"
                echo "No controlling terminal is available; job was not submitted." >&2
            else
                MANIFEST_REASON[$run_index]="insufficient idle nodes; user declined queued submission"
                echo "Job was not submitted." >&2
            fi
            render_launch_manifest
            ACTIVE_RUN_INDEX=""
            OVERALL_FAILURE=1
            return 0
        fi
    fi

    # Only transient live logs are reused. The previous job copied them into
    # its immutable result_dir_<jobid> before leaving the allocation.
    rm -rf logs 2>/dev/null || true
    rm -f ./*.out ./*.err 2>/dev/null || true
    mkdir -p logs

    local out_fmt="logs/presto-tpch-run_n${nodes_count}_sf${SCALE_FACTOR}_i${NUM_ITERATIONS}_%j.out"
    local err_fmt="logs/presto-tpch-run_n${nodes_count}_sf${SCALE_FACTOR}_i${NUM_ITERATIONS}_%j.err"
    local job_name="presto-tpch-run_n${nodes_count}_sf${SCALE_FACTOR}"

    NSYS_WORKER_IDS="${NSYS_WORKER_IDS_REQUESTED}"
    if [[ "${NSYS_WORKER_IDS}" == "all" ]]; then
        NSYS_WORKER_IDS="$(seq -s, 0 $((nodes_count * NUM_GPUS_PER_NODE - 1)))"
    fi
    export NSYS_WORKER_IDS

    build_common_export_vars
    EXPORT_VARS+=",NUM_ITERATIONS=${NUM_ITERATIONS}"
    EXPORT_VARS+=",DEDICATED_COORDINATOR=${DEDICATED_COORDINATOR}"
    EXPORT_VARS+=",ENABLE_GDS=${ENABLE_GDS},ENABLE_METRICS=${ENABLE_METRICS}"
    EXPORT_VARS+=",ENABLE_NSYS=${ENABLE_NSYS}"
    EXPORT_VARS+=",ENABLE_PERF=${ENABLE_PERF},PERF_WORKER_ID=${PERF_WORKER_ID}"
    EXPORT_VARS+=",VERIFY_CPU_UCX=${VERIFY_CPU_UCX}"

    echo ""
    echo "Submitting run $((run_index + 1))/${#NODE_COUNTS[@]}: ${nodes_count} worker nodes, ${allocated_nodes_count} allocated nodes..."
    local submission_output=""
    if ! submission_output="$(sbatch --parsable --job-name="${job_name}" --nodes="${allocated_nodes_count}" "${NODELIST_ARG[@]}" \
        "${CLUSTER_SBATCH_ARGS[@]}" \
        --export="${EXPORT_VARS}" \
        --output="${out_fmt}" --error="${err_fmt}" "${EXTRA_ARGS[@]}" "${GRES_ARGS[@]}" \
        run-presto-benchmarks.slurm 2>&1)"; then
        echo "Slurm submission failed for -n ${nodes_count}: ${submission_output}" >&2
        MANIFEST_STATUS[$run_index]="submission_failed"
        MANIFEST_REASON[$run_index]="${submission_output:-sbatch failed without output}"
        render_launch_manifest
        ACTIVE_RUN_INDEX=""
        OVERALL_FAILURE=1
        return 0
    fi

    local job_token job_id
    job_token="$(awk '/^[0-9]+(;[^[:space:]]+)?$/ { print; exit }' <<< "${submission_output}")"
    job_id="${job_token%%;*}"
    if ! [[ "${job_id}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Unable to parse a job ID from sbatch output: ${submission_output}" >&2
        echo "The submission command used --parsable, but verify squeue before retrying in case Slurm accepted the job." >&2
        MANIFEST_STATUS[$run_index]="submission_failed"
        MANIFEST_REASON[$run_index]="unable to parse job ID from sbatch output"
        render_launch_manifest
        ACTIVE_RUN_INDEX=""
        OVERALL_FAILURE=1
        return 0
    fi

    ACTIVE_JOB_ID="${job_id}"
    local run_result_dir="result_dir_${job_id}"
    local out_file="${out_fmt//%j/${job_id}}"
    local err_file="${err_fmt//%j/${job_id}}"
    ACTIVE_RESULT_DIR="${run_result_dir}"
    RUNS_SUBMITTED=$((RUNS_SUBMITTED + 1))

    MANIFEST_STATUS[$run_index]="submitted"
    MANIFEST_JOB_ID[$run_index]="${job_id}"
    MANIFEST_RESULT_DIR[$run_index]="${run_result_dir}"
    MANIFEST_REASON[$run_index]="-"
    render_launch_manifest
    write_result_launch_metadata "${run_index}"

    # Keep the historical one-line pointer contract for scripts that do
    # run_dir="$(cat latest_result_dir.txt)". The richer invocation-wide data
    # lives in latest_result_dirs.tsv.
    local pointer_tmp="${LATEST_RESULT_POINTER}.tmp.$$"
    printf '%s\n' "${run_result_dir}" > "${pointer_tmp}"
    mv -f "${pointer_tmp}" "${LATEST_RESULT_POINTER}"

    echo "Job submitted with ID: ${job_id}"
    echo "Run manifest: ${LAUNCH_MANIFEST}"
    echo ""

    # Resolve and print the coordinator address after allocation. While the job
    # is pending, report state/reason changes (and a heartbeat every minute)
    # rather than appearing hung for five minutes and then waiting silently.
    echo "Resolving coordinator IP..."
    local last_pending=""
    local queue_row state job_nodelist pending_reason remainder first_node part first_ip
    local allocated=0
    local poll=0
    local nonpending_polls=0
    while true; do
        poll=$((poll + 1))
        queue_row="$(squeue -j "${job_id}" -h -o '%T|%N|%R' 2>/dev/null | head -n 1 || true)"
        if [[ -z "${queue_row}" ]]; then
            echo "Job ${job_id} is no longer in squeue before coordinator-address resolution."
            break
        fi
        state="${queue_row%%|*}"
        remainder="${queue_row#*|}"
        job_nodelist="${remainder%%|*}"
        pending_reason="${remainder#*|}"

        if [[ "${state}|${pending_reason}" != "${last_pending}" || $((poll % 12)) -eq 0 ]]; then
            echo "  Job ${job_id}: state=${state}, reason=${pending_reason:-unknown}"
            last_pending="${state}|${pending_reason}"
        fi
        if [[ -n "${job_nodelist}" && "${job_nodelist}" != "(null)" ]]; then
            first_node="$(scontrol show hostnames "${job_nodelist}" | head -n 1)"
            if [[ -n "${first_node}" ]]; then
                part="$(scontrol getaddrs "${first_node}" 2>/dev/null | awk 'NR==1{print $2}')"
                first_ip="${part%%:*}"
                if [[ -n "${first_ip}" ]]; then
                    if [[ -n "${CLUSTER_SSH_TUNNEL_HOST:-}" ]]; then
                        echo "Run this command to access the Presto Web UI:"
                        echo "  ssh -N -L ${CLUSTER_DEFAULT_PORT}:${first_ip}:${CLUSTER_DEFAULT_PORT} ${CLUSTER_SSH_TUNNEL_HOST}"
                        echo "The UI will be available at http://localhost:${CLUSTER_DEFAULT_PORT}"
                    else
                        echo "Coordinator is accessible at ${first_ip}:${CLUSTER_DEFAULT_PORT}"
                    fi
                    echo ""
                    allocated=1
                    break
                fi
            fi
        fi
        if [[ "${state}" != "PENDING" ]]; then
            nonpending_polls=$((nonpending_polls + 1))
            if (( nonpending_polls >= 60 )); then
                echo "Coordinator address was not resolved within five minutes after job ${job_id} left PENDING state."
                break
            fi
        fi
        sleep 5
    done
    if (( allocated == 0 )); then
        echo "Coordinator address is not available yet; continuing to wait for job ${job_id}."
        echo "Check scheduling details with: squeue -j ${job_id} -o '%.18i %.9T %.30R %.30N'"
    fi

    print_monitor_hints "${job_id}" "${out_file}" "${err_file}" \
        "tail -f logs/coord.log" \
        "tail -f logs/worker_*.log" \
        "tail -f logs/cli.log"
    echo ""
    echo "Waiting for job to complete..."
    wait_for_job "${job_id}"
    [[ "${SWEEP_MODE}" == "1" ]] && SWEEP_COOLDOWN_PENDING=1

    # The job is no longer queued/running, so a later Ctrl-C must not offer to
    # cancel it while output is being displayed or copied.
    ACTIVE_JOB_ID=""
    MANIFEST_JOB_STATE[$run_index]="${JOB_STATE}"
    MANIFEST_EXIT_CODE[$run_index]="${JOB_EXIT_CODE}"
    if [[ "${JOB_STATE}" == "COMPLETED" ]]; then
        MANIFEST_STATUS[$run_index]="completed"
    else
        MANIFEST_STATUS[$run_index]="failed"
        MANIFEST_REASON[$run_index]="Slurm state ${JOB_STATE}, exit ${JOB_EXIT_CODE}"
        OVERALL_FAILURE=1
    fi
    render_launch_manifest
    write_result_launch_metadata "${run_index}"

    echo ""
    echo "Output files:"
    ls -lh "${out_file}" "${err_file}" 2>/dev/null || echo "No output files found"
    show_job_output "${out_file}" "${err_file}" "logs/cli.log" "benchmark results"

    if [[ -d "${run_result_dir}" ]]; then
        echo ""
        echo "Job results preserved at: ${SCRIPT_DIR}/${run_result_dir}"
        echo "Launch metadata: ${SCRIPT_DIR}/${run_result_dir}/launch_metadata.tsv"
        echo "Latest-result pointer: ${LATEST_RESULT_POINTER}"
    else
        echo "No job result directory was created at ${SCRIPT_DIR}/${run_result_dir}" >&2
    fi

    if [[ -n "${OUTPUT_PATH}" && -d "${run_result_dir}" ]]; then
        local copy_destination="${OUTPUT_PATH}"
        if [[ "${SWEEP_MODE}" == "1" ]]; then
            copy_destination="${OUTPUT_PATH%/}/n${nodes_count}_${run_result_dir}"
        fi
        echo ""
        echo "Copying results to ${copy_destination}..."
        mkdir -p "${copy_destination}"
        cp -r "${run_result_dir}/." "${copy_destination}/"
        echo "Results copied to ${copy_destination}"
    fi

    ACTIVE_RUN_INDEX=""
    ACTIVE_WORKER_NODES=""
    ACTIVE_ALLOCATED_NODES=""
    ACTIVE_RESULT_DIR=""
}

for run_index in "${!NODE_COUNTS[@]}"; do
    run_one_node_count "${run_index}"
done

trap - INT
render_launch_manifest

echo ""
echo "========================================"
if [[ "${SWEEP_MODE}" == "1" ]]; then
    echo "Node-count sweep complete: ${RUNS_SUBMITTED} submitted, ${RUNS_SKIPPED} skipped."
else
    echo "Benchmark launch complete: ${RUNS_SUBMITTED} submitted."
fi
echo "Invocation manifest: ${LAUNCH_MANIFEST}"
echo "Latest manifest: ${LATEST_RESULT_MANIFEST}"
if (( RUNS_SUBMITTED == 0 )); then
    echo "No jobs were submitted; ${LATEST_RESULT_POINTER} was left unchanged."
fi
echo "========================================"

(( OVERALL_FAILURE == 0 )) || exit 1
