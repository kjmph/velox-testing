#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEV_RESTART_TARGET=all
DEV_CLEAN_FIRST=false
DEV_SKIP_UI="${PRESTO_DEV_SKIP_UI:-false}"
DEV_JAVA_CLEAN="${PRESTO_DEV_JAVA_CLEAN:-false}"
DEV_PRESTO_DEPENDENCIES="${PRESTO_DEV_PRESTO_DEPENDENCIES:-false}"
DEV_ARGS=()

print_dev_help() {
  cat << EOF

Usage: $0 [DEV_OPTIONS] [START_OPTIONS]

Draft GPU developer start script. It keeps orchestration Python dependencies in
.venv-orchestration and supports targeted container recreation without calling
stop_presto.sh first.

DEV_OPTIONS:
    --restart-target all|coordinator|worker|none
        Which service set to recreate after any build. Default: all.
        "all" is bootstrap/recovery. Use "worker" after native GPU worker code
        changes to keep the coordinator up. When switching CPU/GPU variants,
        use "all" so stale workers from the previous variant can be removed.
    --clean-first
        Run stop_presto.sh before build/up. Useful when switching variants or
        recovering from orphaned containers.
    --skip-ui
        Skip the presto-ui Maven module for coordinator tight loops. The UI is
        built by default. Can also be set with PRESTO_DEV_SKIP_UI=true.
    --with-ui
        Build the UI even if PRESTO_DEV_SKIP_UI=true is set in the environment.
    --clean-java
        Run Maven clean before the dev coordinator package build. By default,
        coordinator builds are incremental.
    --dev-presto-dependencies
        Limit the coordinator Maven reactor to the artifacts copied into the
        dev coordinator image and their Maven dependencies. This is the fast
        coordinator iteration path and avoids unrelated tools like
        presto-verifier.

START_OPTIONS:
    Accepts the same GPU options as start_native_gpu_presto.sh, including:
    -b/--build, -w/--num-workers, -g/--gpu-ids, --single-container, --wait,
    --no-cache, --build-type, --all-cuda-archs, --profile, --profile-args,
    --skip-generate-config, --overwrite-config, --logs-dir, and sccache options.

CACHE BEHAVIOR:
    Without --no-cache, native source changes invalidate the native build RUN
    layer via a git hash while preserving package-manager layers and BuildKit
    build-directory cache mounts. Set NATIVE_BUILD_CACHE_SCOPE to use a
    different persistent CMake/object cache namespace. Use --no-cache for a
    full Docker layer-cache bypass.
    Coordinator dev builds use an incremental Maven package builder and a
    generated runtime Dockerfile that installs java-17-openjdk-headless instead
    of the desktop JDK package. The generated dev Dockerfile uses a package
    artifact hash to invalidate the coordinator image.

DEV NETWORK:
    Worker-only restarts use a static external Docker network so recreated
    workers keep stable IPs. Override with PRESTO_DEV_NETWORK_NAME,
    PRESTO_DEV_NETWORK_SUBNET, PRESTO_DEV_NETWORK_GATEWAY,
    PRESTO_DEV_COORDINATOR_IP, and PRESTO_DEV_WORKER_<N>_IP.

Examples:
    $0 -w 2 --wait -b worker --restart-target worker
    $0 -w 2 -g 2,3 --wait -b worker --restart-target worker
    $0 -w 2 --wait -b all --restart-target all
    $0 -w 2 --wait -b coordinator --restart-target coordinator --skip-ui
    $0 -w 2 --wait -b coordinator --restart-target coordinator --skip-ui --dev-presto-dependencies
    $0 -w 2 --wait --restart-target none

EOF
}

function normalize_dev_bool() {
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
  case $1 in
    -h|--help)
      print_dev_help
      exit 0
      ;;
    --restart-target)
      DEV_RESTART_TARGET=${2:?Error: --restart-target requires a value}
      shift 2
      ;;
    --clean-first)
      DEV_CLEAN_FIRST=true
      shift
      ;;
    --skip-ui)
      DEV_SKIP_UI=true
      shift
      ;;
    --with-ui)
      DEV_SKIP_UI=false
      shift
      ;;
    --clean-java)
      DEV_JAVA_CLEAN=true
      shift
      ;;
    --dev-presto-dependencies)
      DEV_PRESTO_DEPENDENCIES=true
      shift
      ;;
    *)
      DEV_ARGS+=("$1")
      shift
      ;;
  esac
done

if ! DEV_SKIP_UI="$(normalize_dev_bool "$DEV_SKIP_UI" "PRESTO_DEV_SKIP_UI")"; then
  exit 1
fi
if ! DEV_JAVA_CLEAN="$(normalize_dev_bool "$DEV_JAVA_CLEAN" "PRESTO_DEV_JAVA_CLEAN")"; then
  exit 1
fi
if ! DEV_PRESTO_DEPENDENCIES="$(normalize_dev_bool "$DEV_PRESTO_DEPENDENCIES" "PRESTO_DEV_PRESTO_DEPENDENCIES")"; then
  exit 1
fi

if [[ ! ${DEV_RESTART_TARGET} =~ ^(all|coordinator|worker|none)$ ]]; then
  echo "Error: --restart-target must be one of all, coordinator, worker, none." >&2
  exit 1
fi

if [[ "$DEV_CLEAN_FIRST" == "true" && "$DEV_RESTART_TARGET" =~ ^(worker|none)$ ]]; then
  echo "ERROR: --clean-first removes the coordinator, so --restart-target ${DEV_RESTART_TARGET} cannot produce a usable cluster." >&2
  echo "Use --restart-target all with --clean-first, or omit --clean-first for the fast path." >&2
  exit 1
fi

VARIANT_TYPE=gpu
SCRIPT_NAME=$0
set -- "${DEV_ARGS[@]}"
# shellcheck source=start_presto_helper_parse_args.sh
set +u
source "${SCRIPT_DIR}/start_presto_helper_parse_args.sh"
set -u

function validate_sibling_repos() {
  "${REPO_ROOT}/scripts/validate_directories_exist.sh" "${REPO_ROOT}/../presto" "${REPO_ROOT}/../velox"
}

function validate_sccache_auth() {
  if [[ "$ENABLE_SCCACHE" == true ]]; then
    echo "Checking for sccache authentication files in: $SCCACHE_AUTH_DIR"
    [[ -d "$SCCACHE_AUTH_DIR" ]] || { echo "ERROR: sccache auth directory not found: $SCCACHE_AUTH_DIR" >&2; exit 1; }
    [[ -f "$SCCACHE_AUTH_DIR/github_token" ]] || { echo "ERROR: GitHub token not found: $SCCACHE_AUTH_DIR/github_token" >&2; exit 1; }
    [[ -f "$SCCACHE_AUTH_DIR/aws_credentials" ]] || { echo "ERROR: AWS credentials not found: $SCCACHE_AUTH_DIR/aws_credentials" >&2; exit 1; }
    echo "sccache authentication files found."
  fi
}

if [[ -z "${PRESTO_IMAGE_TAG:-}" ]]; then
  export PRESTO_IMAGE_TAG="${USER:-latest}"
fi
echo "Using PRESTO_IMAGE_TAG: $PRESTO_IMAGE_TAG"

PRESTO_DEV_NETWORK_NAME="${PRESTO_DEV_NETWORK_NAME:-presto_dev}"
PRESTO_DEV_NETWORK_SUBNET="${PRESTO_DEV_NETWORK_SUBNET:-172.31.240.0/24}"
PRESTO_DEV_NETWORK_GATEWAY="${PRESTO_DEV_NETWORK_GATEWAY:-172.31.240.1}"
PRESTO_DEV_COORDINATOR_IP="${PRESTO_DEV_COORDINATOR_IP:-172.31.240.10}"
export PRESTO_DEV_NETWORK_NAME

COORDINATOR_SERVICE="presto-coordinator"
COORDINATOR_IMAGE="${COORDINATOR_SERVICE}:${PRESTO_IMAGE_TAG}"
GPU_WORKER_SERVICE="presto-native-worker-gpu"
GPU_WORKER_IMAGE="${GPU_WORKER_SERVICE}:${PRESTO_IMAGE_TAG}"
DEPS_IMAGE="presto/prestissimo-dependency:centos9-${USER:-latest}"
export DEPS_IMAGE

BUILD_TARGET_ARG=()

function is_image_missing() {
  [[ -z "$(docker images -q "$1")" ]]
}

function conditionally_add_build_target() {
  local image=$1
  local service=$2
  local target_pattern=$3

  if is_image_missing "$image"; then
    echo "Added $service to the list of services to build because the $image image is missing"
    BUILD_TARGET_ARG+=("$service")
  elif [[ ${BUILD_TARGET:-} =~ ^($target_pattern|all|a)$ ]]; then
    echo "Added $service to the list of services to build because the '${BUILD_TARGET}' build target was specified"
    BUILD_TARGET_ARG+=("$service")
  fi
}

function emit_git_hash_input() {
  local repo_dir=$1
  local label=$2

  echo "repo=${label}"
  if git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$repo_dir" rev-parse HEAD || true
    git -C "$repo_dir" status --short --untracked-files=all || true
    git -C "$repo_dir" diff --binary HEAD -- || true

    local file
    while IFS= read -r -d '' file; do
      [[ -f "${repo_dir}/${file}" ]] || continue
      printf 'untracked:%s:' "$file"
      sha256sum "${repo_dir}/${file}" | awk '{print $1}'
    done < <(git -C "$repo_dir" ls-files --others --exclude-standard -z | sort -z)
  else
    echo "not-a-git-repo"
    find "$repo_dir" -type f -print0 | sort -z | xargs -0 sha256sum
  fi
}

function compute_source_hash() {
  {
    emit_git_hash_input "${REPO_ROOT}/../presto" "presto"
    emit_git_hash_input "${REPO_ROOT}/../velox" "velox"
  } | sha256sum | awk '{print $1}'
}

function compute_native_build_cache_scope() {
  realpath "${REPO_ROOT}" | sha256sum | awk '{print substr($1, 1, 16)}'
}

function compute_presto_package_hash() {
  local presto_version=$1
  local docker_dir="${REPO_ROOT}/../presto/docker"
  local files=(
    "presto-server-${presto_version}.tar.gz"
    "presto-cli-${presto_version}-executable.jar"
    "presto-function-server-${presto_version}-executable.jar"
  )
  local file

  for file in "${files[@]}"; do
    if [[ ! -f "${docker_dir}/${file}" ]]; then
      echo "ERROR: expected coordinator package artifact is missing: ${docker_dir}/${file}" >&2
      return 1
    fi
    sha256sum "${docker_dir}/${file}"
  done | sha256sum | awk '{print $1}'
}

function docker_compose() {
  docker compose "$@"
}

function docker_compose_tty() {
  if [[ -t 2 && ! -t 1 ]]; then
    docker compose "$@" 1>&2
  else
    docker compose "$@"
  fi
}

function container_networks() {
  local container=$1
  docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container" 2>/dev/null || true
}

function ensure_dev_network() {
  if docker network inspect "$PRESTO_DEV_NETWORK_NAME" >/dev/null 2>&1; then
    local subnets
    subnets="$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$PRESTO_DEV_NETWORK_NAME" 2>/dev/null || true)"
    if [[ -n "$subnets" ]] && ! grep -Fxq "$PRESTO_DEV_NETWORK_SUBNET" <<< "$subnets"; then
      echo "WARNING: Docker network '$PRESTO_DEV_NETWORK_NAME' already exists with subnet(s):" >&2
      sed 's/^/  /' <<< "$subnets" >&2
      echo "         Requested subnet is ${PRESTO_DEV_NETWORK_SUBNET}; static IPs must fit the existing network." >&2
    fi
    return
  fi

  echo "Creating dev Docker network ${PRESTO_DEV_NETWORK_NAME} (${PRESTO_DEV_NETWORK_SUBNET})"
  if ! docker network create \
      --driver bridge \
      --subnet "$PRESTO_DEV_NETWORK_SUBNET" \
      --gateway "$PRESTO_DEV_NETWORK_GATEWAY" \
      "$PRESTO_DEV_NETWORK_NAME" >/dev/null; then
    echo "ERROR: failed to create Docker network '$PRESTO_DEV_NETWORK_NAME'." >&2
    echo "Set PRESTO_DEV_NETWORK_SUBNET/PRESTO_DEV_NETWORK_GATEWAY if ${PRESTO_DEV_NETWORK_SUBNET} overlaps another Docker network." >&2
    exit 1
  fi
}

function coordinator_container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$COORDINATOR_SERVICE" 2>/dev/null || true)" == "true" ]]
}

function ensure_coordinator_network_compatible() {
  [[ "$DEV_CLEAN_FIRST" == "true" ]] && return

  local networks
  networks=$(container_networks "$COORDINATOR_SERVICE")
  if [[ -z "$networks" ]]; then
    if [[ "$DEV_RESTART_TARGET" == "worker" ]]; then
      echo "ERROR: --restart-target worker requires an existing $COORDINATOR_SERVICE container." >&2
      echo "Run once with --restart-target all to create a coordinator." >&2
      exit 1
    fi
    return
  fi

  if grep -Fxq "$PRESTO_DEV_NETWORK_NAME" <<< "$networks"; then
    return
  fi

  if [[ "$DEV_RESTART_TARGET" == "worker" || "$DEV_RESTART_TARGET" == "none" ]]; then
    if ! coordinator_container_running; then
      echo "ERROR: existing $COORDINATOR_SERVICE is not running; worker-only restart cannot attach it to ${PRESTO_DEV_NETWORK_NAME}." >&2
      exit 1
    fi
    echo "Attaching existing $COORDINATOR_SERVICE to dev Docker network ${PRESTO_DEV_NETWORK_NAME} at ${PRESTO_DEV_COORDINATOR_IP}"
    docker network connect \
      --alias "$COORDINATOR_SERVICE" \
      --ip "$PRESTO_DEV_COORDINATOR_IP" \
      "$PRESTO_DEV_NETWORK_NAME" \
      "$COORDINATOR_SERVICE"
  fi
}

function set_properties_file_value() {
  local key=$1
  local value=$2
  local file=$3
  local key_regex="${key//./\\.}"

  if grep -q "^${key_regex}=" "$file"; then
    sed -i "s+^${key_regex}=.*+${key}=${value}+g" "$file"
  else
    printf "\n%s=%s\n" "$key" "$value" >>"$file"
  fi
}

function gpu_worker_ids() {
  if [[ -n "${GPU_IDS:-}" ]]; then
    local id
    IFS=',' read -ra ids <<< "$GPU_IDS"
    for id in "${ids[@]}"; do
      echo "$id"
    done
  else
    local i
    for ((i = 0; i < NUM_WORKERS; i++)); do
      echo "$i"
    done
  fi
}

function gpu_worker_services() {
  if [[ -n "$NUM_WORKERS" && "$NUM_WORKERS" -gt 1 && "$SINGLE_CONTAINER" == "false" ]]; then
    local id
    while IFS= read -r id; do
      echo "presto-native-worker-gpu-${id}"
    done < <(gpu_worker_ids)
  else
    echo "presto-native-worker-gpu"
  fi
}

function active_presto_worker_containers() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^presto-(native-worker-(cpu|gpu)(-[0-9]+)?|java-worker)$' || true
}

function opposite_variant_worker_containers() {
  active_presto_worker_containers | grep -E '^presto-native-worker-cpu(-[0-9]+)?$|^presto-java-worker$' || true
}

function name_in_list() {
  local needle=$1
  shift || true
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

function remove_stale_worker_containers() {
  local desired=("$@")
  local stale=()
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    name_in_list "$name" "${desired[@]}" && continue
    stale+=("$name")
  done < <(active_presto_worker_containers)

  if (( ${#stale[@]} )); then
    echo "Removing stale Presto worker container(s): ${stale[*]}"
    docker rm -f "${stale[@]}"
  fi
}

function prepare_worker_container_set() {
  local desired=()
  local opposite=()
  mapfile -t desired < <(gpu_worker_services)
  mapfile -t opposite < <(opposite_variant_worker_containers)

  if (( ${#opposite[@]} )) && [[ "$DEV_RESTART_TARGET" != "all" && "$DEV_CLEAN_FIRST" != "true" ]]; then
    echo "ERROR: found existing non-GPU Presto worker container(s): ${opposite[*]}" >&2
    echo "Use --restart-target all or --clean-first when switching variants." >&2
    exit 1
  fi

  if [[ "$DEV_RESTART_TARGET" == "all" || "$DEV_RESTART_TARGET" == "worker" ]]; then
    remove_stale_worker_containers "${desired[@]}"
  fi
}

function gpu_expected_worker_entries() {
  local id id_num service port
  while IFS= read -r id; do
    id_num=$((10#$id))
    if [[ -n "$NUM_WORKERS" && "$NUM_WORKERS" -gt 1 && "$SINGLE_CONTAINER" == "false" ]]; then
      service="presto-native-worker-gpu-${id}"
    else
      service="presto-native-worker-gpu"
    fi
    port="$(printf "10%02d0" "$id_num")"
    echo "${id} ${service} ${port}"
  done < <(gpu_worker_ids)
}

function apply_dev_discovery_tuning() {
  local config_dir="${SCRIPT_DIR}/../docker/config/generated/gpu"
  local coordinator_config="${config_dir}/etc_coordinator/config_native.properties"

  [[ -f "$coordinator_config" ]] || return

  local discovery_max_age="${PRESTO_DEV_DISCOVERY_MAX_AGE:-3s}"
  local discovery_store_cache_ttl="${PRESTO_DEV_DISCOVERY_STORE_CACHE_TTL:-250ms}"
  local node_discovery_poll_ms="${PRESTO_DEV_NODE_DISCOVERY_POLL_MS:-500}"
  local failure_heartbeat="${PRESTO_DEV_FAILURE_DETECTOR_HEARTBEAT:-250ms}"
  local failure_warmup="${PRESTO_DEV_FAILURE_DETECTOR_WARMUP:-1s}"
  local failure_decay="${PRESTO_DEV_FAILURE_DETECTOR_DECAY_SECONDS:-1}"
  local worker_announcement_ms="${PRESTO_DEV_ANNOUNCEMENT_MAX_FREQUENCY_MS:-1000}"

  set_properties_file_value "discovery.max-age" "$discovery_max_age" "$coordinator_config"
  set_properties_file_value "discovery.store-cache-ttl" "$discovery_store_cache_ttl" "$coordinator_config"
  set_properties_file_value "internal-communication.node-discovery-polling-interval-millis" "$node_discovery_poll_ms" "$coordinator_config"
  set_properties_file_value "failure-detector.heartbeat-interval" "$failure_heartbeat" "$coordinator_config"
  set_properties_file_value "failure-detector.warmup-interval" "$failure_warmup" "$coordinator_config"
  set_properties_file_value "failure-detector.exponential-decay-seconds" "$failure_decay" "$coordinator_config"

  local worker_config
  for worker_config in "${config_dir}"/etc_worker*/config_native.properties; do
    [[ -f "$worker_config" ]] || continue
    set_properties_file_value "announcement-max-frequency-ms" "$worker_announcement_ms" "$worker_config"
  done

  echo "Dev discovery tuning: discovery.max-age=${discovery_max_age} discovery.store-cache-ttl=${discovery_store_cache_ttl} node-discovery-poll-ms=${node_discovery_poll_ms} worker-announcement-ms=${worker_announcement_ms}"
}

function apply_dev_node_addresses() {
  local config_dir="${SCRIPT_DIR}/../docker/config/generated/gpu"
  local coordinator_node_config="${config_dir}/etc_coordinator/node.properties"

  [[ -f "$coordinator_node_config" ]] || return
  set_properties_file_value "node.internal-address" "$COORDINATOR_SERVICE" "$coordinator_node_config"

  local id worker_node_config worker_service
  while IFS= read -r id; do
    worker_node_config="${config_dir}/etc_worker_${id}/node.properties"
    [[ -f "$worker_node_config" ]] || continue
    if [[ -n "$NUM_WORKERS" && "$NUM_WORKERS" -gt 1 && "$SINGLE_CONTAINER" == "false" ]]; then
      worker_service="presto-native-worker-gpu-${id}"
    else
      worker_service="presto-native-worker-gpu"
    fi
    set_properties_file_value "node.internal-address" "$worker_service" "$worker_node_config"
  done < <(gpu_worker_ids)
}

function render_dev_network_override() {
  local rendered_dir=$1
  local override_path="${rendered_dir}/docker-compose.gpu-dev-network.yml"
  local worker_services=()
  local i
  mkdir -p "$rendered_dir"
  mapfile -t worker_services < <(gpu_worker_services)

  {
    printf "networks:\n"
    printf "  presto_dev:\n"
    printf "    external: true\n"
    printf "    name: %s\n" "$PRESTO_DEV_NETWORK_NAME"
    printf "\nservices:\n"
    printf "  %s:\n" "$COORDINATOR_SERVICE"
    printf "    networks:\n"
    printf "      presto_dev:\n"
    printf "        ipv4_address: %s\n" "$PRESTO_DEV_COORDINATOR_IP"

    for i in "${!worker_services[@]}"; do
      local service="${worker_services[$i]}"
      local worker_ip_var="PRESTO_DEV_WORKER_${i}_IP"
      local worker_ip="${!worker_ip_var:-}"
      if [[ -z "$worker_ip" ]]; then
        if [[ "${#worker_services[@]}" -eq 1 && -n "${PRESTO_DEV_WORKER_IP:-}" ]]; then
          worker_ip="$PRESTO_DEV_WORKER_IP"
        else
          worker_ip="172.31.240.$((20 + i))"
        fi
      fi
      printf "  %s:\n" "$service"
      printf "    networks:\n"
      printf "      presto_dev:\n"
      printf "        ipv4_address: %s\n" "$worker_ip"
    done
  } > "$override_path"

  echo "$override_path"
}

function render_dev_coordinator_dockerfile() {
  local rendered_dir=$1
  local dockerfile_path="${rendered_dir}/coordinator_dev.dockerfile"
  local source_dockerfile="${REPO_ROOT}/../presto/docker/Dockerfile"
  local runtime_install="dnf install -y java-17-openjdk less procps python3"
  local dev_runtime_install="dnf install -y java-17-openjdk-headless less procps-ng python3 curl-minimal"

  if ! grep -Fq "$runtime_install" "$source_dockerfile"; then
    echo "ERROR: unable to generate coordinator dev Dockerfile; expected runtime install line not found in ${source_dockerfile}." >&2
    exit 1
  fi

  sed \
    -e "s+${runtime_install}+${dev_runtime_install}+" \
    -e '/ARG JMX_PROMETHEUS_JAVAAGENT_VERSION/a ARG PRESTO_DEV_PACKAGE_HASH=unknown' \
    -e 's+ln -s $(which python3) /usr/bin/python+ln -sf /usr/bin/python3 /usr/bin/python+' \
    -e 's+mv /etc/yum/protected.d/systemd.conf /etc/yum/protected.d/systemd.conf.bak+[ ! -f /etc/yum/protected.d/systemd.conf ] || mv /etc/yum/protected.d/systemd.conf /etc/yum/protected.d/systemd.conf.bak+' \
    -e 's+RUN --mount=type=bind,source=$PRESTO_PKG,target=/$PRESTO_PKG \\+RUN --mount=type=bind,source=$PRESTO_PKG,target=/$PRESTO_PKG \\\n    echo "PRESTO_DEV_PACKAGE_HASH=${PRESTO_DEV_PACKAGE_HASH}" >/tmp/presto_dev_package_hash \&\& \\+' \
    "$source_dockerfile" > "$dockerfile_path"
  echo "$dockerfile_path"
}

function render_dev_coordinator_override() {
  local rendered_dir=$1
  local override_path="${rendered_dir}/docker-compose.gpu-dev-coordinator.yml"
  local dockerfile_path
  mkdir -p "$rendered_dir"
  dockerfile_path="$(render_dev_coordinator_dockerfile "$rendered_dir")"

  {
    printf "services:\n"
    printf "  %s:\n" "$COORDINATOR_SERVICE"
    printf "    build:\n"
    printf "      context: ../../../../../presto/docker\n"
    printf "      dockerfile: ../../velox-testing/presto/docker/docker-compose/generated/%s\n" "$(basename "$dockerfile_path")"
  } > "$override_path"

  echo "$override_path"
}

function build_targets_include() {
  local service=$1
  local target
  for target in "${BUILD_TARGET_ARG[@]}"; do
    [[ "$target" == "$service" ]] && return 0
  done
  return 1
}

function build_targets_include_gpu_worker() {
  local worker_services=()
  local service
  mapfile -t worker_services < <(gpu_worker_services)
  for service in "${worker_services[@]}"; do
    build_targets_include "$service" && return 0
  done
  return 1
}

function compute_cuda_architectures() {
  if [[ "$ALL_CUDA_ARCHS" == "true" ]]; then
    echo "75;80;86;90;100;120"
    return
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi could not be found. Please ensure that the NVIDIA drivers and Docker runtime are properly installed." >&2
    exit 1
  fi

  nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1 | sed 's/\.//g'
}

conditionally_add_build_target "$COORDINATOR_IMAGE" "$COORDINATOR_SERVICE" "coordinator|c"

DOCKER_COMPOSE_FILE="native-gpu"
DOCKER_COMPOSE_FILE_PATH="${SCRIPT_DIR}/../docker/docker-compose.${DOCKER_COMPOSE_FILE}.yml"
TEMPLATE_PATH="${SCRIPT_DIR}/../docker/docker-compose/template/docker-compose.${DOCKER_COMPOSE_FILE}.yml.jinja"

FIRST_GPU_ID=""
while IFS= read -r FIRST_GPU_ID; do
  break
done < <(gpu_worker_ids)
if [[ -n "$NUM_WORKERS" && "$NUM_WORKERS" -gt 1 && "$SINGLE_CONTAINER" == "false" ]]; then
  GPU_WORKER_SERVICE="presto-native-worker-gpu-${FIRST_GPU_ID}"
fi
conditionally_add_build_target "$GPU_WORKER_IMAGE" "$GPU_WORKER_SERVICE" "worker|w"

LOGS_DIR="${LOGS_DIR:-${SCRIPT_DIR}/presto_logs}"
if [[ "$DEV_RESTART_TARGET" == "all" || "$DEV_CLEAN_FIRST" == "true" ]]; then
  [[ -L "${LOGS_DIR}" ]] && rm -f "${LOGS_DIR}"
  mkdir -p "${LOGS_DIR}"
  if compgen -G "${LOGS_DIR}/*.log" >/dev/null 2>&1; then
    mkdir -p "${LOGS_DIR}/archive"
    mv "${LOGS_DIR}"/*.log "${LOGS_DIR}/archive/"
  fi
else
  mkdir -p "${LOGS_DIR}"
fi
export SERVER_START_TIMESTAMP="$(date +"%Y%m%dT%H%M%S")"
export LOGS_DIR

if [[ "$DEV_CLEAN_FIRST" == "true" ]]; then
  "${SCRIPT_DIR}/stop_presto.sh"
fi

if [[ "${SKIP_GENERATE_CONFIG:-false}" != "true" ]]; then
  VARIANT_TYPE=gpu "${SCRIPT_DIR}/generate_presto_config.sh"
fi
apply_dev_node_addresses
apply_dev_discovery_tuning

RENDERED_DIR="${SCRIPT_DIR}/../docker/docker-compose/generated"
RENDERED_PATH="${RENDERED_DIR}/docker-compose.${DOCKER_COMPOSE_FILE}.rendered.yml"
RENDER_SCRIPT_PATH="$(readlink -f "${REPO_ROOT}/template_rendering/render_docker_compose_template.py")"

# shellcheck source=../../scripts/dev_python_env.sh
source "${REPO_ROOT}/scripts/dev_python_env.sh"
dev_python_activate "${SCRIPT_DIR}/.venv-orchestration" "${REPO_ROOT}/template_rendering/requirements.txt"
RENDER_SCCACHE=false
if [[ "$ENABLE_SCCACHE" == true ]] && build_targets_include_gpu_worker; then
  RENDER_SCCACHE=true
fi
RENDER_ARGS=(
  --template-path "$TEMPLATE_PATH"
  --output-path "$RENDERED_PATH"
  --num-workers "$NUM_WORKERS"
  --single-container "$SINGLE_CONTAINER"
  --kvikio-threads "$KVIKIO_THREADS"
  --sccache "$RENDER_SCCACHE"
  --variant gpu
)
if [[ -n "${GPU_IDS:-}" ]]; then
  RENDER_ARGS+=(--gpu-ids "$GPU_IDS")
fi
python "$RENDER_SCRIPT_PATH" "${RENDER_ARGS[@]}"
DOCKER_COMPOSE_FILE_PATH="$RENDERED_PATH"

COMPOSE_FILE_ARGS=(-f "$DOCKER_COMPOSE_FILE_PATH")
if build_targets_include "$COORDINATOR_SERVICE"; then
  COORDINATOR_DEV_OVERRIDE_PATH="$(render_dev_coordinator_override "$RENDERED_DIR")"
  COMPOSE_FILE_ARGS+=(-f "$COORDINATOR_DEV_OVERRIDE_PATH")
fi
if [[ "$DEV_RESTART_TARGET" != "none" || "$WAIT_FOR_WORKERS" == "true" ]]; then
  DEV_NETWORK_OVERRIDE_PATH="$(render_dev_network_override "$RENDERED_DIR")"
  COMPOSE_FILE_ARGS+=(-f "$DEV_NETWORK_OVERRIDE_PATH")
  ensure_dev_network
  ensure_coordinator_network_compatible
  prepare_worker_container_set
  echo "Using dev Docker network: ${PRESTO_DEV_NETWORK_NAME} (${PRESTO_DEV_NETWORK_SUBNET})"
fi

if (( ${#BUILD_TARGET_ARG[@]} )); then
  if [[ "$ENABLE_SCCACHE" == true ]] && build_targets_include_gpu_worker; then
    validate_sccache_auth
  fi
  validate_sibling_repos
  SOURCE_HASH="not-used"
  NATIVE_BUILD_CACHE_SCOPE="${NATIVE_BUILD_CACHE_SCOPE:-}"
  if build_targets_include_gpu_worker; then
    SOURCE_HASH="$(compute_source_hash)"
    NATIVE_BUILD_CACHE_SCOPE="${NATIVE_BUILD_CACHE_SCOPE:-$(compute_native_build_cache_scope)}"
    echo "Using VELOX_TESTING_SOURCE_HASH=${SOURCE_HASH}"
    echo "Using NATIVE_BUILD_CACHE_SCOPE=${NATIVE_BUILD_CACHE_SCOPE}"
  fi
  NATIVE_BUILD_CACHE_SCOPE="${NATIVE_BUILD_CACHE_SCOPE:-default}"

  if build_targets_include_gpu_worker && is_image_missing "${DEPS_IMAGE}"; then
    echo "ERROR: Presto dependencies/run-time image '${DEPS_IMAGE}' not found!" >&2
    echo "Build it with presto/scripts/build_centos_deps_image.sh or fetch it first." >&2
    exit 1
  fi

  PRESTO_VERSION=testing
  PRESTO_DEV_PACKAGE_HASH="not-used"
  if [[ ${BUILD_TARGET_ARG[*]} =~ $COORDINATOR_SERVICE ]]; then
    JAVA_BUILD_ARGS=()
    [[ "$DEV_SKIP_UI" == true ]] && JAVA_BUILD_ARGS+=(--skip-ui)
    [[ "$DEV_JAVA_CLEAN" == true ]] && JAVA_BUILD_ARGS+=(--clean)
    [[ "$DEV_PRESTO_DEPENDENCIES" == true ]] && JAVA_BUILD_ARGS+=(--dev-presto-dependencies)
    PRESTO_VERSION=$PRESTO_VERSION "${SCRIPT_DIR}/build_presto_java_package_dev.sh" "${JAVA_BUILD_ARGS[@]}"
    PRESTO_DEV_PACKAGE_HASH="$(compute_presto_package_hash "$PRESTO_VERSION")"
    echo "Using PRESTO_DEV_PACKAGE_HASH=${PRESTO_DEV_PACKAGE_HASH}"
  fi

  SCCACHE_BUILD_ARGS=()
  SCCACHE_BUILD_ARGS+=(--build-arg "SCCACHE_VERSION=${SCCACHE_VERSION}")
  if [[ "$ENABLE_SCCACHE" == true ]]; then
    SCCACHE_BUILD_ARGS+=(--build-arg "ENABLE_SCCACHE=ON")
    if [[ "$SCCACHE_ENABLE_DIST" != true ]]; then
      SCCACHE_BUILD_ARGS+=(--build-arg "SCCACHE_NO_DIST_COMPILE=1")
    else
      echo "WARNING: sccache distributed compilation enabled - may cause compilation differences"
    fi
  else
    SCCACHE_BUILD_ARGS+=(--build-arg "ENABLE_SCCACHE=OFF")
    SCCACHE_BUILD_ARGS+=(--build-arg "SCCACHE_NO_DIST_COMPILE=1")
  fi

  CUDA_ARCHITECTURES=""
  if build_targets_include_gpu_worker; then
    CUDA_ARCHITECTURES="$(compute_cuda_architectures)"
    echo "Building GPU with CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}"
  fi

  echo "Building services: ${BUILD_TARGET_ARG[*]}"
  docker_compose --progress=plain "${COMPOSE_FILE_ARGS[@]}" build \
    ${SKIP_CACHE_ARG:-} \
    --build-arg "VELOX_TESTING_SOURCE_HASH=${SOURCE_HASH}" \
    --build-arg "NATIVE_BUILD_CACHE_SCOPE=${NATIVE_BUILD_CACHE_SCOPE}" \
    --build-arg "PRESTO_DEV_PACKAGE_HASH=${PRESTO_DEV_PACKAGE_HASH}" \
    --build-arg "PRESTO_VERSION=${PRESTO_VERSION}" \
    --build-arg "NUM_THREADS=${NUM_THREADS}" \
    --build-arg "BUILD_TYPE=${BUILD_TYPE}" \
    --build-arg "CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}" \
    "${SCCACHE_BUILD_ARGS[@]}" \
    "${BUILD_TARGET_ARG[@]}"
fi

function container_ip_on_dev_network() {
  local container=$1
  local network="$PRESTO_DEV_NETWORK_NAME"
  docker inspect -f "{{with index .NetworkSettings.Networks \"${network}\"}}{{.IPAddress}}{{end}}" "$container" 2>/dev/null || true
}

function verify_gpu_worker_endpoints() {
  local quiet="${1:-false}"
  local expected_lines=()
  local id service port ip

  while read -r id service port; do
    ip="$(container_ip_on_dev_network "$service")"
    if [[ -z "$ip" ]]; then
      echo "ERROR: unable to inspect Docker IP for ${service} on ${PRESTO_DEV_NETWORK_NAME}." >&2
      return 1
    fi
    expected_lines+=("${id} ${service} ${ip} ${port}")
  done < <(gpu_expected_worker_entries)

  EXPECTED_WORKER_ENDPOINTS="$(printf "%s\n" "${expected_lines[@]}")" VERIFY_WORKER_ENDPOINTS_QUIET="$quiet" python3 - <<'PY'
import json
import os
import re
import sys
import urllib.request
from urllib.parse import urlparse

quiet = os.environ.get("VERIFY_WORKER_ENDPOINTS_QUIET") == "true"
expected = []
valid_urls = set()
worker_ports = set()

for line in os.environ["EXPECTED_WORKER_ENDPOINTS"].splitlines():
    worker_id, service, ip, port = line.split()
    alternatives = (f"http://{ip}:{port}", f"http://{service}:{port}")
    expected.append((worker_id, service, alternatives))
    valid_urls.update(alternatives)
    worker_ports.add(port)

try:
    with urllib.request.urlopen("http://localhost:8080/v1/node", timeout=3) as response:
        nodes = json.load(response)
except Exception as error:
    if not quiet:
        print(f"ERROR: unable to read coordinator node view: {error}", file=sys.stderr)
    sys.exit(1)

node_text = json.dumps(nodes, sort_keys=True)

def normalize_http_url(url):
    parsed = urlparse(url)
    if not parsed.scheme or not parsed.hostname or parsed.port is None:
        return None
    return f"{parsed.scheme}://{parsed.hostname}:{parsed.port}"

observed_urls = {
    normalized
    for url in re.findall(r"http://[^\"\\\s,}]+", node_text)
    for normalized in (normalize_http_url(url),)
    if normalized
}

missing = [
    (worker_id, service, alternatives)
    for worker_id, service, alternatives in expected
    if not any(url in node_text for url in alternatives)
]
unexpected = sorted(
    url for url in observed_urls
    if str(urlparse(url).port) in worker_ports and url not in valid_urls
)

if missing or unexpected:
    if quiet:
        sys.exit(1)

    print("ERROR: coordinator node view does not match the current GPU worker containers.", file=sys.stderr)
    for worker_id, service, alternatives in missing:
        print(f"  missing GPU worker {worker_id} ({service}): expected one of {', '.join(alternatives)}", file=sys.stderr)
    for url in unexpected:
        print(f"  stale/unexpected worker endpoint: {url}", file=sys.stderr)

    if isinstance(nodes, list):
        print("  coordinator /v1/node view:", file=sys.stderr)
        for node in nodes:
            if isinstance(node, dict):
                values = []
                for key in ("nodeId", "nodeIdentifier", "id", "uri", "httpUri", "internalUri"):
                    if key in node:
                        values.append(f"{key}={node[key]}")
                print("    " + (" ".join(values) if values else json.dumps(node, sort_keys=True)), file=sys.stderr)
            else:
                print(f"    {node}", file=sys.stderr)

    print("Coordinator discovery state is still stale after the wait timeout.", file=sys.stderr)
    print("If this persists after one retry, restart only the coordinator with --restart-target coordinator.", file=sys.stderr)
    sys.exit(1)

if not quiet:
    print("Coordinator GPU worker endpoints match current containers.")
PY
}

case "$DEV_RESTART_TARGET" in
  all)
    docker_compose_tty "${COMPOSE_FILE_ARGS[@]}" up -d --force-recreate --remove-orphans
    ;;
  coordinator)
    docker_compose_tty "${COMPOSE_FILE_ARGS[@]}" up -d --no-deps --force-recreate "$COORDINATOR_SERVICE"
    ;;
  worker)
    mapfile -t WORKER_SERVICES < <(gpu_worker_services)
    docker_compose_tty "${COMPOSE_FILE_ARGS[@]}" up -d --no-deps --force-recreate "${WORKER_SERVICES[@]}"
    ;;
  none)
    echo "Skipping docker compose up because --restart-target none was specified."
    ;;
esac

if [[ "$WAIT_FOR_WORKERS" == "true" ]]; then
  echo "Waiting for ${NUM_WORKERS} GPU worker(s) to register with coordinator (timeout: ${WAIT_FOR_WORKERS_TIMEOUT}s)..."
  deadline=$(( $(date +%s) + WAIT_FOR_WORKERS_TIMEOUT ))
  workers=0
  endpoints_ready=false
  while [[ $(date +%s) -lt $deadline ]]; do
    workers=$(python3 - <<'PY'
import json
import urllib.request

try:
    with urllib.request.urlopen("http://localhost:8080/v1/node", timeout=1) as r:
        print(len(json.load(r)))
except Exception:
    print(0)
PY
)
    echo "  ${workers}/${NUM_WORKERS} worker(s) registered"
    if [[ "$workers" -ge "$NUM_WORKERS" ]]; then
      if verify_gpu_worker_endpoints true; then
        endpoints_ready=true
        break
      fi
      echo "  worker count is sufficient, but coordinator still has stale GPU worker endpoints"
    fi
    sleep 5
  done
  if [[ "$workers" -lt "$NUM_WORKERS" ]]; then
    echo "ERROR: only ${workers}/${NUM_WORKERS} workers registered after ${WAIT_FOR_WORKERS_TIMEOUT}s" >&2
    exit 1
  fi
  if [[ "$endpoints_ready" != "true" ]]; then
    verify_gpu_worker_endpoints
    exit 1
  fi
  verify_gpu_worker_endpoints
fi
