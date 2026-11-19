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

short=$(cat "${HERE}/.last-build" 2>/dev/null || echo "")
if [ -n "${short}" ]; then
    IMAGE=${REGISTRY}/flare-control-plane:${short}
else
    IMAGE=localhost/flare-control-plane:latest
fi
UNIT=flare-control-plane.service

pool_answers() {
    curl -fsS --max-time 3 "http://127.0.0.1:9200/" >/dev/null 2>&1 \
        || timeout 2 bash -c '</dev/tcp/127.0.0.1/9200' 2>/dev/null
}

case "${1:-ensure}" in
    ensure)
        note "control plane on ${CONTROL_HOST}"
        # A recorded tag from a node-only build has no control-plane image behind
        # it; fall back to the local one before building from scratch.
        if ! ssh_to "${CONTROL_HOST}" "podman image exists ${IMAGE}"; then
            local_image=localhost/flare-control-plane:latest
            if [ "${IMAGE}" != "${local_image}" ] && ssh_to "${CONTROL_HOST}" "podman image exists ${local_image}"; then
                step "no ${IMAGE}; using ${local_image}"
                IMAGE=${local_image}
            fi
        fi
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
        # The controller CLI comes out of the image the pool runs, so the grant
        # schema and the placement logic match the agents exactly.
        ssh_to "${CONTROL_HOST}" "
            set -e
            mkdir -p \$HOME/.local/bin
            podman rm -f flare-cli-extract >/dev/null 2>&1 || true
            podman create --name flare-cli-extract '${IMAGE}' >/dev/null
            podman cp flare-cli-extract:/usr/local/bin/flare \$HOME/.local/bin/flare.new >/dev/null
            podman rm -f flare-cli-extract >/dev/null
            chmod 0755 \$HOME/.local/bin/flare.new
            if [ -f \$HOME/.local/bin/flare ]; then cp -f \$HOME/.local/bin/flare \$HOME/.local/bin/flare.previous; fi
            mv -f \$HOME/.local/bin/flare.new \$HOME/.local/bin/flare
            \$HOME/.local/bin/flare --version | sed 's/^/   cli /'
        "
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
