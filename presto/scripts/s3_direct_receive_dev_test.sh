#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d "${SCRIPT_DIR}/.s3_direct_receive_dev_test.XXXXXX")
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/s3_direct_receive_dev.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local needle=$1
  local file=$2
  grep -F -- "${needle}" "${file}" >/dev/null ||
    fail "${file} does not contain: ${needle}"
}

assert_not_contains() {
  local needle=$1
  local file=$2
  if grep -F -- "${needle}" "${file}" >/dev/null; then
    fail "${file} unexpectedly contains: ${needle}"
  fi
}

assert_gpu_launcher_rejects_ucx_environment() {
  local expected_message=$1
  shift
  local error_file="${TEST_ROOT}/gpu-ucx-environment-error.txt"

  if env \
    -u UCX_TLS \
    -u PRESTO_GPU_UCX_TLS \
    -u UCX_MAX_RNDV_RAILS \
    -u PRESTO_GPU_UCX_MAX_RNDV_RAILS \
    -u UCX_MAX_RDNV_RAILS \
    -u PRESTO_GPU_UCX_MAX_RDNV_RAILS \
    "$@" \
    "${GPU_LAUNCHER}" --restart-target none \
    > /dev/null 2> "${error_file}"; then
    fail 'GPU launcher accepted an invalid UCX environment'
  fi
  assert_contains "${expected_message}" "${error_file}"
}

assert_gpu_launcher_rejects_cuda_deps_override() {
  local error_file="${TEST_ROOT}/gpu-cuda-deps-override-error.txt"

  if DEPS_IMAGE=test.example/presto-deps:ordinary \
    "${GPU_LAUNCHER}" --cuda-version 13.2 --restart-target none \
    > /dev/null 2> "${error_file}"; then
    fail 'GPU launcher accepted DEPS_IMAGE together with --cuda-version'
  fi
  assert_contains 'DEPS_IMAGE cannot be combined with --cuda-version' "${error_file}"
}

assert_gpu_launcher_rejects_cuda_version() {
  local error_file="${TEST_ROOT}/gpu-cuda-version-error.txt"

  if "${GPU_LAUNCHER}" --cuda-version latest --restart-target none \
    > /dev/null 2> "${error_file}"; then
    fail 'GPU launcher accepted an invalid CUDA toolkit version'
  fi
  assert_contains \
    '--cuda-version must be a major.minor version such as 13.2' \
    "${error_file}"
}

assert_launcher_rejects_aws_direct_receive_mode() {
  local launcher=$1
  local expected_message=$2
  shift 2
  local launcher_name
  local error_file
  launcher_name=$(basename "${launcher}")
  error_file="${TEST_ROOT}/${launcher_name}.aws-direct-receive-mode-error.txt"

  if "${launcher}" "$@" --restart-target none \
    > /dev/null 2> "${error_file}"; then
    fail "${launcher_name} accepted an invalid AWS direct-receive mode configuration"
  fi
  assert_contains "${expected_message}" "${error_file}"
}

assert_occurs_before() {
  local first=$1
  local second=$2
  local file=$3
  local first_line second_line

  first_line=$(awk -v needle="${first}" 'index($0, needle) { print NR; exit }' "${file}")
  second_line=$(awk -v needle="${second}" 'index($0, needle) { print NR; exit }' "${file}")
  [[ -n ${first_line} && -n ${second_line} && ${first_line} -lt ${second_line} ]] ||
    fail "${file} does not place '${first}' before '${second}'"
}

unset KVIKIO_REMOTE_IO_BACKEND \
  KVIKIO_REMOTE_DIRECT_RECEIVE \
  KVIKIO_TASK_SIZE \
  KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS \
  KVIKIO_REMOTE_IO_NUM_REACTORS \
  KVIKIO_REMOTE_IO_REACTOR_DISPATCH || true
apply_s3_direct_receive_kvikio_defaults
[[ ${KVIKIO_REMOTE_IO_BACKEND} == MULTI_POLL ]] ||
  fail 'default KvikIO remote backend is not MULTI_POLL'
[[ ${KVIKIO_REMOTE_DIRECT_RECEIVE} == REQUIRE ]] ||
  fail 'default KvikIO direct-receive mode is not REQUIRE'
[[ ${KVIKIO_TASK_SIZE} == 16777216 ]] ||
  fail 'default KvikIO task size is not 16 MiB'
[[ ${KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS} == 64 ]] ||
  fail 'default KvikIO request concurrency is not 64'
[[ ${KVIKIO_REMOTE_IO_NUM_REACTORS} == 4 ]] ||
  fail 'default KvikIO reactor count is not four'
[[ ${KVIKIO_REMOTE_IO_REACTOR_DISPATCH} == PER_CHUNK ]] ||
  fail 'default KvikIO reactor dispatch is not PER_CHUNK'

export KVIKIO_REMOTE_IO_BACKEND=override-backend
export KVIKIO_REMOTE_DIRECT_RECEIVE=override-direct-receive
export KVIKIO_TASK_SIZE=override-task-size
export KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS=override-request-limit
export KVIKIO_REMOTE_IO_NUM_REACTORS=override-reactors
export KVIKIO_REMOTE_IO_REACTOR_DISPATCH=override-dispatch
apply_s3_direct_receive_kvikio_defaults
[[ ${KVIKIO_REMOTE_IO_BACKEND} == override-backend ]] ||
  fail 'explicit KvikIO remote backend was overwritten'
[[ ${KVIKIO_REMOTE_DIRECT_RECEIVE} == override-direct-receive ]] ||
  fail 'explicit KvikIO direct-receive mode was overwritten'
[[ ${KVIKIO_TASK_SIZE} == override-task-size ]] ||
  fail 'explicit KvikIO task size was overwritten'
[[ ${KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS} == override-request-limit ]] ||
  fail 'explicit KvikIO request concurrency was overwritten'
[[ ${KVIKIO_REMOTE_IO_NUM_REACTORS} == override-reactors ]] ||
  fail 'explicit KvikIO reactor count was overwritten'
[[ ${KVIKIO_REMOTE_IO_REACTOR_DISPATCH} == override-dispatch ]] ||
  fail 'explicit KvikIO reactor dispatch was overwritten'
unset KVIKIO_REMOTE_IO_BACKEND \
  KVIKIO_REMOTE_DIRECT_RECEIVE \
  KVIKIO_TASK_SIZE \
  KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS \
  KVIKIO_REMOTE_IO_NUM_REACTORS \
  KVIKIO_REMOTE_IO_REACTOR_DISPATCH

for mode in caller-buffer preferred required; do
  [[ $(normalize_s3_aws_direct_receive_mode "${mode^^}") == "${mode}" ]] ||
    fail "S3 AWS direct-receive mode '${mode}' was not normalized"
done
if normalize_s3_aws_direct_receive_mode invalid >/dev/null 2>&1; then
  fail 'invalid S3 AWS direct-receive mode was accepted'
fi
if normalize_s3_aws_direct_receive_mode disabled >/dev/null 2>&1; then
  fail 'disabled was accepted as an enabled S3 AWS direct-receive mode'
fi

for mode in auto on off; do
  [[ $(normalize_s3_adaptive_tcp_mss_mode "${mode^^}") == "${mode}" ]] ||
    fail "adaptive TCP MSS mode '${mode}' was not normalized"
done
if normalize_s3_adaptive_tcp_mss_mode invalid >/dev/null 2>&1; then
  fail 'invalid adaptive TCP MSS mode was accepted'
fi
[[ $(resolve_s3_adaptive_tcp_mss_enabled cpu true buffered auto) == true ]] ||
  fail 'CPU auto mode did not enable adaptive TCP MSS'
[[ $(resolve_s3_adaptive_tcp_mss_enabled gpu true buffered-cache auto) == true ]] ||
  fail 'GPU buffered-cache auto mode did not enable adaptive TCP MSS'
[[ $(resolve_s3_adaptive_tcp_mss_enabled gpu true kvikio auto) == false ]] ||
  fail 'GPU KvikIO auto mode unexpectedly enabled the AWS SDK policy'
[[ $(resolve_s3_adaptive_tcp_mss_enabled cpu true buffered off) == false ]] ||
  fail 'adaptive TCP MSS off mode was ignored'
if resolve_s3_adaptive_tcp_mss_enabled gpu true kvikio on >/dev/null 2>&1; then
  fail 'adaptive TCP MSS on mode was accepted for KvikIO'
fi
if resolve_s3_adaptive_tcp_mss_enabled cpu false buffered on >/dev/null 2>&1; then
  fail 'adaptive TCP MSS on mode was accepted without direct receive'
fi

clear_aws_credential_env() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN || true
}

assert_credential_source_fails() {
  local source=$1
  local message=$2
  local error_file="${TEST_ROOT}/credential-source-error.txt"

  if resolve_s3_direct_receive_credential_source "${source}" \
    > /dev/null 2> "${error_file}"; then
    fail "credential source '${source}' unexpectedly succeeded"
  fi
  assert_contains "${message}" "${error_file}"
}

[[ $(derive_s3_direct_dependency_image_name repo/image:ordinary) == repo/image:ordinary-s3-direct ]] ||
  fail 'tagged image derivation failed'
[[ $(derive_s3_direct_dependency_image_name repo/image) == repo/image:s3-direct ]] ||
  fail 'untagged image derivation failed'
[[ $(derive_s3_direct_dependency_image_name registry.example:5000/team/deps:base) == \
  registry.example:5000/team/deps:base-s3-direct ]] ||
  fail 'registry-port image derivation failed'
if derive_s3_direct_dependency_image_name \
  'repo/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  2>/dev/null; then
  fail 'digest base did not require an explicit output image'
fi
[[ $(isolate_s3_direct_cache_scope explicit) == explicit-s3-direct ]] ||
  fail 'explicit cache scope was not isolated'
[[ $(isolate_s3_direct_cache_scope explicit-s3-direct) == explicit-s3-direct ]] ||
  fail 'direct cache scope suffix was duplicated'
DEPENDENCY_IMAGE_ID="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
[[ $(native_cache_scope_for_dependency_image_id explicit "${DEPENDENCY_IMAGE_ID}") == \
  explicit-deps-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef ]] ||
  fail 'dependency image ID was not incorporated into the native cache scope'
SECOND_DEPENDENCY_IMAGE_ID="sha256:1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
[[ $(native_cache_scope_for_dependency_image_id explicit "${DEPENDENCY_IMAGE_ID}") != \
  "$(native_cache_scope_for_dependency_image_id explicit "${SECOND_DEPENDENCY_IMAGE_ID}")" ]] ||
  fail 'dependency image replacement did not rotate the native cache scope'
if native_cache_scope_for_dependency_image_id explicit not-an-image-id 2>/dev/null; then
  fail 'invalid dependency image ID was accepted'
fi

# Called indirectly by bind_native_cache_scope_to_dependency_image.
# shellcheck disable=SC2317
docker() {
  [[ $* == "image inspect --format {{.Id}} dependency-image" ]] ||
    fail "unexpected mocked docker invocation: $*"
  printf '%s\n' "${DEPENDENCY_IMAGE_ID}"
}
[[ $(bind_native_cache_scope_to_dependency_image explicit dependency-image) == \
  explicit-deps-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef ]] ||
  fail 'dependency image was not bound to the native cache scope'
unset -f docker

ORIGINAL_SCRIPT_DIR=${SCRIPT_DIR}
MOCK_SCRIPT_DIR="${TEST_ROOT}/mock-scripts"
MOCK_BUILD_LOG="${TEST_ROOT}/mock-build.log"
mkdir -p "${MOCK_SCRIPT_DIR}"
# The mock script must expand these variables when it runs, not while this
# test constructs it.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "PRESTO_DEV_CUDA_VERSION=%s\\n" "${PRESTO_DEV_CUDA_VERSION:-}" > "${MOCK_BUILD_LOG}"' \
  'printf "%s\\n" "$@" >> "${MOCK_BUILD_LOG}"' \
  'exit "${MOCK_BUILD_EXIT:-0}"' \
  > "${MOCK_SCRIPT_DIR}/build_centos_deps_image.sh"
chmod +x "${MOCK_SCRIPT_DIR}/build_centos_deps_image.sh"
export MOCK_BUILD_LOG MOCK_BUILD_EXIT=0
SCRIPT_DIR=${MOCK_SCRIPT_DIR}
MOCK_BASE_MISSING=false
is_image_missing() {
  case $1 in
    ordinary-image) [[ ${MOCK_BASE_MISSING} == true ]] ;;
    *) return 0 ;;
  esac
}

# Direct mode never falls back to or retags a generic ordinary image.
MOCK_BASE_MISSING=true
if ensure_s3_direct_dependency_image \
  direct-image ordinary-image /src/presto /src/velox false 2>/dev/null; then
  fail 'missing ordinary base did not fail direct dependency derivation'
fi
[[ ! -e ${MOCK_BUILD_LOG} ]] || fail 'missing ordinary base invoked a build'

# Every worker build revalidates provenance through the derived builder.
MOCK_BASE_MISSING=false
PRESTO_DEV_CUDA_VERSION=13.2 ensure_s3_direct_dependency_image \
  direct-image ordinary-image /src/presto /src/velox true
assert_contains 'PRESTO_DEV_CUDA_VERSION=' "${MOCK_BUILD_LOG}"
assert_not_contains 'PRESTO_DEV_CUDA_VERSION=13.2' "${MOCK_BUILD_LOG}"
for argument in \
  --s3-direct-receive \
  ordinary-image \
  direct-image \
  /src/presto \
  /src/velox \
  --no-cache; do
  assert_contains "${argument}" "${MOCK_BUILD_LOG}"
done
MOCK_BUILD_EXIT=41
if ensure_s3_direct_dependency_image \
  direct-image ordinary-image /src/presto /src/velox false; then
  fail 'derived dependency builder failure was not propagated'
fi
MOCK_BUILD_EXIT=0
SCRIPT_DIR=${ORIGINAL_SCRIPT_DIR}

CONFIG_ROOT="${TEST_ROOT}/config"
BASELINE="${TEST_ROOT}/baseline.properties"
COORDINATOR_BASELINE="${TEST_ROOT}/coordinator-baseline.properties"
mkdir -p \
  "${CONFIG_ROOT}/etc_worker/catalog" \
  "${CONFIG_ROOT}/etc_worker_0/catalog" \
  "${CONFIG_ROOT}/etc_coordinator/catalog"
printf '%s\n' \
  'connector.name=hive-hadoop2' \
  'cudf.hive.use-buffered-input=true' > "${BASELINE}"
printf '%s\n' \
  'connector.name=hive-hadoop2' \
  '# hive.node-selection-strategy=SOFT_AFFINITY' \
  > "${COORDINATOR_BASELINE}"
for file in \
  "${CONFIG_ROOT}/etc_worker/catalog/hive.properties" \
  "${CONFIG_ROOT}/etc_worker_0/catalog/hive.properties" \
  "${CONFIG_ROOT}/etc_coordinator/catalog/hive.properties"; do
  printf '%s\n' \
    'connector.name=hive-hadoop2' \
    'hive.s3.direct-receive-mode=stale' \
    'hive.s3.adaptive-tcp-mss-enabled=stale' \
    'cudf.hive.use-buffered-input=stale' > "${file}"
done

apply_gpu_s3_coordinator_config \
  true buffered-cache "${CONFIG_ROOT}" "${COORDINATOR_BASELINE}"
apply_gpu_s3_coordinator_config \
  true buffered-cache "${CONFIG_ROOT}" "${COORDINATOR_BASELINE}"
COORDINATOR_CATALOG="${CONFIG_ROOT}/etc_coordinator/catalog/hive.properties"
[[ $(grep -c '^hive.node-selection-strategy=SOFT_AFFINITY$' "${COORDINATOR_CATALOG}") -eq 1 ]] ||
  fail 'GPU buffered-cache mode did not enable soft affinity exactly once'
gpu_s3_coordinator_requires_restart \
  true buffered-cache "${COORDINATOR_BASELINE}" \
  "${GPU_S3_NODE_SELECTION_STATE_UNSET}" ||
  fail 'entering buffered-cache did not require a coordinator restart'
if gpu_s3_coordinator_requires_restart \
  true buffered-cache "${COORDINATOR_BASELINE}" SOFT_AFFINITY; then
  fail 'unchanged buffered-cache policy required a coordinator restart'
fi
[[ $(gpu_s3_restart_target_for_coordinator_state \
  worker true buffered-cache "${COORDINATOR_BASELINE}" \
  "${GPU_S3_NODE_SELECTION_STATE_UNSET}") == all ]] ||
  fail 'worker-only transition did not widen to an all-service restart'
[[ $(gpu_s3_restart_target_for_coordinator_state \
  worker true buffered-cache "${COORDINATOR_BASELINE}" SOFT_AFFINITY) == worker ]] ||
  fail 'matching coordinator policy did not retain the worker-only fast path'
[[ $(gpu_s3_restart_target_for_coordinator_state \
  worker true buffered-cache "${COORDINATOR_BASELINE}" UNKNOWN) == all ]] ||
  fail 'unknown coordinator state did not fail safely to an all-service restart'
[[ $(gpu_s3_restart_target_for_coordinator_state \
  coordinator true buffered-cache "${COORDINATOR_BASELINE}" \
  "${GPU_S3_NODE_SELECTION_STATE_UNSET}") == coordinator ]] ||
  fail 'explicit coordinator-only restart was unexpectedly widened'

COORDINATOR_STATE_OVERRIDE="${TEST_ROOT}/coordinator-state.yml"
render_gpu_s3_coordinator_state_override \
  true buffered-cache "${COORDINATOR_BASELINE}" \
  "${COORDINATOR_STATE_OVERRIDE}"
assert_contains \
  "${GPU_S3_NODE_SELECTION_STATE_LABEL}: \"SOFT_AFFINITY\"" \
  "${COORDINATOR_STATE_OVERRIDE}"
render_gpu_s3_coordinator_state_override \
  true buffered "${COORDINATOR_BASELINE}" \
  "${COORDINATOR_STATE_OVERRIDE}"
assert_contains \
  "${GPU_S3_NODE_SELECTION_STATE_LABEL}: \"${GPU_S3_NODE_SELECTION_STATE_UNSET}\"" \
  "${COORDINATOR_STATE_OVERRIDE}"

for mode in kvikio buffered; do
  apply_gpu_s3_coordinator_config \
    true "${mode}" "${CONFIG_ROOT}" "${COORDINATOR_BASELINE}"
  assert_not_contains 'hive.node-selection-strategy=' "${COORDINATOR_CATALOG}"
done

printf '%s\n' \
  'connector.name=hive-hadoop2' \
  'hive.node-selection-strategy=NO_PREFERENCE' \
  > "${COORDINATOR_BASELINE}"
apply_gpu_s3_coordinator_config \
  false kvikio "${CONFIG_ROOT}" "${COORDINATOR_BASELINE}"
[[ $(grep -c '^hive.node-selection-strategy=NO_PREFERENCE$' "${COORDINATOR_CATALOG}") -eq 1 ]] ||
  fail 'disabled direct receive did not restore the coordinator baseline'
gpu_s3_coordinator_requires_restart \
  false kvikio "${COORDINATOR_BASELINE}" SOFT_AFFINITY ||
  fail 'leaving buffered-cache did not require a coordinator restart'
if gpu_s3_coordinator_requires_restart \
  false kvikio "${COORDINATOR_BASELINE}" NO_PREFERENCE; then
  fail 'matching coordinator baseline required a restart'
fi

# Restore the ordinary commented baseline for the remaining catalog tests.
printf '%s\n' \
  'connector.name=hive-hadoop2' \
  '# hive.node-selection-strategy=SOFT_AFFINITY' \
  > "${COORDINATOR_BASELINE}"
for file in \
  "${CONFIG_ROOT}/etc_worker/config_native.properties" \
  "${CONFIG_ROOT}/etc_worker_0/config_native.properties"; do
  printf '%s\n' \
    'system-memory-gb=stale' \
    'query-memory-gb=stale' \
    'query.max-memory-per-node=stale' \
    'system-mem-limit-gb=stale' \
    'async-data-cache-enabled=stale' > "${file}"
done

apply_s3_direct_receive_worker_catalogs cpu true "${CONFIG_ROOT}" "${BASELINE}"
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  [[ $(grep -c '^hive.s3.direct-receive-mode=required$' "${file}") -eq 1 ]] ||
    fail "CPU strict kTLS default was not reconciled exactly once in ${file}"
done
for direct_mode in caller-buffer preferred required; do
  apply_s3_direct_receive_worker_catalogs \
    cpu true "${CONFIG_ROOT}" "${BASELINE}" buffered auto "${direct_mode}"
  for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
    [[ $(grep -c "^hive.s3.direct-receive-mode=${direct_mode}$" "${file}") -eq 1 ]] ||
      fail "CPU ${direct_mode} mode was not reconciled exactly once in ${file}"
    [[ $(grep -c '^hive.s3.adaptive-tcp-mss-enabled=true$' "${file}") -eq 1 ]] ||
      fail "CPU adaptive TCP MSS mode was not reconciled exactly once in ${file}"
  done
done
apply_s3_direct_receive_worker_catalogs \
  cpu true "${CONFIG_ROOT}" "${BASELINE}" buffered off caller-buffer
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  assert_contains 'hive.s3.direct-receive-mode=caller-buffer' "${file}"
  assert_not_contains 'hive.s3.adaptive-tcp-mss-enabled=' "${file}"
done
assert_contains \
  'hive.s3.direct-receive-mode=stale' \
  "${CONFIG_ROOT}/etc_coordinator/catalog/hive.properties"
assert_contains \
  'hive.s3.adaptive-tcp-mss-enabled=stale' \
  "${CONFIG_ROOT}/etc_coordinator/catalog/hive.properties"

apply_s3_direct_receive_worker_catalogs cpu false "${CONFIG_ROOT}" "${BASELINE}"
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  assert_not_contains 'hive.s3.direct-receive-mode=' "${file}"
  assert_not_contains 'hive.s3.adaptive-tcp-mss-enabled=' "${file}"
done

apply_s3_direct_receive_worker_catalogs gpu true "${CONFIG_ROOT}" "${BASELINE}"
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  [[ $(grep -c '^cudf.hive.use-buffered-input=false$' "${file}") -eq 1 ]] ||
    fail "GPU direct mode was not reconciled exactly once in ${file}"
  assert_not_contains 'hive.s3.direct-receive-mode=' "${file}"
  assert_not_contains 'hive.s3.adaptive-tcp-mss-enabled=' "${file}"
done

apply_s3_direct_receive_worker_catalogs \
  gpu true "${CONFIG_ROOT}" "${BASELINE}" buffered-cache
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  assert_contains 'cudf.hive.use-buffered-input=true' "${file}"
  [[ $(grep -c '^hive.s3.direct-receive-mode=required$' "${file}") -eq 1 ]] ||
    fail "GPU buffered-cache did not default to strict kTLS exactly once in ${file}"
done

for reader_mode in buffered buffered-cache; do
  for direct_mode in caller-buffer preferred required; do
    apply_s3_direct_receive_worker_catalogs \
      gpu true "${CONFIG_ROOT}" "${BASELINE}" \
      "${reader_mode}" auto "${direct_mode}"
    for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
      [[ $(grep -c '^cudf.hive.use-buffered-input=true$' "${file}") -eq 1 ]] ||
        fail "GPU ${reader_mode} mode did not enable buffered input exactly once in ${file}"
      [[ $(grep -c "^hive.s3.direct-receive-mode=${direct_mode}$" "${file}") -eq 1 ]] ||
        fail "GPU ${reader_mode}/${direct_mode} was not reconciled exactly once in ${file}"
      [[ $(grep -c '^hive.s3.adaptive-tcp-mss-enabled=true$' "${file}") -eq 1 ]] ||
        fail "GPU ${reader_mode} mode did not enable adaptive TCP MSS exactly once in ${file}"
    done
  done
done

apply_s3_direct_receive_worker_catalogs \
  gpu true "${CONFIG_ROOT}" "${BASELINE}" buffered off preferred
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  assert_contains 'cudf.hive.use-buffered-input=true' "${file}"
  assert_contains 'hive.s3.direct-receive-mode=preferred' "${file}"
  assert_not_contains 'hive.s3.adaptive-tcp-mss-enabled=' "${file}"
done
if apply_s3_direct_receive_worker_catalogs \
  gpu true "${CONFIG_ROOT}" "${BASELINE}" kvikio on 2>/dev/null; then
  fail 'catalog reconciliation enabled the AWS SDK adaptive policy for KvikIO'
fi

if apply_s3_direct_receive_worker_catalogs \
  gpu true "${CONFIG_ROOT}" "${BASELINE}" invalid-mode 2>/dev/null; then
  fail 'invalid GPU S3 reader mode was accepted by catalog reconciliation'
fi
if apply_s3_direct_receive_worker_catalogs \
  gpu true "${CONFIG_ROOT}" "${BASELINE}" buffered auto invalid-mode 2>/dev/null; then
  fail 'invalid S3 AWS direct-receive mode was accepted by catalog reconciliation'
fi
if apply_s3_direct_receive_worker_catalogs \
  cpu true "${CONFIG_ROOT}" "${BASELINE}" buffered auto invalid-mode 2>/dev/null; then
  fail 'invalid CPU S3 AWS direct-receive mode was accepted by catalog reconciliation'
fi

apply_s3_direct_receive_worker_catalogs gpu false "${CONFIG_ROOT}" "${BASELINE}"
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  [[ $(grep -c '^cudf.hive.use-buffered-input=true$' "${file}") -eq 1 ]] ||
    fail "GPU disabled mode did not restore the ordinary baseline in ${file}"
  assert_not_contains 'hive.s3.direct-receive-mode=' "${file}"
  assert_not_contains 'hive.s3.adaptive-tcp-mss-enabled=' "${file}"
done

unset GPU_HOST_RESERVE_GB GPU_SYSTEM_MEM_LIMIT_GB \
  GPU_SYSTEM_MEM_GB GPU_QUERY_MEM_GB || true
for mode in kvikio buffered; do
  memory_summary=$(apply_gpu_worker_memory_and_cache_config \
    "${mode}" "${CONFIG_ROOT}" 8 2032)
  assert_contains 'cache=false' <(printf '%s\n' "${memory_summary}")
  for file in "${CONFIG_ROOT}"/etc_worker*/config_native.properties; do
    [[ $(grep -c '^system-memory-gb=219$' "${file}") -eq 1 ]] ||
      fail "GPU ${mode} mode did not set system memory exactly once in ${file}"
    [[ $(grep -c '^query-memory-gb=153$' "${file}") -eq 1 ]] ||
      fail "GPU ${mode} mode did not reserve cache headroom in ${file}"
    [[ $(grep -c '^query.max-memory-per-node=153GB$' "${file}") -eq 1 ]] ||
      fail "GPU ${mode} mode did not set the coordinator-visible query limit in ${file}"
    [[ $(grep -c '^system-mem-limit-gb=229$' "${file}") -eq 1 ]] ||
      fail "GPU ${mode} mode did not bound the worker process in ${file}"
    [[ $(grep -c '^async-data-cache-enabled=false$' "${file}") -eq 1 ]] ||
      fail "GPU ${mode} mode unexpectedly enabled the async cache in ${file}"
  done
done

memory_summary=$(apply_gpu_worker_memory_and_cache_config \
  buffered-cache "${CONFIG_ROOT}" 8 2032)
assert_contains 'cache=true' <(printf '%s\n' "${memory_summary}")
for file in "${CONFIG_ROOT}"/etc_worker*/config_native.properties; do
  [[ $(grep -c '^async-data-cache-enabled=true$' "${file}") -eq 1 ]] ||
    fail "GPU buffered-cache mode did not enable the async cache in ${file}"
done

export GPU_HOST_RESERVE_GB=200
export GPU_SYSTEM_MEM_LIMIT_GB=220
export GPU_SYSTEM_MEM_GB=210
export GPU_QUERY_MEM_GB=140
apply_gpu_worker_memory_and_cache_config \
  buffered-cache "${CONFIG_ROOT}" 8 2032 >/dev/null
for file in "${CONFIG_ROOT}"/etc_worker*/config_native.properties; do
  assert_contains 'system-mem-limit-gb=220' "${file}"
  assert_contains 'system-memory-gb=210' "${file}"
  assert_contains 'query-memory-gb=140' "${file}"
  assert_contains 'query.max-memory-per-node=140GB' "${file}"
done
export GPU_SYSTEM_MEM_LIMIT_GB=230
if apply_gpu_worker_memory_and_cache_config \
  buffered-cache "${CONFIG_ROOT}" 8 2032 >/dev/null 2>&1; then
  fail 'aggregate GPU worker memory overcommit was accepted'
fi
unset GPU_HOST_RESERVE_GB GPU_SYSTEM_MEM_LIMIT_GB \
  GPU_SYSTEM_MEM_GB GPU_QUERY_MEM_GB

clear_aws_credential_env
[[ $(resolve_s3_direct_receive_credential_source auto) == instance-profile ]] ||
  fail 'auto mode did not select the instance profile without environment credentials'
assert_credential_source_fails environment \
  'environment S3 credentials require AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY'

export AWS_ACCESS_KEY_ID='AKIA_TEST_ACCESS_KEY'
assert_credential_source_fails auto \
  'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must either both be set or both be unset'
assert_credential_source_fails environment \
  'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must either both be set or both be unset'

clear_aws_credential_env
export AWS_SECRET_ACCESS_KEY='TEST_SECRET_KEY'
assert_credential_source_fails auto \
  'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must either both be set or both be unset'

clear_aws_credential_env
export AWS_SESSION_TOKEN='TEST_SESSION_TOKEN'
assert_credential_source_fails auto \
  'AWS_SESSION_TOKEN requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY'

export AWS_ACCESS_KEY_ID='AKIA_TEST_ACCESS_KEY'
assert_credential_source_fails auto \
  'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must either both be set or both be unset'

clear_aws_credential_env
export AWS_SECRET_ACCESS_KEY='TEST_SECRET_KEY'
export AWS_SESSION_TOKEN='TEST_SESSION_TOKEN'
assert_credential_source_fails environment \
  'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must either both be set or both be unset'

export AWS_ACCESS_KEY_ID='AKIA_TEST_ACCESS_KEY'
unset AWS_SESSION_TOKEN
[[ $(resolve_s3_direct_receive_credential_source auto) == environment ]] ||
  fail 'auto mode did not select complete long-lived environment credentials'
[[ $(resolve_s3_direct_receive_credential_source environment) == environment ]] ||
  fail 'explicit environment mode rejected complete long-lived credentials'

export AWS_SESSION_TOKEN='TEST_SESSION_TOKEN'
assert_credential_source_fails auto \
  'auto S3 credential selection will not snapshot temporary AWS environment credentials'
[[ $(resolve_s3_direct_receive_credential_source environment) == environment ]] ||
  fail 'explicit environment mode rejected complete temporary credentials'
[[ $(resolve_s3_direct_receive_credential_source instance-profile) == instance-profile ]] ||
  fail 'instance-profile mode did not suppress complete environment credentials'

export AWS_ACCESS_KEY_ID='ASIA_TEST_TEMPORARY_KEY'
unset AWS_SESSION_TOKEN
assert_credential_source_fails environment \
  'temporary AWS access keys require AWS_SESSION_TOKEN'
assert_credential_source_fails invalid-source \
  'S3 credential source must be auto, environment, or instance-profile'

export AWS_ACCESS_KEY_ID='SENTINEL_ACCESS_KEY_MUST_NOT_BE_RENDERED'
export AWS_SECRET_ACCESS_KEY='SENTINEL_SECRET_KEY_MUST_NOT_BE_RENDERED'
export AWS_SESSION_TOKEN='SENTINEL_SESSION_TOKEN_MUST_NOT_BE_RENDERED'
export AWS_REGION='SENTINEL_REGION_MUST_NOT_BE_RENDERED'
export AWS_ENDPOINT_URL='https://sentinel-endpoint-must-not-be-rendered.invalid'
export AWS_EC2_METADATA_SERVICE_ENDPOINT='http://sentinel-imds-must-not-be-rendered.invalid'
export KVIKIO_REMOTE_IO_NUM_REACTORS='SENTINEL_KVIKIO_VALUE_MUST_NOT_BE_RENDERED'
export KVIKIO_REMOTE_IO_REACTOR_DISPATCH='SENTINEL_KVIKIO_VALUE_MUST_NOT_BE_RENDERED'
export KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS='SENTINEL_KVIKIO_VALUE_MUST_NOT_BE_RENDERED'
export KVIKIO_TASK_SIZE='SENTINEL_KVIKIO_VALUE_MUST_NOT_BE_RENDERED'
export KVIKIO_REMOTE_DIRECT_RECEIVE='SENTINEL_KVIKIO_VALUE_MUST_NOT_BE_RENDERED'

CPU_OVERRIDE="${TEST_ROOT}/cpu-direct.yml"
render_s3_direct_receive_compose_override \
  cpu true 'presto-native-worker-cpu:test-s3-direct' "${CPU_OVERRIDE}" \
  environment \
  presto-native-worker-cpu-0 presto-native-worker-cpu-1
assert_contains 'image: "presto-native-worker-cpu:test-s3-direct"' "${CPU_OVERRIDE}"
assert_contains '  presto-coordinator:' "${CPU_OVERRIDE}"
assert_contains 'AWS_ACCESS_KEY_ID:' "${CPU_OVERRIDE}"
assert_contains 'AWS_SECRET_ACCESS_KEY:' "${CPU_OVERRIDE}"
assert_not_contains 'KVIKIO_REMOTE_IO_BACKEND:' "${CPU_OVERRIDE}"

GPU_OVERRIDE="${TEST_ROOT}/gpu-direct.yml"
render_s3_direct_receive_compose_override \
  gpu true 'presto-native-worker-gpu:test-s3-direct' "${GPU_OVERRIDE}" \
  environment \
  presto-native-worker-gpu
assert_contains '  presto-coordinator:' "${GPU_OVERRIDE}"
assert_contains 'AWS_SESSION_TOKEN:' "${GPU_OVERRIDE}"
assert_contains 'AWS_DEFAULT_REGION:' "${GPU_OVERRIDE}"
assert_contains 'AWS_ENDPOINT_URL:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_IO_BACKEND:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_IO_NUM_REACTORS:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_IO_REACTOR_DISPATCH:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_TASK_SIZE:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_DIRECT_RECEIVE:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_DIRECT_RECEIVE_SLOT_SIZE:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_DIRECT_RECEIVE_MAX_PINNED_BYTES:' "${GPU_OVERRIDE}"
for sentinel in SENTINEL_ACCESS SENTINEL_SECRET SENTINEL_SESSION \
  SENTINEL_REGION sentinel-endpoint SENTINEL_KVIKIO; do
  assert_not_contains "${sentinel}" "${CPU_OVERRIDE}"
  assert_not_contains "${sentinel}" "${GPU_OVERRIDE}"
done
for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
  AWS_REGION AWS_DEFAULT_REGION AWS_ENDPOINT_URL AWS_EC2_METADATA_SERVICE_ENDPOINT; do
  [[ $(grep -Fxc "      ${variable}:" "${CPU_OVERRIDE}") -eq 3 ]] ||
    fail "CPU override did not forward ${variable} to the coordinator and both workers"
  [[ $(grep -Fxc "      ${variable}:" "${GPU_OVERRIDE}") -eq 2 ]] ||
    fail "GPU override did not forward ${variable} to the coordinator and worker"
done
for variable in KVIKIO_REMOTE_IO_BACKEND KVIKIO_REMOTE_IO_NUM_REACTORS \
  KVIKIO_REMOTE_IO_REACTOR_DISPATCH KVIKIO_REMOTE_IO_MAX_CONCURRENT_REQUESTS \
  KVIKIO_TASK_SIZE KVIKIO_REMOTE_DIRECT_RECEIVE \
  KVIKIO_REMOTE_DIRECT_RECEIVE_SLOT_SIZE \
  KVIKIO_REMOTE_DIRECT_RECEIVE_MAX_PINNED_BYTES; do
  grep -Fx "      ${variable}:" "${GPU_OVERRIDE}" >/dev/null ||
    fail "GPU override did not render ${variable} as a blank mapping"
done

CPU_PROVIDER_OVERRIDE="${TEST_ROOT}/cpu-instance-profile.yml"
render_s3_direct_receive_compose_override \
  cpu true 'presto-native-worker-cpu:test-s3-direct' \
  "${CPU_PROVIDER_OVERRIDE}" instance-profile \
  presto-native-worker-cpu-0 presto-native-worker-cpu-1
GPU_PROVIDER_OVERRIDE="${TEST_ROOT}/gpu-instance-profile.yml"
render_s3_direct_receive_compose_override \
  gpu true 'presto-native-worker-gpu:test-s3-direct' \
  "${GPU_PROVIDER_OVERRIDE}" instance-profile presto-native-worker-gpu
for override in "${CPU_PROVIDER_OVERRIDE}" "${GPU_PROVIDER_OVERRIDE}"; do
  for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    assert_not_contains "${variable}:" "${override}"
  done
  for variable in AWS_REGION AWS_DEFAULT_REGION AWS_ENDPOINT_URL \
    AWS_EC2_METADATA_SERVICE_ENDPOINT; do
    assert_contains "      ${variable}:" "${override}"
  done
  for sentinel in SENTINEL_ACCESS SENTINEL_SECRET SENTINEL_SESSION \
    SENTINEL_REGION sentinel-endpoint sentinel-imds; do
    assert_not_contains "${sentinel}" "${override}"
  done
done
assert_not_contains 'KVIKIO_REMOTE_IO_BACKEND:' "${CPU_PROVIDER_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_IO_BACKEND:' "${GPU_PROVIDER_OVERRIDE}"

INVALID_OVERRIDE="${TEST_ROOT}/invalid-source.yml"
if render_s3_direct_receive_compose_override \
  gpu true ignored "${INVALID_OVERRIDE}" auto presto-native-worker-gpu \
  2> "${TEST_ROOT}/invalid-render-source.txt"; then
  fail 'compose renderer accepted an unresolved credential source'
fi
assert_contains 'compose rendering requires a resolved S3 credential source' \
  "${TEST_ROOT}/invalid-render-source.txt"

DISABLED_OVERRIDE="${TEST_ROOT}/disabled.yml"
render_s3_direct_receive_compose_override \
  gpu false ignored "${DISABLED_OVERRIDE}" instance-profile \
  presto-native-worker-gpu
[[ ! -s ${DISABLED_OVERRIDE} ]] ||
  fail 'disabled mode rendered a credential-forwarding override'

CPU_LAUNCHER="${SCRIPT_DIR}/start_native_cpu_presto_dev.sh"
GPU_LAUNCHER="${SCRIPT_DIR}/start_native_gpu_presto_dev.sh"
GPU_COMPOSE_TEMPLATE="${SCRIPT_DIR}/../docker/docker-compose/template/docker-compose.native-gpu.yml.jinja"
NATIVE_DOCKERFILE="${SCRIPT_DIR}/../docker/native_build.dockerfile"
S3_DIRECT_DEPS_DOCKERFILE="${SCRIPT_DIR}/../docker/s3_direct_receive_deps.dockerfile"
ADAPTERS_DOCKERFILE="${SCRIPT_DIR}/../../velox/docker/adapters_build.dockerfile"
COMMON_COMPOSE="${SCRIPT_DIR}/../docker/docker-compose.common.yml"
for launcher in "${CPU_LAUNCHER}" "${GPU_LAUNCHER}"; do
  assert_contains '--s3-direct-receive' "${launcher}"
  assert_contains 'PRESTO_DEV_S3_DIRECT_RECEIVE' "${launcher}"
  assert_contains '--s3-aws-direct-receive-mode' "${launcher}"
  assert_contains 'PRESTO_DEV_S3_AWS_DIRECT_RECEIVE_MODE' "${launcher}"
  assert_contains 'normalize_s3_aws_direct_receive_mode' "${launcher}"
  assert_contains '--s3-credential-source' "${launcher}"
  assert_contains 'PRESTO_DEV_S3_CREDENTIAL_SOURCE' "${launcher}"
  assert_contains '--s3-adaptive-tcp-mss' "${launcher}"
  assert_contains 'PRESTO_DEV_S3_ADAPTIVE_TCP_MSS' "${launcher}"
  assert_contains 'resolve_s3_adaptive_tcp_mss_enabled' "${launcher}"
  assert_contains 'resolve_s3_direct_receive_credential_source' "${launcher}"
  assert_contains '--build-arg "S3_DIRECT_RECEIVE=' "${launcher}"
  assert_contains 'isolate_s3_direct_cache_scope' "${launcher}"
  assert_contains 'bind_native_cache_scope_to_dependency_image' "${launcher}"
  assert_contains 'ensure_s3_direct_dependency_image' "${launcher}"
  assert_occurs_before \
    'ensure_s3_direct_dependency_image' \
    'bind_native_cache_scope_to_dependency_image' \
    "${launcher}"
done
# The following assertions intentionally match literal shell/Docker variables.
# shellcheck disable=SC2016
assert_contains 'CPU_WORKER_IMAGE="${CPU_WORKER_SERVICE}:${PRESTO_IMAGE_TAG}-s3-direct"' "${CPU_LAUNCHER}"
# shellcheck disable=SC2016
assert_contains 'GPU_WORKER_IMAGE="${GPU_WORKER_SERVICE}:${PRESTO_IMAGE_TAG}${PRESTO_GPU_WORKER_IMAGE_TAG_SUFFIX}-s3-direct"' "${GPU_LAUNCHER}"
# shellcheck disable=SC2016
assert_contains 'PRESTO_GPU_WORKER_IMAGE_TAG_SUFFIX="-cuda${DEV_CUDA_VERSION}"' "${GPU_LAUNCHER}"
# shellcheck disable=SC2016
assert_contains '${PRESTO_GPU_WORKER_IMAGE_TAG_SUFFIX:-}' "${GPU_COMPOSE_TEMPLATE}"
assert_contains 'apply_s3_direct_receive_kvikio_defaults' "${GPU_LAUNCHER}"
assert_not_contains 'apply_s3_direct_receive_kvikio_defaults' "${CPU_LAUNCHER}"
assert_contains '--s3-reader-mode' "${GPU_LAUNCHER}"
assert_contains 'PRESTO_DEV_GPU_S3_READER_MODE' "${GPU_LAUNCHER}"
assert_contains '--cuda-version' "${GPU_LAUNCHER}"
assert_contains 'PRESTO_DEV_CUDA_VERSION' "${GPU_LAUNCHER}"
# This assertion intentionally matches a literal shell variable.
# shellcheck disable=SC2016
assert_contains '--cuda-version "$DEV_CUDA_VERSION"' "${GPU_LAUNCHER}"
assert_gpu_launcher_rejects_cuda_version
assert_gpu_launcher_rejects_cuda_deps_override
assert_launcher_rejects_aws_direct_receive_mode \
  "${CPU_LAUNCHER}" \
  'S3 AWS direct-receive mode must be caller-buffer, preferred, or required' \
  --s3-aws-direct-receive-mode invalid
assert_launcher_rejects_aws_direct_receive_mode \
  "${GPU_LAUNCHER}" \
  'S3 AWS direct-receive mode must be caller-buffer, preferred, or required' \
  --s3-reader-mode buffered-cache --s3-aws-direct-receive-mode invalid
assert_launcher_rejects_aws_direct_receive_mode \
  "${GPU_LAUNCHER}" \
  'S3 AWS direct-receive mode applies only to --s3-reader-mode buffered or buffered-cache' \
  --s3-aws-direct-receive-mode required
# Existing versioned worker images must remain reusable without an explicit
# worker build target.
# shellcheck disable=SC2016
assert_contains 'conditionally_add_build_target "$GPU_WORKER_IMAGE"' "${GPU_LAUNCHER}"
# shellcheck disable=SC2016
assert_not_contains '! build_targets_include_gpu_worker' "${GPU_LAUNCHER}"
assert_contains 'apply_gpu_worker_memory_and_cache_config' "${GPU_LAUNCHER}"
assert_contains 'apply_gpu_s3_coordinator_config' "${GPU_LAUNCHER}"
assert_contains 'reconcile_gpu_s3_coordinator_restart_target' "${GPU_LAUNCHER}"
assert_contains 'configure_dev_gpu_ucx_environment' "${GPU_LAUNCHER}"
assert_contains 'PRESTO_GPU_UCX_TLS' "${GPU_LAUNCHER}"
assert_contains 'PRESTO_GPU_UCX_MAX_RNDV_RAILS' "${GPU_LAUNCHER}"
assert_gpu_launcher_rejects_ucx_environment \
  'UCX_MAX_RDNV_RAILS is misspelled; use UCX_MAX_RNDV_RAILS.' \
  UCX_MAX_RDNV_RAILS=1
assert_gpu_launcher_rejects_ucx_environment \
  'PRESTO_GPU_UCX_MAX_RNDV_RAILS must be a positive integer.' \
  UCX_MAX_RNDV_RAILS=zero
assert_gpu_launcher_rejects_ucx_environment \
  'PRESTO_GPU_UCX_TLS must contain at least one UCX transport.' \
  'UCX_TLS= '
assert_contains 'render_gpu_s3_coordinator_state_override' "${GPU_LAUNCHER}"
assert_contains 'COMPOSE_FILE_ARGS+=(-f "${GPU_S3_COORDINATOR_STATE_OVERRIDE_PATH}")' "${GPU_LAUNCHER}"
assert_not_contains '--s3-reader-mode' "${CPU_LAUNCHER}"
# shellcheck disable=SC2016
[[ $(grep -Fxc '      UCX_TLS: "${UCX_TLS:-tcp,cuda_copy,cuda_ipc}"' "${GPU_COMPOSE_TEMPLATE}") -eq 3 ]] ||
  fail 'GPU compose template does not forward UCX_TLS to every worker layout'
# shellcheck disable=SC2016
[[ $(grep -Fxc '      UCX_MAX_RNDV_RAILS: "${UCX_MAX_RNDV_RAILS:-2}"' "${GPU_COMPOSE_TEMPLATE}") -eq 3 ]] ||
  fail 'GPU compose template does not forward UCX_MAX_RNDV_RAILS to every worker layout'
assert_contains 'config/template/etc_worker/catalog/hive.properties' "${GPU_LAUNCHER}"
assert_contains 'ARG S3_DIRECT_RECEIVE=OFF' "${NATIVE_DOCKERFILE}"
assert_contains '-DVELOX_ENABLE_S3_DIRECT_RECEIVE=ON' "${NATIVE_DOCKERFILE}"
# shellcheck disable=SC2016
assert_contains '-DAWSSDK_ROOT_DIR=${S3_DIRECT_RECEIVE_PREFIX}' "${NATIVE_DOCKERFILE}"
# shellcheck disable=SC2016
assert_contains '-DCURL_DIR=${S3_DIRECT_RECEIVE_PREFIX}/lib/cmake/CURL' "${NATIVE_DOCKERFILE}"
assert_contains 'curl_recv_buffer_build_version_v1' "${NATIVE_DOCKERFILE}"
assert_contains 'curl_ktls_direct_rx_build_version_v1' "${NATIVE_DOCKERFILE}"
assert_contains 'GetDirectResponseReceiveApiVersionV2()' "${NATIVE_DOCKERFILE}"
assert_contains 'GetDirectResponseReceiveStrictKernelTlsApiVersionV1()' "${NATIVE_DOCKERFILE}"
assert_contains 'GetAdaptiveTcpMssApiVersionV1()' "${NATIVE_DOCKERFILE}"
assert_contains 'GetAdaptiveTcpMssApiVersionV1()' "${S3_DIRECT_DEPS_DOCKERFILE}"
assert_contains 'direct_prefix=/opt/presto-s3-direct/lib' "${NATIVE_DOCKERFILE}"
# shellcheck disable=SC2016
assert_contains 'Runtime resolved libcurl outside ${direct_prefix}' "${NATIVE_DOCKERFILE}"
for dockerfile in "${NATIVE_DOCKERFILE}" "${ADAPTERS_DOCKERFILE}"; do
  assert_contains '--mount=type=secret,id=github_token,target=/run/secrets/github_token' "${dockerfile}"
  assert_not_contains '--mount=type=secret,id=github_token,env=' "${dockerfile}"
  assert_contains '    set +x;' "${dockerfile}"
  # shellcheck disable=SC2016
  assert_contains 'SCCACHE_DIST_AUTH_TOKEN="$(cat /run/secrets/github_token)"' "${dockerfile}"
  assert_contains '    set -x;' "${dockerfile}"
done
# shellcheck disable=SC2016
assert_contains 'Runtime resolved ${soname} outside ${direct_prefix}' "${NATIVE_DOCKERFILE}"
# shellcheck disable=SC2016
assert_contains 'index($3, direct_prefix) == 1' "${NATIVE_DOCKERFILE}"
assert_contains 'cp -a /runtime-libraries/. /usr/lib64/presto-native-libs/' "${NATIVE_DOCKERFILE}"
assert_not_contains 'xargs -0 -r cp -a -t /runtime-libraries/' "${NATIVE_DOCKERFILE}"
# shellcheck disable=SC2016
assert_contains 'S3_DIRECT_RECEIVE=${S3_DIRECT_RECEIVE:-OFF}' "${COMMON_COMPOSE}"

echo 'S3 direct-receive developer integration tests passed.'
