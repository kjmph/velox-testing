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

ORIGINAL_SCRIPT_DIR=${SCRIPT_DIR}
MOCK_SCRIPT_DIR="${TEST_ROOT}/mock-scripts"
MOCK_BUILD_LOG="${TEST_ROOT}/mock-build.log"
mkdir -p "${MOCK_SCRIPT_DIR}"
# The mock script must expand these variables when it runs, not while this
# test constructs it.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$@" > "${MOCK_BUILD_LOG}"' \
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
ensure_s3_direct_dependency_image \
  direct-image ordinary-image /src/presto /src/velox true
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
mkdir -p \
  "${CONFIG_ROOT}/etc_worker/catalog" \
  "${CONFIG_ROOT}/etc_worker_0/catalog" \
  "${CONFIG_ROOT}/etc_coordinator/catalog"
printf '%s\n' \
  'connector.name=hive-hadoop2' \
  'cudf.hive.use-buffered-input=true' > "${BASELINE}"
for file in \
  "${CONFIG_ROOT}/etc_worker/catalog/hive.properties" \
  "${CONFIG_ROOT}/etc_worker_0/catalog/hive.properties" \
  "${CONFIG_ROOT}/etc_coordinator/catalog/hive.properties"; do
  printf '%s\n' \
    'connector.name=hive-hadoop2' \
    'hive.s3.direct-receive-mode=stale' \
    'cudf.hive.use-buffered-input=stale' > "${file}"
done

apply_s3_direct_receive_worker_catalogs cpu true "${CONFIG_ROOT}" "${BASELINE}"
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  [[ $(grep -c '^hive.s3.direct-receive-mode=caller-buffer$' "${file}") -eq 1 ]] ||
    fail "CPU direct mode was not reconciled exactly once in ${file}"
done
assert_contains \
  'hive.s3.direct-receive-mode=stale' \
  "${CONFIG_ROOT}/etc_coordinator/catalog/hive.properties"

apply_s3_direct_receive_worker_catalogs cpu false "${CONFIG_ROOT}" "${BASELINE}"
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  assert_not_contains 'hive.s3.direct-receive-mode=' "${file}"
done

apply_s3_direct_receive_worker_catalogs gpu true "${CONFIG_ROOT}" "${BASELINE}"
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  [[ $(grep -c '^cudf.hive.use-buffered-input=false$' "${file}") -eq 1 ]] ||
    fail "GPU direct mode was not reconciled exactly once in ${file}"
  assert_not_contains 'hive.s3.direct-receive-mode=' "${file}"
done

apply_s3_direct_receive_worker_catalogs gpu false "${CONFIG_ROOT}" "${BASELINE}"
for file in "${CONFIG_ROOT}"/etc_worker*/catalog/hive.properties; do
  [[ $(grep -c '^cudf.hive.use-buffered-input=true$' "${file}") -eq 1 ]] ||
    fail "GPU disabled mode did not restore the ordinary baseline in ${file}"
done

export AWS_ACCESS_KEY_ID='SENTINEL_ACCESS_KEY_MUST_NOT_BE_RENDERED'
export AWS_SECRET_ACCESS_KEY='SENTINEL_SECRET_KEY_MUST_NOT_BE_RENDERED'
export AWS_SESSION_TOKEN='SENTINEL_SESSION_TOKEN_MUST_NOT_BE_RENDERED'
export AWS_REGION='SENTINEL_REGION_MUST_NOT_BE_RENDERED'
export AWS_ENDPOINT_URL='https://sentinel-endpoint-must-not-be-rendered.invalid'
export KVIKIO_REMOTE_DIRECT_RECEIVE='SENTINEL_KVIKIO_VALUE_MUST_NOT_BE_RENDERED'

CPU_OVERRIDE="${TEST_ROOT}/cpu-direct.yml"
render_s3_direct_receive_compose_override \
  cpu true 'presto-native-worker-cpu:test-s3-direct' "${CPU_OVERRIDE}" \
  presto-native-worker-cpu-0 presto-native-worker-cpu-1
assert_contains 'image: "presto-native-worker-cpu:test-s3-direct"' "${CPU_OVERRIDE}"
assert_contains '  presto-coordinator:' "${CPU_OVERRIDE}"
assert_contains 'AWS_ACCESS_KEY_ID:' "${CPU_OVERRIDE}"
assert_contains 'AWS_SECRET_ACCESS_KEY:' "${CPU_OVERRIDE}"
assert_not_contains 'KVIKIO_REMOTE_IO_BACKEND:' "${CPU_OVERRIDE}"

GPU_OVERRIDE="${TEST_ROOT}/gpu-direct.yml"
render_s3_direct_receive_compose_override \
  gpu true 'presto-native-worker-gpu:test-s3-direct' "${GPU_OVERRIDE}" \
  presto-native-worker-gpu
assert_contains '  presto-coordinator:' "${GPU_OVERRIDE}"
assert_contains 'AWS_SESSION_TOKEN:' "${GPU_OVERRIDE}"
assert_contains 'AWS_DEFAULT_REGION:' "${GPU_OVERRIDE}"
assert_contains 'AWS_ENDPOINT_URL:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_IO_BACKEND:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_DIRECT_RECEIVE:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_DIRECT_RECEIVE_SLOT_SIZE:' "${GPU_OVERRIDE}"
assert_contains 'KVIKIO_REMOTE_DIRECT_RECEIVE_MAX_PINNED_BYTES:' "${GPU_OVERRIDE}"
for sentinel in SENTINEL_ACCESS SENTINEL_SECRET SENTINEL_SESSION \
  SENTINEL_REGION sentinel-endpoint SENTINEL_KVIKIO; do
  assert_not_contains "${sentinel}" "${CPU_OVERRIDE}"
  assert_not_contains "${sentinel}" "${GPU_OVERRIDE}"
done
for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
  AWS_REGION AWS_DEFAULT_REGION AWS_ENDPOINT_URL; do
  [[ $(grep -Fxc "      ${variable}:" "${CPU_OVERRIDE}") -eq 3 ]] ||
    fail "CPU override did not forward ${variable} to the coordinator and both workers"
  [[ $(grep -Fxc "      ${variable}:" "${GPU_OVERRIDE}") -eq 2 ]] ||
    fail "GPU override did not forward ${variable} to the coordinator and worker"
done
for variable in KVIKIO_REMOTE_IO_BACKEND KVIKIO_REMOTE_DIRECT_RECEIVE \
  KVIKIO_REMOTE_DIRECT_RECEIVE_SLOT_SIZE \
  KVIKIO_REMOTE_DIRECT_RECEIVE_MAX_PINNED_BYTES; do
  grep -Fx "      ${variable}:" "${GPU_OVERRIDE}" >/dev/null ||
    fail "GPU override did not render ${variable} as a blank mapping"
done

DISABLED_OVERRIDE="${TEST_ROOT}/disabled.yml"
render_s3_direct_receive_compose_override \
  gpu false ignored "${DISABLED_OVERRIDE}" presto-native-worker-gpu
[[ ! -s ${DISABLED_OVERRIDE} ]] ||
  fail 'disabled mode rendered a credential-forwarding override'

CPU_LAUNCHER="${SCRIPT_DIR}/start_native_cpu_presto_dev.sh"
GPU_LAUNCHER="${SCRIPT_DIR}/start_native_gpu_presto_dev.sh"
NATIVE_DOCKERFILE="${SCRIPT_DIR}/../docker/native_build.dockerfile"
ADAPTERS_DOCKERFILE="${SCRIPT_DIR}/../../velox/docker/adapters_build.dockerfile"
COMMON_COMPOSE="${SCRIPT_DIR}/../docker/docker-compose.common.yml"
for launcher in "${CPU_LAUNCHER}" "${GPU_LAUNCHER}"; do
  assert_contains '--s3-direct-receive' "${launcher}"
  assert_contains 'PRESTO_DEV_S3_DIRECT_RECEIVE' "${launcher}"
  assert_contains '--build-arg "S3_DIRECT_RECEIVE=' "${launcher}"
  assert_contains 'isolate_s3_direct_cache_scope' "${launcher}"
  assert_contains 'ensure_s3_direct_dependency_image' "${launcher}"
done
# The following assertions intentionally match literal shell/Docker variables.
# shellcheck disable=SC2016
assert_contains 'CPU_WORKER_IMAGE="${CPU_WORKER_SERVICE}:${PRESTO_IMAGE_TAG}-s3-direct"' "${CPU_LAUNCHER}"
# shellcheck disable=SC2016
assert_contains 'GPU_WORKER_IMAGE="${GPU_WORKER_SERVICE}:${PRESTO_IMAGE_TAG}-s3-direct"' "${GPU_LAUNCHER}"
assert_contains 'KVIKIO_REMOTE_IO_BACKEND:-MULTI_POLL' "${GPU_LAUNCHER}"
assert_contains 'KVIKIO_REMOTE_DIRECT_RECEIVE:-REQUIRE' "${GPU_LAUNCHER}"
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
