#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="${OUT_DIR:-${script_dir}/cpu_ucx_trace_${timestamp}}"
coordinator_url="${PRESTO_COORDINATOR_URL:-http://localhost:8080}"
since="${SINCE:-30m}"

mkdir -p "${out}"

capture_queries() {
  local name="$1"
  date -u +%Y-%m-%dT%H:%M:%SZ >"${out}/${name}.time.txt"
  curl -sS --max-time 5 "${coordinator_url}/v1/query" \
    >"${out}/${name}.json" || true
}

capture_queries coordinator_queries.before
cp "${out}/coordinator_queries.before.json" "${out}/coordinator_queries.json" || true

if [[ "$#" -gt 0 ]]; then
  containers=("$@")
else
  mapfile -t containers < <(
    docker ps --format '{{.Names}}' |
      grep '^presto-native-worker-cpu' |
      sort -V
  )
fi

for container in "${containers[@]}"; do
  echo "=== ${container}"

  docker logs --since "${since}" "${container}" \
    >"${out}/${container}.log" 2>&1 || true

  docker exec "${container}" sh -lc \
    'env | sort | grep -E "WORKER_ID|VELOX_UCX|UCX_" || true' \
    >"${out}/${container}.env.txt" 2>&1 || true

  docker exec "${container}" sh -lc \
    'ps -eLo pid,tid,psr,pcpu,stat,wchan:40,comm | sort -k4 -nr | head -100' \
    >"${out}/${container}.threads.txt" 2>&1 || true

  trace_list="${out}/${container}.ucx_cpu_trace.files.txt"
  docker exec "${container}" sh -lc \
    'for f in /tmp/ucx_cpu_trace_*.log; do [ -e "$f" ] || continue; stat -c "%n %s %Y" "$f"; done' \
    >"${trace_list}" 2>&1 || true

  while read -r trace_path _size _mtime; do
    [[ -n "${trace_path:-}" && "${trace_path}" == /tmp/ucx_cpu_trace_*.log ]] || continue
    trace_base="$(basename "${trace_path}")"
    echo "copying ${container}:${trace_path}"
    docker cp "${container}:${trace_path}" "${out}/${container}.${trace_base}" || true
  done <"${trace_list}"
done

capture_queries coordinator_queries.after
echo "${out}"
