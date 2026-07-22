#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_out_root="$(cd "${script_dir}/../../.." && pwd)"
out_root="${OUT_ROOT:-${default_out_root}}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="${OUT_DIR:-${out_root}/deadlock_debug_${timestamp}_server_stacks}"

if [[ "$#" -gt 0 ]]; then
  containers=("$@")
else
  containers=(
    presto-native-worker-gpu-0
    presto-native-worker-gpu-2
    presto-native-worker-gpu-3
    presto-native-worker-gpu-4
    presto-native-worker-gpu-5
    presto-native-worker-gpu-6
    presto-native-worker-gpu-7
  )
fi

mkdir -p "${out}"

for container in "${containers[@]}"; do
  echo "=== ${container}"

  {
    echo "-- container env"
    docker exec "${container}" sh -lc \
      'env | sort | grep -E "CUDA_VISIBLE_DEVICES|WORKER_ID|VELOX_UCX|UCX_TLS|UCX_LOG_LEVEL" || true'
  } >"${out}/${container}.env.txt" 2>&1 || true

  docker top "${container}" -eo pid,ppid,stat,comm,args \
    >"${out}/${container}.top.txt" 2>&1 || true

  mapfile -t pids < <(
    awk '
      NR > 1 && $4 == "presto_server" && $5 == "presto_server" { print $1 }
      NR > 1 && $4 == "presto_server" && $5 != "presto_server" { fallback[++n] = $1 }
      END {
        if (NR > 1) {
          for (i = 1; i <= n; ++i) {
            print fallback[i]
          }
        }
      }
    ' "${out}/${container}.top.txt" | awk '!seen[$0]++'
  )

  if [[ "${#pids[@]}" -eq 0 ]]; then
    echo "No presto_server PID found for ${container}" \
      | tee "${out}/${container}.pid.txt"
    continue
  fi

  printf '%s\n' "${pids[@]}" >"${out}/${container}.pid.txt"

  for pid in "${pids[@]}"; do
    echo "capturing ${container} pid=${pid}"

    ps -L -p "${pid}" -o pid,tid,stat,comm,pcpu,wchan:40,args --sort=-pcpu \
      >"${out}/${container}.${pid}.threads.txt" 2>&1 || true

    sudo gdb -batch \
      -ex "set pagination off" \
      -ex "info threads" \
      -ex "thread apply all bt" \
      -p "${pid}" \
      >"${out}/${container}.${pid}.gdb.txt" 2>&1 || true
  done
done

echo "${out}"
