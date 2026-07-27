#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -e

IMAGE_NAME="presto/prestissimo-dependency:centos9-${USER:-latest}"
NO_CACHE_ARG=''
UCX_SOURCE=''
UCX_SOURCE_HASH=''
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
    -i, --image-name     Desired Docker Image name (default: presto/prestissimo-dependency:centos9-\${USER:-latest})
    -n, --no-cache       Do not use Docker build cache (default: use cache)
    --presto-source PATH Presto source tree whose native dependency image
                         definition should be built (default: ../presto)
    --velox-source PATH  Velox source tree providing dependency setup scripts
                         and CMake modules (default: ../velox)
    --ucx-source PATH    Local UCX source tree to build into the dependency image

Environment:
    PRESTO_DEV_PRESTO_SOURCE
                         Same as --presto-source.
    PRESTO_DEV_VELOX_SOURCE
                         Same as --velox-source.

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
      *)
        echo "Error: Unknown argument $1"
        print_help
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

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

echo "Using Presto dependency source: ${PRESTO_SOURCE}"
echo "Using Velox dependency source: ${VELOX_SOURCE}"

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
  pushd "${PRESTO_NATIVE_DIR}" > /dev/null || return
  if [[ -d velox.bak ]]; then
    echo "Restoring original Presto Velox..."
    rm -rf velox
    mv velox.bak velox
  fi
  if [[ -n "${UCX_SOURCE}" ]]; then
    rm -rf "${LOCAL_UCX_CONTEXT}"
  fi
  popd > /dev/null || return
}
trap cleanup EXIT

# move to Presto Velox
pushd "${PRESTO_NATIVE_DIR}" > /dev/null

# override Presto Velox build config
echo "Overriding Presto Velox build config from selected Velox source..."
mv velox velox.bak
mkdir -p velox
cp -r "${VELOX_SOURCE}/scripts" velox
cp -r "${VELOX_SOURCE}/CMake" velox

BUILD_ARGS=()
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
docker compose --progress plain build ${NO_CACHE_ARG} "${BUILD_ARGS[@]}" centos-native-dependency

# tag with the user-specific name to avoid conflicts between multiple users on the same host
COMPOSE_IMAGE_NAME='presto/prestissimo-dependency:centos9'
if [[ "${IMAGE_NAME}" != "${COMPOSE_IMAGE_NAME}" ]]; then
  echo "Tagging image as ${IMAGE_NAME}..."
  docker tag "${COMPOSE_IMAGE_NAME}" "${IMAGE_NAME}"
fi

# done (will cleanup on exit)
echo "Presto dependencies/run-time container image built!"
