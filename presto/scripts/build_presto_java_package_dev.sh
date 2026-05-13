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
DEV_PRESTO_DEPENDENCIES_PROJECTS="${PRESTO_DEV_PRESTO_DEPENDENCIES_PROJECTS:-:presto-server,:presto-cli,:presto-function-server}"
DEV_BUILDER_IMAGE="${PRESTO_DEV_JAVA_BUILDER_IMAGE:-presto-java-builder-dev:${USER:-latest}-jdk17-git-v1}"

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
                                  --dev-presto-dependencies.

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
if [[ "$DEV_PRESTO_DEPENDENCIES" == true && -z "$DEV_MAVEN_PROJECTS" ]]; then
  DEV_MAVEN_PROJECTS="$DEV_PRESTO_DEPENDENCIES_PROJECTS"
fi

MAVEN_CACHE_DIR="${PRESTO_DEV_MAVEN_CACHE_DIR:-${SCRIPT_DIR}/.mvn_cache}"
mkdir -p "$MAVEN_CACHE_DIR"

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
  -v "${REPO_ROOT}/../presto:/presto" \
  -v "${MAVEN_CACHE_DIR}:/root/.m2" \
  -e "PRESTO_VERSION=${PRESTO_VERSION}" \
  -e "PRESTO_DEV_SKIP_UI=${DEV_SKIP_UI}" \
  -e "PRESTO_DEV_JAVA_CLEAN=${DEV_CLEAN}" \
  -e "PRESTO_DEV_MAVEN_PROJECTS=${DEV_MAVEN_PROJECTS}" \
  -w /presto \
  "$DEV_BUILDER_IMAGE" \
  bash -lc '
    set -euo pipefail

    git config --global --add safe.directory /presto

    maven_args=(
      --no-transfer-progress
      -DskipTests
      -Dair.check.skip-all=true
    )
    if [[ -n "${PRESTO_DEV_MAVEN_PROJECTS}" ]]; then
      maven_args+=(-pl "${PRESTO_DEV_MAVEN_PROJECTS}" -am)
    else
      maven_args+=(-pl "!presto-docs" -pl "!presto-openapi")
    fi
    if [[ "${PRESTO_DEV_SKIP_UI}" == "true" ]]; then
      maven_args+=(-DskipUI)
    fi

    rm -f \
      "docker/presto-server-${PRESTO_VERSION}.tar.gz" \
      docker/presto-function-server-executable.jar \
      "docker/presto-function-server-${PRESTO_VERSION}-executable.jar" \
      "docker/presto-cli-${PRESTO_VERSION}-executable.jar" \
      presto-server/target/presto-server-*.tar.gz \
      presto-function-server/target/presto-function-server-*executable.jar \
      presto-cli/target/presto-cli-*-executable.jar

    if [[ "${PRESTO_DEV_JAVA_CLEAN}" == "true" ]]; then
      ./mvnw clean install "${maven_args[@]}"
    else
      ./mvnw install "${maven_args[@]}"
    fi

    echo "Copying artifacts with version ${PRESTO_VERSION}..."
    cp presto-server/target/presto-server-*.tar.gz "docker/presto-server-${PRESTO_VERSION}.tar.gz"
    cp presto-function-server/target/presto-function-server-*executable.jar docker/presto-function-server-executable.jar
    cp presto-function-server/target/presto-function-server-*executable.jar "docker/presto-function-server-${PRESTO_VERSION}-executable.jar"
    cp presto-cli/target/presto-cli-*-executable.jar "docker/presto-cli-${PRESTO_VERSION}-executable.jar"
    chmod +r "docker/presto-cli-${PRESTO_VERSION}-executable.jar"
    echo "Build complete. Artifacts copied with version ${PRESTO_VERSION}."
  '
