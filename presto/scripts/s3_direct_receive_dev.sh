#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Shared, source-only helpers for the CPU and GPU developer launchers. Keep
# credentials out of generated files: the compose override below declares
# variable names with null values so Compose copies values from the launcher's
# environment directly into the coordinator and worker containers.

S3_DIRECT_RECEIVE_AWS_ENV=(
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
  AWS_REGION
  AWS_DEFAULT_REGION
  AWS_ENDPOINT_URL
)
S3_DIRECT_RECEIVE_KVIKIO_ENV=(
  KVIKIO_REMOTE_IO_BACKEND
  KVIKIO_REMOTE_DIRECT_RECEIVE
  KVIKIO_REMOTE_DIRECT_RECEIVE_SLOT_SIZE
  KVIKIO_REMOTE_DIRECT_RECEIVE_MAX_PINNED_BYTES
)

function derive_s3_direct_dependency_image_name() {
  local base_image=$1
  local final_component=${base_image##*/}

  if [[ ${base_image} == *@* ]]; then
    echo "ERROR: S3_DIRECT_DEPS_IMAGE must be set when DEPS_IMAGE uses a digest." >&2
    return 1
  fi
  if [[ ${final_component} == *:* ]]; then
    printf '%s:%s-s3-direct\n' "${base_image%:*}" "${base_image##*:}"
  else
    printf '%s:s3-direct\n' "${base_image}"
  fi
}

function isolate_s3_direct_cache_scope() {
  local scope=$1
  if [[ ${scope} == *-s3-direct ]]; then
    printf '%s\n' "${scope}"
  else
    printf '%s-s3-direct\n' "${scope}"
  fi
}

function remove_properties_file_key_if_present() {
  local key=$1
  local file=$2
  local key_regex=${key//./\\.}

  [[ -f ${file} ]] || return 0
  sed -i "/^${key_regex}=/d" "${file}"
}

function set_properties_file_value_exact() {
  local key=$1
  local value=$2
  local file=$3

  remove_properties_file_key_if_present "${key}" "${file}"
  printf '\n%s=%s\n' "${key}" "${value}" >> "${file}"
}

function apply_s3_direct_receive_worker_catalogs() {
  local variant=$1
  local enabled=$2
  local config_dir=$3
  local baseline_worker_catalog=${4:-}
  local hive_config
  local baseline_buffered_input=''

  if [[ ${variant} == gpu && -f ${baseline_worker_catalog} ]]; then
    baseline_buffered_input=$(
      sed -n 's/^cudf\.hive\.use-buffered-input=//p' \
        "${baseline_worker_catalog}" | tail -n 1
    )
  fi

  # Reconcile all generated worker layouts. This handles worker-count changes
  # and --skip-generate-config launches without ever placing native-only
  # settings in the Java coordinator catalog.
  for hive_config in "${config_dir}"/etc_worker*/catalog/hive.properties; do
    [[ -f ${hive_config} ]] || continue
    remove_properties_file_key_if_present \
      "hive.s3.direct-receive-mode" "${hive_config}"
    if [[ ${variant} == gpu ]]; then
      remove_properties_file_key_if_present \
        "cudf.hive.use-buffered-input" "${hive_config}"
    fi
    if [[ ${enabled} == true && ${variant} == cpu ]]; then
      set_properties_file_value_exact \
        "hive.s3.direct-receive-mode" "caller-buffer" "${hive_config}"
    fi
    if [[ ${enabled} == true && ${variant} == gpu ]]; then
      set_properties_file_value_exact \
        "cudf.hive.use-buffered-input" "false" "${hive_config}"
    elif [[ ${variant} == gpu && -n ${baseline_buffered_input} ]]; then
      set_properties_file_value_exact \
        "cudf.hive.use-buffered-input" \
        "${baseline_buffered_input}" "${hive_config}"
    fi
  done
}

function render_s3_direct_receive_compose_override() {
  local variant=$1
  local enabled=$2
  local worker_image=$3
  local output_path=$4
  shift 4
  local worker_services=("$@")
  local service variable

  if [[ ${enabled} != true ]]; then
    : > "${output_path}"
    return 0
  fi

  {
    printf 'services:\n'
    # The Java coordinator enumerates S3 objects and creates Hive splits, while
    # native workers read the object bodies. Both sides need the same ambient
    # AWS credential chain.
    printf '  presto-coordinator:\n'
    printf '    environment:\n'
    for variable in "${S3_DIRECT_RECEIVE_AWS_ENV[@]}"; do
      printf '      %s:\n' "${variable}"
    done
    for service in "${worker_services[@]}"; do
      printf '  %s:\n' "${service}"
      printf '    image: "%s"\n' "${worker_image}"
      printf '    environment:\n'
      for variable in "${S3_DIRECT_RECEIVE_AWS_ENV[@]}"; do
        printf '      %s:\n' "${variable}"
      done
      if [[ ${variant} == gpu ]]; then
        for variable in "${S3_DIRECT_RECEIVE_KVIKIO_ENV[@]}"; do
          printf '      %s:\n' "${variable}"
        done
      fi
    done
  } > "${output_path}"
}

function ensure_s3_direct_dependency_image() {
  local output_image=$1
  local base_image=$2
  local presto_source=$3
  local velox_source=$4
  local no_cache=${5:-false}

  if is_image_missing "${base_image}"; then
    echo "ERROR: ordinary dependency image '${base_image}' is required before deriving S3 direct receive." >&2
    echo "Build it with presto/scripts/build_centos_deps_image.sh or fetch it first." >&2
    return 1
  fi

  local args=(
    --s3-direct-receive
    --base-image "${base_image}"
    --image-name "${output_image}"
    --presto-source "${presto_source}"
    --velox-source "${velox_source}"
  )
  [[ ${no_cache} == true ]] && args+=(--no-cache)
  "${SCRIPT_DIR}/build_centos_deps_image.sh" "${args[@]}"
}
