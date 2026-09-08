#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d "${SCRIPT_DIR}/.verify_ucx_runtime_test.XXXXXX")
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

HASH=$(printf 'a%.0s' {1..64})
MARKERS="${TEST_ROOT}/markers"
LIB_DIR="${TEST_ROOT}/lib"
BIN_DIR="${TEST_ROOT}/bin"
UCX_CMAKE_DIR="${LIB_DIR}/cmake/ucx"
mkdir -p "$MARKERS" "${LIB_DIR}/ucx" "$UCX_CMAKE_DIR" "$BIN_DIR"
printf '1.22.0\n' > "${MARKERS}/requested_version"
printf '%s\n' "$HASH" > "${MARKERS}/local_source_hash"
touch "${LIB_DIR}/libucm.so.0" \
  "${LIB_DIR}/libucp.so.0" \
  "${LIB_DIR}/libucs.so.0" \
  "${LIB_DIR}/libuct.so.0" \
  "${LIB_DIR}/ucx/libuct_cuda.so" \
  "${LIB_DIR}/ucx/libuct_ib_efa.so"
touch "${UCX_CMAKE_DIR}/ucx-config.cmake" \
  "${UCX_CMAKE_DIR}/ucx-config-version.cmake" \
  "${UCX_CMAKE_DIR}/ucx-targets.cmake"
for library in libucm libucp libucs libuct; do
  ln -s "${library}.so.0" "${LIB_DIR}/${library}.so"
done
for artifact in \
  libucm.so \
  libucp.so \
  libucs.so \
  libuct.so \
  ucx/libuct_cuda.so \
  ucx/libuct_ib_efa.so; do
  resolved=$(readlink -f "${LIB_DIR}/${artifact}")
  digest=$(sha256sum "$resolved" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$artifact" >> "${MARKERS}/installed_artifacts.sha256"
done
sha256sum "${MARKERS}/installed_artifacts.sha256" | awk '{print $1}' \
  > "${MARKERS}/installed_artifacts_manifest_sha256"

cat > "${BIN_DIR}/ucx_info" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -v ]]; then
  printf '# Library version: %s\n# Library path: %s\n' \
    "${FAKE_UCX_VERSION:-1.22.0}" "${FAKE_UCX_LIBRARY}"
else
  cat <<DEVICES
# Transport: cuda_copy
#    Device: cuda
# Transport: cuda_ipc
#    Device: cuda
# Transport: srd
#    Device: rdmap0s0:1
# Transport: tcp
#    Device: enp1s0
DEVICES
fi
EOF
cat > "${BIN_DIR}/ldd" <<'EOF'
#!/usr/bin/env bash
if [[ ${FAKE_LDD_FAIL:-false} == true ]]; then
  echo 'mock ldd failure' >&2
  exit 42
fi
if [[ -n ${FAKE_LDD_UNRESOLVED:-} ]]; then
  printf '%s => not found\n' "$FAKE_LDD_UNRESOLVED"
fi
exit 0
EOF
chmod +x "${BIN_DIR}/ucx_info" "${BIN_DIR}/ldd"

export PATH="${BIN_DIR}:${PATH}"
export FAKE_UCX_LIBRARY="${LIB_DIR}/libucs.so.0"
export PRESTO_UCX_INFO="${BIN_DIR}/ucx_info"
export PRESTO_UCX_MARKER_DIR="$MARKERS"
export PRESTO_EXPECTED_UCX_VERSION=1.22.0
export PRESTO_EXPECTED_UCX_SOURCE_HASH="$HASH"
export UCX_NET_DEVICES='rdmap0s0:1,enp1s0'
export UCX_TLS='tcp,srd,cuda_copy'

"${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check
"${SCRIPT_DIR}/verify_ucx_runtime.sh"

rm "${UCX_CMAKE_DIR}/ucx-config.cmake"
if "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted a missing UCX CMake package' >&2
  exit 1
fi
touch "${UCX_CMAKE_DIR}/ucx-config.cmake"

rm "${LIB_DIR}/ucx/libuct_cuda.so"
if "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted a missing CUDA module' >&2
  exit 1
fi
touch "${LIB_DIR}/ucx/libuct_cuda.so"

rm "${LIB_DIR}/ucx/libuct_ib_efa.so"
if "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted a missing EFA module' >&2
  exit 1
fi
touch "${LIB_DIR}/ucx/libuct_ib_efa.so"

printf 'tampered\n' >> "${LIB_DIR}/ucx/libuct_cuda.so"
if "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted UCX artifacts that differ from image provenance' >&2
  exit 1
fi
: > "${LIB_DIR}/ucx/libuct_cuda.so"

if PRESTO_EXPECTED_UCX_VERSION=1.21.0 \
  "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted the wrong expected UCX version' >&2
  exit 1
fi

if PRESTO_EXPECTED_UCX_SOURCE_HASH=$(printf 'b%.0s' {1..64}) \
  "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted the wrong exact UCX source hash' >&2
  exit 1
fi

if FAKE_UCX_VERSION=1.21.0 \
  "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted a mismatched loaded UCX version' >&2
  exit 1
fi

if UCX_NET_DEVICES='rdmap-missing:1' \
  "${SCRIPT_DIR}/verify_ucx_runtime.sh" >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted an unavailable requested UCX device' >&2
  exit 1
fi

if UCX_TLS='tcp,cuda_copy' \
  "${SCRIPT_DIR}/verify_ucx_runtime.sh" >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted EFA mode without SRD selected' >&2
  exit 1
fi

if UCX_TLS='tcp,srd' \
  "${SCRIPT_DIR}/verify_ucx_runtime.sh" >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted EFA mode without CUDA copy selected' >&2
  exit 1
fi

if FAKE_LDD_FAIL=true \
  "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted a failed plugin dependency inspection' >&2
  exit 1
fi

if FAKE_LDD_UNRESOLVED=libfabric.so.1 \
  "${SCRIPT_DIR}/verify_ucx_runtime.sh" --build-check >/dev/null 2>&1; then
  echo 'FAIL: verifier accepted an unresolved non-driver dependency' >&2
  exit 1
fi

echo 'verify_ucx_runtime_test.sh: PASS'
