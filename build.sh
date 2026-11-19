#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Build both images and push them to the registry, tagged with the resolved
# commit. Re-running this after a repository update is the whole build step.
#
#   ./build.sh              # build the tip of ${COMMIT}
#   ./build.sh <sha-or-tag> # build a specific revision
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

revision=${1:-${COMMIT}}
sha=$(commit_sha "${revision}")
[ -n "${sha}" ] || fatal "cannot resolve ${revision}"
short=$(echo "${sha}" | cut -c1-8)
note "building revision ${short}"

# Both images clone the source themselves, so the build context carries only the
# Containerfile and its entrypoint.
note "node image on ${BUILD_HOST} (aarch64)"
ssh_to "${BUILD_HOST}" 'rm -rf ~/flare-build-node && mkdir -p ~/flare-build-node'
copy_to "${BUILD_HOST}" "${HERE}/node/Containerfile" "${HOME}/flare-build-node/Containerfile"
copy_to "${BUILD_HOST}" "${HERE}/node/entrypoint.sh" "${HOME}/flare-build-node/entrypoint.sh" 2>/dev/null || true
ssh_to "${BUILD_HOST}" \
    "cd ~/flare-build-node && docker build --build-arg FLARE_COMMIT=${sha} -t ${REGISTRY}/flare-node:${short} ."
ssh_to "${BUILD_HOST}" "docker push ${REGISTRY}/flare-node:${short}"

note "control-plane image on ${CONTROL_HOST} (x86_64)"
ssh_to "${CONTROL_HOST}" 'rm -rf ~/flare-build-control && mkdir -p ~/flare-build-control'
copy_to "${CONTROL_HOST}" "${HERE}/control-plane/Containerfile" "${HOME}/flare-build-control/Containerfile"
copy_to "${CONTROL_HOST}" "${HERE}/control-plane/entrypoint.sh" "${HOME}/flare-build-control/entrypoint.sh"
ssh_to "${CONTROL_HOST}" \
    "cd ~/flare-build-control && podman build --build-arg FLARE_COMMIT=${sha} -t ${REGISTRY}/flare-control-plane:${short} ."
ssh_to "${CONTROL_HOST}" "podman push ${REGISTRY}/flare-control-plane:${short}"

note "pushed"
step "flare-node:${short}"
step "flare-control-plane:${short}"
echo "${short}" > "${HERE}/.last-build"
