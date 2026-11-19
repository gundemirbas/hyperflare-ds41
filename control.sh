#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# The control plane: the Selene pool manager every serving rank attaches to,
# running as a rootless podman container on the control node. `ensure` builds the
# image when it is missing, installs the user unit and starts it.
#
#   ./control.sh ensure|status|stop|logs
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

IMAGE=localhost/flare-control-plane:latest
UNIT=flare-control-plane.service

pool_answers() {
    curl -fsS --max-time 3 "http://127.0.0.1:9200/" >/dev/null 2>&1 \
        || timeout 2 bash -c '</dev/tcp/127.0.0.1/9200' 2>/dev/null
}

case "${1:-ensure}" in
    ensure)
        note "control plane on ${CONTROL_HOST}"
        if ! ssh_to "${CONTROL_HOST}" "podman image exists ${IMAGE}"; then
            step "image missing, building from control-plane/"
            ssh_to "${CONTROL_HOST}" 'rm -rf ~/flare-build-control && mkdir -p ~/flare-build-control'
            scp -q "${HERE}/control-plane/Containerfile" \
                   "${HERE}/control-plane/entrypoint.sh" \
                   "${HERE}/control-plane/flare-control-plane.service" \
                   "${SSH_USER}@${CONTROL_HOST}:~/flare-build-control/"
            ssh_to "${CONTROL_HOST}" \
                "cd ~/flare-build-control && podman build --build-arg FLARE_COMMIT=${COMMIT} -t ${IMAGE} ."
        fi
        # The unit travels with every ensure so an existing image still installs it.
        ssh_to "${CONTROL_HOST}" 'mkdir -p ~/flare-build-control'
        copy_to "${CONTROL_HOST}" "${HERE}/control-plane/${UNIT}" "${HOME}/flare-build-control/${UNIT}"
        ssh_to "${CONTROL_HOST}" "install -m 0644 ~/flare-build-control/${UNIT} ~/.config/systemd/user/;
            systemctl --user daemon-reload || true;
            systemctl --user enable ${UNIT} >/dev/null 2>&1 || true;
            systemctl --user restart ${UNIT}"
        sleep 6
        ssh_to "${CONTROL_HOST}" 'systemctl --user is-active '"${UNIT}"' | sed "s/^/   /"'
        ssh_to "${CONTROL_HOST}" 'ss -ltn | grep -cE ":9200|:9201"' \
            | awk '{print "   listening sockets: "$1}'
        ;;
    status)
        ssh_to "${CONTROL_HOST}" 'systemctl --user is-active '"${UNIT}"'; podman ps --format "{{.Names}} {{.Status}}" | grep flare || true'
        ;;
    stop)
        ssh_to "${CONTROL_HOST}" 'systemctl --user stop '"${UNIT}"' 2>/dev/null || true; podman rm -f flare-control-plane >/dev/null 2>&1 || true; echo "   stopped"'
        ;;
    logs)
        ssh_to "${CONTROL_HOST}" 'podman logs --tail 20 flare-control-plane'
        ;;
    *)
        fatal "usage: $0 ensure|status|stop|logs"
        ;;
esac
