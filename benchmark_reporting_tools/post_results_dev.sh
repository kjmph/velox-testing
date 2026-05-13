#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${BENCHMARK_REPORTING_VENV_DIR:-${SCRIPT_DIR}/.venv-reporting}"

# shellcheck source=../scripts/dev_python_env.sh
source "${REPO_ROOT}/scripts/dev_python_env.sh"

dev_python_activate "$VENV_DIR" "${SCRIPT_DIR}/requirements.txt"
python "${SCRIPT_DIR}/post_results.py" "$@"
