#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -Ee
LOGS_DIR="${LOGS_DIR:-/opt/presto-server/logs}"
ETC_BASE="${ETC_BASE:-/opt/presto-server/etc}"
NUMA_SYSFS_ROOT="${PRESTO_NUMA_SYSFS_ROOT:-/sys/devices/system/node}"
declare -a WORKER_PIDS=()
declare -A WORKER_ID_BY_PID=()

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

valid_cpu_list() {
  [[ $1 =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]
}

numa_node_cpulist() {
  local node=$1
  local cpulist_file="${NUMA_SYSFS_ROOT}/node${node}/cpulist"
  local cpulist

  [[ $node =~ ^[0-9]+$ && -r $cpulist_file ]] || return 1
  cpulist=$(<"${cpulist_file}")
  cpulist=${cpulist//$'\n'/}
  valid_cpu_list "$cpulist" || return 1
  printf '%s\n' "$cpulist"
}

numa_node_has_memory() {
  local node=$1
  local meminfo_file="${NUMA_SYSFS_ROOT}/node${node}/meminfo"

  [[ $node =~ ^[0-9]+$ && -r $meminfo_file ]] || return 1
  awk '/MemTotal:/ { found = 1; if ($4 + 0 > 0) exit 0; exit 1 } END { if (!found) exit 1 }' \
    "$meminfo_file"
}

topology_value() {
  local topology=$1 label=$2
  local values=()

  mapfile -t values < <(awk -F: -v label="$label" '
    $1 == label {
      value = $2
      gsub(/[[:space:]]/, "", value)
      print value
    }
  ' <<< "$topology")
  ((${#values[@]} == 1)) && [[ -n ${values[0]} ]] || return 1
  printf '%s\n' "${values[0]}"
}

run_nvidia_smi() {
  local timeout_seconds=${PRESTO_NVIDIA_SMI_TIMEOUT_SECONDS:-5}

  if [[ ! $timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
    echo "PRESTO_NVIDIA_SMI_TIMEOUT_SECONDS must be a positive integer; got '${timeout_seconds}'." >&2
    return 2
  fi
  command -v nvidia-smi >/dev/null 2>&1 || return 127
  command -v timeout >/dev/null 2>&1 || {
    echo "The timeout command is required for bounded nvidia-smi probes." >&2
    return 127
  }

  timeout --foreground --signal=TERM --kill-after=2s \
    "${timeout_seconds}s" nvidia-smi "$@"
}

# Probe one physical GPU and validate the returned nodes against sysfs. Results
# are returned in PROBED_GPU_* globals so rendered topology can be compared
# with the worker's current device enumeration before it is trusted.
probe_gpu_numa_binding() {
  local worker_id=$1
  local topology cpu_node memory_node cpulist cpu_value memory_value

  PROBED_GPU_CPUSET=''
  PROBED_GPU_CPU_NODE=''
  PROBED_GPU_MEMORY_NODE=''

  if ! topology=$(run_nvidia_smi topo -C -M -i "$worker_id" 2>&1); then
    echo "nvidia-smi topology discovery failed for GPU ${worker_id}: ${topology}" >&2
    return 1
  fi

  cpu_value=$(topology_value "$topology" 'NUMA IDs of closest CPU') || {
    echo "GPU ${worker_id} has no unambiguous closest CPU NUMA node: ${topology}" >&2
    return 1
  }
  [[ $cpu_value =~ ^[0-9]+$ ]] || {
    echo "GPU ${worker_id} has no unambiguous closest CPU NUMA node: ${topology}" >&2
    return 1
  }
  cpu_node=$cpu_value
  cpulist=$(numa_node_cpulist "$cpu_node") || {
    echo "GPU ${worker_id} CPU NUMA node ${cpu_node} has no valid sysfs CPU list." >&2
    return 1
  }

  memory_value=$(topology_value "$topology" 'NUMA IDs of closest memory') || {
    echo "GPU ${worker_id} has a missing or ambiguous closest memory NUMA node: ${topology}" >&2
    return 1
  }
  if [[ $memory_value == N/A ]]; then
    # PCIe GPUs often report N/A for closest memory. Fall back to the closest
    # CPU node only after proving that the node owns local memory.
    memory_node=$cpu_node
  elif [[ $memory_value =~ ^[0-9]+$ ]]; then
    memory_node=$memory_value
  else
    echo "GPU ${worker_id} has a malformed or ambiguous closest memory NUMA node: ${topology}" >&2
    return 1
  fi
  numa_node_has_memory "$memory_node" || {
    echo "GPU ${worker_id} closest memory NUMA node ${memory_node} has no visible local memory." >&2
    return 1
  }

  PROBED_GPU_CPUSET=$cpulist
  PROBED_GPU_CPU_NODE=$cpu_node
  PROBED_GPU_MEMORY_NODE=$memory_node
}

# Resolve one GPU to an exact CPU set and one memory-bearing NUMA node.
# Results are returned in RESOLVED_GPU_* globals.  Rendered host topology takes
# precedence, but is checked again against the sysfs view mounted in the worker.
resolve_gpu_numa_binding() {
  local worker_id=$1
  local policy=${2:-${PRESTO_GPU_NUMA_BINDING:-auto}}
  local explicit_count=0
  local expected_cpulist

  RESOLVED_GPU_CPUSET=''
  RESOLVED_GPU_CPU_NODE=''
  RESOLVED_GPU_MEMORY_NODE=''
  RESOLVED_GPU_NUMA_SOURCE=''

  [[ -n ${PRESTO_GPU_CPUSET:-} ]] && ((explicit_count += 1))
  [[ -n ${PRESTO_GPU_CPU_NUMA_NODE:-} ]] && ((explicit_count += 1))
  [[ -n ${PRESTO_GPU_MEMORY_NUMA_NODE:-} ]] && ((explicit_count += 1))
  if ((explicit_count != 0)); then
    if ((explicit_count != 3)); then
      echo "Incomplete rendered GPU NUMA topology; CPU set, CPU node, and memory node are all required." >&2
      return 2
    fi
    valid_cpu_list "${PRESTO_GPU_CPUSET}" || {
      echo "Invalid rendered GPU CPU set: ${PRESTO_GPU_CPUSET}" >&2
      return 2
    }
    expected_cpulist=$(numa_node_cpulist "${PRESTO_GPU_CPU_NUMA_NODE}") || {
      echo "Rendered GPU CPU NUMA node ${PRESTO_GPU_CPU_NUMA_NODE} is not visible in sysfs." >&2
      return 2
    }
    if [[ ${PRESTO_GPU_CPUSET} != "$expected_cpulist" ]]; then
      echo "Rendered GPU CPU set ${PRESTO_GPU_CPUSET} does not match node ${PRESTO_GPU_CPU_NUMA_NODE} CPU set ${expected_cpulist}." >&2
      return 2
    fi
    numa_node_has_memory "${PRESTO_GPU_MEMORY_NUMA_NODE}" || {
      echo "Rendered GPU memory NUMA node ${PRESTO_GPU_MEMORY_NUMA_NODE} has no visible local memory." >&2
      return 2
    }

    # Docker has already applied the rendered cpuset. A live mismatch cannot
    # safely degrade to an unbound process, so fail closed even in auto mode.
    # Auto may retain a sysfs-valid host mapping if the bounded live probe is
    # unavailable; required insists on confirming it inside the worker.
    if probe_gpu_numa_binding "$worker_id"; then
      if [[ ${PRESTO_GPU_CPU_NUMA_NODE} != "$PROBED_GPU_CPU_NODE" ||
        ${PRESTO_GPU_MEMORY_NUMA_NODE} != "$PROBED_GPU_MEMORY_NODE" ||
        ${PRESTO_GPU_CPUSET} != "$PROBED_GPU_CPUSET" ]]; then
        printf 'Rendered GPU NUMA topology is stale for GPU %s: rendered cpu_node=%s cpuset=%s memory_node=%s; current cpu_node=%s cpuset=%s memory_node=%s.\n' \
          "$worker_id" "${PRESTO_GPU_CPU_NUMA_NODE}" "${PRESTO_GPU_CPUSET}" \
          "${PRESTO_GPU_MEMORY_NUMA_NODE}" "$PROBED_GPU_CPU_NODE" \
          "$PROBED_GPU_CPUSET" "$PROBED_GPU_MEMORY_NODE" >&2
        return 2
      fi
    elif [[ $policy == required ]]; then
      echo "Strict GPU NUMA binding requires live validation of rendered topology for GPU ${worker_id}." >&2
      return 2
    else
      echo "WARNING: live GPU topology validation was unavailable; retaining the sysfs-valid rendered mapping for GPU ${worker_id}." >&2
    fi

    RESOLVED_GPU_CPUSET=${PRESTO_GPU_CPUSET}
    RESOLVED_GPU_CPU_NODE=${PRESTO_GPU_CPU_NUMA_NODE}
    RESOLVED_GPU_MEMORY_NODE=${PRESTO_GPU_MEMORY_NUMA_NODE}
    RESOLVED_GPU_NUMA_SOURCE='host-render'
    return 0
  fi

  probe_gpu_numa_binding "$worker_id" || return 1
  RESOLVED_GPU_CPUSET=$PROBED_GPU_CPUSET
  RESOLVED_GPU_CPU_NODE=$PROBED_GPU_CPU_NODE
  RESOLVED_GPU_MEMORY_NODE=$PROBED_GPU_MEMORY_NODE
  RESOLVED_GPU_NUMA_SOURCE='runtime-nvidia-smi'
}

remove_worker_pid() {
  local completed_pid=$1 pid
  local remaining_pids=()

  for pid in "${WORKER_PIDS[@]}"; do
    if [[ $pid != "$completed_pid" ]]; then
      remaining_pids+=("$pid")
    fi
  done
  WORKER_PIDS=("${remaining_pids[@]}")
  unset 'WORKER_ID_BY_PID[$completed_pid]'
}

terminate_workers() {
  local signal=${1:-TERM} pid job_pid
  local job_pids=()

  # Limit signaling to worker processes that are still known to bash as jobs.
  # This avoids signaling a recycled PID after wait has reaped a worker.
  mapfile -t job_pids < <(jobs -p)
  for pid in "${WORKER_PIDS[@]}"; do
    for job_pid in "${job_pids[@]}"; do
      if [[ $pid == "$job_pid" ]]; then
        kill "-${signal}" "$pid" 2>/dev/null || true
        break
      fi
    done
  done
}

reap_workers() {
  local pid

  for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  WORKER_PIDS=()
  WORKER_ID_BY_PID=()
}

has_running_workers() {
  local pid job_pid
  local running_jobs=()

  mapfile -t running_jobs < <(jobs -pr)
  for pid in "${WORKER_PIDS[@]}"; do
    for job_pid in "${running_jobs[@]}"; do
      [[ $pid == "$job_pid" ]] && return 0
    done
  done
  return 1
}

terminate_and_reap_workers() {
  local signal=${1:-TERM}
  local grace_seconds=${PRESTO_WORKER_SHUTDOWN_GRACE_SECONDS:-10}
  local deadline

  if [[ ! $grace_seconds =~ ^[0-9]+$ ]]; then
    echo "WARNING: invalid PRESTO_WORKER_SHUTDOWN_GRACE_SECONDS='${grace_seconds}'; using 10 seconds." >&2
    grace_seconds=10
  fi

  terminate_workers "$signal"
  deadline=$((SECONDS + grace_seconds))
  while has_running_workers && ((SECONDS < deadline)); do
    sleep 0.1
  done
  if has_running_workers; then
    echo "Native workers did not exit within ${grace_seconds}s; sending KILL." >&2
    terminate_workers KILL
  fi
  reap_workers
}

handle_worker_signal() {
  local signal=$1 status=$2

  trap - ERR HUP INT TERM
  echo "Received ${signal}; terminating all native workers." >&2
  terminate_and_reap_workers "$signal"
  exit "$status"
}

handle_launcher_error() {
  local status=$1

  trap - ERR HUP INT TERM
  echo "Native worker launcher failed with status ${status}; terminating all started workers." >&2
  terminate_and_reap_workers TERM
  exit "$status"
}

wait_for_workers() {
  local completed_pid status worker_id
  local candidates=()

  while ((${#WORKER_PIDS[@]} > 0)); do
    candidates=("${WORKER_PIDS[@]}")
    completed_pid=''
    if wait -n -p completed_pid "${candidates[@]}"; then
      status=0
    else
      status=$?
    fi

    if [[ -z $completed_pid ]]; then
      echo "Unable to identify the completed native worker (wait status ${status})." >&2
      terminate_and_reap_workers TERM
      return "$status"
    fi

    worker_id=${WORKER_ID_BY_PID[$completed_pid]:-unknown}
    remove_worker_pid "$completed_pid"
    if ((status != 0)); then
      echo "Native worker ${worker_id} (PID ${completed_pid}) exited with status ${status}; terminating sibling workers." >&2
      terminate_and_reap_workers TERM
      return "$status"
    fi
    if ((${#WORKER_PIDS[@]} > 0)); then
      echo "Native worker ${worker_id} (PID ${completed_pid}) exited cleanly while sibling workers are still running; terminating the degraded worker set." >&2
      terminate_and_reap_workers TERM
      return 1
    fi
  done
}

# Resolve the NUMA node for a worker and launch presto_server pinned to it.
# Precedence:
#   1. NUMA_NODE env var: explicit bind (used by multi-worker CPU where each
#      container represents one NUMA socket).
#   2. Rendered or runtime nvidia-smi topology: hard CPU affinity to the exact
#      local CPU set and a bind policy to the closest memory-bearing NUMA node.
#   3. numactl fallback: --interleave=all across all NUMA nodes (single-
#      container CPU where one worker spans both sockets).
#   $1 — GPU ID (or 0 for CPU single-worker)
#   $2 — etc-dir path for this instance
launch_worker() {
  local worker_id=$1 etc_dir=$2
  local log_file="${LOGS_DIR}/worker_${worker_id}_${SERVER_START_TIMESTAMP}.log"
  local gpu_name='unknown'
  local gpu_numa_mode="${PRESTO_GPU_NUMA_BINDING:-auto}"

  : > "$log_file"
  echo "Launching worker $worker_id (config: $etc_dir)" | tee -a "$log_file"

  local launcher=()
  local cuda_env=()

  if [[ -n "${NUMA_NODE:-}" ]]; then
    echo "NUMA_NODE=${NUMA_NODE} -- launching with numactl --cpunodebind=${NUMA_NODE} --membind=${NUMA_NODE}" | tee -a "$log_file"
    launcher=(numactl --cpunodebind="${NUMA_NODE}" --membind="${NUMA_NODE}")
  elif [[ -n ${PRESTO_GPU_CPUSET:-} || -n ${CUDA_VISIBLE_DEVICES:-} ]] ||
    command -v nvidia-smi &> /dev/null; then
    case "$gpu_numa_mode" in
      off)
        echo "GPU NUMA binding is disabled by PRESTO_GPU_NUMA_BINDING=off." | tee -a "$log_file"
        ;;
      auto|required)
        local binding_error='topology discovery or validation failed; see the preceding worker log'
        local binding_status=0
        if resolve_gpu_numa_binding "$worker_id" "$gpu_numa_mode" \
            2> >(tee -a "$log_file" >&2); then
          if ! command -v numactl >/dev/null 2>&1; then
            binding_error='numactl is not installed in the worker image'
          else
            launcher=(
              numactl
              --physcpubind="${RESOLVED_GPU_CPUSET}"
              --membind="${RESOLVED_GPU_MEMORY_NODE}"
            )
            if ! "${launcher[@]}" true >> "$log_file" 2>&1; then
              binding_error='numactl could not apply the resolved CPU and memory policy'
              launcher=()
            else
              printf 'GPU NUMA binding: source=%s gpu=%s cpu_node=%s cpuset=%s memory_node=%s\n' \
                "${RESOLVED_GPU_NUMA_SOURCE}" "$worker_id" \
                "${RESOLVED_GPU_CPU_NODE}" "${RESOLVED_GPU_CPUSET}" \
                "${RESOLVED_GPU_MEMORY_NODE}" | tee -a "$log_file"
            fi
          fi
        else
          binding_status=$?
        fi
        if ((binding_status == 2)); then
          echo "ERROR: rendered GPU NUMA binding is unsafe and cannot be relaxed inside its cgroup." | tee -a "$log_file" >&2
          return 1
        fi
        if ((${#launcher[@]} == 0)); then
          if [[ $gpu_numa_mode == required ]]; then
            echo "ERROR: strict GPU NUMA binding was required but unavailable: ${binding_error}" | tee -a "$log_file" >&2
            return 1
          fi
          echo "WARNING: complete GPU CPU/memory NUMA binding is unavailable; continuing without an explicit process policy: ${binding_error}" | tee -a "$log_file" >&2
        fi
        ;;
      *)
        echo "ERROR: PRESTO_GPU_NUMA_BINDING must be auto, required, or off; got '${gpu_numa_mode}'." | tee -a "$log_file" >&2
        return 1
        ;;
    esac

    cuda_env=("CUDA_VISIBLE_DEVICES=$worker_id")
    if command -v nvidia-smi >/dev/null 2>&1; then
      gpu_name="$(run_nvidia_smi --query-gpu=name --format=csv,noheader -i "$worker_id" 2>/dev/null || true)"
    fi
  # No GPU: fall back to NUMA interleaving across all nodes for CPU workers.
  # Requires SYS_NICE capability in the container (set via cap_add in docker-compose).
  elif command -v numactl &> /dev/null; then
    local num_nodes
    num_nodes=$(numactl --hardware 2>/dev/null | grep -c "node [0-9]* cpus:" || echo 0)
    if [[ $num_nodes -gt 1 ]]; then
      echo "No GPU detected; found $num_nodes NUMA nodes -- launching with --interleave=all" | tee -a "$log_file"
      launcher=(numactl --interleave=all)
    fi
  fi

  echo "GPU Name: ${gpu_name:-unknown}" >> "${log_file}"
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

  # Record the policy as observed by the child after numactl applies it.  Note
  # that /proc/self/status Mems_allowed_list is the cgroup eligibility mask;
  # numactl's `policy` and `membind` fields are the process allocation policy.
  local inspect_and_exec='\
echo "Effective NUMA policy:"; \
if command -v numactl >/dev/null 2>&1; then numactl --show || true; fi; \
grep -E "^(Cpus_allowed_list|Mems_allowed_list):" /proc/self/status || true; \
exec "$@"'
  env "${cuda_env[@]}" "${launcher[@]}" \
    bash -c "$inspect_and_exec" _ "${server_cmd[@]}" >> "${log_file}" 2>&1 &
  local worker_pid=$!
  WORKER_PIDS+=("$worker_pid")
  WORKER_ID_BY_PID["$worker_pid"]=$worker_id
}

main() {
  # Run ldconfig once after the runtime image and any mounted libraries exist.
  ldconfig
  mkdir -p "${LOGS_DIR}"
  : "${SERVER_START_TIMESTAMP:?SERVER_START_TIMESTAMP must be set before starting the container}"
  trap 'handle_launcher_error "$?"' ERR
  trap 'handle_worker_signal HUP 129' HUP
  trap 'handle_worker_signal INT 130' INT
  trap 'handle_worker_signal TERM 143' TERM

  # No args → single worker. WORKER_ID env var (set by multi-worker CPU compose
  # where each container is one logical worker) takes precedence; otherwise
  # fall back to CUDA_VISIBLE_DEVICES for GPU runs, defaulting to 0.
  # With args → one worker per GPU ID and etc<gpu_id> configuration directory.
  if [ $# -eq 0 ]; then
    launch_worker "${WORKER_ID:-${CUDA_VISIBLE_DEVICES:-0}}" "${ETC_BASE}/"
  else
    local gpu_id
    for gpu_id in "$@"; do
      launch_worker "$gpu_id" "${ETC_BASE}${gpu_id}"
    done
  fi

  local status
  if wait_for_workers; then
    status=0
  else
    status=$?
  fi
  trap - ERR HUP INT TERM
  return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
