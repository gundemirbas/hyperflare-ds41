#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Local container registry on the control node. Every serving host pulls the node
# image from it, so a rebuilt image reaches the cluster without shipping a tarball.
#
#   ./registry.sh start|stop|status
set -eu

cd "$(dirname "$0")"
. ./cluster.env
. ./lib.sh

IMAGE=registry:2
NAME=flare-registry
VOLUME=flare-registry-data

# The control node runs docker; a host that only has podman still works.
if command -v docker >/dev/null 2>&1; then
    runtime=docker
else
    runtime=podman
fi

case "${1:-status}" in
    start)
        note "registry on ${REGISTRY} (${runtime})"
        if [ "${runtime}" = "docker" ]; then
            "${runtime}" volume inspect "${VOLUME}" >/dev/null 2>&1 || "${runtime}" volume create "${VOLUME}" >/dev/null
            if "${runtime}" container inspect "${NAME}" >/dev/null 2>&1; then
                "${runtime}" start "${NAME}" >/dev/null
            else
                "${runtime}" run -d --name "${NAME}" --restart unless-stopped \
                    --publish 5000:5000 \
                    --volume "${VOLUME}:/var/lib/registry" \
                    "${IMAGE}" >/dev/null
            fi
        else
            "${runtime}" volume exists "${VOLUME}" 2>/dev/null || "${runtime}" volume create "${VOLUME}" >/dev/null
            if "${runtime}" container exists "${NAME}"; then
                "${runtime}" start "${NAME}" >/dev/null
            else
                "${runtime}" run -d --name "${NAME}" --restart unless-stopped \
                    --publish 5000:5000 \
                    --volume "${VOLUME}:/var/lib/registry" \
                    "${IMAGE}" >/dev/null
            fi
        fi
        sleep 3
        curl -fsS "http://localhost:5000/v2/" >/dev/null \
            && step "api reachable" \
            || fatal "registry did not answer on localhost:5000"
        ;;
    stop)
        "${runtime}" stop "${NAME}" >/dev/null 2>&1 || true
        step "stopped"
        ;;
    status)
        "${runtime}" ps --filter "name=${NAME}" --format '{{.Names}} {{.Status}}' 2>/dev/null | grep . || echo "not running"
        curl -fsS "http://localhost:5000/v2/_catalog" 2>/dev/null || true
        echo
        ;;
    *) fatal "usage: $0 start|stop|status" ;;
esac
