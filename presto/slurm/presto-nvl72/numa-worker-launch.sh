#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if (( $# < 2 )); then
    echo "Usage: $0 <cpu-numa-node> <command> [args...]" >&2
    exit 2
fi

cpu_numa_node=$1
shift
if [[ ! "${cpu_numa_node}" =~ ^[0-9]+$ ]]; then
    echo "Invalid CPU NUMA node: ${cpu_numa_node}" >&2
    exit 2
fi

cpu_bind_option="cpunodebind"
if [[ "${LEGACY_CPU_NUMA:-0}" == "1" ]]; then
    # Exact deprecated spelling used by the original Slurm path. numactl
    # interprets its argument as a NUMA node, not as a physical CPU number.
    cpu_bind_option="cpubind"
fi
echo "Requested worker NUMA policy: --${cpu_bind_option}=${cpu_numa_node} --membind=${cpu_numa_node}"

# Enter the requested CPU and memory policies before inspecting them. exec
# preserves the PID across this diagnostic shell and the final Presto server,
# which is required by the host-side perf attachment path.
exec numactl \
    "--${cpu_bind_option}=${cpu_numa_node}" \
    --membind="${cpu_numa_node}" \
    /bin/bash -c '
        echo "Effective worker NUMA policy:"
        numactl --show 2>&1 || true
        grep -E "^(Cpus_allowed_list|Mems_allowed_list):" /proc/self/status || true
        exec "$@"
    ' _ "$@"
