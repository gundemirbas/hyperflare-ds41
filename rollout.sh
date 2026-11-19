#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Pull the node image on every serving host, take the native binary out of it and
# install it, then refresh the Orbit agent. The previous binary is kept so
# `./rollback.sh` can put it back.
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
image="${REGISTRY}/flare-node:${short}"
note "rollout ${image}"

for host in ${NODES}; do
    note "${host}"

    scp -q "${HERE}/node/ensure-registry-trust.sh" "${SSH_USER}@${host}:/tmp/ensure-registry-trust.sh"
    ssh_to "${host}" "sudo sh /tmp/ensure-registry-trust.sh ${REGISTRY}"

    ssh_to "${host}" "docker pull -q ${image} >/dev/null && echo '   image pulled'"

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
