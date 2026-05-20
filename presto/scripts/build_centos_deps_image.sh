#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -e

IMAGE_NAME="presto/prestissimo-dependency:centos9-${USER:-latest}"
NO_CACHE_ARG=''
UCX_SOURCE=''
UCX_SOURCE_HASH=''

print_help() {
  cat << EOF

Usage: build_centos_deps_image.sh [OPTIONS]

This script does a local build of a Presto dependencies/run-time container to a Docker image.
It expects sibling Presto and Velox clones, and will override the Presto Velox dependencies
scripts and CMake config to be those of the sibling Velox.

If an image of the given name already exists, it is left in place until the new
build succeeds and is retagged.

OPTIONS:
    -h, --help           Show this help message
    -i, --image-name     Desired Docker Image name (default: presto/prestissimo-dependency:centos9-\${USER:-latest})
    -n, --no-cache       Do not use Docker build cache (default: use cache)
    --ucx-source         Local UCX source tree to build into the dependency image

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

# verify sibling Presto and Velox clones
if [[ ! -d "${REPO_ROOT}/../presto/presto-native-execution" || ! -d "${REPO_ROOT}/../velox" ]]; then
  echo "Error: Sibling Presto and/or Velox clone not found"
  exit 1
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

PRESTO_NATIVE_DIR="${REPO_ROOT}/../presto/presto-native-execution"
LOCAL_UCX_CONTEXT=".local_ucx_source"

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
echo "Overriding Presto Velox build config from sibling Velox clone..."
mv velox velox.bak
mkdir -p velox
cp -r ../../velox/scripts velox
cp -r ../../velox/CMake velox

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
  docker tag ${COMPOSE_IMAGE_NAME} ${IMAGE_NAME}
fi

# done (will cleanup on exit)
echo "Presto dependencies/run-time container image built!"
