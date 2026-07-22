#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -e
# Run ldconfig once
ldconfig

LOGS_DIR="/opt/presto-server/logs"
mkdir -p "${LOGS_DIR}"
: "${SERVER_START_TIMESTAMP:?SERVER_START_TIMESTAMP must be set before starting the container}"

ETC_BASE="/opt/presto-server/etc"

log_ucx_build_info() {
  local log_file=$1
  local marker_dir="/opt/presto-ucx-build"

  if [[ ! -d "$marker_dir" ]]; then
    echo "UCX build info: unavailable" >> "$log_file"
    return
  fi

  echo "UCX build info:" >> "$log_file"
  for file in requested_version local_source_hash; do
    if [[ -f "${marker_dir}/${file}" ]]; then
      echo "  ${file}: $(cat "${marker_dir}/${file}")" >> "$log_file"
    fi
  done

  if [[ -s "${marker_dir}/ucx_info_v.txt" ]]; then
    sed 's/^/  ucx_info: /' "${marker_dir}/ucx_info_v.txt" | head -20 >> "$log_file"
  fi

  if [[ -s "${marker_dir}/ldconfig_ucx.txt" ]]; then
    sed 's/^/  ldconfig: /' "${marker_dir}/ldconfig_ucx.txt" | head -20 >> "$log_file"
  fi
}

resolve_compute_sanitizer() {
  if [[ -n "${PRESTO_COMPUTE_SANITIZER_PATH:-}" ]]; then
    if command -v "${PRESTO_COMPUTE_SANITIZER_PATH}" &> /dev/null; then
      command -v "${PRESTO_COMPUTE_SANITIZER_PATH}"
      return 0
    fi
    if [[ -x "${PRESTO_COMPUTE_SANITIZER_PATH}" ]]; then
      echo "${PRESTO_COMPUTE_SANITIZER_PATH}"
      return 0
    fi

    if [[ "${PRESTO_COMPUTE_SANITIZER_PATH}" =~ /usr/local/cuda-([0-9]+([.][0-9]+)?)/ ]] &&
       command -v dnf &> /dev/null; then
      local requested_cuda_version="${BASH_REMATCH[1]}"
      local requested_cuda_major_minor
      requested_cuda_major_minor=$(echo "$requested_cuda_version" | awk -F. '{print $1 "." $2}')
      local requested_cuda_version_dashed="${requested_cuda_version//./-}"
      local requested_cuda_major_minor_dashed="${requested_cuda_major_minor//./-}"

      dnf install -y "cuda-sanitizer-${requested_cuda_major_minor_dashed}" >&2 ||
        dnf install -y "cuda-sanitizer-${requested_cuda_version_dashed}" >&2 ||
        true

      if command -v "${PRESTO_COMPUTE_SANITIZER_PATH}" &> /dev/null; then
        command -v "${PRESTO_COMPUTE_SANITIZER_PATH}"
        return 0
      fi
      if [[ -x "${PRESTO_COMPUTE_SANITIZER_PATH}" ]]; then
        echo "${PRESTO_COMPUTE_SANITIZER_PATH}"
        return 0
      fi
    fi

    echo "Requested PRESTO_COMPUTE_SANITIZER_PATH=${PRESTO_COMPUTE_SANITIZER_PATH}, but it was not found or is not executable." >&2
    return 1
  fi

  local cuda_version="${CUDA_VERSION:-}"
  if [[ -z "$cuda_version" ]] && command -v nvcc &> /dev/null; then
    cuda_version=$(nvcc --version | sed -n 's/.*release \([0-9][0-9.]*\),.*/\1/p' | head -1)
  fi

  local candidate
  for candidate in \
    compute-sanitizer \
    ${cuda_version:+/usr/local/cuda-${cuda_version}/bin/compute-sanitizer} \
    ${cuda_version:+/usr/local/cuda-${cuda_version}/compute-sanitizer/compute-sanitizer} \
    /usr/local/cuda-*/bin/compute-sanitizer \
    /usr/local/cuda-*/compute-sanitizer/compute-sanitizer \
    /usr/local/cuda-13.2/bin/compute-sanitizer \
    /usr/local/cuda-13.2/compute-sanitizer/compute-sanitizer \
    /usr/local/cuda/bin/compute-sanitizer \
    /usr/local/cuda/compute-sanitizer/compute-sanitizer; do
    if command -v "$candidate" &> /dev/null; then
      command -v "$candidate"
      return 0
    fi
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  if command -v dnf &> /dev/null; then
    if [[ -n "$cuda_version" ]]; then
      local cuda_version_major_minor
      cuda_version_major_minor=$(echo "$cuda_version" | awk -F. '{print $1 "." $2}')
      local cuda_version_dashed="${cuda_version//./-}"
      local cuda_version_major_minor_dashed="${cuda_version_major_minor//./-}"
      dnf install -y "cuda-sanitizer-${cuda_version_major_minor_dashed}" >&2 ||
        dnf install -y "cuda-sanitizer-${cuda_version_dashed}" >&2 ||
        true
    fi
  fi

  for candidate in \
    compute-sanitizer \
    ${cuda_version:+/usr/local/cuda-${cuda_version}/bin/compute-sanitizer} \
    ${cuda_version:+/usr/local/cuda-${cuda_version}/compute-sanitizer/compute-sanitizer} \
    /usr/local/cuda-*/bin/compute-sanitizer \
    /usr/local/cuda-*/compute-sanitizer/compute-sanitizer \
    /usr/local/cuda-13.2/bin/compute-sanitizer \
    /usr/local/cuda-13.2/compute-sanitizer/compute-sanitizer \
    /usr/local/cuda/bin/compute-sanitizer \
    /usr/local/cuda/compute-sanitizer/compute-sanitizer; do
    if command -v "$candidate" &> /dev/null; then
      command -v "$candidate"
      return 0
    fi
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# Resolve the NUMA node for a worker and launch presto_server pinned to it.
# Precedence:
#   1. NUMA_NODE env var: explicit bind (used by multi-worker CPU where each
#      container represents one NUMA socket).
#   2. nvidia-smi topology: pins to the NUMA node closest to the worker's GPU.
#   3. numactl fallback: --interleave=all across all NUMA nodes (single-
#      container CPU where one worker spans both sockets).
#   $1 — GPU ID (or 0 for CPU single-worker)
#   $2 — etc-dir path for this instance
launch_worker() {
  local worker_id=$1 etc_dir=$2
  echo "Launching worker $worker_id (config: $etc_dir)"

  local launcher=()
  local cuda_env=()

  if [[ -n "${NUMA_NODE:-}" ]]; then
    echo "NUMA_NODE=${NUMA_NODE} -- launching with numactl --cpunodebind=${NUMA_NODE} --membind=${NUMA_NODE}"
    launcher=(numactl --cpunodebind="${NUMA_NODE}" --membind="${NUMA_NODE}")
  elif command -v nvidia-smi &> /dev/null; then
    local topo
    topo=$(nvidia-smi topo -C -M -i "$worker_id")
    echo "$topo"

    local cpu_numa mem_numa
    cpu_numa=$(echo "$topo" | awk -F: '/NUMA IDs of closest CPU/{ gsub(/ /,"",$2); print $2 }')
    mem_numa=$(echo "$topo" | awk -F: '/NUMA IDs of closest memory/{ gsub(/ /,"",$2); print $2 }')

    if [[ $cpu_numa =~ ^[0-9]+$ ]]; then
      launcher=(numactl --cpunodebind="$cpu_numa")
      if [[ $mem_numa =~ ^[0-9]+$ ]]; then
        launcher+=(--membind="$mem_numa")
      else
        launcher+=(--membind="$cpu_numa")
      fi
    fi

    cuda_env=("CUDA_VISIBLE_DEVICES=$worker_id")
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null -i "$worker_id")"
  # No GPU: fall back to NUMA interleaving across all nodes for CPU workers.
  # Requires SYS_NICE capability in the container (set via cap_add in docker-compose).
  elif command -v numactl &> /dev/null; then
    local num_nodes
    num_nodes=$(numactl --hardware 2>/dev/null | grep -c "node [0-9]* cpus:" || echo 0)
    if [[ $num_nodes -gt 1 ]]; then
      echo "No GPU detected; found $num_nodes NUMA nodes -- launching with --interleave=all"
      launcher=(numactl --interleave=all)
    fi
  fi

  log_file="${LOGS_DIR}/worker_${worker_id}_${SERVER_START_TIMESTAMP}.log"
  echo "GPU Name: ${gpu_name:-unknown}" > "${log_file}"
  log_ucx_build_info "${log_file}"

  local server_cmd=(presto_server --etc-dir="$etc_dir")
  if [[ "${PRESTO_COMPUTE_SANITIZER:-0}" == "1" ]]; then
    local compute_sanitizer
    if ! compute_sanitizer=$(resolve_compute_sanitizer 2>> "${log_file}"); then
      echo "ERROR: PRESTO_COMPUTE_SANITIZER=1, but compute-sanitizer was not found and could not be installed." >> "${log_file}"
      echo "Install the CUDA sanitizer package in the worker image, e.g. cuda-sanitizer-\${CUDA_VERSION//./-}." >> "${log_file}"
      return 1
    fi

    local sanitizer_log="${LOGS_DIR}/compute_sanitizer_worker_${worker_id}_${SERVER_START_TIMESTAMP}_%p.log"
    echo "Running worker $worker_id under compute-sanitizer; log: ${sanitizer_log}" >> "${log_file}"
    echo "Resolved compute-sanitizer: ${compute_sanitizer}" >> "${log_file}"
    "${compute_sanitizer}" --version >> "${log_file}" 2>&1 || true
    server_cmd=(
      "${compute_sanitizer}"
      --tool memcheck
      --track-stream-ordered-races all
      --target-processes all
      --error-exitcode=99
      --log-file "${sanitizer_log}"
      "${server_cmd[@]}"
    )
  fi

  env "${cuda_env[@]}" "${launcher[@]}" "${server_cmd[@]}" >> "${log_file}" 2>&1 &
}

# No args → single worker. WORKER_ID env var (set by multi-worker CPU compose
# where each container is one logical worker) takes precedence; otherwise fall
# back to CUDA_VISIBLE_DEVICES for GPU runs, defaulting to 0.
# With args → one worker per GPU ID, each with its own config dir (etc<gpu_id>).
if [ $# -eq 0 ]; then
  # Single worker mode.
  launch_worker "${WORKER_ID:-${CUDA_VISIBLE_DEVICES:-0}}" "${ETC_BASE}/"
else
  # Multi-worker single-container mode.  Each GPU ID is an argument.
  for gpu_id in "$@"; do
    launch_worker "$gpu_id" "${ETC_BASE}${gpu_id}"
  done
fi

wait
