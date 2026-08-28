#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ -z "${PRESTO_VERSION:-}" ]]; then
  echo "Internal error: PRESTO_VERSION must be set" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"

DEV_SKIP_UI="${PRESTO_DEV_SKIP_UI:-false}"
DEV_CLEAN="${PRESTO_DEV_JAVA_CLEAN:-false}"
DEV_REBUILD_BUILDER="${PRESTO_DEV_REBUILD_JAVA_BUILDER:-false}"
DEV_PRESTO_DEPENDENCIES="${PRESTO_DEV_PRESTO_DEPENDENCIES:-false}"
DEV_MAVEN_PROJECTS="${PRESTO_DEV_MAVEN_PROJECTS:-}"
DEV_PRESTO_DEPENDENCIES_PROJECTS="${PRESTO_DEV_PRESTO_DEPENDENCIES_PROJECTS:-}"
DEV_PRESTO_DEPENDENCIES_BOOTSTRAP_PROJECTS=""
DEV_BUILDER_IMAGE="${PRESTO_DEV_JAVA_BUILDER_IMAGE:-presto-java-builder-dev:${USER:-latest}-jdk17-git-v1}"
DEV_PRESTO_SOURCE="${PRESTO_DEV_PRESTO_SOURCE:-${REPO_ROOT}/../presto}"

print_help() {
  cat << EOF

Usage: PRESTO_VERSION=testing $0 [OPTIONS]

Dev-only Presto Java package builder. It keeps Maven artifacts and module
targets warm, builds the UI by default, and only skips UI when requested.

OPTIONS:
    --skip-ui
        Pass -DskipUI to Maven. Use this for tight coordinator-only loops where
        the Presto web UI is not part of the change.
    --with-ui
        Build the UI even if PRESTO_DEV_SKIP_UI=true is set.
    --clean
        Run "mvn clean install" instead of incremental "mvn install".
    --rebuild-builder
        Rebuild the cached dev Java builder image before running Maven.
    --dev-presto-dependencies
        Limit the Maven reactor to the Java artifacts copied into the dev
        coordinator image and their Maven dependencies. This is the fast path
        for coordinator iteration and avoids unrelated tools like
        presto-verifier.

Environment:
    PRESTO_DEV_SKIP_UI=true      Same as --skip-ui.
    PRESTO_DEV_JAVA_CLEAN=true   Same as --clean.
    PRESTO_DEV_REBUILD_JAVA_BUILDER=true
                                  Same as --rebuild-builder.
    PRESTO_DEV_PRESTO_DEPENDENCIES=true
                                  Same as --dev-presto-dependencies.
    PRESTO_DEV_MAVEN_CACHE_DIR   Override the Maven cache mount.
    PRESTO_DEV_JAVA_BUILDER_IMAGE
                                  Override the cached builder image tag.
    PRESTO_DEV_MAVEN_PROJECTS    Optional Maven -pl project list. Example:
                                  ":presto-server,:presto-cli,:presto-function-server"
    PRESTO_DEV_PRESTO_DEPENDENCIES_PROJECTS
                                  Override the project list used by
                                  --dev-presto-dependencies. By default this
                                  is derived from presto-server's Provisio
                                  runtime descriptor so cold Maven caches build
                                  the plugin ZIPs the server package resolves.
    PRESTO_DEV_PRESTO_SOURCE      Build from this Presto source tree instead
                                  of the default ../presto sibling.

EOF
}

normalize_bool() {
  local value="${1,,}"
  local name=$2

  case "$value" in
    true|1|yes|y|on)
      echo true
      ;;
    false|0|no|n|off|"")
      echo false
      ;;
    *)
      echo "ERROR: ${name} must be true or false." >&2
      return 1
      ;;
  esac
}

compute_presto_dependencies_projects() {
  local presto_root="$DEV_PRESTO_SOURCE"
  local provisio_file="${presto_root}/presto-server/src/main/provisio/presto.xml"
  local -a projects=(
    "presto-server"
    "presto-cli"
    "presto-function-server"
  )
  local artifact
  local seen
  declare -A seen=()

  if [[ ! -f "$provisio_file" ]]; then
    echo "ERROR: expected Presto server runtime descriptor is missing: ${provisio_file}" >&2
    return 1
  fi

  while IFS= read -r artifact; do
    projects+=("$artifact")
  done < <(
    sed -n 's/.*artifact id="${project\.groupId}:\([^:"]*\):.*${project\.version}".*/\1/p' "$provisio_file"
  )

  local -a project_refs=()
  for artifact in "${projects[@]}"; do
    if [[ -n "${seen[$artifact]:-}" ]]; then
      continue
    fi
    seen[$artifact]=1
    if [[ ! -d "${presto_root}/${artifact}" ]]; then
      echo "ERROR: ${provisio_file} references ${artifact}, but ${presto_root}/${artifact} does not exist." >&2
      return 1
    fi
    project_refs+=(":${artifact}")
  done

  local IFS=,
  echo "${project_refs[*]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --skip-ui)
      DEV_SKIP_UI=true
      shift
      ;;
    --with-ui)
      DEV_SKIP_UI=false
      shift
      ;;
    --clean)
      DEV_CLEAN=true
      shift
      ;;
    --rebuild-builder)
      DEV_REBUILD_BUILDER=true
      shift
      ;;
    --dev-presto-dependencies)
      DEV_PRESTO_DEPENDENCIES=true
      shift
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      print_help >&2
      exit 1
      ;;
  esac
done

if ! DEV_SKIP_UI="$(normalize_bool "$DEV_SKIP_UI" "PRESTO_DEV_SKIP_UI")"; then
  exit 1
fi
if ! DEV_CLEAN="$(normalize_bool "$DEV_CLEAN" "PRESTO_DEV_JAVA_CLEAN")"; then
  exit 1
fi
if ! DEV_REBUILD_BUILDER="$(normalize_bool "$DEV_REBUILD_BUILDER" "PRESTO_DEV_REBUILD_JAVA_BUILDER")"; then
  exit 1
fi
if ! DEV_PRESTO_DEPENDENCIES="$(normalize_bool "$DEV_PRESTO_DEPENDENCIES" "PRESTO_DEV_PRESTO_DEPENDENCIES")"; then
  exit 1
fi
if [[ ! -d "$DEV_PRESTO_SOURCE" ]]; then
  echo "ERROR: PRESTO_DEV_PRESTO_SOURCE does not exist: ${DEV_PRESTO_SOURCE}" >&2
  exit 1
fi
DEV_PRESTO_SOURCE="$(cd "$DEV_PRESTO_SOURCE" && pwd)"
if [[ ! -f "${DEV_PRESTO_SOURCE}/pom.xml" ||
      ! -d "${DEV_PRESTO_SOURCE}/presto-server" ||
      ! -d "${DEV_PRESTO_SOURCE}/presto-native-execution" ||
      ! -d "${DEV_PRESTO_SOURCE}/docker" ]]; then
  echo "ERROR: PRESTO_DEV_PRESTO_SOURCE must point to a Presto source tree: ${DEV_PRESTO_SOURCE}" >&2
  exit 1
fi

PRESTO_CONTAINER_SOURCE="$DEV_PRESTO_SOURCE"
PRESTO_GIT_MOUNT_ARGS=()
if [[ -f "${DEV_PRESTO_SOURCE}/.git" ]]; then
  IFS= read -r presto_gitdir_line < "${DEV_PRESTO_SOURCE}/.git"
  if [[ "$presto_gitdir_line" != "gitdir: "* ]]; then
    echo "ERROR: unsupported linked-worktree .git file: ${DEV_PRESTO_SOURCE}/.git" >&2
    exit 1
  fi

  PRESTO_RECORDED_GIT_DIR="${presto_gitdir_line#gitdir: }"
  if [[ "$PRESTO_RECORDED_GIT_DIR" != /* ]]; then
    PRESTO_RECORDED_GIT_DIR="$(realpath -m "${DEV_PRESTO_SOURCE}/${PRESTO_RECORDED_GIT_DIR}")"
  fi

  PRESTO_HOST_GIT_DIR="$PRESTO_RECORDED_GIT_DIR"
  if [[ ! -d "$PRESTO_HOST_GIT_DIR" ]]; then
    # The worktree may have been created in a different mount namespace. For
    # example, the gitfile can record /home/user/... while the host-side
    # launcher sees the same workspace under /raid/user/home/....
    presto_recorded_common_guess="$(dirname "$(dirname "$PRESTO_RECORDED_GIT_DIR")")"
    presto_main_worktree_name="$(basename "$(dirname "$presto_recorded_common_guess")")"
    presto_worktree_name="$(basename "$PRESTO_RECORDED_GIT_DIR")"
    presto_host_git_dir_candidate="$(dirname "$DEV_PRESTO_SOURCE")/${presto_main_worktree_name}/.git/worktrees/${presto_worktree_name}"
    if [[ ! -d "$presto_host_git_dir_candidate" ]]; then
      echo "ERROR: unable to resolve linked-worktree Git metadata recorded as ${PRESTO_RECORDED_GIT_DIR}." >&2
      echo "Checked host-side candidate: ${presto_host_git_dir_candidate}" >&2
      exit 1
    fi
    PRESTO_HOST_GIT_DIR="$(cd "$presto_host_git_dir_candidate" && pwd)"
  fi

  if [[ ! -f "${PRESTO_HOST_GIT_DIR}/commondir" || ! -f "${PRESTO_HOST_GIT_DIR}/gitdir" ]]; then
    echo "ERROR: incomplete linked-worktree Git metadata: ${PRESTO_HOST_GIT_DIR}" >&2
    exit 1
  fi

  IFS= read -r presto_commondir < "${PRESTO_HOST_GIT_DIR}/commondir"
  PRESTO_HOST_GIT_COMMON_DIR="$(cd "${PRESTO_HOST_GIT_DIR}/${presto_commondir}" && pwd)"
  PRESTO_CONTAINER_GIT_COMMON_DIR="$(realpath -m "${PRESTO_RECORDED_GIT_DIR}/${presto_commondir}")"

  IFS= read -r presto_recorded_gitfile < "${PRESTO_HOST_GIT_DIR}/gitdir"
  if [[ "$presto_recorded_gitfile" != /*/.git ]]; then
    echo "ERROR: unsupported linked-worktree gitfile backlink: ${presto_recorded_gitfile}" >&2
    exit 1
  fi
  PRESTO_CONTAINER_SOURCE="${presto_recorded_gitfile%/.git}"
  PRESTO_GIT_MOUNT_ARGS+=(
    -v "${PRESTO_HOST_GIT_COMMON_DIR}:${PRESTO_CONTAINER_GIT_COMMON_DIR}:ro"
  )
fi

if [[ "$DEV_PRESTO_DEPENDENCIES" == true && -z "$DEV_MAVEN_PROJECTS" ]]; then
  if [[ -z "$DEV_PRESTO_DEPENDENCIES_PROJECTS" ]]; then
    DEV_PRESTO_DEPENDENCIES_PROJECTS="$(compute_presto_dependencies_projects)"
  fi
  DEV_MAVEN_PROJECTS="$DEV_PRESTO_DEPENDENCIES_PROJECTS"
fi
if [[ "$DEV_PRESTO_DEPENDENCIES" == true ]]; then
  IFS=, read -r -a dev_projects <<< "$DEV_MAVEN_PROJECTS"
  dev_bootstrap_projects=()
  for project in "${dev_projects[@]}"; do
    [[ "$project" == ":presto-server" ]] && continue
    dev_bootstrap_projects+=("$project")
  done
  if (( ${#dev_bootstrap_projects[@]} )); then
    DEV_PRESTO_DEPENDENCIES_BOOTSTRAP_PROJECTS="$(IFS=,; echo "${dev_bootstrap_projects[*]}")"
  fi
fi

DEFAULT_MAVEN_CACHE_DIR="${SCRIPT_DIR}/.mvn_cache"
if [[ -d "${HOME}/.m2/repository" ]]; then
  DEFAULT_MAVEN_CACHE_DIR="${HOME}/.m2"
fi
MAVEN_CACHE_DIR="${PRESTO_DEV_MAVEN_CACHE_DIR:-${DEFAULT_MAVEN_CACHE_DIR}}"
mkdir -p "$MAVEN_CACHE_DIR"

if [[ -f "${MAVEN_CACHE_DIR}/settings.xml" ]]; then
  MAVEN_SETTINGS_FILE="${MAVEN_CACHE_DIR}/settings.xml"
else
  MAVEN_SETTINGS_FILE="${SCRIPT_DIR}/maven-central-mirror-settings.xml"
fi
if [[ ! -f "$MAVEN_SETTINGS_FILE" ]]; then
  echo "ERROR: Maven settings file does not exist: ${MAVEN_SETTINGS_FILE}" >&2
  exit 1
fi
MAVEN_SETTINGS_FILE="$(cd "$(dirname "$MAVEN_SETTINGS_FILE")" && pwd)/$(basename "$MAVEN_SETTINGS_FILE")"
MAVEN_SETTINGS_CONTAINER_PATH="/tmp/presto-dev-maven-settings.xml"

image_missing() {
  [[ -z "$(docker images -q "$1")" ]]
}

ensure_builder_image() {
  if [[ "$DEV_REBUILD_BUILDER" != true ]] && ! image_missing "$DEV_BUILDER_IMAGE"; then
    return
  fi

  echo "Building Presto Java dev builder image: ${DEV_BUILDER_IMAGE}"
  docker build --progress=plain --pull=false -t "$DEV_BUILDER_IMAGE" - <<'DOCKERFILE'
FROM eclipse-temurin:17-jdk-jammy
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
}

echo "Building Presto Java dev package with PRESTO_VERSION: $PRESTO_VERSION"
echo "Using Presto source: ${DEV_PRESTO_SOURCE}"
echo "Using Maven settings: ${MAVEN_SETTINGS_FILE}"
if [[ "$PRESTO_CONTAINER_SOURCE" != "$DEV_PRESTO_SOURCE" ]]; then
  echo "Mapping linked Presto worktree into builder: ${DEV_PRESTO_SOURCE} -> ${PRESTO_CONTAINER_SOURCE}"
fi
if [[ "$DEV_SKIP_UI" == true ]]; then
  echo "Dev Java build: skipping presto-ui (-DskipUI)."
else
  echo "Dev Java build: building presto-ui. Use --skip-ui for tight coordinator loops."
fi
if [[ "$DEV_CLEAN" == true ]]; then
  echo "Dev Java build: running Maven clean."
fi
if [[ -n "$DEV_MAVEN_PROJECTS" ]]; then
  echo "Dev Java build: limiting Maven reactor to ${DEV_MAVEN_PROJECTS} plus dependencies."
fi

ensure_builder_image

docker run --rm \
  -v "${DEV_PRESTO_SOURCE}:${PRESTO_CONTAINER_SOURCE}" \
  "${PRESTO_GIT_MOUNT_ARGS[@]}" \
  -v "${MAVEN_CACHE_DIR}:/root/.m2" \
  -v "${MAVEN_SETTINGS_FILE}:${MAVEN_SETTINGS_CONTAINER_PATH}:ro" \
  -e "GIT_OPTIONAL_LOCKS=0" \
  -e "MVNW_REPOURL=https://maven-central.storage-download.googleapis.com/maven2" \
  -e "PRESTO_VERSION=${PRESTO_VERSION}" \
  -e "PRESTO_DEV_PRESTO_SOURCE=${PRESTO_CONTAINER_SOURCE}" \
  -e "PRESTO_DEV_MAVEN_SETTINGS=${MAVEN_SETTINGS_CONTAINER_PATH}" \
  -e "PRESTO_DEV_SKIP_UI=${DEV_SKIP_UI}" \
  -e "PRESTO_DEV_JAVA_CLEAN=${DEV_CLEAN}" \
  -e "PRESTO_DEV_MAVEN_PROJECTS=${DEV_MAVEN_PROJECTS}" \
  -e "PRESTO_DEV_PRESTO_DEPENDENCIES_BOOTSTRAP_PROJECTS=${DEV_PRESTO_DEPENDENCIES_BOOTSTRAP_PROJECTS}" \
  -w "$PRESTO_CONTAINER_SOURCE" \
  "$DEV_BUILDER_IMAGE" \
  bash -lc '
    set -euo pipefail

    git config --global --add safe.directory "${PRESTO_DEV_PRESTO_SOURCE}"

    maven_common_args=(
      --no-transfer-progress
      --settings "${PRESTO_DEV_MAVEN_SETTINGS}"
      -DskipTests
      -Dair.check.skip-all=true
    )
    maven_project_args=()
    if [[ -n "${PRESTO_DEV_MAVEN_PROJECTS}" ]]; then
      maven_project_args+=(-pl "${PRESTO_DEV_MAVEN_PROJECTS}" -am)
    else
      maven_project_args+=(-pl "!presto-docs" -pl "!presto-openapi")
    fi
    if [[ "${PRESTO_DEV_SKIP_UI}" == "true" ]]; then
      maven_common_args+=(-DskipUI)
    fi

    rm -f \
      "docker/presto-server-${PRESTO_VERSION}.tar.gz" \
      docker/presto-function-server-executable.jar \
      "docker/presto-function-server-${PRESTO_VERSION}-executable.jar" \
      "docker/presto-cli-${PRESTO_VERSION}-executable.jar" \
      presto-server/target/presto-server-*.tar.gz \
      presto-function-server/target/presto-function-server-*executable.jar \
      presto-cli/target/presto-cli-*-executable.jar

    if [[ -n "${PRESTO_DEV_PRESTO_DEPENDENCIES_BOOTSTRAP_PROJECTS}" ]]; then
      echo "Dev Java build: pre-installing server runtime artifacts from ${PRESTO_DEV_PRESTO_DEPENDENCIES_BOOTSTRAP_PROJECTS}."
      ./mvnw install "${maven_common_args[@]}" -pl "${PRESTO_DEV_PRESTO_DEPENDENCIES_BOOTSTRAP_PROJECTS}" -am
    fi

    if [[ "${PRESTO_DEV_JAVA_CLEAN}" == "true" ]]; then
      ./mvnw clean install "${maven_common_args[@]}" "${maven_project_args[@]}"
    else
      ./mvnw install "${maven_common_args[@]}" "${maven_project_args[@]}"
    fi

    echo "Copying artifacts with version ${PRESTO_VERSION}..."
    cp presto-server/target/presto-server-*.tar.gz "docker/presto-server-${PRESTO_VERSION}.tar.gz"
    cp presto-function-server/target/presto-function-server-*executable.jar docker/presto-function-server-executable.jar
    cp presto-function-server/target/presto-function-server-*executable.jar "docker/presto-function-server-${PRESTO_VERSION}-executable.jar"
    cp presto-cli/target/presto-cli-*-executable.jar "docker/presto-cli-${PRESTO_VERSION}-executable.jar"

    artifact_owner="$(stat -c "%u:%g" docker)"
    chown "${artifact_owner}" \
      "docker/presto-server-${PRESTO_VERSION}.tar.gz" \
      docker/presto-function-server-executable.jar \
      "docker/presto-function-server-${PRESTO_VERSION}-executable.jar" \
      "docker/presto-cli-${PRESTO_VERSION}-executable.jar"
    chmod u+rw,go+r \
      "docker/presto-server-${PRESTO_VERSION}.tar.gz" \
      docker/presto-function-server-executable.jar \
      "docker/presto-function-server-${PRESTO_VERSION}-executable.jar" \
      "docker/presto-cli-${PRESTO_VERSION}-executable.jar"
    echo "Build complete. Artifacts copied with version ${PRESTO_VERSION}."
  '
