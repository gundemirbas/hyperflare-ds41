#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# One entry point for the whole control plane. Run it on the control node.
#
#   ./deploy.sh registry     start the local registry
#   ./deploy.sh control      start the control plane (Selene pool)
#   ./deploy.sh cleanup      reclaim disk on the serving hosts
#   ./deploy.sh build        build both images at ${COMMIT} and push
#   ./deploy.sh rollout      pull the node image, install the binary, refresh agents
#   ./deploy.sh pair         install agents and pair every host with the controller
#   ./deploy.sh archive      copy the complete core onto the control node
#   ./deploy.sh stage        place the newest core on every host ahead of a launch
#   ./deploy.sh prepare      produce a new core from the checkpoint (hours)
#   ./deploy.sh up|down      start or stop the Orbit group
#   ./deploy.sh status       group and node status
#   ./deploy.sh rollback     restore the previous binary and restart the group
#   ./deploy.sh all          registry, build, rollout, up
#   ./deploy.sh all --with-export   the same, plus prepare
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

command=${1:-status}
shift 2>/dev/null || true

case "${command}" in
    registry) ./registry.sh start ;;
    control)  ./control.sh "${1:-ensure}" ;;
    cleanup)  ./cleanup.sh "$@" ;;
    build)    ./build.sh "$@" ;;
    rollout)  ./rollout.sh "$@" ;;
    pair)     ./pair.sh ;;
    stage)    ./stage.sh "$@" ;;
    archive)  ./archive.sh "$@" ;;
    prepare)  ./prepare.sh "$@" ;;
    up)       ./group.sh up ;;
    down)     ./group.sh down ;;
    status)   ./group.sh status ;;
    health)   ./group.sh health ;;
    rollback)
        note "restoring the previous binary"
        for host in ${NODES}; do
            ssh_to "${host}" "
                set -e
                if sudo test -f /opt/flare-previous/flare; then
                    sudo install -m 0755 /opt/flare-previous/flare /usr/bin/flare
                    /usr/bin/flare agent install >/dev/null 2>&1 || true
                    printf '   %s %s\n' '${host}' \"\$(/usr/bin/flare --version 2>&1 | head -1)\"
                else
                    printf '   %s no previous binary\n' '${host}'
                fi
            "
        done
        ./group.sh up
        ;;
    all)
        ./registry.sh start
        ./control.sh ensure
        ./build.sh
        ./rollout.sh
        ./pair.sh
        if [ "${1:-}" = "--with-export" ]; then ./prepare.sh; fi
        ./group.sh up
        ./cleanup.sh
        ;;
    *)
        fatal "unknown command ${command}; see the header of $0"
        ;;
esac
