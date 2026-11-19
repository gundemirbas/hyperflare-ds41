#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Put the node image on every serving host, take the native binary out of it and
# install it, then refresh the Orbit agent. The previous binary is kept so
# `./deploy.sh rollback` can put it back.
#
# A host without the image receives it from the build host over the cluster
# network; there is no registry.
#
#   ./rollout.sh            # the tag recorded by the last build
#   ./rollout.sh <short-sha>
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

short=${1:-$(cat "${HERE}/.last-build" 2>/dev/null || echo "")}
[ -n "${short}" ] || fatal "no build recorded; run ./build.sh or pass a tag"
image="flare-node:${short}"
note "rollout ${image}"

ssh_to "${BUILD_HOST}" "docker image inspect ${image} >/dev/null 2>&1" \
    || fatal "${image} is not on ${BUILD_HOST}; run ./build.sh first"

for host in ${NODES}; do
    note "${host}"

    if ! ssh_to "${host}" "docker image inspect ${image} >/dev/null 2>&1"; then
        step "sending the image from ${BUILD_HOST}"
        ssh_to "${BUILD_HOST}" \
            "docker save ${image} | ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${SSH_USER}@${host} docker load > /dev/null"
    fi

    ssh_to "${host}" "
        set -e
        docker rm -f flare-extract >/dev/null 2>&1 || true
        docker create --name flare-extract ${image} >/dev/null
        docker cp flare-extract:/usr/local/bin/flare /tmp/flare-new >/dev/null
        docker rm -f flare-extract >/dev/null
        chmod 0755 /tmp/flare-new
        sudo mkdir -p /opt/flare-previous
        if [ -f /usr/bin/flare ]; then sudo cp -a /usr/bin/flare /opt/flare-previous/flare; fi
        sudo install -m 0755 /tmp/flare-new /usr/bin/flare
        printf '   %s\n' \"\$(/usr/bin/flare --version 2>&1 | head -1)\"
        /usr/bin/flare agent install >/dev/null 2>&1 && echo '   agent refreshed'
    "
done

note "rollout complete on $(echo ${NODES} | wc -w) hosts"
