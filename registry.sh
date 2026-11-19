#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Local container registry on the control node. Rootless podman publishes port
# 5000, which is what the Sparks pull from.
#
#   ./registry.sh start|stop|status
set -eu

cd "$(dirname "$0")"
. ./cluster.env
. ./lib.sh

IMAGE=registry:2
NAME=flare-registry
VOLUME=flare-registry-data

case "${1:-status}" in
    start)
        note "registry on ${REGISTRY}"
        podman volume exists "${VOLUME}" 2>/dev/null || podman volume create "${VOLUME}" >/dev/null
        if podman container exists "${NAME}"; then
            podman start "${NAME}" >/dev/null
        else
            podman run -d --name "${NAME}" \
                --publish 5000:5000 \
                --volume "${VOLUME}:/var/lib/registry" \
                "${IMAGE}" >/dev/null
        fi
        sleep 2
        curl -fsS "http://localhost:5000/v2/" >/dev/null \
            && step "api reachable" \
            || fatal "registry did not answer on localhost:5000"
        ;;
    stop)
        podman stop "${NAME}" >/dev/null 2>&1 || true
        step "stopped"
        ;;
    status)
        if curl -fsS "http://localhost:5000/v2/_catalog" 2>/dev/null; then
            echo
        else
            echo "registry not answering"
        fi
        ;;
    *)
        fatal "usage: $0 start|stop|status"
        ;;
esac
