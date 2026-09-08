#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Produce a deterministic identity for the exact source payload copied into the
# dependency build context. Include ignored/generated files, symlink targets,
# and executable modes; exclude only Git administration, exactly like staging.
compute_ucx_source_hash() {
  local source=$1
  local absolute_source
  absolute_source=$(cd "$source" && pwd)

  (
    cd "$absolute_source" || exit
    while IFS= read -r -d '' path; do
      local relative=${path#./}
      local mode
      mode=$(stat -c '%a' -- "$path")
      if [[ -L "$path" ]]; then
        printf 'symlink\0%s\0%s\0' "$relative" "$mode"
        readlink -z -- "$path"
        printf '\0'
      elif [[ -d "$path" ]]; then
        printf 'directory\0%s\0%s\0' "$relative" "$mode"
      elif [[ -f "$path" ]]; then
        local digest
        digest=$(sha256sum -- "$path" | awk '{print $1}')
        printf 'file\0%s\0%s\0%s\0' "$relative" "$mode" "$digest"
      else
        echo "Error: unsupported special file in UCX source payload: ${relative}" >&2
        exit 1
      fi
    done < <(
      find . -name .git -prune -o ! -path . -print0 |
        LC_ALL=C sort -z
    )
  ) | sha256sum | awk '{print $1}'
}

# The dependency Dockerfile and selected Velox installer form a cross-repo
# contract. Validate it before a multi-minute build instead of accepting a
# build that downloaded stock UCX after the caller supplied an exact tree.
validate_local_ucx_build_contract() {
  local presto_source=$1
  local velox_source=$2
  local dependency_dockerfile="${presto_source}/presto-native-execution/scripts/dockerfiles/centos-dependency.dockerfile"

  if ! grep -Eq '^ARG UCX_LOCAL_SOURCE([=[:space:]]|$)' "$dependency_dockerfile" ||
    ! grep -Fq 'source=${UCX_LOCAL_SOURCE}' "$dependency_dockerfile" ||
    ! grep -Fq 'UCX_LOCAL_SOURCE_HASH' "$dependency_dockerfile" ||
    ! grep -Fq 'installed_artifacts.sha256' "$dependency_dockerfile"; then
    echo "Error: selected Presto dependency Dockerfile does not mount and attest UCX_LOCAL_SOURCE" >&2
    echo "Expected contract in: ${dependency_dockerfile}" >&2
    return 1
  fi

  if ! grep -R -Fq 'UCX_LOCAL_SOURCE' "${velox_source}/scripts" ||
    ! grep -R -Fq -- '--with-efa' "${velox_source}/scripts"; then
    echo "Error: selected Velox installer does not consume UCX_LOCAL_SOURCE with EFA enabled" >&2
    echo "Expected contract under: ${velox_source}/scripts" >&2
    return 1
  fi
}
