#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

expected_version="${PRESTO_EXPECTED_UCX_VERSION:-}"
expected_hash="${PRESTO_EXPECTED_UCX_SOURCE_HASH:-}"
marker_dir="${PRESTO_UCX_MARKER_DIR:-/opt/presto-ucx-build}"
temp_files=()

cleanup() {
  rm -f -- "${temp_files[@]}"
}
trap cleanup EXIT

if [[ -z "$expected_version" || -z "$expected_hash" ]]; then
  echo "Exact UCX verification requires PRESTO_EXPECTED_UCX_VERSION and PRESTO_EXPECTED_UCX_SOURCE_HASH." >&2
  exit 1
fi
if [[ "$expected_hash" == none || ! "$expected_hash" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid exact UCX source hash: ${expected_hash:-unset}" >&2
  exit 1
fi
ucx_info="${PRESTO_UCX_INFO:-$(command -v ucx_info || true)}"
if [[ ! -x "$ucx_info" ]]; then
  echo "ucx_info is missing from the worker image." >&2
  exit 1
fi
for marker in \
  requested_version \
  local_source_hash \
  installed_artifacts.sha256 \
  installed_artifacts_manifest_sha256; do
  if [[ ! -s "${marker_dir}/${marker}" ]]; then
    echo "UCX build marker is missing: ${marker_dir}/${marker}" >&2
    exit 1
  fi
done

marker_version=$(<"${marker_dir}/requested_version")
marker_hash=$(<"${marker_dir}/local_source_hash")
if [[ "$marker_version" != "$expected_version" || "$marker_hash" != "$expected_hash" ]]; then
  echo "UCX build provenance mismatch." >&2
  printf '  expected: version=%s source=%s\n' "$expected_version" "$expected_hash" >&2
  printf '  image:    version=%s source=%s\n' "$marker_version" "$marker_hash" >&2
  exit 1
fi

actual_version=$("$ucx_info" -v | awk '/Library version:/{print $4; exit}')
actual_library=$("$ucx_info" -v | awk '/Library path:/{print $4; exit}')
if [[ "$actual_version" != "$expected_version" || ! -e "$actual_library" ]]; then
  echo "Loaded UCX does not match the exact dependency image build." >&2
  "$ucx_info" -v >&2 || true
  exit 1
fi

ucx_lib_dir=$(dirname "$actual_library")
ucx_module_dir="${ucx_lib_dir}/ucx"
artifact_manifest=$(mktemp)
temp_files+=("$artifact_manifest")
for artifact in \
  libucm.so \
  libucp.so \
  libucs.so \
  libuct.so \
  ucx/libuct_cuda.so \
  ucx/libuct_ib_efa.so; do
  resolved=$(readlink -f "${ucx_lib_dir}/${artifact}" || true)
  if [[ ! -f "$resolved" ]]; then
    echo "Required UCX artifact is missing: ${ucx_lib_dir}/${artifact}" >&2
    exit 1
  fi
  digest=$(sha256sum "$resolved" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$artifact" >> "$artifact_manifest"
done
recorded_manifest_digest=$(<"${marker_dir}/installed_artifacts_manifest_sha256")
actual_recorded_digest=$(sha256sum "${marker_dir}/installed_artifacts.sha256" | awk '{print $1}')
if [[ ! $recorded_manifest_digest =~ ^[0-9a-f]{64}$ ||
  "$actual_recorded_digest" != "$recorded_manifest_digest" ]]; then
  echo "Installed UCX artifact manifest is corrupt." >&2
  exit 1
fi
if ! cmp -s "$artifact_manifest" "${marker_dir}/installed_artifacts.sha256"; then
  echo "Installed UCX artifact fingerprint does not match dependency-image provenance." >&2
  diff -u "${marker_dir}/installed_artifacts.sha256" "$artifact_manifest" >&2 || true
  exit 1
fi

for plugin in libuct_cuda.so libuct_ib_efa.so; do
  plugin_path="${ucx_module_dir}/${plugin}"
  if [[ ! -e "$plugin_path" ]]; then
    echo "Required UCX plugin is missing: ${plugin_path}" >&2
    exit 1
  fi
  if ! ldd_output=$(ldd "$plugin_path" 2>&1); then
    echo "Unable to inspect UCX plugin dependencies: ${plugin_path}" >&2
    echo "$ldd_output" >&2
    exit 1
  fi
  unresolved=$(grep 'not found' <<< "$ldd_output" |
    grep -vE 'libcuda\.so|libnvidia' || true)
  if [[ -n "$unresolved" ]]; then
    echo "UCX plugin has unresolved dependencies: ${plugin_path}" >&2
    echo "$unresolved" >&2
    exit 1
  fi
done

if [[ ${1:-} == --build-check ]]; then
  ucx_cmake_dir="${ucx_lib_dir}/cmake/ucx"
  for package_file in \
    ucx-config.cmake \
    ucx-config-version.cmake \
    ucx-targets.cmake; do
    if [[ ! -f "${ucx_cmake_dir}/${package_file}" ]]; then
      echo "Required UCX CMake package file is missing: ${ucx_cmake_dir}/${package_file}" >&2
      exit 1
    fi
  done
  printf 'Verified exact UCX %s build: source=%s plugins=%s\n' \
    "$actual_version" "$expected_hash" "$ucx_module_dir"
  exit 0
fi

ucx_devices=$(mktemp)
temp_files+=("$ucx_devices")
UCX_TLS=all UCX_NET_DEVICES=all "$ucx_info" -d > "$ucx_devices"

for transport in cuda_copy cuda_ipc srd; do
  if ! grep -Eq "Transport:[[:space:]]+${transport}$" "$ucx_devices"; then
    echo "Required UCX transport is unavailable at runtime: ${transport}" >&2
    exit 1
  fi
done

effective_tls=${UCX_TLS:-}
for transport in srd cuda_copy; do
  if [[ "$effective_tls" != all && ! "$effective_tls" =~ (^|,)${transport}(,|$) ]]; then
    echo "EFA mode requires UCX_TLS to select ${transport}; got ${effective_tls:-unset}" >&2
    exit 1
  fi
done

requested_devices=()
if [[ -n ${UCX_NET_DEVICES:-} ]]; then
  requested_devices+=("$UCX_NET_DEVICES")
fi
while IFS='=' read -r _ value; do
  [[ -n "$value" ]] && requested_devices+=("$value")
done < <(env | grep -E '^UCX_NET_DEVICES_GPU_[0-9]+=' || true)

for device_list in "${requested_devices[@]}"; do
  IFS=',' read -ra devices <<< "$device_list"
  for device in "${devices[@]}"; do
    [[ -n "$device" ]] || continue
    if ! grep -Eq "Device:[[:space:]]+${device}$" "$ucx_devices"; then
      echo "Requested UCX device is unavailable at runtime: ${device}" >&2
      exit 1
    fi
  done
done

printf 'Verified exact UCX %s runtime: CUDA IPC/copy and EFA SRD are available.\n' "$actual_version"
