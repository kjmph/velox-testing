#!/usr/bin/env bash

# Read-only GDS/RoCE rail check for a GB200 compute node.
#
# Defaults target physical GPU 2 (NUMA node 1) and its prepared 10 GiB GDS
# data set.  The first positional argument or GDS_DATASET can override it.

set -uo pipefail

GDSIO=${GDSIO:-/usr/local/cuda/gds/tools/gdsio}
GPU=${GPU:-2}
CPU_BIND=${CPU_BIND:-72-87}
MEM_NODE=${MEM_NODE:-1}
RUN_SECONDS=${RUN_SECONDS:-20}
DATASET=${1:-${GDS_DATASET:-/scratch/gds-bench/gpu${GPU}-10g}}

rails=(rail0 rail1 rail2 rail3)
# On GB200 compute nodes, rail2 is mlx5_4; mlx5_2 is a BlueField/bond0 HCA.
devices=(mlx5_0 mlx5_1 mlx5_4 mlx5_5)

if [[ ! -x "$GDSIO" ]]; then
    printf 'ERROR: gdsio is not executable: %s\n' "$GDSIO" >&2
    exit 2
fi

if [[ ! -d "$DATASET" ]]; then
    printf 'ERROR: GDS data directory does not exist: %s\n' "$DATASET" >&2
    printf 'Existing candidate directories:\n' >&2
    find /scratch/gds-bench -mindepth 1 -maxdepth 1 -type d -print \
        2>/dev/null >&2 || true
    exit 2
fi

if [[ -z "$(find "$DATASET" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]]; then
    printf 'ERROR: GDS data directory contains no files: %s\n' "$DATASET" >&2
    exit 2
fi

before=()
for i in "${!devices[@]}"; do
    counter="/sys/class/infiniband/${devices[$i]}/ports/1/counters/port_rcv_data"
    if [[ ! -r "$counter" ]]; then
        printf 'ERROR: receive-data counter is not readable: %s\n' "$counter" >&2
        exit 2
    fi
    before[$i]=$(<"$counter")
    if [[ ! ${before[$i]} =~ ^[0-9]+$ ]]; then
        printf 'ERROR: nonnumeric value in %s: %q\n' "$counter" "${before[$i]}" >&2
        exit 2
    fi
done

stamp=$(date -u +%Y%m%dT%H%M%SZ)
log="/var/tmp/$(hostname -s)-gpu${GPU}-gds-rail-${stamp}.txt"

printf 'host=%s dataset=%s physical_gpu=%s cpu_bind=%s mem_node=%s\n' \
    "$(hostname -f 2>/dev/null || hostname)" "$DATASET" "$GPU" "$CPU_BIND" "$MEM_NODE"
printf 'compute mapping: rail0=mlx5_0 rail1=mlx5_1 rail2=mlx5_4 rail3=mlx5_5\n'

started=$(date +%s)
CUDA_VISIBLE_DEVICES="$GPU" \
    numactl --physcpubind="$CPU_BIND" --membind="$MEM_NODE" \
    "$GDSIO" \
        -D "$DATASET" \
        -w 16 -s 10G -i 1M -I 0 -d 0 -n "$MEM_NODE" -x 0 \
        -T "$RUN_SECONDS" \
        2>&1 | tee "$log"
gdsio_rc=${PIPESTATUS[0]}
ended=$(date +%s)
elapsed=$((ended - started))
if (( elapsed < 1 )); then
    elapsed=1
fi

printf '\ngdsio_rc=%d elapsed=%ds\n' "$gdsio_rc" "$elapsed"
printf 'port_rcv_data deltas (the counter is in 4-byte words):\n'

for i in "${!devices[@]}"; do
    dev=${devices[$i]}
    counter="/sys/class/infiniband/${dev}/ports/1/counters/port_rcv_data"
    after=$(<"$counter")
    if [[ ! $after =~ ^[0-9]+$ ]]; then
        printf '%s %-6s ERROR: nonnumeric after value: %q\n' \
            "${rails[$i]}" "$dev" "$after"
        continue
    fi

    delta_words=$((after - before[$i]))
    if (( delta_words < 0 )); then
        printf '%s %-6s ERROR: counter reset or wrapped (%s -> %s)\n' \
            "${rails[$i]}" "$dev" "${before[$i]}" "$after"
        continue
    fi

    # Keep one decimal place using only Bash integer arithmetic.
    mib_tenths=$((delta_words * 40 / 1048576))
    rate_tenths=$((mib_tenths / elapsed))
    printf '%s %-6s received=%10d.%01d MiB  average=%8d.%01d MiB/s\n' \
        "${rails[$i]}" "$dev" \
        "$((mib_tenths / 10))" "$((mib_tenths % 10))" \
        "$((rate_tenths / 10))" "$((rate_tenths % 10))"
done

printf 'log=%s\n' "$log"
exit "$gdsio_rc"
