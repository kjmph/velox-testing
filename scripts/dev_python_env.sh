#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

# Lightweight, persistent Python venv helper for local developer workflows.
# This does not create or delete conda environments, but it can use a
# conda-provided Python interpreter when one is active.

function dev_python_can_create_venv() {
  "$1" - <<'PY' >/dev/null 2>&1
import venv
PY
  return $?
}

function dev_python_has_ensurepip() {
  "$1" - <<'PY' >/dev/null 2>&1
import ensurepip
PY
}

function dev_python_can_bootstrap_pip() {
  if dev_python_has_ensurepip "$1"; then
    return 0
  fi

  "$1" -m pip --version >/dev/null 2>&1
}

function dev_python_resolve_candidate() {
  local candidate=$1

  if [[ -n "$candidate" && -x "$candidate" ]]; then
    echo "$candidate"
    return 0
  elif [[ -n "$candidate" ]] && command -v "$candidate" >/dev/null 2>&1; then
    command -v "$candidate"
    return 0
  fi
  return 1
}

function dev_python_find_interpreter() {
  local candidates=()
  local candidate
  local resolved

  candidates+=("${VELOX_DEV_PYTHON:-}")
  candidates+=("${PYTHON:-}")
  [[ -n "${CONDA_PREFIX:-}" ]] && candidates+=("${CONDA_PREFIX}/bin/python")
  candidates+=(python3.12 python3 python)

  for candidate in "${candidates[@]}"; do
    resolved=$(dev_python_resolve_candidate "$candidate" || true)
    [[ -n "$resolved" ]] || continue

    if dev_python_can_create_venv "$resolved" && dev_python_can_bootstrap_pip "$resolved"; then
      echo "$resolved"
      return 0
    fi
  done

  echo "Error: no Python interpreter with venv and ensurepip support was found." >&2
  echo "Set VELOX_DEV_PYTHON to a conda/miniforge Python or install python3.12-venv." >&2
  return 1
}

function dev_python_create_venv() {
  local python_bin=$1
  local venv_dir=$2

  if dev_python_has_ensurepip "$python_bin"; then
    "$python_bin" -m venv "$venv_dir"
    return $?
  fi

  if ! "$python_bin" -m pip --version >/dev/null 2>&1; then
    return 1
  fi

  echo "Creating venv without ensurepip; bootstrapping pip from $python_bin"
  "$python_bin" -m venv --without-pip "$venv_dir"
  "$python_bin" -m pip --python "$venv_dir/bin/python" install -q pip
}

function dev_python_can_remove_env_path() {
  local venv_dir=$1
  local base
  base="$(basename "$venv_dir")"

  [[ "$base" == .venv* || "$base" == venv ]]
}

function dev_python_remove_env_path() {
  local venv_dir=$1

  if ! dev_python_can_remove_env_path "$venv_dir"; then
    echo "Error: refusing to remove non-venv-looking path: $venv_dir" >&2
    echo "Use a directory named .venv*, venv, or remove the path manually." >&2
    return 1
  fi

  rm -rf "$venv_dir"
}

function dev_python_activate() {
  local venv_dir=$1
  local requirements_file=${2:-}
  local python_bin
  local env_ready=false

  python_bin=$(dev_python_find_interpreter)
  mkdir -p "$(dirname "$venv_dir")"

  if [[ -f "$venv_dir/pyvenv.cfg" ]]; then
    if [[ -f "$venv_dir/bin/activate" && -x "$venv_dir/bin/python" ]]; then
      echo "Reusing Python virtual environment at $venv_dir"
      # shellcheck disable=SC1091
      source "$venv_dir/bin/activate"
      env_ready=true
    else
      echo "Recreating incomplete Python virtual environment at $venv_dir"
      dev_python_remove_env_path "$venv_dir" || return 1
    fi
  elif [[ -d "$venv_dir/conda-meta" ]]; then
    if [[ -x "$venv_dir/bin/python" ]]; then
      echo "Using existing conda environment at $venv_dir"
      export PATH="$venv_dir/bin:$PATH"
      hash -r
      env_ready=true
    else
      echo "Error: conda environment at $venv_dir has no executable bin/python" >&2
      return 1
    fi
  fi

  if [[ "$env_ready" != "true" ]]; then
    if [[ -e "$venv_dir" ]]; then
      echo "Removing non-venv path at $venv_dir"
      dev_python_remove_env_path "$venv_dir" || return 1
    fi
    echo "Creating Python virtual environment at $venv_dir"
    if ! dev_python_create_venv "$python_bin" "$venv_dir"; then
      dev_python_remove_env_path "$venv_dir" || return 1
      return 1
    fi

    if [[ ! -f "$venv_dir/bin/activate" || ! -x "$venv_dir/bin/python" ]]; then
      echo "Error: failed to create a complete virtual environment at $venv_dir" >&2
      dev_python_remove_env_path "$venv_dir" || return 1
      return 1
    fi

    # shellcheck disable=SC1091
    source "$venv_dir/bin/activate"
  fi

  if [[ -n "$requirements_file" ]]; then
    if [[ ! -f "$requirements_file" ]]; then
      echo "Error: requirements file not found: $requirements_file" >&2
      return 1
    fi

    local stamp_file="$venv_dir/.requirements_install_stamp"
    local requirements_hash
    local python_fingerprint
    local desired_stamp
    requirements_hash="$(sha256sum "$requirements_file" | awk '{print $1}')"
    python_fingerprint="$(python - <<'PY'
import sys

print(f"{sys.executable}|{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
PY
)"
    desired_stamp="${requirements_hash} ${python_fingerprint}"

    if [[ ! -f "$stamp_file" ]] || [[ "$(cat "$stamp_file")" != "$desired_stamp" ]]; then
      echo "Installing Python requirements from $requirements_file"
      python -m pip install -q -r "$requirements_file"
      printf "%s\n" "$desired_stamp" > "$stamp_file"
    else
      echo "Python requirements unchanged for $venv_dir"
    fi
  fi
}
