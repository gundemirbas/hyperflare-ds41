#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Drive the Orbit group. `up` brings the Selene pool container first, then defines
# the group from scratch and starts it: `orbit run` inherits unspecified flags
# from a saved group, so reusing a stale definition silently keeps an old core or
# an old pool address.
#
#   ./group.sh up|down|status|health
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

rank0=$(first_node)
controller="${CONTROL_HOST}"

resolve_core() {
    if [ -n "${CORE}" ]; then
        echo "${CORE}"
        return
    fi
    ssh_to "${rank0}" \
        "ls -1dt ${CORE_ROOT}/models/*/*/model.safetensors 2>/dev/null | head -1"
}

case "${1:-status}" in
    up)
        ./control.sh ensure

        core=$(resolve_core)
        [ -n "${core}" ] || fatal "no prepared core under ${CORE_ROOT}"
        note "core ${core}"

        node_name=$(ssh_to "${rank0}" 'hostname')
        # A running group refuses to be redefined, and the saved definition
        # would otherwise donate stale flags to the new launch.
        ssh_to "${controller}" "~/.local/bin/flare orbit stop '${GROUP}' --cluster '${CLUSTER}' >/dev/null 2>&1 || true"
        ssh_to "${controller}" "~/.local/bin/flare orbit rm '${GROUP}' >/dev/null 2>&1 || true"

        note "starting ${GROUP} with ${CONCURRENCY} slots and the pool"
        ssh_to "${controller}" "~/.local/bin/flare orbit run \
            '${node_name}:${core}' \
            --cluster '${CLUSTER}' --name '${GROUP}' --persistent --detach \
            --gpus 0 --tensor-parallel 3 --host 0.0.0.0 --port 8000 \
            --max-concurrency '${CONCURRENCY}' --memory-limit=-1G \
            --prefix-cache-disk '${PREFIX_DISK}' \
            --prefix-cache-disk-limit '${PREFIX_DISK_LIMIT}' \
            --prefix-cache-memory 0 \
            --prefix-cache-pool '${POOL_ADDR}' \
            --publisher-keys '${PUBLISHER_KEYS}' \
            --dangerously-accept-publisher '${PUBLISHER_NAMESPACE}' \
            --dangerously-approve-key '${APPROVE_KEY}'" | tail -3

        wait_health "${rank0}" 90 || fatal "group did not become healthy"
        ;;
    down)
        note "stopping ${GROUP}"
        ssh_to "${controller}" "~/.local/bin/flare orbit stop '${GROUP}' --cluster '${CLUSTER}'" || true
        ;;
    status)
        ssh_to "${controller}" "~/.local/bin/flare orbit ls --cluster '${CLUSTER}'"
        ;;
    health)
        wait_health "${rank0}" 12 || fatal "health is not 200"
        ;;
    *)
        fatal "usage: $0 up|down|status|health"
        ;;
esac
