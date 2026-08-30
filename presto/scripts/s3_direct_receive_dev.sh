#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Shared, source-only helpers for the CPU and GPU developer launchers. Keep
# credentials out of generated files: environment mode declares credential
# names with null values so Compose copies them from the launcher environment.
# Instance-profile mode omits those names, allowing in-container providers to
# discover and refresh EC2 role credentials without snapshotting the host environment.

S3_DIRECT_RECEIVE_AWS_CREDENTIAL_ENV=(
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
)
S3_DIRECT_RECEIVE_AWS_ROUTING_ENV=(
  AWS_REGION
  AWS_DEFAULT_REGION
  AWS_ENDPOINT_URL
  AWS_EC2_METADATA_SERVICE_ENDPOINT
)
S3_DIRECT_RECEIVE_KVIKIO_ENV=(
  KVIKIO_REMOTE_IO_BACKEND
  KVIKIO_REMOTE_IO_NUM_REACTORS
  KVIKIO_REMOTE_IO_REACTOR_DISPATCH
  KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS
  KVIKIO_TASK_SIZE
  KVIKIO_REMOTE_DIRECT_RECEIVE
  KVIKIO_REMOTE_DIRECT_RECEIVE_SLOT_SIZE
  KVIKIO_REMOTE_DIRECT_RECEIVE_MAX_PINNED_BYTES
)
GPU_S3_NODE_SELECTION_STATE_LABEL='com.nvidia.velox-testing.gpu-s3-node-selection-strategy'
GPU_S3_NODE_SELECTION_STATE_UNSET='UNSET'

function apply_s3_direct_receive_kvikio_defaults() {
  # These defaults are specific to the GPU S3 direct-receive path. Keep every
  # value overridable so topology-specific experiments do not require script
  # edits, and leave slot sizing to KvikIO until it is benchmarked separately.
  export KVIKIO_REMOTE_IO_BACKEND="${KVIKIO_REMOTE_IO_BACKEND:-MULTI_POLL}"
  export KVIKIO_REMOTE_DIRECT_RECEIVE="${KVIKIO_REMOTE_DIRECT_RECEIVE:-REQUIRE}"
  export KVIKIO_TASK_SIZE="${KVIKIO_TASK_SIZE:-16777216}"
  export KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS="${KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS:-64}"
  export KVIKIO_REMOTE_IO_NUM_REACTORS="${KVIKIO_REMOTE_IO_NUM_REACTORS:-4}"
  export KVIKIO_REMOTE_IO_REACTOR_DISPATCH="${KVIKIO_REMOTE_IO_REACTOR_DISPATCH:-PER_CHUNK}"
}

function normalize_gpu_s3_reader_mode() {
  local mode=${1,,}

  case ${mode} in
    kvikio|buffered|buffered-cache)
      printf '%s\n' "${mode}"
      ;;
    *)
      echo "ERROR: GPU S3 reader mode must be kvikio, buffered, or buffered-cache; got '${1}'." >&2
      return 1
      ;;
  esac
}

function resolve_s3_direct_receive_credential_source() {
  local requested_source=${1,,}
  local has_access_key=false
  local has_secret_key=false
  local has_session_token=false

  [[ -n ${AWS_ACCESS_KEY_ID:-} ]] && has_access_key=true
  [[ -n ${AWS_SECRET_ACCESS_KEY:-} ]] && has_secret_key=true
  [[ -n ${AWS_SESSION_TOKEN:-} ]] && has_session_token=true

  case ${requested_source} in
    instance-profile)
      printf '%s\n' instance-profile
      return 0
      ;;
    auto|environment)
      ;;
    *)
      echo "ERROR: S3 credential source must be auto, environment, or instance-profile; got '${requested_source}'." >&2
      return 1
      ;;
  esac

  if [[ ${has_access_key} != "${has_secret_key}" ]]; then
    echo "ERROR: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must either both be set or both be unset." >&2
    return 1
  fi
  if [[ ${has_session_token} == true && ${has_access_key} == false ]]; then
    echo "ERROR: AWS_SESSION_TOKEN requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY." >&2
    return 1
  fi
  if [[ ${has_access_key} == true && ${AWS_ACCESS_KEY_ID} == ASIA* && ${has_session_token} == false ]]; then
    echo "ERROR: temporary AWS access keys require AWS_SESSION_TOKEN." >&2
    return 1
  fi

  if [[ ${requested_source} == environment ]]; then
    if [[ ${has_access_key} == false ]]; then
      echo "ERROR: environment S3 credentials require AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY." >&2
      return 1
    fi
    printf '%s\n' environment
    return 0
  fi

  if [[ ${has_access_key} == false ]]; then
    printf '%s\n' instance-profile
    return 0
  fi
  if [[ ${has_session_token} == true ]]; then
    echo "ERROR: auto S3 credential selection will not snapshot temporary AWS environment credentials." >&2
    echo "Choose --s3-credential-source environment to forward them intentionally, or instance-profile to use refreshable EC2 role credentials." >&2
    return 1
  fi

  printf '%s\n' environment
}

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

function native_cache_scope_for_dependency_image_id() {
  local scope=$1
  local image_id=$2
  local digest=${image_id#sha256:}

  if [[ ! ${digest} =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "ERROR: invalid dependency image ID '${image_id}'" >&2
    return 1
  fi

  # CMake records absolute paths and other discovery results from the build
  # image in its persistent build directory. Bind that directory to the
  # immutable image ID so replacing a mutable dependency-image tag cannot
  # reuse configuration or objects produced against its predecessor.
  printf '%s-deps-%s\n' "${scope}" "${digest}"
}

function bind_native_cache_scope_to_dependency_image() {
  local scope=$1
  local image=$2
  local image_id

  if ! image_id=$(docker image inspect --format '{{.Id}}' "${image}"); then
    echo "ERROR: could not inspect dependency image '${image}'" >&2
    return 1
  fi

  native_cache_scope_for_dependency_image_id "${scope}" "${image_id}"
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

function properties_file_value() {
  local key=$1
  local file=$2
  local key_regex=${key//./\\.}

  [[ -f ${file} ]] || return 0
  sed -n "s/^${key_regex}=//p" "${file}" | tail -n 1
}

function gpu_s3_node_selection_strategy() {
  local enabled=$1
  local reader_mode=$2
  local baseline_coordinator_catalog=$3

  if [[ ${enabled} == true ]]; then
    reader_mode=$(normalize_gpu_s3_reader_mode "${reader_mode}") || return 1
  fi

  if [[ ${enabled} == true && ${reader_mode} == buffered-cache ]]; then
    printf '%s\n' SOFT_AFFINITY
    return 0
  fi

  properties_file_value \
    "hive.node-selection-strategy" "${baseline_coordinator_catalog}"
}

function gpu_s3_node_selection_state() {
  local enabled=$1
  local reader_mode=$2
  local baseline_coordinator_catalog=$3
  local strategy

  strategy=$(
    gpu_s3_node_selection_strategy \
      "${enabled}" "${reader_mode}" "${baseline_coordinator_catalog}"
  ) || return 1
  printf '%s\n' "${strategy:-${GPU_S3_NODE_SELECTION_STATE_UNSET}}"
}

function gpu_s3_coordinator_requires_restart() {
  local enabled=$1
  local reader_mode=$2
  local baseline_coordinator_catalog=$3
  local active_state=$4
  local desired_state

  desired_state=$(
    gpu_s3_node_selection_state \
      "${enabled}" "${reader_mode}" "${baseline_coordinator_catalog}"
  ) || return 1

  [[ ${active_state} != "${desired_state}" ]]
}

function gpu_s3_restart_target_for_coordinator_state() {
  local requested_target=$1
  local enabled=$2
  local reader_mode=$3
  local baseline_coordinator_catalog=$4
  local active_state=$5
  local desired_state

  desired_state=$(
    gpu_s3_node_selection_state \
      "${enabled}" "${reader_mode}" "${baseline_coordinator_catalog}"
  ) || return 1

  if [[ ${requested_target} == worker && ${active_state} != "${desired_state}" ]]; then
    printf '%s\n' all
  else
    printf '%s\n' "${requested_target}"
  fi
}

function apply_gpu_s3_coordinator_config() {
  local enabled=$1
  local reader_mode=$2
  local config_dir=$3
  local baseline_coordinator_catalog=$4
  local coordinator_catalog="${config_dir}/etc_coordinator/catalog/hive.properties"
  local node_selection_strategy

  [[ -f ${coordinator_catalog} ]] || return 0
  node_selection_strategy=$(
    gpu_s3_node_selection_strategy \
      "${enabled}" "${reader_mode}" "${baseline_coordinator_catalog}"
  ) || return 1

  remove_properties_file_key_if_present \
    "hive.node-selection-strategy" "${coordinator_catalog}"
  if [[ -n ${node_selection_strategy} ]]; then
    set_properties_file_value_exact \
      "hive.node-selection-strategy" \
      "${node_selection_strategy}" \
      "${coordinator_catalog}"
  fi
}

function render_gpu_s3_coordinator_state_override() {
  local enabled=$1
  local reader_mode=$2
  local baseline_coordinator_catalog=$3
  local output_path=$4
  local state

  state=$(
    gpu_s3_node_selection_state \
      "${enabled}" "${reader_mode}" "${baseline_coordinator_catalog}"
  ) || return 1

  {
    printf 'services:\n'
    printf '  presto-coordinator:\n'
    printf '    labels:\n'
    printf '      %s: "%s"\n' \
      "${GPU_S3_NODE_SELECTION_STATE_LABEL}" "${state}"
  } > "${output_path}"
}

function apply_s3_direct_receive_worker_catalogs() {
  local variant=$1
  local enabled=$2
  local config_dir=$3
  local baseline_worker_catalog=${4:-}
  local gpu_reader_mode=${5:-kvikio}
  local hive_config
  local baseline_buffered_input=''

  if [[ ${variant} == gpu && ${enabled} == true ]]; then
    gpu_reader_mode=$(normalize_gpu_s3_reader_mode "${gpu_reader_mode}") || return 1
  fi

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
    if [[ ${enabled} == true && ${variant} == gpu && ${gpu_reader_mode} == kvikio ]]; then
      set_properties_file_value_exact \
        "cudf.hive.use-buffered-input" "false" "${hive_config}"
    elif [[ ${enabled} == true && ${variant} == gpu ]]; then
      # Buffered cuDF reads use Velox's S3 filesystem. Keep the same patched
      # dependency chain as the KvikIO arm and receive directly into the
      # caller-owned host buffer, which may be an AsyncDataCache entry.
      set_properties_file_value_exact \
        "hive.s3.direct-receive-mode" "caller-buffer" "${hive_config}"
      set_properties_file_value_exact \
        "cudf.hive.use-buffered-input" "true" "${hive_config}"
    elif [[ ${variant} == gpu && -n ${baseline_buffered_input} ]]; then
      set_properties_file_value_exact \
        "cudf.hive.use-buffered-input" \
        "${baseline_buffered_input}" "${hive_config}"
    fi
  done
}

function apply_gpu_worker_memory_and_cache_config() {
  local reader_mode=$1
  local config_dir=$2
  local num_workers=$3
  local host_ram_gb=$4
  local cache_enabled=false
  local default_host_reserve_gb
  local host_reserve_gb
  local worker_envelope_gb
  local system_mem_limit_gb
  local system_mem_gb
  local query_mem_gb
  local cfg

  reader_mode=$(normalize_gpu_s3_reader_mode "${reader_mode}") || return 1
  if [[ ${reader_mode} == buffered-cache ]]; then
    cache_enabled=true
  fi

  if [[ ! ${num_workers} =~ ^[1-9][0-9]*$ || ! ${host_ram_gb} =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: GPU memory sizing requires positive integer worker and host-RAM counts." >&2
    return 1
  fi

  # Leave the coordinator, OS, container runtime, and non-Velox allocations a
  # host-wide reserve. Large benchmark hosts reserve 200 GiB; smaller hosts use
  # 10%, with a 32-GiB floor. Divide only the remainder among worker processes.
  default_host_reserve_gb=$(( host_ram_gb / 10 ))
  (( default_host_reserve_gb < 32 )) && default_host_reserve_gb=32
  (( default_host_reserve_gb > 200 )) && default_host_reserve_gb=200
  host_reserve_gb=${GPU_HOST_RESERVE_GB:-${default_host_reserve_gb}}
  if [[ ! ${host_reserve_gb} =~ ^[1-9][0-9]*$ || ${host_reserve_gb} -ge ${host_ram_gb} ]]; then
    echo "ERROR: GPU_HOST_RESERVE_GB must be a positive integer smaller than host RAM." >&2
    return 1
  fi

  worker_envelope_gb=$(( (host_ram_gb - host_reserve_gb) / num_workers ))
  if (( worker_envelope_gb <= 10 )); then
    echo "ERROR: GPU worker memory envelope is too small after reserving host memory." >&2
    return 1
  fi

  system_mem_limit_gb=${GPU_SYSTEM_MEM_LIMIT_GB:-${worker_envelope_gb}}
  system_mem_gb=${GPU_SYSTEM_MEM_GB:-$(( system_mem_limit_gb - 10 ))}
  query_mem_gb=${GPU_QUERY_MEM_GB:-$(( system_mem_gb * 70 / 100 ))}
  for value in "${system_mem_limit_gb}" "${system_mem_gb}" "${query_mem_gb}"; do
    if [[ ! ${value} =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: GPU memory overrides must be positive integer GiB values." >&2
      return 1
    fi
  done
  if (( query_mem_gb >= system_mem_gb || system_mem_gb > system_mem_limit_gb )); then
    echo "ERROR: GPU memory sizing must satisfy query < system <= system limit." >&2
    return 1
  fi
  if (( system_mem_limit_gb * num_workers > host_ram_gb - host_reserve_gb )); then
    echo "ERROR: aggregate GPU worker memory limits exceed host RAM after the reserve." >&2
    return 1
  fi

  for cfg in "${config_dir}"/etc_worker*/config_native.properties; do
    [[ -f ${cfg} ]] || continue
    set_properties_file_value_exact "system-memory-gb" "${system_mem_gb}" "${cfg}"
    set_properties_file_value_exact "query-memory-gb" "${query_mem_gb}" "${cfg}"
    set_properties_file_value_exact \
      "query.max-memory-per-node" "${query_mem_gb}GB" "${cfg}"
    set_properties_file_value_exact \
      "system-mem-limit-gb" "${system_mem_limit_gb}" "${cfg}"
    set_properties_file_value_exact \
      "async-data-cache-enabled" "${cache_enabled}" "${cfg}"
  done

  printf 'GPU worker memory: host=%sGB reserve=%sGB workers=%s system=%sGB query=%sGB limit=%sGB cache=%s\n' \
    "${host_ram_gb}" "${host_reserve_gb}" "${num_workers}" \
    "${system_mem_gb}" "${query_mem_gb}" "${system_mem_limit_gb}" \
    "${cache_enabled}"
}

function render_s3_direct_receive_compose_override() {
  local variant=$1
  local enabled=$2
  local worker_image=$3
  local output_path=$4
  local credential_source=$5
  shift 5
  local worker_services=("$@")
  local service variable

  if [[ ${enabled} != true ]]; then
    : > "${output_path}"
    return 0
  fi
  if [[ ${credential_source} != environment && ${credential_source} != instance-profile ]]; then
    echo "ERROR: compose rendering requires a resolved S3 credential source; got '${credential_source}'." >&2
    return 1
  fi

  {
    printf 'services:\n'
    # The Java coordinator enumerates S3 objects and creates Hive splits, while
    # native workers read the object bodies. Both sides use the same selected
    # credential source and routing configuration.
    printf '  presto-coordinator:\n'
    printf '    environment:\n'
    if [[ ${credential_source} == environment ]]; then
      for variable in "${S3_DIRECT_RECEIVE_AWS_CREDENTIAL_ENV[@]}"; do
        printf '      %s:\n' "${variable}"
      done
    fi
    for variable in "${S3_DIRECT_RECEIVE_AWS_ROUTING_ENV[@]}"; do
      printf '      %s:\n' "${variable}"
    done
    for service in "${worker_services[@]}"; do
      printf '  %s:\n' "${service}"
      printf '    image: "%s"\n' "${worker_image}"
      printf '    environment:\n'
      if [[ ${credential_source} == environment ]]; then
        for variable in "${S3_DIRECT_RECEIVE_AWS_CREDENTIAL_ENV[@]}"; do
          printf '      %s:\n' "${variable}"
        done
      fi
      for variable in "${S3_DIRECT_RECEIVE_AWS_ROUTING_ENV[@]}"; do
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
