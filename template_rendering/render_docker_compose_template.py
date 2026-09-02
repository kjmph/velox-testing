#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import argparse
import os
import re
import subprocess
import sys


def detect_numa_nodes():
    """Return list of NUMA node IDs visible on this host.

    Reads /sys/devices/system/node/node<N> entries. Falls back to [0] when
    the sysfs layout is unavailable (non-Linux, minimal container, etc.).
    """
    node_dir = "/sys/devices/system/node"
    if not os.path.isdir(node_dir):
        return [0]
    nodes = []
    for entry in sorted(os.listdir(node_dir)):
        m = re.match(r"^node(\d+)$", entry)
        if m:
            nodes.append(int(m.group(1)))
    return nodes or [0]


_NUMA_NOT_APPLICABLE = object()
_NVIDIA_SMI_TIMEOUT_SECONDS = 5


def _parse_nvidia_topology_node(output: str, label: str):
    """Return one NUMA node or the explicit N/A sentinel.

    nvidia-smi calls these fields "NUMA IDs" because some platforms may
    report more than one.  A process cannot be strictly memory-bound to an
    ambiguous closest node, so only one numeric ID is accepted here. Missing,
    malformed, and multi-node values are distinct from an explicit N/A.
    """
    matches = re.findall(rf"^{re.escape(label)}:\s*(.+?)\s*$", output, re.MULTILINE)
    if len(matches) != 1:
        return None
    value = matches[0].strip()
    if re.fullmatch(r"\d+", value):
        return int(value)
    if value == "N/A":
        return _NUMA_NOT_APPLICABLE
    return None


def _read_node_cpulist(node_dir: str, node: int):
    path = os.path.join(node_dir, f"node{node}", "cpulist")
    try:
        with open(path, encoding="utf-8") as cpulist_file:
            cpulist = cpulist_file.read().strip()
    except OSError:
        return None

    range_element = r"\d+(?:-\d+)?"
    if not cpulist or not re.fullmatch(rf"{range_element}(?:,{range_element})*", cpulist):
        return None
    return cpulist


def _node_has_memory(node_dir: str, node: int):
    meminfo_path = os.path.join(node_dir, f"node{node}", "meminfo")
    try:
        with open(meminfo_path, encoding="utf-8") as meminfo_file:
            meminfo = meminfo_file.read()
    except OSError:
        return False

    match = re.search(r"MemTotal:\s*(\d+)\s+kB", meminfo)
    return bool(match and int(match.group(1)) > 0)


def detect_gpu_numa_binding(
    gpu_id: int,
    node_dir: str = "/sys/devices/system/node",
    command_runner=subprocess.run,
):
    """Discover a strict CPU and memory binding for one physical GPU.

    The rendered Compose service receives a cgroup CPU set and the worker
    launcher receives the corresponding memory node.  Return None instead of
    guessing when topology is absent or ambiguous; the launcher then performs
    the same discovery inside the worker and otherwise starts unbound in its
    default best-effort mode.
    """
    try:
        result = command_runner(
            ["nvidia-smi", "topo", "-C", "-M", "-i", str(gpu_id)],
            check=False,
            capture_output=True,
            text=True,
            timeout=_NVIDIA_SMI_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    if result.returncode != 0:
        return None

    cpu_node = _parse_nvidia_topology_node(result.stdout, "NUMA IDs of closest CPU")
    memory_node = _parse_nvidia_topology_node(result.stdout, "NUMA IDs of closest memory")
    if not isinstance(cpu_node, int):
        return None

    cpulist = _read_node_cpulist(node_dir, cpu_node)
    if cpulist is None:
        return None

    # PCIe GPUs commonly report N/A for closest memory.  The closest CPU node
    # is a safe fallback only when sysfs confirms that it owns local memory.
    if memory_node is _NUMA_NOT_APPLICABLE:
        memory_node = cpu_node
    elif not isinstance(memory_node, int):
        return None
    if not _node_has_memory(node_dir, memory_node):
        return None

    return {
        "cpu_node": cpu_node,
        "memory_node": memory_node,
        "cpuset": cpulist,
        "source": "nvidia-smi",
    }


def parse_args():
    parser = argparse.ArgumentParser(description="Render a Docker Compose template")

    # Helper to parse boolean-like strings passed from shell (e.g., "true"/"false")
    def str_to_bool(value: str) -> bool:
        truthy = {"1", "true", "t", "yes", "y", "on"}
        falsy = {"0", "false", "f", "no", "n", "off"}
        val = value.strip().lower()
        if val in truthy:
            return True
        if val in falsy:
            return False
        raise argparse.ArgumentTypeError(f"Invalid boolean value: {value}")

    parser.add_argument(
        "--template-path", type=str, required=True, dest="template_path", help="Path to the template file"
    )
    parser.add_argument("--output-path", type=str, required=True, dest="output_path", help="Path to the output file")
    parser.add_argument("--num-workers", type=int, required=True, dest="num_workers", help="Number of workers")
    parser.add_argument(
        "--single-container",
        type=str_to_bool,
        required=True,
        dest="single_container",
        help="Whether to run in a single container",
    )
    parser.add_argument(
        "--gpu-ids", type=str, default=None, dest="gpu_ids", required=False, help="Comma-delimited list of GPU IDs"
    )
    parser.add_argument(
        "--kvikio-threads",
        type=int,
        default=None,
        dest="kvikio_threads",
        required=False,
        help="Number of KvikIO threads (optional).",
    )
    parser.add_argument(
        "--sccache",
        type=str_to_bool,
        default=False,
        dest="sccache",
        required=False,
        help="Enable sccache build secrets in the rendered compose file.",
    )
    parser.add_argument(
        "--variant",
        type=str,
        default="gpu",
        choices=["gpu", "cpu"],
        dest="variant",
        required=False,
        help="Which variant this template describes. 'cpu' uses NUMA-node assignment; "
        "'gpu' uses per-GPU assignment via --gpu-ids.",
    )
    parser.add_argument(
        "--gpu-numa-binding",
        type=str,
        default=os.environ.get("PRESTO_GPU_NUMA_BINDING", "auto"),
        choices=["auto", "required", "off"],
        dest="gpu_numa_binding",
        required=False,
        help="GPU NUMA placement policy. Defaults to PRESTO_GPU_NUMA_BINDING or 'auto'.",
    )
    parsed_args = parser.parse_args()
    if parsed_args.gpu_numa_binding not in {"auto", "required", "off"}:
        parser.error("--gpu-numa-binding (or PRESTO_GPU_NUMA_BINDING) must be one of: auto, required, off")
    return parsed_args


def main() -> int:
    parsed_args = parse_args()

    # Parse GPU IDs if provided
    gpu_ids = None
    if parsed_args.gpu_ids:
        gpu_ids = [int(gpu_id.strip()) for gpu_id in parsed_args.gpu_ids.split(",")]
        if len(gpu_ids) != parsed_args.num_workers:
            print(
                f"ERROR: Number of GPU IDs ({len(gpu_ids)}) must match num_workers ({parsed_args.num_workers})",
                file=sys.stderr,
            )
            return 2

    try:
        from jinja2 import Environment, FileSystemLoader
    except Exception:
        print("ERROR: Jinja2 is required. Install it via requirements.txt using run_py_script.sh.", file=sys.stderr)
        return 1

    env = Environment(
        loader=FileSystemLoader(os.path.dirname(parsed_args.template_path)),
        autoescape=False,
        keep_trailing_newline=True,
    )
    template = env.get_template(os.path.basename(parsed_args.template_path))

    # Build the worker list.
    # - GPU variant (default): plain list of GPU IDs. Preserves the existing
    #   contract the GPU template expects (worker loop variable is the GPU id).
    # - CPU variant: list of dicts with {id, numa_node}. NUMA assignment is
    #   round-robin across the NUMA nodes detected on the host so that with
    #   --num-workers equal to the node count each worker lands on its own
    #   socket. With fewer workers than nodes, leading nodes are used.
    if parsed_args.variant == "gpu":
        if gpu_ids:
            workers = gpu_ids
        else:
            workers = list(range(max(0, parsed_args.num_workers)))
    else:
        numa_nodes = detect_numa_nodes()
        workers = [
            {"id": i, "numa_node": numa_nodes[i % len(numa_nodes)]} for i in range(max(0, parsed_args.num_workers))
        ]

    gpu_numa_bindings = {}
    if parsed_args.variant == "gpu" and not parsed_args.single_container and parsed_args.gpu_numa_binding != "off":
        for gpu_id in workers:
            binding = detect_gpu_numa_binding(gpu_id)
            if binding is None:
                print(
                    f"WARNING: could not resolve an unambiguous NUMA binding for GPU {gpu_id}; "
                    "the worker launcher will retry topology discovery at runtime",
                    file=sys.stderr,
                )
            else:
                gpu_numa_bindings[gpu_id] = binding

    rendered = template.render(
        num_workers=parsed_args.num_workers,
        workers=workers,
        single_container=parsed_args.single_container,
        kvikio_threads=parsed_args.kvikio_threads,
        sccache=parsed_args.sccache,
        variant=parsed_args.variant,
        gpu_numa_bindings=gpu_numa_bindings,
        gpu_numa_binding=parsed_args.gpu_numa_binding,
    )

    os.makedirs(os.path.dirname(parsed_args.output_path), exist_ok=True)
    with open(parsed_args.output_path, "w") as f:
        f.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
