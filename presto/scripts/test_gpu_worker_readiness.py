# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Run the launcher's shell checks against local HTTP endpoints."""

import json
import os
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).with_name("start_native_gpu_presto_dev.sh").read_text()
CHECK_ENDPOINTS = (
    "function verify_gpu_worker_endpoints() {"
    + SCRIPT.split("function verify_gpu_worker_endpoints() {", 1)[1].split('\ncase "$DEV_RESTART_TARGET" in', 1)[0]
)
COUNT_WORKERS = (
    "workers=$(python3 - <<'PY'\n"
    + SCRIPT.split("workers=$(python3 - <<'PY'\n", 1)[1].split("\nPY\n)", 1)[0]
    + '\nPY\n)\nprintf "%s\\n" "$workers"'
)
WAIT_LOOP = SCRIPT[SCRIPT.rindex('\nif [[ "$WAIT_FOR_WORKERS" == "true" ]]; then') :]


class HttpReadinessTest(unittest.TestCase):
    def setUp(self):
        self.responses = {
            "/v1/info/state": "ACTIVE",
            "/v1/cluster?includeLocalInfoOnly=true": {"activeWorkers": 8},
        }
        responses = self.responses
        self.requests = requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                requests.append(self.path)
                value = responses.get(self.path)
                if value is None:
                    self.send_error(503)
                    return
                body = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        servers = []
        for _ in range(2):
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=lambda server=server: server.serve_forever(poll_interval=0.05), daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            servers.append(server)
        self.coordinator = f"http://127.0.0.1:{servers[0].server_port}"
        self.worker_port = servers[1].server_port
        self.responses["/v1/node"] = [{"uri": f"http://127.0.0.1:{self.worker_port}/v1/status"}]

    def run_shell(self, code):
        return subprocess.run(
            ["bash", "-c", code.replace("http://localhost:8080", self.coordinator)],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "http_proxy": "http://proxy.invalid:1",
                "HTTP_PROXY": "http://proxy.invalid:1",
                "no_proxy": "",
                "NO_PROXY": "",
            },
        )

    def check_endpoints(self):
        setup = f"""
set -euo pipefail
UCX_EFA=true
PRESTO_WORKER_INTERNAL_ADDRESS=127.0.0.1
gpu_expected_worker_entries() {{ printf '0 worker-0 {self.worker_port}\\n'; }}
"""
        return self.run_shell(setup + CHECK_ENDPOINTS + "\nverify_gpu_worker_endpoints")

    def test_direct_health_uses_get_only_without_dns_or_proxy(self):
        result = self.check_endpoints()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests, ["/v1/node", "/v1/info/state"])

    def test_starting_or_unavailable_worker_does_not_pass(self):
        for state in ("STARTING", None):
            with self.subTest(state=state):
                self.responses["/v1/info/state"] = state
                self.assertEqual(self.check_endpoints().returncode, 1)

    def test_wrong_registered_endpoint_does_not_pass(self):
        self.responses["/v1/node"] = [{"uri": f"http://127.0.0.99:{self.worker_port}/v1/status"}]
        self.assertEqual(self.check_endpoints().returncode, 1)

    def test_count_uses_active_workers_not_discovery_inventory(self):
        self.responses["/v1/node"] *= 8
        for response, expected in (({"activeWorkers": 1}, "1"), ({"activeWorkers": 8}, "8"), (None, "0"), ({}, "0")):
            with self.subTest(response=response):
                self.responses["/v1/cluster?includeLocalInfoOnly=true"] = response
                result = self.run_shell(COUNT_WORKERS)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
        self.assertNotIn("/v1/node", self.requests)


class WaitLoopTest(unittest.TestCase):
    def test_waits_for_both_conditions_twice_and_keeps_timeout(self):
        cases = [
            ("echo 8", ":", 30, 0, "ready_at=5"),
            ("if ((now < 5)); then echo 1; else echo 8; fi", ":", 30, 0, "ready_at=10"),
            ("echo 8", '[[ "$now" -ne 5 ]]', 30, 0, "ready_at=15"),
            ("echo 8", ":", 3, 1, ""),
            ("echo 1", ":", 10, 1, ""),
            ("echo 9", ":", 10, 1, ""),
        ]
        for count, health, timeout, status, message in cases:
            with self.subTest(count=count, health=health, timeout=timeout):
                setup = f"""
set -euo pipefail
now=0
NUM_WORKERS=1
WAIT_FOR_WORKERS=true
WAIT_FOR_WORKERS_TIMEOUT={timeout}
gpu_expected_worker_entries() {{ printf '%s\\n' {{0..7}}; }}
date() {{ echo "$now"; }}
sleep() {{ now=$((now + $1)); }}
python3() {{ {count}; }}
verify_gpu_worker_endpoints() {{ {health}; }}
fail_if_gpu_workers_exited() {{ :; }}
"""
                result = subprocess.run(
                    ["bash", "-c", setup + WAIT_LOOP + '\necho "ready_at=$now"'], capture_output=True, text=True
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(message, result.stdout)

    def test_native_template_excludes_coordinator_from_count(self):
        config = Path(__file__).parents[1] / "docker/config/template/etc_coordinator/config_native.properties"
        self.assertIn("node-scheduler.include-coordinator=false", config.read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
