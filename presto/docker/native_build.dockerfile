# check=skip=SecretsUsedInArgOrEnv
ARG BASE_IMAGE=presto/prestissimo-dependency:centos9
FROM ${BASE_IMAGE}

RUN rpm --import https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub && \
    dnf config-manager --add-repo "https://developer.download.nvidia.com/devtools/repos/rhel$(source /etc/os-release; echo ${VERSION_ID%%.*})/$(rpm --eval '%{_arch}' | sed s/aarch/arm/)/" && \
    dnf install -y nsight-systems-cli-2025.5.1 numactl

ARG GPU=ON
ARG BUILD_TYPE=release
ARG BUILD_BASE_DIR=/presto_native_${BUILD_TYPE}_gpu_${GPU}_build
ARG NUM_THREADS=12
ARG EXTRA_CMAKE_FLAGS="\
    -DPRESTO_ENABLE_TESTING=OFF \
    -DPRESTO_ENABLE_PARQUET=ON \
    -DPRESTO_ENABLE_S3=ON \
    -DPRESTO_ENABLE_CUDF=${GPU} \
    -DVELOX_ENABLE_UCX_EXCHANGE=ON \
    -DVELOX_BUILD_TESTING=OFF \
    -DPRESTO_STATS_REPORTER_TYPE=PROMETHEUS"
ARG CUDA_ARCHITECTURES="75;80;86;90;100;120"
ARG TARGETARCH
ARG ENABLE_SCCACHE=OFF
ARG SCCACHE_SERVER_LOG="sccache=info"
ARG SCCACHE_VERSION=latest
ARG SCCACHE_RECACHE
ARG SCCACHE_NO_CACHE
ARG SCCACHE_NO_DIST_COMPILE
ARG VELOX_TESTING_SOURCE_HASH=unknown
ARG NATIVE_BUILD_CACHE_SCOPE=default
ARG S3_DIRECT_RECEIVE=OFF

# Override ARM_BUILD_TARGET to prevent get_cxx_flags() in Velox's
# setup-helper-functions.sh from reading the MIDR_EL1 register and emitting
# -mcpu=neoverse-v1. Build runners (Neoverse V1) and test runners (e.g. Neoverse N1)
# may differ; the fallback -march=armv8-a+crc+crypto is safe on all ARMv8-A hardware.
# Must be a non-empty value: the script uses ${ARM_BUILD_TARGET:-"local"}, so an
# empty string is treated the same as unset and falls back to "local".
ENV CC=/opt/rh/gcc-toolset-14/root/bin/gcc \
    CXX=/opt/rh/gcc-toolset-14/root/bin/g++ \
    ARM_BUILD_TARGET="generic" \
    CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    EXTRA_CMAKE_FLAGS=${EXTRA_CMAKE_FLAGS} \
    NUM_THREADS=${NUM_THREADS} \
    ENABLE_SCCACHE="${ENABLE_SCCACHE}" \
    SCCACHE_VERSION="${SCCACHE_VERSION}" \
    SCCACHE_SERVER_LOG="${SCCACHE_SERVER_LOG}" \
    SCCACHE_ERROR_LOG=/tmp/sccache.log \
    SCCACHE_CACHE_SIZE=107374182400 \
    SCCACHE_BUCKET=rapids-sccache-devs \
    SCCACHE_REGION=us-east-2 \
    SCCACHE_S3_NO_CREDENTIALS=false \
    SCCACHE_S3_USE_SSL=true \
    SCCACHE_DIRECT=true \
    SCCACHE_IDLE_TIMEOUT=0 \
    SCCACHE_DIST_AUTH_TYPE=token \
    SCCACHE_DIST_REQUEST_TIMEOUT=7140 \
    SCCACHE_DIST_SCHEDULER_URL="https://${TARGETARCH}.linux.sccache.rapids.nvidia.com" \
    SCCACHE_DIST_MAX_RETRIES=10 \
    SCCACHE_DIST_FALLBACK_TO_LOCAL_COMPILE=true \
    SCCACHE_S3_USE_PREPROCESSOR_CACHE_MODE=true \
    SCCACHE_S3_KEY_PREFIX=velox-testing/object-cache \
    SCCACHE_S3_PREPROCESSOR_CACHE_KEY_PREFIX=velox-testing/preprocessor-cache

RUN mkdir /runtime-libraries

RUN \
    --mount=type=bind,source=presto/presto-native-execution,target=/presto_native_staging/presto \
    --mount=type=bind,source=velox,target=/presto_native_staging/presto/velox \
    --mount=type=cache,id=presto-native-build-${NATIVE_BUILD_CACHE_SCOPE}-${TARGETARCH}-${BUILD_TYPE}-gpu-${GPU},target=${BUILD_BASE_DIR},sharing=locked \
    --mount=type=cache,target=/root/.cache/sccache/preprocessor \
    --mount=type=cache,target=/root/.cache/sccache-dist-client \
    --mount=type=secret,id=github_token,env=SCCACHE_DIST_AUTH_TOKEN \
    --mount=type=secret,id=aws_credentials,target=/root/.aws/credentials \
    --mount=type=bind,source=velox-testing/scripts/sccache/sccache_setup.sh,target=/sccache_setup.sh,ro \
<<EOF
set -euxo pipefail;

source /opt/rh/gcc-toolset-14/enable;
export CC=/opt/rh/gcc-toolset-14/root/bin/gcc CXX=/opt/rh/gcc-toolset-14/root/bin/g++;
echo "VELOX_TESTING_SOURCE_HASH=${VELOX_TESTING_SOURCE_HASH}";
printf '%s\n' "${VELOX_TESTING_SOURCE_HASH}" > "${BUILD_BASE_DIR}/.velox_testing_source_hash";

S3_DIRECT_RECEIVE_PREFIX=/opt/presto-s3-direct;
case "${S3_DIRECT_RECEIVE}" in
  ON)
    test -f "${S3_DIRECT_RECEIVE_PREFIX}/share/presto-s3-direct-receive/build-info.env";
    export LD_LIBRARY_PATH="${S3_DIRECT_RECEIVE_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}";
    EXTRA_CMAKE_FLAGS="${EXTRA_CMAKE_FLAGS} \
      -DVELOX_ENABLE_S3_DIRECT_RECEIVE=ON \
      -DCMAKE_PREFIX_PATH=${S3_DIRECT_RECEIVE_PREFIX} \
      -DAWSSDK_ROOT_DIR=${S3_DIRECT_RECEIVE_PREFIX} \
      -DAWSSDK_DIR=${S3_DIRECT_RECEIVE_PREFIX}/lib/cmake/AWSSDK \
      -DCURL_DIR=${S3_DIRECT_RECEIVE_PREFIX}/lib/cmake/CURL";
    ;;
  OFF)
    EXTRA_CMAKE_FLAGS="${EXTRA_CMAKE_FLAGS} -DVELOX_ENABLE_S3_DIRECT_RECEIVE=OFF";
    ;;
  *)
    echo "S3_DIRECT_RECEIVE must be ON or OFF, got '${S3_DIRECT_RECEIVE}'" >&2;
    exit 1;
    ;;
esac;

# Clear stale CMake cache if the compiler changed
if [ -f "${BUILD_BASE_DIR}/CMakeCache.txt" ]; then
  CACHED_CXX=$(grep -m1 'CMAKE_CXX_COMPILER:' "${BUILD_BASE_DIR}/CMakeCache.txt" | cut -d= -f2 || true);
  CURRENT_CXX=$(command -v "$CXX");
  if [ -n "$CACHED_CXX" ] && [ "$CACHED_CXX" != "$CURRENT_CXX" ]; then
    echo "Compiler changed ($CACHED_CXX -> $CURRENT_CXX), clearing CMake cache";
    rm -f "${BUILD_BASE_DIR}/CMakeCache.txt";
  fi
fi

if [ "$ENABLE_SCCACHE" = "ON" ]; then
  if [ -n "${SCCACHE_NO_DIST_COMPILE:-}" ]; then
    export SCCACHE_NO_DIST_COMPILE=1;
  fi
  bash /sccache_setup.sh;
  EXTRA_CMAKE_FLAGS="${EXTRA_CMAKE_FLAGS} -DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache -DCMAKE_CUDA_COMPILER_LAUNCHER=sccache";
  export NVCC_APPEND_FLAGS="${NVCC_APPEND_FLAGS:+$NVCC_APPEND_FLAGS }-t=100";
fi

make --directory="/presto_native_staging/presto" cmake-and-build BUILD_TYPE=${BUILD_TYPE} BUILD_DIR="" BUILD_BASE_DIR=${BUILD_BASE_DIR};

if [ "${S3_DIRECT_RECEIVE}" = "ON" ]; then
  grep -Fx 'VELOX_ENABLE_S3_DIRECT_RECEIVE:BOOL=ON' "${BUILD_BASE_DIR}/CMakeCache.txt";
  grep -E '^CURL_DIR:(PATH|UNINITIALIZED)=/opt/presto-s3-direct/lib/cmake/CURL$' \
    "${BUILD_BASE_DIR}/CMakeCache.txt";
  grep -E '^AWSSDK_DIR:(PATH|UNINITIALIZED)=/opt/presto-s3-direct/lib/cmake/AWSSDK$' \
    "${BUILD_BASE_DIR}/CMakeCache.txt";
fi;

if [ "$ENABLE_SCCACHE" = "ON" ]; then
  echo "Post-build sccache statistics:";
  sccache --show-adv-stats;
fi

PRESTO_SERVER=${BUILD_BASE_DIR}/presto_cpp/main/presto_server;
LDD_LIBRARY_PATH="${LD_LIBRARY_PATH:+${LD_LIBRARY_PATH}:}/usr/local/lib";
ldd_output=$(LD_LIBRARY_PATH="${LDD_LIBRARY_PATH}" ldd "${PRESTO_SERVER}");
! grep "not found" <<<"${ldd_output}" | grep -v -E "libcuda\.so|libnvidia";
# A direct worker inherits the complete isolated prefix from its dependency
# image. Keep that prefix canonical instead of copying duplicate SONAMEs into
# the generic runtime closure. A future separate runtime stage must copy the
# prefix intact.
awk -v direct_mode="${S3_DIRECT_RECEIVE}" \
  -v direct_prefix="${S3_DIRECT_RECEIVE_PREFIX}/lib/" \
  'NF == 4 && $3 != "not" && $1 !~ /libcuda\.so|libnvidia/ && !(direct_mode == "ON" && index($3, direct_prefix) == 1) { print $3 }' \
  <<<"${ldd_output}" | sort -u | xargs -r -I{} cp -L "{}" /runtime-libraries/;

if [ "${S3_DIRECT_RECEIVE}" = "ON" ]; then
  mapfile -t resolved_curls < <(
    awk '$1 == "libcurl.so.4" { print $3 }' <<<"${ldd_output}"
  );
  [ "${#resolved_curls[@]}" -eq 1 ];
  resolved_curl=$(readlink -f "${resolved_curls[0]}");
  case "${resolved_curl}" in
    "${S3_DIRECT_RECEIVE_PREFIX}"/lib/*) ;;
    *)
      echo "Direct build did not resolve the isolated libcurl: ${resolved_curl}" >&2;
      exit 1;
      ;;
  esac;
  nm -D --defined-only "${resolved_curl}" |
    awk '$3 == "curl_recv_buffer_build_version_v1" { found = 1 } END { exit !found }';
  nm -D --defined-only "${resolved_curl}" |
    awk '$3 == "curl_ktls_direct_rx_build_version_v1" { found = 1 } END { exit !found }';
fi;
cp "${PRESTO_SERVER}" /usr/bin;
EOF

RUN set -euxo pipefail; \
    mkdir /usr/lib64/presto-native-libs && \
    cp -a /runtime-libraries/. /usr/lib64/presto-native-libs/ && \
    echo "/usr/lib64/presto-native-libs" > /etc/ld.so.conf.d/presto_native.conf && \
    ldconfig && \
    if [ "${S3_DIRECT_RECEIVE}" = "ON" ]; then \
      direct_prefix=/opt/presto-s3-direct/lib; \
      ldd_output=$(ldd /usr/bin/presto_server); \
      ! grep "not found" <<<"${ldd_output}" | grep -v -E "libcuda\.so|libnvidia"; \
      mapfile -t resolved_curls < <(awk '$1 == "libcurl.so.4" { print $3 }' <<<"${ldd_output}"); \
      [ "${#resolved_curls[@]}" -eq 1 ]; \
      resolved_curl=$(readlink -f "${resolved_curls[0]}"); \
      case "${resolved_curl}" in \
        "${direct_prefix}"/*) ;; \
        *) echo "Runtime resolved libcurl outside ${direct_prefix}: ${resolved_curl}" >&2; exit 1 ;; \
      esac; \
      for soname in libaws-cpp-sdk-core.so libaws-cpp-sdk-s3.so; do \
        mapfile -t resolved_aws < <(awk -v soname="${soname}" '$1 == soname { print $3 }' <<<"${ldd_output}"); \
        [ "${#resolved_aws[@]}" -eq 1 ]; \
        resolved_aws_library=$(readlink -f "${resolved_aws[0]}"); \
        case "${resolved_aws_library}" in \
          "${direct_prefix}"/*) ;; \
          *) echo "Runtime resolved ${soname} outside ${direct_prefix}: ${resolved_aws_library}" >&2; exit 1 ;; \
        esac; \
      done; \
      nm -D --defined-only "${resolved_curl}" | \
        awk '$3 == "curl_recv_buffer_build_version_v1" { found = 1 } END { exit !found }'; \
      nm -D --defined-only "${resolved_curl}" | \
        awk '$3 == "curl_ktls_direct_rx_build_version_v1" { found = 1 } END { exit !found }'; \
      aws_core=$(awk '$1 == "libaws-cpp-sdk-core.so" { print $3 }' <<<"${ldd_output}"); \
      nm -D -C --defined-only "${aws_core}" | \
        grep -F 'Aws::Http::GetDirectResponseReceiveApiVersionV2()' >/dev/null; \
      nm -D -C --defined-only "${aws_core}" | \
        grep -F 'Aws::Http::GetDirectResponseReceiveStrictKernelTlsApiVersionV1()' >/dev/null; \
    fi

COPY velox-testing/presto/docker/launch_presto_servers.sh velox-testing/presto/docker/presto_profiling_wrapper.sh /opt

CMD ["bash", "/opt/presto_profiling_wrapper.sh"]
