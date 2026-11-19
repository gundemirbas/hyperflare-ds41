#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Build the node image on the serving host whose architecture matches, tagged
# with the resolved commit. Re-running this after a repository update is the
# whole build step; rollout.sh carries the image to the other hosts.
#
#   ./build.sh              # build ${COMMIT}
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
image="flare-node:${short}"
note "building ${image} on ${BUILD_HOST}"

# The image clones the source itself, so the build context carries only the
# Containerfile and its entrypoint.
ssh_to "${BUILD_HOST}" 'rm -rf ~/flare-build-node && mkdir -p ~/flare-build-node'
copy_to "${BUILD_HOST}" "${HERE}/node/Containerfile" "${HOME}/flare-build-node/Containerfile"
copy_to "${BUILD_HOST}" "${HERE}/node/entrypoint.sh" "${HOME}/flare-build-node/entrypoint.sh"
ssh_to "${BUILD_HOST}" \
    "cd ~/flare-build-node && docker build -f Containerfile --build-arg FLARE_COMMIT=${sha} -t ${image} ."

echo "${short}" > "${HERE}/.last-build"
note "built"
step "${image}"
