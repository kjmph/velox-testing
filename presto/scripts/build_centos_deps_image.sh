#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -e

DEFAULT_IMAGE_NAME="presto/prestissimo-dependency:centos9-${USER:-latest}"
COMPOSE_IMAGE_NAME='presto/prestissimo-dependency:centos9'
IMAGE_NAME="${DEFAULT_IMAGE_NAME}"
IMAGE_NAME_SET=false
BASE_IMAGE=''
BASE_IMAGE_ID=''
BASE_DEPENDENCY_BUILD_IMAGE=''
NO_CACHE_ARG=''
S3_DIRECT_RECEIVE=false
UCX_SOURCE=''
UCX_SOURCE_HASH=''
REQUESTED_CUDA_VERSION="${PRESTO_DEV_CUDA_VERSION:-}"
PRESTO_SOURCE="${PRESTO_DEV_PRESTO_SOURCE:-}"
VELOX_SOURCE="${PRESTO_DEV_VELOX_SOURCE:-}"

print_help() {
  cat << EOF

Usage: build_centos_deps_image.sh [OPTIONS]

This script does a local build of a Presto dependencies/run-time container to a Docker image.
It uses selected Presto and Velox source trees and temporarily overrides the
Presto native module's Velox dependency scripts and CMake configuration.

If an image of the given name already exists, it is left in place until the new
build succeeds and is retagged.

OPTIONS:
    -h, --help           Show this help message
    -i, --image-name     Desired Docker image name. The normal default is
                         presto/prestissimo-dependency:centos9-\${USER:-latest}.
                         Direct-receive mode derives a separate -s3-direct tag
                         from its base image unless this option is specified.
    -n, --no-cache       Do not use Docker build cache (default: use cache)
    --presto-source PATH Presto source tree whose native dependency image
                         definition should be built (default: ../presto)
    --velox-source PATH  Velox source tree providing dependency setup scripts
                         and CMake modules (default: ../velox)
    --ucx-source PATH    Local UCX source tree to build into the dependency image
    --cuda-version X.Y   CUDA toolkit major.minor version to install in an
                         ordinary dependency image (for example, 13.2). Direct
                         mode inherits CUDA from --base-image instead.
    --s3-direct-receive  Derive an isolated S3 direct-receive dependency image
                         from an existing CentOS dependency image. This does
                         not rebuild or retag the base image.
    --base-image IMAGE   Existing dependency image to extend in direct-receive
                         mode (default: presto/prestissimo-dependency:centos9-\${USER:-latest})

Environment:
    PRESTO_DEV_PRESTO_SOURCE
                         Same as --presto-source.
    PRESTO_DEV_VELOX_SOURCE
                         Same as --velox-source.
    PRESTO_DEV_CUDA_VERSION
                         Same as --cuda-version.

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        print_help
        exit 0
        ;;
      -i|--image-name)
        if [[ -n $2 ]]; then
          IMAGE_NAME=$2
          IMAGE_NAME_SET=true
          shift 2
        else
          echo "Error: --image-name requires a value"
          exit 1
        fi
        ;;
      -n|--no-cache)
        NO_CACHE_ARG="--no-cache"
        shift
        ;;
      --presto-source)
        if [[ -n $2 ]]; then
          PRESTO_SOURCE=$2
          shift 2
        else
          echo "Error: --presto-source requires a value"
          exit 1
        fi
        ;;
      --velox-source)
        if [[ -n $2 ]]; then
          VELOX_SOURCE=$2
          shift 2
        else
          echo "Error: --velox-source requires a value"
          exit 1
        fi
        ;;
      --ucx-source)
        if [[ -n $2 ]]; then
          UCX_SOURCE=$2
          shift 2
        else
          echo "Error: --ucx-source requires a value"
          exit 1
        fi
        ;;
      --cuda-version)
        if [[ -n $2 ]]; then
          REQUESTED_CUDA_VERSION=$2
          shift 2
        else
          echo "Error: --cuda-version requires a value"
          exit 1
        fi
        ;;
      --s3-direct-receive)
        S3_DIRECT_RECEIVE=true
        shift
        ;;
      --base-image)
        if [[ -n $2 ]]; then
          BASE_IMAGE=$2
          shift 2
        else
          echo "Error: --base-image requires a value"
          exit 1
        fi
        ;;
      *)
        echo "Error: Unknown argument $1"
        print_help
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

if [[ -n ${REQUESTED_CUDA_VERSION} && ! ${REQUESTED_CUDA_VERSION} =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "Error: --cuda-version must be a major.minor version such as 13.2" >&2
  exit 1
fi

function derive_s3_direct_image_name {
  local base_image=$1
  local final_component=${base_image##*/}

  if [[ ${base_image} == *@* ]]; then
    echo "Error: --image-name is required when --base-image uses a digest" >&2
    return 1
  fi
  if [[ ${final_component} == *:* ]]; then
    printf '%s:%s-s3-direct\n' "${base_image%:*}" "${base_image##*:}"
  else
    printf '%s:s3-direct\n' "${base_image}"
  fi
}

function normalize_image_reference_for_compare {
  local image_reference=$1
  local first_component=${image_reference%%/*}
  local final_component

  if [[ ${image_reference} == index.docker.io/* ]]; then
    image_reference="docker.io/${image_reference#index.docker.io/}"
  elif [[ ${image_reference} != */* ]]; then
    image_reference="docker.io/library/${image_reference}"
  elif [[ ${first_component} != *.* &&
          ${first_component} != *:* &&
          ${first_component} != localhost ]]; then
    image_reference="docker.io/${image_reference}"
  fi
  final_component=${image_reference##*/}
  if [[ ${image_reference} != *@* && ${final_component} != *:* ]]; then
    image_reference="${image_reference}:latest"
  fi
  printf '%s\n' "${image_reference}"
}

function verify_cuda_toolkit_image {
  local image=$1
  local requested_version=$2
  local image_info
  local image_cuda_version
  local nvcc_cuda_version

  if ! image_info=$(docker run --rm --entrypoint /bin/bash "${image}" -c '
    set -euo pipefail
    nvcc_release=$(nvcc --version |
      sed -n "s/.*release \([0-9][0-9.]*\),.*/\1/p")
    test -n "${nvcc_release}"
    nvcc --list-gpu-arch >/dev/null
    printf "%s\n%s\n" "${CUDA_VERSION:-}" "${nvcc_release}"
  '); then
    echo "Error: unable to validate CUDA toolkit ${requested_version} in ${image}" >&2
    return 1
  fi

  image_cuda_version=$(sed -n '1p' <<< "${image_info}")
  nvcc_cuda_version=$(sed -n '2p' <<< "${image_info}")
  if [[ ${image_cuda_version} != "${requested_version}" ||
        ${nvcc_cuda_version} != "${requested_version}" ]]; then
    echo "Error: CUDA toolkit validation failed for ${image}" >&2
    echo "Expected ${requested_version}; image reports CUDA_VERSION=${image_cuda_version:-<unset>}, nvcc=${nvcc_cuda_version:-<unknown>}." >&2
    return 1
  fi
  echo "Validated CUDA toolkit ${requested_version} in ${image}"
}

if ${S3_DIRECT_RECEIVE}; then
  if [[ -n ${REQUESTED_CUDA_VERSION} ]]; then
    echo "Error: --cuda-version cannot be combined with --s3-direct-receive" >&2
    echo "Build the ordinary base with --cuda-version first, then extend it with --base-image." >&2
    exit 1
  fi
  BASE_IMAGE=${BASE_IMAGE:-${DEFAULT_IMAGE_NAME}}
  if ! ${IMAGE_NAME_SET}; then
    IMAGE_NAME=$(derive_s3_direct_image_name "${BASE_IMAGE}")
  fi
  NORMALIZED_IMAGE_NAME=$(normalize_image_reference_for_compare "${IMAGE_NAME}")
  NORMALIZED_BASE_IMAGE=$(normalize_image_reference_for_compare "${BASE_IMAGE}")
  NORMALIZED_COMPOSE_IMAGE_NAME=$(normalize_image_reference_for_compare "${COMPOSE_IMAGE_NAME}")
  NORMALIZED_DEFAULT_IMAGE_NAME=$(normalize_image_reference_for_compare "${DEFAULT_IMAGE_NAME}")
  if [[ ${NORMALIZED_IMAGE_NAME} == "${NORMALIZED_BASE_IMAGE}" ||
        ${NORMALIZED_IMAGE_NAME} == "${NORMALIZED_COMPOSE_IMAGE_NAME}" ||
        ${NORMALIZED_IMAGE_NAME} == "${NORMALIZED_DEFAULT_IMAGE_NAME}" ]]; then
    echo "Error: the direct-receive image must not replace its base or an ordinary dependency image"
    exit 1
  fi
  if [[ -n ${UCX_SOURCE} ]]; then
    echo "Error: --ucx-source cannot be combined with --s3-direct-receive"
    echo "Build the base dependency image with --ucx-source first, then extend that image."
    exit 1
  fi
elif [[ -n ${BASE_IMAGE} ]]; then
  echo "Error: --base-image requires --s3-direct-receive"
  exit 1
elif [[ -n ${REQUESTED_CUDA_VERSION} ]] && ! ${IMAGE_NAME_SET}; then
  IMAGE_NAME="${DEFAULT_IMAGE_NAME}-cuda${REQUESTED_CUDA_VERSION}"
fi

# Compute the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the root of the git repository
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"

# Resolve and verify the selected Presto and Velox clones.
PRESTO_SOURCE="${PRESTO_SOURCE:-${REPO_ROOT}/../presto}"
VELOX_SOURCE="${VELOX_SOURCE:-${REPO_ROOT}/../velox}"
if [[ ! -d "$PRESTO_SOURCE" ]]; then
  echo "Error: Presto source tree not found: ${PRESTO_SOURCE}"
  exit 1
fi
if [[ ! -d "$VELOX_SOURCE" ]]; then
  echo "Error: Velox source tree not found: ${VELOX_SOURCE}"
  exit 1
fi
PRESTO_SOURCE="$(cd "$PRESTO_SOURCE" && pwd)"
VELOX_SOURCE="$(cd "$VELOX_SOURCE" && pwd)"
if [[ ! -f "${PRESTO_SOURCE}/pom.xml" ||
      ! -f "${PRESTO_SOURCE}/presto-native-execution/docker-compose.yml" ]]; then
  echo "Error: --presto-source must point to a Presto source tree: ${PRESTO_SOURCE}"
  exit 1
fi
if [[ ! -f "${VELOX_SOURCE}/CMakeLists.txt" ||
      ! -f "${VELOX_SOURCE}/scripts/setup-centos9.sh" ||
      ! -d "${VELOX_SOURCE}/CMake" ]]; then
  echo "Error: --velox-source must point to a Velox source tree: ${VELOX_SOURCE}"
  exit 1
fi
if ${S3_DIRECT_RECEIVE} &&
  [[ ! -f "${VELOX_SOURCE}/scripts/setup-common.sh" ||
    ! -f "${VELOX_SOURCE}/scripts/setup-versions.sh" ]]; then
  echo "Error: selected Velox source does not provide the S3 direct-receive installer"
  exit 1
fi

echo "Using Presto dependency source: ${PRESTO_SOURCE}"
echo "Using Velox dependency source: ${VELOX_SOURCE}"

function read_literal_commit_assignment {
  local assignment_name=$1
  local versions_file=$2

  awk -v assignment_name="${assignment_name}" '
    index($0, assignment_name "=\"") == 1 && substr($0, length($0), 1) == "\"" {
      value = substr($0, length(assignment_name) + 3)
      value = substr(value, 1, length(value) - 1)
      if (value !~ /^[0-9a-f]+$/ || length(value) != 40) {
        exit 1
      }
      print value
      ++matches
      next
    }
    $0 ~ ("^" assignment_name "=") {
      exit 1
    }
    END {
      if (matches != 1) {
        exit 1
      }
    }
  ' "${versions_file}"
}

function compute_installer_source_hash {
  (
    cd "${VELOX_SOURCE}"
    find scripts \( -type f -o -type l \) -print0 |
      LC_ALL=C sort -z |
      xargs -0 sha256sum |
      sha256sum |
      awk '{print $1}'
  )
}

S3_DIRECT_RECEIVE_CURL_COMMIT=''
S3_DIRECT_RECEIVE_AWS_SDK_COMMIT=''
S3_DIRECT_RECEIVE_INSTALLER_SOURCE_SHA256=''
if ${S3_DIRECT_RECEIVE}; then
  if ! S3_DIRECT_RECEIVE_CURL_COMMIT=$(read_literal_commit_assignment \
    S3_DIRECT_RECEIVE_CURL_COMMIT \
    "${VELOX_SOURCE}/scripts/setup-versions.sh") ||
    ! S3_DIRECT_RECEIVE_AWS_SDK_COMMIT=$(read_literal_commit_assignment \
      S3_DIRECT_RECEIVE_AWS_SDK_COMMIT \
      "${VELOX_SOURCE}/scripts/setup-versions.sh"); then
    echo "Error: selected Velox source must pin exact 40-character curl and AWS SDK commits"
    exit 1
  fi
  S3_DIRECT_RECEIVE_INSTALLER_SOURCE_SHA256=$(compute_installer_source_hash)
  if ! BASE_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "${BASE_IMAGE}" 2>/dev/null); then
    echo "Error: S3 direct-receive base image does not exist locally: ${BASE_IMAGE}"
    echo "Build or fetch that dependency image before deriving the direct-receive image."
    exit 1
  fi
  if [[ ! ${BASE_IMAGE_ID} =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Error: unable to determine an immutable image ID for ${BASE_IMAGE}"
    exit 1
  fi
  echo "Using S3 direct-receive base image: ${BASE_IMAGE}"
  echo "Using S3 direct-receive base image ID: ${BASE_IMAGE_ID}"
  echo "Writing S3 direct-receive image: ${IMAGE_NAME}"
  echo "Pinned direct-receive curl: ${S3_DIRECT_RECEIVE_CURL_COMMIT}"
  echo "Pinned direct-receive AWS SDK: ${S3_DIRECT_RECEIVE_AWS_SDK_COMMIT}"
  echo "Selected Velox installer source SHA256: ${S3_DIRECT_RECEIVE_INSTALLER_SOURCE_SHA256}"
fi

if [[ -n "${UCX_SOURCE}" ]]; then
  UCX_SOURCE="$(cd "${UCX_SOURCE}" && pwd)"
  if [[ ! -f "${UCX_SOURCE}/autogen.sh" ]]; then
    echo "Error: --ucx-source must point to a UCX source tree with autogen.sh"
    exit 1
  fi
fi

function compute_ucx_source_hash {
  if git -C "${UCX_SOURCE}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      git -C "${UCX_SOURCE}" rev-parse HEAD || true
      git -C "${UCX_SOURCE}" status --short --untracked-files=all || true
      git -C "${UCX_SOURCE}" diff --binary HEAD -- || true

      local file
      while IFS= read -r -d '' file; do
        [[ -f "${UCX_SOURCE}/${file}" ]] || continue
        printf 'untracked:%s:' "$file"
        sha256sum "${UCX_SOURCE}/${file}" | awk '{print $1}'
      done < <(git -C "${UCX_SOURCE}" ls-files --others --exclude-standard -z | sort -z)
    } | sha256sum | awk '{print $1}'
  else
    find "${UCX_SOURCE}" -path "${UCX_SOURCE}/.git" -prune -o -type f -print0 |
      sort -z |
      xargs -0 sha256sum |
      sha256sum |
      awk '{print $1}'
  fi
}

PRESTO_NATIVE_DIR="${PRESTO_SOURCE}/presto-native-execution"
LOCAL_UCX_CONTEXT=".local_ucx_source"
if [[ -e "${PRESTO_NATIVE_DIR}/velox.bak" ]]; then
  echo "Error: stale dependency-build backup already exists: ${PRESTO_NATIVE_DIR}/velox.bak"
  echo "Inspect and restore or remove it before rebuilding dependencies."
  exit 1
fi

# restore original Presto Velox on exit
function cleanup {
  local exit_status=$?
  local cleanup_status=0
  trap - EXIT
  set +e
  if pushd "${PRESTO_NATIVE_DIR}" > /dev/null; then
    if [[ -d velox.bak ]]; then
      echo "Restoring original Presto Velox..."
      rm -rf velox && mv velox.bak velox || cleanup_status=1
    fi
    if [[ -n "${UCX_SOURCE}" ]]; then
      rm -rf "${LOCAL_UCX_CONTEXT}" || cleanup_status=1
    fi
    popd > /dev/null || cleanup_status=1
  else
    cleanup_status=1
  fi
  if [[ ${exit_status} -ne 0 ]]; then
    exit "${exit_status}"
  fi
  exit "${cleanup_status}"
}
trap cleanup EXIT

if ${S3_DIRECT_RECEIVE}; then
  # BuildKit does not reliably accept a bare local sha256 image ID in FROM.
  # Give the inspected ID a stable content-addressed local alias. This pins
  # both stages if the caller's mutable base tag changes during the build and
  # preserves the FROM identity across launches so BuildKit can reuse layers.
  BASE_DEPENDENCY_BUILD_IMAGE="presto/s3-direct-build-base:sha256-${BASE_IMAGE_ID#sha256:}"
  CONTENT_ADDRESSED_BASE_ID=''
  if CONTENT_ADDRESSED_BASE_ID=$(docker image inspect \
    --format '{{.Id}}' "${BASE_DEPENDENCY_BUILD_IMAGE}" 2>/dev/null); then
    if [[ ${CONTENT_ADDRESSED_BASE_ID} != "${BASE_IMAGE_ID}" ]]; then
      echo "Error: content-addressed base alias resolves to an unexpected image: ${BASE_DEPENDENCY_BUILD_IMAGE}"
      echo "Expected ${BASE_IMAGE_ID}, found ${CONTENT_ADDRESSED_BASE_ID}; refusing to overwrite it."
      exit 1
    fi
  else
    docker tag "${BASE_IMAGE_ID}" "${BASE_DEPENDENCY_BUILD_IMAGE}"
    CONTENT_ADDRESSED_BASE_ID=$(docker image inspect \
      --format '{{.Id}}' "${BASE_DEPENDENCY_BUILD_IMAGE}" 2>/dev/null || true)
    if [[ ${CONTENT_ADDRESSED_BASE_ID} != "${BASE_IMAGE_ID}" ]]; then
      echo "Error: failed to create the content-addressed base alias: ${BASE_DEPENDENCY_BUILD_IMAGE}"
      exit 1
    fi
  fi
fi

# move to Presto Velox
pushd "${PRESTO_NATIVE_DIR}" > /dev/null

# override Presto Velox build config
echo "Overriding Presto Velox build config from selected Velox source..."
mv velox velox.bak
mkdir -p velox
cp -r "${VELOX_SOURCE}/scripts" velox
cp -r "${VELOX_SOURCE}/CMake" velox

BUILD_ARGS=()
if [[ -n ${REQUESTED_CUDA_VERSION} ]]; then
  echo "Installing CUDA toolkit ${REQUESTED_CUDA_VERSION} in the ordinary dependency image"
  BUILD_ARGS+=(--build-arg "CUDA_VERSION=${REQUESTED_CUDA_VERSION}")
  # The Compose path forwards this explicitly. Preserve the same portable ARM
  # policy when the versioned CUDA path invokes docker build directly.
  BUILD_ARGS+=(--build-arg "ARM_BUILD_TARGET=${ARM_BUILD_TARGET:-}")
fi
if [[ -n "${UCX_SOURCE}" ]]; then
  UCX_SOURCE_HASH="$(compute_ucx_source_hash)"
  echo "Using UCX_LOCAL_SOURCE_HASH=${UCX_SOURCE_HASH}"
  echo "Staging local UCX source from ${UCX_SOURCE}..."
  rm -rf "${LOCAL_UCX_CONTEXT}"
  mkdir -p "${LOCAL_UCX_CONTEXT}"
  if command -v rsync > /dev/null 2>&1; then
    rsync -a --delete --exclude .git "${UCX_SOURCE}/" "${LOCAL_UCX_CONTEXT}/"
  else
    tar -C "${UCX_SOURCE}" --exclude ./.git --exclude .git -cf - . | tar -C "${LOCAL_UCX_CONTEXT}" -xf -
  fi
  BUILD_ARGS+=(--build-arg "UCX_LOCAL_SOURCE=${LOCAL_UCX_CONTEXT}")
  BUILD_ARGS+=(--build-arg "UCX_LOCAL_SOURCE_HASH=${UCX_SOURCE_HASH}")
fi

# now build
echo "Building..."
if ${S3_DIRECT_RECEIVE}; then
  S3_DIRECT_DOCKERFILE="${REPO_ROOT}/presto/docker/s3_direct_receive_deps.dockerfile"
  if [[ ! -f ${S3_DIRECT_DOCKERFILE} ]]; then
    echo "Error: S3 direct-receive Dockerfile not found: ${S3_DIRECT_DOCKERFILE}"
    exit 1
  fi
  DIRECT_BUILD_ARGS=(
    --build-arg "BASE_DEPENDENCY_BUILD_IMAGE=${BASE_DEPENDENCY_BUILD_IMAGE}"
    --build-arg "BASE_DEPENDENCY_IMAGE=${BASE_IMAGE}"
    --build-arg "BASE_DEPENDENCY_IMAGE_ID=${BASE_IMAGE_ID}"
    --build-arg "EXPECTED_CURL_COMMIT=${S3_DIRECT_RECEIVE_CURL_COMMIT}"
    --build-arg "EXPECTED_AWS_SDK_COMMIT=${S3_DIRECT_RECEIVE_AWS_SDK_COMMIT}"
    --build-arg "INSTALLER_SOURCE_SHA256=${S3_DIRECT_RECEIVE_INSTALLER_SOURCE_SHA256}"
  )
  if [[ -n ${NO_CACHE_ARG} ]]; then
    DIRECT_BUILD_ARGS+=("${NO_CACHE_ARG}")
  fi
  docker build --progress plain \
    "${DIRECT_BUILD_ARGS[@]}" \
    --file "${S3_DIRECT_DOCKERFILE}" \
    --tag "${IMAGE_NAME}" \
    "${PRESTO_NATIVE_DIR}"
else
  if [[ -n ${REQUESTED_CUDA_VERSION} ]]; then
    # Build an opt-in toolkit directly to its requested tag. The Compose
    # service names the shared canonical image, so using it here would silently
    # replace the ordinary toolkit image even when IMAGE_NAME is versioned.
    ORDINARY_BUILD_ARGS=(--progress plain)
    [[ -n ${NO_CACHE_ARG} ]] && ORDINARY_BUILD_ARGS+=("${NO_CACHE_ARG}")
    ORDINARY_BUILD_ARGS+=(
      "${BUILD_ARGS[@]}"
      --file scripts/dockerfiles/centos-dependency.dockerfile
      --tag "${IMAGE_NAME}"
    )
    docker build "${ORDINARY_BUILD_ARGS[@]}" .
    verify_cuda_toolkit_image "${IMAGE_NAME}" "${REQUESTED_CUDA_VERSION}"
  else
    docker compose --progress plain build ${NO_CACHE_ARG} "${BUILD_ARGS[@]}" centos-native-dependency

    # tag with the user-specific name to avoid conflicts between multiple users on the host
    if [[ "${IMAGE_NAME}" != "${COMPOSE_IMAGE_NAME}" ]]; then
      echo "Tagging image as ${IMAGE_NAME}..."
      docker tag "${COMPOSE_IMAGE_NAME}" "${IMAGE_NAME}"
    fi
  fi
fi

# done (will cleanup on exit)
echo "Presto dependencies/run-time container image built!"
