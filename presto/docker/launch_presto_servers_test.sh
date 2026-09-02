#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Some build hosts mount /tmp noexec, so keep executable test doubles beside
# the test script and remove the private directory on exit.
TEST_ROOT=$(mktemp -d "${SCRIPT_DIR}/.launch_presto_servers_test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export PRESTO_NUMA_SYSFS_ROOT="${TEST_ROOT}/sys/devices/system/node"
export PATH="${TEST_ROOT}/bin:${PATH}"
export LOGS_DIR="${TEST_ROOT}/logs"
export SERVER_START_TIMESTAMP=test
mkdir -p \
  "${PRESTO_NUMA_SYSFS_ROOT}/node0" \
  "${PRESTO_NUMA_SYSFS_ROOT}/node1" \
  "${TEST_ROOT}/bin" \
  "${LOGS_DIR}"

printf '%s\n' '0-47,96-143' > "${PRESTO_NUMA_SYSFS_ROOT}/node0/cpulist"
printf '%s\n' '48-95,144-191' > "${PRESTO_NUMA_SYSFS_ROOT}/node1/cpulist"
printf '%s\n' 'Node 0 MemTotal: 1024 kB' > "${PRESTO_NUMA_SYSFS_ROOT}/node0/meminfo"
printf '%s\n' 'Node 1 MemTotal: 1024 kB' > "${PRESTO_NUMA_SYSFS_ROOT}/node1/meminfo"

cat > "${TEST_ROOT}/bin/nvidia-smi" <<'EOF'
#!/bin/bash
if [[ " $* " == *' topo '* ]]; then
  case " $* " in
    *' -i 0 '*)
      printf '%s\n' \
        'NUMA IDs of closest CPU: 0' \
        'NUMA IDs of closest memory: N/A'
      ;;
    *)
      printf '%s\n' \
        'NUMA IDs of closest CPU: 1' \
        'NUMA IDs of closest memory: 1'
      ;;
  esac
else
  printf '%s\n' 'Test GPU'
fi
EOF

cat > "${TEST_ROOT}/bin/numactl" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --show ]]; then
  printf '%s\n' 'policy: bind' 'physcpubind: 0 1' 'membind: 0'
  exit 0
fi
printf '%s\n' "$*" > "${TEST_NUMACTL_ARGS}"
while [[ ${1:-} == --*bind=* ]]; do
  shift
done
exec "$@"
EOF

cat > "${TEST_ROOT}/bin/presto_server" <<'EOF'
#!/bin/bash
case "$*" in
  *fail-fast-sibling*)
    : > "${TEST_SIBLING_READY}"
    trap 'printf "%s\n" terminated > "${TEST_SIBLING_TERMINATED}"; exit 0' TERM
    for _ in {1..1000}; do
      sleep 0.01
    done
    exit 99
    ;;
  *fail-fast-failure*)
    for _ in {1..1000}; do
      [[ -e ${TEST_SIBLING_READY} ]] && exit 42
      sleep 0.01
    done
    exit 98
    ;;
  *fail-fast-clean-exit*)
    for _ in {1..1000}; do
      [[ -e ${TEST_SIBLING_READY} ]] && exit 0
      sleep 0.01
    done
    exit 96
    ;;
  *fail-fast-stubborn-failure*)
    for _ in {1..1000}; do
      [[ -e ${TEST_STUBBORN_READY} ]] && exit 43
      sleep 0.01
    done
    exit 97
    ;;
  *fail-fast-stubborn*)
    : > "${TEST_STUBBORN_READY}"
    trap '' TERM
    while true; do sleep 1; done
    ;;
esac
printf 'mock presto_server %s\n' "$*"
EOF
chmod +x "${TEST_ROOT}/bin/nvidia-smi" "${TEST_ROOT}/bin/numactl" \
  "${TEST_ROOT}/bin/presto_server"

# Sourcing the launcher exposes its topology helpers without starting a server.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/launch_presto_servers.sh"

fail() {
  echo "launch_presto_servers_test.sh: $*" >&2
  exit 1
}

unset PRESTO_GPU_CPUSET PRESTO_GPU_CPU_NUMA_NODE PRESTO_GPU_MEMORY_NUMA_NODE
resolve_gpu_numa_binding 0
[[ ${RESOLVED_GPU_CPUSET} == '0-47,96-143' ]] || fail 'runtime CPU set was not resolved'
[[ ${RESOLVED_GPU_CPU_NODE} == 0 ]] || fail 'runtime CPU node was not resolved'
[[ ${RESOLVED_GPU_MEMORY_NODE} == 0 ]] || fail 'N/A memory affinity did not safely fall back'
[[ ${RESOLVED_GPU_NUMA_SOURCE} == runtime-nvidia-smi ]] || fail 'runtime source was not recorded'

cat > "${TEST_ROOT}/bin/nvidia-smi" <<'EOF'
#!/bin/bash
if [[ " $* " == *' topo '* ]]; then
  printf '%s\n' \
    'NUMA IDs of closest CPU: 0' \
    'NUMA IDs of closest memory: 0,1'
else
  printf '%s\n' 'Test GPU'
fi
EOF
chmod +x "${TEST_ROOT}/bin/nvidia-smi"
if resolve_gpu_numa_binding 0 2> "${TEST_ROOT}/ambiguous-memory.txt"; then
  fail 'ambiguous closest memory topology was accepted'
fi
grep -F 'malformed or ambiguous closest memory NUMA node' \
  "${TEST_ROOT}/ambiguous-memory.txt" >/dev/null ||
  fail 'ambiguous closest memory topology did not explain the error'

# A wedged driver utility must not hang worker startup indefinitely.
cat > "${TEST_ROOT}/bin/nvidia-smi" <<'EOF'
#!/bin/bash
sleep 10
EOF
chmod +x "${TEST_ROOT}/bin/nvidia-smi"
export PRESTO_NVIDIA_SMI_TIMEOUT_SECONDS=1
if run_nvidia_smi topo -C -M -i 0 > /dev/null 2>&1; then
  fail 'bounded nvidia-smi probe unexpectedly succeeded'
else
  timeout_status=$?
fi
[[ $timeout_status == 124 ]] ||
  fail "bounded nvidia-smi probe returned ${timeout_status}, not timeout status 124"
unset PRESTO_NVIDIA_SMI_TIMEOUT_SECONDS

# Restore a valid per-GPU topology for rendered-map validation and launch.
cat > "${TEST_ROOT}/bin/nvidia-smi" <<'EOF'
#!/bin/bash
if [[ " $* " == *' topo '* ]]; then
  case " $* " in
    *' -i 0 '*)
      printf '%s\n' \
        'NUMA IDs of closest CPU: 0' \
        'NUMA IDs of closest memory: N/A'
      ;;
    *)
      printf '%s\n' \
        'NUMA IDs of closest CPU: 1' \
        'NUMA IDs of closest memory: 1'
      ;;
  esac
else
  printf '%s\n' 'Test GPU'
fi
EOF
chmod +x "${TEST_ROOT}/bin/nvidia-smi"

export PRESTO_GPU_CPUSET='48-95,144-191'
export PRESTO_GPU_CPU_NUMA_NODE=1
export PRESTO_GPU_MEMORY_NUMA_NODE=1
resolve_gpu_numa_binding 7
[[ ${RESOLVED_GPU_NUMA_SOURCE} == host-render ]] || fail 'rendered topology did not take precedence'

PRESTO_GPU_CPUSET='0-47,96-143'
if resolve_gpu_numa_binding 7 2> "${TEST_ROOT}/mismatch.txt"; then
  fail 'mismatched rendered CPU set was accepted'
fi
grep -F 'does not match node 1 CPU set' "${TEST_ROOT}/mismatch.txt" >/dev/null ||
  fail 'mismatched rendered CPU set did not explain the error'

export PRESTO_GPU_CPUSET='0-47,96-143'
export PRESTO_GPU_CPU_NUMA_NODE=0
export PRESTO_GPU_MEMORY_NUMA_NODE=0
if resolve_gpu_numa_binding 7 auto 2> "${TEST_ROOT}/stale.txt"; then
  fail 'stale rendered topology was accepted in auto mode'
else
  stale_status=$?
fi
[[ $stale_status == 2 ]] || fail "stale rendered topology returned ${stale_status}, not 2"
grep -F 'Rendered GPU NUMA topology is stale for GPU 7' "${TEST_ROOT}/stale.txt" >/dev/null ||
  fail 'stale rendered topology did not explain the error'

export PRESTO_GPU_CPUSET='0-47,96-143'
export PRESTO_GPU_CPU_NUMA_NODE=0
export PRESTO_GPU_MEMORY_NUMA_NODE=0
export PRESTO_GPU_NUMA_BINDING=required
export TEST_NUMACTL_ARGS="${TEST_ROOT}/numactl.args"
launch_worker 0 /tmp/etc
wait_for_workers

grep -F -- '--physcpubind=0-47,96-143 --membind=0' "${TEST_NUMACTL_ARGS}" >/dev/null ||
  fail 'worker was not launched with strict CPU and memory binding'
WORKER_LOG="${LOGS_DIR}/worker_0_${SERVER_START_TIMESTAMP}.log"
grep -F 'GPU NUMA binding: source=host-render gpu=0 cpu_node=0 cpuset=0-47,96-143 memory_node=0' \
  "${WORKER_LOG}" >/dev/null || fail 'resolved topology was not logged'
grep -F 'Effective NUMA policy:' "${WORKER_LOG}" >/dev/null ||
  fail 'effective policy heading was not logged'
grep -F 'policy: bind' "${WORKER_LOG}" >/dev/null ||
  fail 'effective memory policy was not logged'
grep -F 'mock presto_server --etc-dir=/tmp/etc' "${WORKER_LOG}" >/dev/null ||
  fail 'mock worker was not executed'

# Auto mode may start unbound when runtime topology is unavailable and no
# cgroup cpuset was rendered. Required mode must reject the same condition.
unset PRESTO_GPU_CPUSET PRESTO_GPU_CPU_NUMA_NODE PRESTO_GPU_MEMORY_NUMA_NODE
cat > "${TEST_ROOT}/bin/nvidia-smi" <<'EOF'
#!/bin/bash
if [[ " $* " == *' topo '* ]]; then
  printf '%s\n' \
    'NUMA IDs of closest CPU: 0' \
    'NUMA IDs of closest memory: 0,1'
else
  printf '%s\n' 'Test GPU'
fi
EOF
chmod +x "${TEST_ROOT}/bin/nvidia-smi"

export PRESTO_GPU_NUMA_BINDING=auto
launch_worker 0 auto-fallback
wait_for_workers
grep -F 'continuing without an explicit process policy' \
  "${LOGS_DIR}/worker_0_${SERVER_START_TIMESTAMP}.log" >/dev/null ||
  fail 'auto mode did not report its unbound fallback'

export PRESTO_GPU_NUMA_BINDING=required
if launch_worker 0 required-failure; then
  fail 'required mode accepted unavailable runtime topology'
fi
((${#WORKER_PIDS[@]} == 0)) ||
  fail 'required-mode setup failure left a worker running'

# The off control path must bypass topology and numactl placement entirely.
export PRESTO_GPU_NUMA_BINDING=off
launch_worker 0 numa-off
wait_for_workers
grep -F 'GPU NUMA binding is disabled' \
  "${LOGS_DIR}/worker_0_${SERVER_START_TIMESTAMP}.log" >/dev/null ||
  fail 'off mode was not recorded'

export TEST_SIBLING_READY="${TEST_ROOT}/sibling.ready"
export TEST_SIBLING_TERMINATED="${TEST_ROOT}/sibling.terminated"
launch_worker 1 fail-fast-sibling
launch_worker 2 fail-fast-failure
if wait_for_workers; then
  fail 'worker failure was not propagated by wait_for_workers'
else
  worker_status=$?
fi
[[ $worker_status == 42 ]] ||
  fail "worker failure status was not preserved: ${worker_status}"
[[ -e ${TEST_SIBLING_TERMINATED} ]] ||
  fail 'failed worker did not terminate its running sibling'
((${#WORKER_PIDS[@]} == 0)) ||
  fail 'worker PID state was not cleared after failure'

export TEST_SIBLING_READY="${TEST_ROOT}/clean-exit-sibling.ready"
export TEST_SIBLING_TERMINATED="${TEST_ROOT}/clean-exit-sibling.terminated"
launch_worker 1 fail-fast-sibling
launch_worker 2 fail-fast-clean-exit
if wait_for_workers; then
  fail 'clean worker exit left a degraded worker set running'
else
  worker_status=$?
fi
[[ $worker_status == 1 ]] ||
  fail "unexpected clean worker exit returned ${worker_status}, not 1"
[[ -e ${TEST_SIBLING_TERMINATED} ]] ||
  fail 'clean worker exit did not terminate its running sibling'

export TEST_STUBBORN_READY="${TEST_ROOT}/stubborn.ready"
export PRESTO_WORKER_SHUTDOWN_GRACE_SECONDS=0
launch_worker 3 fail-fast-stubborn
launch_worker 4 fail-fast-stubborn-failure
if wait_for_workers; then
  fail 'stubborn-worker failure was not propagated'
else
  worker_status=$?
fi
[[ $worker_status == 43 ]] ||
  fail "stubborn-worker failure status was not preserved: ${worker_status}"
((${#WORKER_PIDS[@]} == 0)) ||
  fail 'forced worker shutdown left PID state behind'
unset PRESTO_WORKER_SHUTDOWN_GRACE_SECONDS

# Exercise the actual entrypoint wrapper, not only its wait helper: the
# container's top-level status must be the worker's status.
ldconfig() { :; }
export TEST_SIBLING_READY="${TEST_ROOT}/main-sibling.ready"
export TEST_SIBLING_TERMINATED="${TEST_ROOT}/main-sibling.terminated"
if main fail-fast-sibling fail-fast-failure; then
  fail 'main hid a native worker failure'
else
  main_status=$?
fi
[[ $main_status == 42 ]] ||
  fail "main returned ${main_status}, not the worker status 42"
[[ -e ${TEST_SIBLING_TERMINATED} ]] ||
  fail 'main did not terminate the failed worker sibling'

echo 'GPU NUMA launcher tests passed.'
