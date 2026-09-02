#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_SCRIPT="${SCRIPT_DIR}/build_centos_deps_image.sh"
TEST_ROOT=$(mktemp -d "${SCRIPT_DIR}/.build_centos_deps_image_test.XXXXXX")
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

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

PRESTO_SOURCE="${TEST_ROOT}/presto"
PRESTO_NATIVE_DIR="${PRESTO_SOURCE}/presto-native-execution"
VELOX_SOURCE="${TEST_ROOT}/velox"
FAKE_BIN="${TEST_ROOT}/bin"
DOCKER_LOG="${TEST_ROOT}/docker.log"
CANONICAL_ID_FILE="${TEST_ROOT}/canonical.id"
BASE_ID_FILE="${TEST_ROOT}/base.id"
OUTPUT_ID_FILE="${TEST_ROOT}/output.id"
CONTENT_ALIAS_FILE="${TEST_ROOT}/content-alias"
CANONICAL_IMAGE='presto/prestissimo-dependency:centos9'
DEFAULT_BASE_IMAGE='presto/prestissimo-dependency:centos9-tester'
BASE_IMAGE='registry.example.test:5000/presto/dependency:base'
CURL_COMMIT='f6d53a27b7d80fa4087709243d4d425b3405c941'
AWS_COMMIT='2c43b2350a49edfd8ff91fae2816291dc2ed282f'
CANONICAL_ID="sha256:$(printf 'c%.0s' {1..64})"
BASE_ID="sha256:$(printf 'b%.0s' {1..64})"

mkdir -p \
  "${PRESTO_NATIVE_DIR}/velox" \
  "${VELOX_SOURCE}/scripts" \
  "${VELOX_SOURCE}/CMake" \
  "${FAKE_BIN}"
touch "${PRESTO_SOURCE}/pom.xml"
touch "${PRESTO_NATIVE_DIR}/docker-compose.yml"
touch "${VELOX_SOURCE}/CMakeLists.txt"
touch "${VELOX_SOURCE}/scripts/setup-centos9.sh"
touch "${VELOX_SOURCE}/scripts/setup-common.sh"
printf 'original\n' > "${PRESTO_NATIVE_DIR}/velox/original-marker"
printf 'selected\n' > "${VELOX_SOURCE}/scripts/selected-marker"
printf 'S3_DIRECT_RECEIVE_CURL_COMMIT="%s"\nS3_DIRECT_RECEIVE_AWS_SDK_COMMIT="%s"\n' \
  "${CURL_COMMIT}" "${AWS_COMMIT}" \
  > "${VELOX_SOURCE}/scripts/setup-versions.sh"
printf 'touch %q\n' "${TEST_ROOT}/host-code-ran" \
  >> "${VELOX_SOURCE}/scripts/setup-versions.sh"

cat > "${FAKE_BIN}/docker" <<'EOF'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG}"

if [[ $1 == image && $2 == inspect ]]; then
  image=${!#}
  case ${image} in
    "${FAKE_DOCKER_BASE_IMAGE}")
      cat "${FAKE_DOCKER_BASE_ID_FILE}"
      ;;
    "${FAKE_DOCKER_DEFAULT_BASE_IMAGE}")
      cat "${FAKE_DOCKER_BASE_ID_FILE}"
      ;;
    "${FAKE_DOCKER_CANONICAL_IMAGE}")
      cat "${FAKE_DOCKER_CANONICAL_ID_FILE}"
      ;;
    presto/s3-direct-build-base:sha256-*)
      if [[ ${FAKE_DOCKER_ALIAS_COLLISION:-0} == 1 ]]; then
        printf 'sha256:%064d\n' 9
      elif [[ -f ${FAKE_DOCKER_CONTENT_ALIAS_FILE} &&
        $(<"${FAKE_DOCKER_CONTENT_ALIAS_FILE}") == "${image}" ]]; then
        cat "${FAKE_DOCKER_BASE_ID_FILE}"
      else
        exit 1
      fi
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi

if [[ $1 == compose ]]; then
  printf 'sha256:compose-overwrite\n' > "${FAKE_DOCKER_CANONICAL_ID_FILE}"
  if [[ ${FAKE_DOCKER_FAIL_BUILD:-0} == 1 ]]; then
    exit 42
  fi
  exit 0
fi

if [[ $1 == tag ]]; then
  if [[ $2 == "${FAKE_DOCKER_CANONICAL_IMAGE}" ]]; then
    cat "${FAKE_DOCKER_CANONICAL_ID_FILE}" > "${FAKE_DOCKER_OUTPUT_ID_FILE}"
  elif [[ $2 == "$(<"${FAKE_DOCKER_BASE_ID_FILE}")" &&
    $3 == presto/s3-direct-build-base:sha256-* ]]; then
    printf '%s\n' "$3" > "${FAKE_DOCKER_CONTENT_ALIAS_FILE}"
  fi
  exit 0
fi

if [[ $1 == run ]]; then
  if [[ ${FAKE_DOCKER_FAIL_CUDA_VALIDATION:-0} == 1 ]]; then
    exit 47
  fi
  printf '%s\n%s\n' \
    "${FAKE_CUDA_ENV_VERSION:-13.2}" \
    "${FAKE_NVCC_VERSION:-13.2}"
  exit 0
fi

if [[ $1 == build ]]; then
  tag=''
  dockerfile=''
  expected_installer_hash=''
  base_dependency_build_image=''
  context=${!#}
  for ((index = 1; index <= $#; ++index)); do
    if [[ ${!index} == --tag ]]; then
      next=$((index + 1))
      tag=${!next}
    elif [[ ${!index} == --file ]]; then
      next=$((index + 1))
      dockerfile=${!next}
    elif [[ ${!index} == --build-arg ]]; then
      next=$((index + 1))
      if [[ ${!next} == INSTALLER_SOURCE_SHA256=* ]]; then
        expected_installer_hash=${!next#INSTALLER_SOURCE_SHA256=}
      elif [[ ${!next} == BASE_DEPENDENCY_BUILD_IMAGE=* ]]; then
        base_dependency_build_image=${!next#BASE_DEPENDENCY_BUILD_IMAGE=}
      fi
    fi
  done
  [[ -f ${context}/velox/scripts/selected-marker ]] || exit 43
  if [[ ${dockerfile} == scripts/dockerfiles/centos-dependency.dockerfile ]]; then
    if [[ ${FAKE_DOCKER_FAIL_BUILD:-0} == 1 ]]; then
      exit 42
    fi
    printf 'sha256:ordinary-result\n' > "${FAKE_DOCKER_OUTPUT_ID_FILE}"
    exit 0
  fi
  actual_installer_hash=$(
    cd "${context}/velox"
    find scripts \( -type f -o -type l \) -print0 |
      LC_ALL=C sort -z |
      xargs -0 sha256sum |
      sha256sum |
      awk '{print $1}'
  )
  [[ -n ${expected_installer_hash} &&
    ${actual_installer_hash} == "${expected_installer_hash}" ]] || exit 45
  [[ ${base_dependency_build_image} != sha256:* &&
    -f ${FAKE_DOCKER_CONTENT_ALIAS_FILE} &&
    $(<"${FAKE_DOCKER_CONTENT_ALIAS_FILE}") == "${base_dependency_build_image}" ]] || exit 46
  printf 'selected-context=%s\n' "${context}" >> "${FAKE_DOCKER_LOG}"
  if [[ ${FAKE_DOCKER_FAIL_BUILD:-0} == 1 ]]; then
    exit 42
  fi
  case ${tag} in
    "${FAKE_DOCKER_CANONICAL_IMAGE}")
      printf 'sha256:direct-overwrite\n' > "${FAKE_DOCKER_CANONICAL_ID_FILE}"
      ;;
    "${FAKE_DOCKER_BASE_IMAGE}")
      printf 'sha256:direct-overwrite\n' > "${FAKE_DOCKER_BASE_ID_FILE}"
      ;;
    *)
      printf 'sha256:direct-result\n' > "${FAKE_DOCKER_OUTPUT_ID_FILE}"
      ;;
  esac
  exit 0
fi

exit 44
EOF
chmod +x "${FAKE_BIN}/docker"

export PATH="${FAKE_BIN}:${PATH}"
export FAKE_DOCKER_LOG="${DOCKER_LOG}"
export FAKE_DOCKER_CANONICAL_IMAGE="${CANONICAL_IMAGE}"
export FAKE_DOCKER_DEFAULT_BASE_IMAGE="${DEFAULT_BASE_IMAGE}"
export FAKE_DOCKER_BASE_IMAGE="${BASE_IMAGE}"
export FAKE_DOCKER_CANONICAL_ID_FILE="${CANONICAL_ID_FILE}"
export FAKE_DOCKER_BASE_ID_FILE="${BASE_ID_FILE}"
export FAKE_DOCKER_OUTPUT_ID_FILE="${OUTPUT_ID_FILE}"
export FAKE_DOCKER_CONTENT_ALIAS_FILE="${CONTENT_ALIAS_FILE}"

reset_fake_images() {
  : > "${DOCKER_LOG}"
  printf '%s\n' "${CANONICAL_ID}" > "${CANONICAL_ID_FILE}"
  printf '%s\n' "${BASE_ID}" > "${BASE_ID_FILE}"
  rm -f "${OUTPUT_ID_FILE}" "${CONTENT_ALIAS_FILE}"
}

assert_embedded_velox_restored() {
  [[ -f ${PRESTO_NATIVE_DIR}/velox/original-marker ]] ||
    fail 'the embedded Velox tree was not restored'
  [[ ! -e ${PRESTO_NATIVE_DIR}/velox/scripts/selected-marker ]] ||
    fail 'the selected Velox scripts leaked into the embedded tree'
  [[ ! -e ${PRESTO_NATIVE_DIR}/velox.bak ]] ||
    fail 'the embedded Velox backup was not removed'
}

# The ordinary mode retains the existing compose build and retag behavior.
reset_fake_images
"${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --image-name test.example/presto-deps:ordinary
assert_contains 'compose --progress plain build centos-native-dependency' "${DOCKER_LOG}"
assert_contains \
  'tag presto/prestissimo-dependency:centos9 test.example/presto-deps:ordinary' \
  "${DOCKER_LOG}"
assert_not_contains 'build --progress plain --build-arg' "${DOCKER_LOG}"
assert_embedded_velox_restored

# An explicit toolkit version is forwarded only to the ordinary dependency
# build. The selected image remains user-namespaced by the caller.
reset_fake_images
"${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --cuda-version 13.2 \
  --image-name test.example/presto-deps:cuda13.2
assert_contains \
  'build --progress plain --build-arg CUDA_VERSION=13.2 --build-arg ARM_BUILD_TARGET= --file scripts/dockerfiles/centos-dependency.dockerfile --tag test.example/presto-deps:cuda13.2 .' \
  "${DOCKER_LOG}"
assert_not_contains 'compose ' "${DOCKER_LOG}"
assert_not_contains \
  'tag presto/prestissimo-dependency:centos9 test.example/presto-deps:cuda13.2' \
  "${DOCKER_LOG}"
[[ $(<"${CANONICAL_ID_FILE}") == "${CANONICAL_ID}" ]] ||
  fail 'the versioned CUDA build changed the canonical dependency image'
assert_embedded_velox_restored

# Without an explicit output name, a CUDA build derives a versioned per-user
# tag instead of replacing the ordinary dependency image.
reset_fake_images
USER=tester "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --cuda-version 13.2
assert_contains \
  '--tag presto/prestissimo-dependency:centos9-tester-cuda13.2' \
  "${DOCKER_LOG}"
assert_not_contains \
  '--tag presto/prestissimo-dependency:centos9-tester .' \
  "${DOCKER_LOG}"
[[ $(<"${CANONICAL_ID_FILE}") == "${CANONICAL_ID}" ]] ||
  fail 'the default versioned CUDA build changed the canonical dependency image'
assert_embedded_velox_restored

# The direct docker-build path preserves the same explicit ARM portability
# override as the ordinary Compose build.
reset_fake_images
ARM_BUILD_TARGET=common "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --cuda-version 13.2 \
  --image-name test.example/presto-deps:cuda13.2-arm
assert_contains '--build-arg ARM_BUILD_TARGET=common' "${DOCKER_LOG}"
assert_embedded_velox_restored

# CUDA and local UCX selection share the isolated direct docker-build path.
UCX_SOURCE="${TEST_ROOT}/ucx"
mkdir -p "${UCX_SOURCE}"
printf 'ucx-source\n' > "${UCX_SOURCE}/marker"
printf '#!/bin/sh\n' > "${UCX_SOURCE}/autogen.sh"
reset_fake_images
"${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --ucx-source "${UCX_SOURCE}" \
  --cuda-version 13.2 \
  --image-name test.example/presto-deps:cuda13.2-ucx
assert_contains '--build-arg CUDA_VERSION=13.2' "${DOCKER_LOG}"
assert_contains '--build-arg UCX_LOCAL_SOURCE=.local_ucx_source' "${DOCKER_LOG}"
assert_contains '--tag test.example/presto-deps:cuda13.2-ucx' "${DOCKER_LOG}"
[[ ! -e ${PRESTO_NATIVE_DIR}/.local_ucx_source ]] ||
  fail 'the staged local UCX source was not removed'
assert_embedded_velox_restored

reset_fake_images
if FAKE_NVCC_VERSION=12.9 "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --cuda-version 13.2 \
  --image-name test.example/presto-deps:cuda-mismatch; then
  fail 'a dependency image with the wrong nvcc version was accepted'
fi
assert_embedded_velox_restored

if "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --cuda-version latest; then
  fail 'an invalid CUDA toolkit version was accepted'
fi

if "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --cuda-version 13.2 \
  --s3-direct-receive; then
  fail 'direct mode accepted a CUDA version instead of inheriting its base toolkit'
fi
assert_embedded_velox_restored

# The environment and command-line interfaces have the same direct-mode
# contract: CUDA is selected while building the ordinary immutable base.
if PRESTO_DEV_CUDA_VERSION=13.2 "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --s3-direct-receive \
  --base-image "${BASE_IMAGE}" \
  --image-name test.example/presto-deps:cuda13.2-s3-direct; then
  fail 'direct mode accepted PRESTO_DEV_CUDA_VERSION instead of inheriting its base toolkit'
fi

# With no explicit base or output, direct mode extends the ordinary per-user
# image and derives a distinct tag.
reset_fake_images
USER=tester "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --s3-direct-receive
assert_contains "image inspect --format {{.Id}} ${DEFAULT_BASE_IMAGE}" "${DOCKER_LOG}"
assert_contains \
  '--tag presto/prestissimo-dependency:centos9-tester-s3-direct' \
  "${DOCKER_LOG}"
[[ $(<"${CANONICAL_ID_FILE}") == "${CANONICAL_ID}" ]] ||
  fail 'the default direct build changed the canonical dependency image'
[[ $(<"${BASE_ID_FILE}") == "${BASE_ID}" ]] ||
  fail 'the default direct build changed its base image'
assert_embedded_velox_restored

# Direct mode derives a separate tag from the explicit, pre-existing base.
reset_fake_images
"${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --s3-direct-receive \
  --base-image "${BASE_IMAGE}"
DIRECT_IMAGE='registry.example.test:5000/presto/dependency:base-s3-direct'
CONTENT_ALIAS="presto/s3-direct-build-base:sha256-${BASE_ID#sha256:}"
assert_contains "image inspect --format {{.Id}} ${BASE_IMAGE}" "${DOCKER_LOG}"
assert_contains "--build-arg BASE_DEPENDENCY_IMAGE=${BASE_IMAGE}" "${DOCKER_LOG}"
assert_contains "tag ${BASE_ID} ${CONTENT_ALIAS}" "${DOCKER_LOG}"
assert_contains "--build-arg BASE_DEPENDENCY_BUILD_IMAGE=${CONTENT_ALIAS}" "${DOCKER_LOG}"
assert_not_contains "--build-arg BASE_DEPENDENCY_BUILD_IMAGE=${BASE_ID}" "${DOCKER_LOG}"
assert_contains "--build-arg BASE_DEPENDENCY_IMAGE_ID=${BASE_ID}" "${DOCKER_LOG}"
assert_contains "--build-arg EXPECTED_CURL_COMMIT=${CURL_COMMIT}" "${DOCKER_LOG}"
assert_contains "--build-arg EXPECTED_AWS_SDK_COMMIT=${AWS_COMMIT}" "${DOCKER_LOG}"
assert_contains "--tag ${DIRECT_IMAGE}" "${DOCKER_LOG}"
assert_contains 'selected-context=' "${DOCKER_LOG}"
assert_not_contains 'compose ' "${DOCKER_LOG}"
assert_not_contains "tag ${CANONICAL_IMAGE}" "${DOCKER_LOG}"
[[ $(<"${CANONICAL_ID_FILE}") == "${CANONICAL_ID}" ]] ||
  fail 'a successful direct build changed the canonical dependency image'
[[ $(<"${BASE_ID_FILE}") == "${BASE_ID}" ]] ||
  fail 'a successful direct build changed its base image'
[[ $(<"${OUTPUT_ID_FILE}") == 'sha256:direct-result' ]] ||
  fail 'the direct build did not create its separate output image'
[[ $(<"${CONTENT_ALIAS_FILE}") == "${CONTENT_ALIAS}" ]] ||
  fail 'the direct build did not retain its content-addressed base alias'
[[ ! -e ${TEST_ROOT}/host-code-ran ]] ||
  fail 'the selected setup-versions.sh executed under host credentials'
assert_embedded_velox_restored

# A subsequent derivation from the same image ID reuses the immutable alias
# without retagging it, preserving a stable BuildKit FROM identity.
: > "${DOCKER_LOG}"
"${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --s3-direct-receive \
  --base-image "${BASE_IMAGE}" \
  --image-name test.example/presto-deps:alias-reuse
assert_contains "image inspect --format {{.Id}} ${CONTENT_ALIAS}" "${DOCKER_LOG}"
assert_not_contains "tag ${BASE_ID} ${CONTENT_ALIAS}" "${DOCKER_LOG}"
assert_contains "--build-arg BASE_DEPENDENCY_BUILD_IMAGE=${CONTENT_ALIAS}" "${DOCKER_LOG}"
assert_embedded_velox_restored

# The recorded installer hash covers dirty and untracked selected script
# content, rather than only the selected repository commit.
FIRST_INSTALLER_HASH=$(
  sed -n 's/.*--build-arg INSTALLER_SOURCE_SHA256=\([0-9a-f]\{64\}\).*/\1/p' \
    "${DOCKER_LOG}" | head -1
)
[[ -n ${FIRST_INSTALLER_HASH} ]] || fail 'the first installer hash was not recorded'
printf 'local dirty installer content\n' > "${VELOX_SOURCE}/scripts/local-dirty-file"
reset_fake_images
"${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --s3-direct-receive \
  --base-image "${BASE_IMAGE}" \
  --image-name test.example/presto-deps:dirty-source
SECOND_INSTALLER_HASH=$(
  sed -n 's/.*--build-arg INSTALLER_SOURCE_SHA256=\([0-9a-f]\{64\}\).*/\1/p' \
    "${DOCKER_LOG}" | head -1
)
[[ -n ${SECOND_INSTALLER_HASH} ]] || fail 'the second installer hash was not recorded'
[[ ${SECOND_INSTALLER_HASH} != "${FIRST_INSTALLER_HASH}" ]] ||
  fail 'dirty selected installer content did not change its provenance hash'
rm -f "${VELOX_SOURCE}/scripts/local-dirty-file"
[[ $(<"${CANONICAL_ID_FILE}") == "${CANONICAL_ID}" ]] ||
  fail 'the dirty-source direct build changed the canonical dependency image'
[[ $(<"${BASE_ID_FILE}") == "${BASE_ID}" ]] ||
  fail 'the dirty-source direct build changed its base image'
assert_embedded_velox_restored

# Direct mode rejects either ordinary dependency tag as an output, even when
# extending a differently named base image.
for forbidden_image in \
  "${CANONICAL_IMAGE}" \
  "docker.io/${CANONICAL_IMAGE}" \
  "${DEFAULT_BASE_IMAGE}" \
  "index.docker.io/${DEFAULT_BASE_IMAGE}"; do
  reset_fake_images
  if USER=tester "${BUILD_SCRIPT}" \
    --presto-source "${PRESTO_SOURCE}" \
    --velox-source "${VELOX_SOURCE}" \
    --s3-direct-receive \
    --base-image "${BASE_IMAGE}" \
    --image-name "${forbidden_image}"; then
    fail "direct mode accepted ordinary dependency tag ${forbidden_image}"
  fi
  [[ $(<"${CANONICAL_ID_FILE}") == "${CANONICAL_ID}" ]] ||
    fail 'rejected direct output changed the canonical dependency image'
  assert_embedded_velox_restored
done

# Explicit :latest and an omitted tag name the same Docker image and must not
# bypass the base-image protection.
reset_fake_images
if "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --s3-direct-receive \
  --base-image registry.example.test/presto/dependency \
  --image-name registry.example.test/presto/dependency:latest; then
  fail 'direct mode accepted an implicit-latest alias of its base image'
fi
[[ $(<"${CANONICAL_ID_FILE}") == "${CANONICAL_ID}" ]] ||
  fail 'rejected implicit-latest output changed the canonical dependency image'
assert_embedded_velox_restored

# A failed direct build also restores the source tree and leaves both existing
# image tags untouched.
reset_fake_images
printf 'sha256:existing-direct-output\n' > "${OUTPUT_ID_FILE}"
if FAKE_DOCKER_FAIL_BUILD=1 "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --s3-direct-receive \
  --base-image "${BASE_IMAGE}" \
  --image-name test.example/presto-deps:failed; then
  fail 'the simulated direct build failure unexpectedly succeeded'
fi
assert_not_contains 'compose ' "${DOCKER_LOG}"
[[ $(<"${CANONICAL_ID_FILE}") == "${CANONICAL_ID}" ]] ||
  fail 'a failed direct build changed the canonical dependency image'
[[ $(<"${BASE_ID_FILE}") == "${BASE_ID}" ]] ||
  fail 'a failed direct build changed its base image'
[[ $(<"${OUTPUT_ID_FILE}") == 'sha256:existing-direct-output' ]] ||
  fail 'a failed direct build changed the existing output image'
assert_embedded_velox_restored

# Never overwrite or remove an unexpected pre-existing content-addressed
# alias. A mismatch indicates local image-store corruption or interference and
# must stop the build before Docker sees a FROM reference.
reset_fake_images
printf '%s\n' "${CONTENT_ALIAS}" > "${CONTENT_ALIAS_FILE}"
if FAKE_DOCKER_ALIAS_COLLISION=1 "${BUILD_SCRIPT}" \
  --presto-source "${PRESTO_SOURCE}" \
  --velox-source "${VELOX_SOURCE}" \
  --s3-direct-receive \
  --base-image "${BASE_IMAGE}" \
  --image-name test.example/presto-deps:alias-collision; then
  fail 'a mismatched content-addressed base alias was accepted'
fi
[[ $(<"${CONTENT_ALIAS_FILE}") == "${CONTENT_ALIAS}" ]] ||
  fail 'a mismatched pre-existing content-addressed alias was changed'
assert_not_contains "tag ${BASE_ID} ${CONTENT_ALIAS}" "${DOCKER_LOG}"
assert_not_contains '--tag test.example/presto-deps:alias-collision' "${DOCKER_LOG}"
assert_embedded_velox_restored

DOCKERFILE="${SCRIPT_DIR}/../docker/s3_direct_receive_deps.dockerfile"
# Docker expands this build argument.
# shellcheck disable=SC2016
[[ $(grep -Fc 'FROM ${BASE_DEPENDENCY_BUILD_IMAGE}' "${DOCKERFILE}") -eq 2 ]] ||
  fail 'the direct dependency Dockerfile is not an isolated multi-stage build'
assert_contains \
  'COPY --from=s3-direct-builder /opt/presto-s3-direct /opt/presto-s3-direct' \
  "${DOCKERFILE}"
assert_contains 'io.prestodb.s3-direct-receive.base-image-id' "${DOCKERFILE}"
assert_contains 'io.prestodb.s3-direct-receive.installer-source-sha256' "${DOCKERFILE}"
assert_contains "! grep -F 'not found'" "${DOCKERFILE}"
assert_not_contains '/etc/ld.so.conf' "${DOCKERFILE}"
assert_not_contains 'ldconfig' "${DOCKERFILE}"

echo 'build_centos_deps_image_test.sh: PASS'
