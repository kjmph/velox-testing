# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

ARG BASE_DEPENDENCY_BUILD_IMAGE
FROM ${BASE_DEPENDENCY_BUILD_IMAGE} AS s3-direct-builder

ARG EXPECTED_CURL_COMMIT
ARG EXPECTED_AWS_SDK_COMMIT
ARG INSTALLER_SOURCE_SHA256

COPY velox/scripts /opt/presto-s3-direct-build/scripts

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
RUN source /opt/presto-s3-direct-build/scripts/setup-common.sh && \
    [[ ${S3_DIRECT_RECEIVE_CURL_COMMIT} == "${EXPECTED_CURL_COMMIT}" ]] && \
    [[ ${S3_DIRECT_RECEIVE_AWS_SDK_COMMIT} == "${EXPECTED_AWS_SDK_COMMIT}" ]] && \
    actual_installer_hash=$( \
      cd /opt/presto-s3-direct-build && \
      find scripts \( -type f -o -type l \) -print0 | \
        LC_ALL=C sort -z | \
        xargs -0 sha256sum | \
        sha256sum | \
        awk '{print $1}' \
    ) && \
    [[ ${actual_installer_hash} == "${INSTALLER_SOURCE_SHA256}" ]] && \
    export DEPENDENCY_DIR=/opt/presto-s3-direct-build/dependencies && \
    export S3_DIRECT_RECEIVE_INSTALL_PREFIX=/opt/presto-s3-direct && \
    install_s3_direct_receive_deps && \
    rm -rf /opt/presto-s3-direct-build/dependencies

FROM ${BASE_DEPENDENCY_BUILD_IMAGE}

ARG BASE_DEPENDENCY_IMAGE
ARG BASE_DEPENDENCY_IMAGE_ID
ARG EXPECTED_CURL_COMMIT
ARG EXPECTED_AWS_SDK_COMMIT
ARG INSTALLER_SOURCE_SHA256

LABEL io.prestodb.s3-direct-receive.base-image="${BASE_DEPENDENCY_IMAGE}"
LABEL io.prestodb.s3-direct-receive.base-image-id="${BASE_DEPENDENCY_IMAGE_ID}"
LABEL io.prestodb.s3-direct-receive.installer-source-sha256="${INSTALLER_SOURCE_SHA256}"
LABEL io.prestodb.s3-direct-receive.curl-commit="${EXPECTED_CURL_COMMIT}"
LABEL io.prestodb.s3-direct-receive.aws-sdk-commit="${EXPECTED_AWS_SDK_COMMIT}"

COPY --from=s3-direct-builder /opt/presto-s3-direct /opt/presto-s3-direct

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]
RUN curl_library=$(readlink -f /opt/presto-s3-direct/lib/libcurl.so.4) && \
    aws_core_library=$(readlink -f /opt/presto-s3-direct/lib/libaws-cpp-sdk-core.so) && \
    nm -D --defined-only "${curl_library}" | \
      awk '$3 == "curl_recv_buffer_build_version_v1" { found = 1 } END { exit !found }' && \
    nm -D --defined-only "${curl_library}" | \
      awk '$3 == "curl_ktls_direct_rx_build_version_v1" { found = 1 } END { exit !found }' && \
    nm -D -C --defined-only "${aws_core_library}" | \
      grep -F 'Aws::Http::GetDirectResponseReceiveApiVersionV2()' >/dev/null && \
    nm -D -C --defined-only "${aws_core_library}" | \
      grep -F 'Aws::Http::GetDirectResponseReceiveStrictKernelTlsApiVersionV1()' >/dev/null && \
    ldd_output=$( \
      LD_LIBRARY_PATH="/opt/presto-s3-direct/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        ldd "${aws_core_library}" \
    ) && \
    ! grep -F 'not found' <<<"${ldd_output}" && \
    mapfile -t resolved_curls < <( \
      awk '$1 == "libcurl.so.4" { print $3 }' <<<"${ldd_output}" \
    ) && \
    [[ ${#resolved_curls[@]} -eq 1 ]] && \
    [[ $(readlink -f "${resolved_curls[0]}") == "${curl_library}" ]] && \
    mkdir -p /opt/presto-s3-direct/share/presto-s3-direct-receive && \
    printf 'S3_DIRECT_RECEIVE_CURL_COMMIT=%s\nS3_DIRECT_RECEIVE_AWS_SDK_COMMIT=%s\n' \
      "${EXPECTED_CURL_COMMIT}" \
      "${EXPECTED_AWS_SDK_COMMIT}" \
      > /opt/presto-s3-direct/share/presto-s3-direct-receive/build-info.env && \
    printf 'BASE_DEPENDENCY_IMAGE=%s\nBASE_DEPENDENCY_IMAGE_ID=%s\nINSTALLER_SOURCE_SHA256=%s\n' \
      "${BASE_DEPENDENCY_IMAGE}" \
      "${BASE_DEPENDENCY_IMAGE_ID}" \
      "${INSTALLER_SOURCE_SHA256}" \
      >> /opt/presto-s3-direct/share/presto-s3-direct-receive/build-info.env
