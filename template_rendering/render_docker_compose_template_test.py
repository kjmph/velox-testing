#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from jinja2 import Environment, FileSystemLoader

sys.path.insert(0, os.path.dirname(__file__))
import render_docker_compose_template as renderer
from render_docker_compose_template import detect_gpu_numa_binding


def completed(stdout, returncode=0):
    def run(*_args, **_kwargs):
        return SimpleNamespace(stdout=stdout, stderr="", returncode=returncode)

    return run


class DetectGpuNumaBindingTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.node_dir = self.temp_dir.name
        self.add_node(0, "0-47,96-143", 1024)
        self.add_node(1, "48-95,144-191", 2048)

    def tearDown(self):
        self.temp_dir.cleanup()

    def add_node(self, node, cpulist, memory_kb):
        path = os.path.join(self.node_dir, f"node{node}")
        os.makedirs(path)
        with open(os.path.join(path, "cpulist"), "w", encoding="utf-8") as output:
            output.write(f"{cpulist}\n")
        with open(os.path.join(path, "meminfo"), "w", encoding="utf-8") as output:
            output.write(f"Node {node} MemTotal: {memory_kb} kB\n")

    def test_uses_distinct_closest_cpu_and_memory_nodes(self):
        binding = detect_gpu_numa_binding(
            3,
            self.node_dir,
            completed("NUMA IDs of closest CPU: 0\nNUMA IDs of closest memory: 1\n"),
        )

        self.assertEqual(
            binding,
            {
                "cpu_node": 0,
                "memory_node": 1,
                "cpuset": "0-47,96-143",
                "source": "nvidia-smi",
            },
        )

    def test_pcie_gpu_without_memory_affinity_uses_memory_bearing_cpu_node(self):
        binding = detect_gpu_numa_binding(
            0,
            self.node_dir,
            completed("NUMA IDs of closest CPU: 0\nNUMA IDs of closest memory: N/A\n"),
        )

        self.assertEqual(binding["memory_node"], 0)

    def test_rejects_ambiguous_cpu_affinity(self):
        binding = detect_gpu_numa_binding(
            0,
            self.node_dir,
            completed("NUMA IDs of closest CPU: 0,1\nNUMA IDs of closest memory: 0\n"),
        )

        self.assertIsNone(binding)

    def test_rejects_ambiguous_memory_affinity(self):
        binding = detect_gpu_numa_binding(
            0,
            self.node_dir,
            completed("NUMA IDs of closest CPU: 0\nNUMA IDs of closest memory: 0,1\n"),
        )

        self.assertIsNone(binding)

    def test_rejects_missing_memory_affinity_field(self):
        binding = detect_gpu_numa_binding(
            0,
            self.node_dir,
            completed("NUMA IDs of closest CPU: 0\n"),
        )

        self.assertIsNone(binding)

    def test_rejects_memoryless_fallback_node(self):
        with open(os.path.join(self.node_dir, "node0", "meminfo"), "w", encoding="utf-8") as output:
            output.write("Node 0 MemTotal: 0 kB\n")

        binding = detect_gpu_numa_binding(
            0,
            self.node_dir,
            completed("NUMA IDs of closest CPU: 0\nNUMA IDs of closest memory: N/A\n"),
        )

        self.assertIsNone(binding)

    def test_command_failure_is_a_safe_fallback(self):
        binding = detect_gpu_numa_binding(
            0,
            self.node_dir,
            completed("", returncode=1),
        )

        self.assertIsNone(binding)

    def test_command_timeout_is_a_safe_fallback(self):
        def timeout(*args, **kwargs):
            raise subprocess.TimeoutExpired(args[0], kwargs["timeout"])

        self.assertIsNone(detect_gpu_numa_binding(0, self.node_dir, timeout))

    def test_topology_probe_has_a_bounded_timeout(self):
        observed = {}

        def run(*_args, **kwargs):
            observed.update(kwargs)
            return SimpleNamespace(
                stdout="NUMA IDs of closest CPU: 0\nNUMA IDs of closest memory: 0\n",
                stderr="",
                returncode=0,
            )

        self.assertIsNotNone(detect_gpu_numa_binding(0, self.node_dir, run))
        self.assertEqual(observed["timeout"], 5)

    @staticmethod
    def gpu_template():
        template_dir = os.path.join(
            os.path.dirname(__file__),
            "..",
            "presto",
            "docker",
            "docker-compose",
            "template",
        )
        return Environment(
            loader=FileSystemLoader(template_dir),
            autoescape=False,
            keep_trailing_newline=True,
        ).get_template("docker-compose.native-gpu.yml.jinja")

    def test_gpu_template_emits_hard_cpuset_labels_and_runtime_fallback(self):
        rendered = self.gpu_template().render(
            num_workers=2,
            workers=[0, 1],
            single_container=False,
            kvikio_threads=8,
            sccache=False,
            variant="gpu",
            gpu_numa_binding="auto",
            gpu_numa_bindings={
                0: {
                    "cpu_node": 0,
                    "memory_node": 0,
                    "cpuset": "0-47,96-143",
                }
            },
        )

        self.assertIn('cpuset: "0-47,96-143"', rendered)
        self.assertIn('PRESTO_GPU_MEMORY_NUMA_NODE: "0"', rendered)
        self.assertIn('com.nvidia.velox-testing.gpu-numa-cpuset: "0-47,96-143"', rendered)
        self.assertIn('com.nvidia.velox-testing.gpu-numa-topology-source: "runtime-discovery"', rendered)

    def test_gpu_template_defaults_to_runtime_discovery_without_new_context(self):
        rendered = self.gpu_template().render(
            num_workers=2,
            workers=[0, 1],
            single_container=False,
            kvikio_threads=8,
            sccache=False,
            variant="gpu",
        )

        self.assertIn('PRESTO_GPU_NUMA_BINDING: "auto"', rendered)
        self.assertIn('com.nvidia.velox-testing.gpu-numa-topology-source: "runtime-discovery"', rendered)
        self.assertNotIn("cpuset:", rendered)

    def test_off_policy_suppresses_rendered_topology(self):
        rendered = self.gpu_template().render(
            num_workers=2,
            workers=[0, 1],
            single_container=False,
            kvikio_threads=8,
            sccache=False,
            variant="gpu",
            gpu_numa_binding="off",
            gpu_numa_bindings={
                0: {
                    "cpu_node": 0,
                    "memory_node": 0,
                    "cpuset": "0-47,96-143",
                }
            },
        )

        self.assertIn('PRESTO_GPU_NUMA_BINDING: "off"', rendered)
        self.assertIn('com.nvidia.velox-testing.gpu-numa-topology-source: "disabled"', rendered)
        self.assertNotIn("PRESTO_GPU_CPUSET:", rendered)
        self.assertNotIn("cpuset:", rendered)

    def test_main_off_policy_does_not_probe_gpu_topology(self):
        template_path = os.path.join(
            os.path.dirname(__file__),
            "..",
            "presto",
            "docker",
            "docker-compose",
            "template",
            "docker-compose.native-gpu.yml.jinja",
        )
        output_path = os.path.join(self.node_dir, "rendered.yml")
        argv = [
            "render_docker_compose_template.py",
            "--template-path",
            template_path,
            "--output-path",
            output_path,
            "--num-workers",
            "2",
            "--single-container",
            "false",
            "--kvikio-threads",
            "8",
            "--variant",
            "gpu",
            "--gpu-numa-binding",
            "off",
        ]

        with (
            patch.object(sys, "argv", argv),
            patch.object(
                renderer,
                "detect_gpu_numa_binding",
                side_effect=AssertionError("off policy must not probe GPU topology"),
            ),
        ):
            self.assertEqual(renderer.main(), 0)

        with open(output_path, encoding="utf-8") as output:
            rendered = output.read()
        self.assertIn('PRESTO_GPU_NUMA_BINDING: "off"', rendered)

    def test_invalid_environment_policy_is_rejected(self):
        argv = [
            "render_docker_compose_template.py",
            "--template-path",
            "unused.jinja",
            "--output-path",
            "unused.yml",
            "--num-workers",
            "1",
            "--single-container",
            "false",
        ]

        with (
            patch.object(sys, "argv", argv),
            patch.dict(os.environ, {"PRESTO_GPU_NUMA_BINDING": "bogus"}),
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as raised,
        ):
            renderer.parse_args()

        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
