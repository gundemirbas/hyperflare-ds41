#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# One entry point for the cluster. Everything runs on the control node and
# reaches the other hosts over SSH.
#
#   ./deploy.sh build        build the node image on the control node
#   ./deploy.sh rollout      put the image and binary on every host, refresh agents
#   ./deploy.sh pair         install each agent and pair it with the controller
#   ./deploy.sh up           launch the group and wait for health
#   ./deploy.sh down         stop the group
#   ./deploy.sh status       group state and health
#   ./deploy.sh controller   keep the group running as a container (start|stop|logs)
#   ./deploy.sh archive      copy the complete core onto the control node
#   ./deploy.sh cleanup      reclaim disk on the serving hosts
#   ./deploy.sh prepare      export and join inside the node image (hours)
#   ./deploy.sh all          build, rollout, pair, up, cleanup
#
# Replacing an agent restarts it, and a restart stops the ranks it supervises, so
# rollout and pair take a running service down; run `up` afterwards.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

CONTROLLER=flare-controller
INTERVAL=60

image_name() {
    short=$(cat "${HERE}/.last-build" 2>/dev/null || echo "")
    if [ -z "${short}" ]; then
        short=$(ssh_to "${CONTROL_HOST}" "docker images --format '{{.Tag}}' flare-node 2>/dev/null | head -1")
    fi
    [ -n "${short}" ] || fatal "no flare-node image; run ./deploy.sh build first"
    echo "flare-node:${short}"
}

cmd_build() {
    revision=${1:-${COMMIT}}
    sha=$(commit_sha "${revision}")
    [ -n "${sha}" ] || fatal "cannot resolve ${revision}"
    short=$(echo "${sha}" | cut -c1-8)
    note "building flare-node:${short} on ${BUILD_HOST}"

    ssh_to "${BUILD_HOST}" 'rm -rf ~/flare-build-node && mkdir -p ~/flare-build-node'
    copy_to "${BUILD_HOST}" "${HERE}/node/Containerfile" "${HOME}/flare-build-node/Containerfile"
    copy_to "${BUILD_HOST}" "${HERE}/node/entrypoint.sh" "${HOME}/flare-build-node/entrypoint.sh"
    ssh_to "${BUILD_HOST}" \
        "cd ~/flare-build-node && docker build -f Containerfile --build-arg FLARE_COMMIT=${sha} -t flare-node:${short} ."

    echo "${short}" > "${HERE}/.last-build"
    step "flare-node:${short}"
}

cmd_rollout() {
    image=$(image_name)
    note "rollout ${image}"
    ssh_to "${BUILD_HOST}" "docker image inspect ${image} >/dev/null 2>&1" \
        || fatal "${image} is not on ${BUILD_HOST}; run ./deploy.sh build first"

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
    step "binary installed on $(echo ${NODES} | wc -w) hosts"
}

cmd_pair() {
    flare=$(flare_bin)
    for host in ${NODES}; do
        note "${host}"
        name=$(ssh_to "${host}" 'hostname')
        code=$(ssh_to "${host}" \
            '/usr/bin/flare agent install 2>&1 | sed -n "s/^join code:[[:space:]]*//p"' | tr -d '\r' | head -1)
        if [ -z "${code}" ]; then
            step "no join code; assuming an existing pairing"
            continue
        fi
        ssh_to "${CONTROL_HOST}" "${flare} orbit forget '${name}' >/dev/null 2>&1 || true"
        ssh_to "${CONTROL_HOST}" "${flare} orbit pair '${name}' --code '${code}'" | sed 's/^/   /'
    done
    note "membership"
    ssh_to "${CONTROL_HOST}" "${flare} orbit status --cluster ${CLUSTER}" \
        | grep -E '^(NODE|thinkstation|gx10)' | sed 's/^/   /'
}

resolve_core() {
    if [ -n "${CORE}" ]; then
        echo "${CORE}"
        return
    fi
    ssh_to "$(first_node)" "ls -1dt ${CORE_ROOT}/models/*/*/model.safetensors 2>/dev/null | head -1"
}

cmd_up() {
    flare=$(flare_bin)
    core=$(resolve_core)
    [ -n "${core}" ] || fatal "no prepared core under ${CORE_ROOT}"
    note "core ${core}"

    node_name=$(ssh_to "$(first_node)" 'hostname')
    ssh_to "${CONTROL_HOST}" "${flare} orbit stop '${GROUP}' --cluster '${CLUSTER}' >/dev/null 2>&1 || true"
    ssh_to "${CONTROL_HOST}" "${flare} orbit rm '${GROUP}' >/dev/null 2>&1 || true"

    note "starting ${GROUP} with ${CONCURRENCY} slots"
    ssh_to "${CONTROL_HOST}" "${flare} orbit run \
        '${node_name}:${core}' --cluster '${CLUSTER}' --name '${GROUP}' --persistent --detach \
        --gpus 0 --tensor-parallel 3 --host 0.0.0.0 --port 8000 \
        --max-concurrency '${CONCURRENCY}' --memory-limit=-1G \
        --prefix-cache-disk '${PREFIX_DISK}' --prefix-cache-disk-limit '${PREFIX_DISK_LIMIT}' \
        --prefix-cache-memory 0 \
        --publisher-keys '${PUBLISHER_KEYS}' \
        --dangerously-accept-publisher '${PUBLISHER_NAMESPACE}' \
        --dangerously-approve-key '${APPROVE_KEY}'" | tail -3

    wait_health "$(first_node)" 90 || fatal "the group did not become healthy"
}

cmd_down() {
    note "stopping ${GROUP}"
    ssh_to "${CONTROL_HOST}" "$(flare_bin) orbit stop '${GROUP}' --cluster '${CLUSTER}'" || true
}

cmd_status() {
    flare=$(flare_bin)
    ssh_to "${CONTROL_HOST}" "${flare} orbit ls --cluster '${CLUSTER}'"
    code=$(ssh_to "$(first_node)" \
        'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8000/health' 2>/dev/null || echo 000)
    step "health ${code}"
}

cmd_controller() {
    action=${1:-start}
    case "${action}" in
        start)
            image=$(image_name)
            cat > /tmp/controller-loop.sh <<LOOP
#!/bin/sh
# Written by deploy.sh. Relaunches the group when it is not running.
while true; do
    if ! /usr/local/bin/flare orbit ls --cluster ${CLUSTER} 2>/dev/null | grep -q running; then
        echo "\$(date -u +%H:%M:%S) group not running; launching"
        (cd ${HERE} && FLARE_BIN=/usr/local/bin/flare ./deploy.sh up) 2>&1 | tail -2
    fi
    sleep ${INTERVAL}
done
LOOP
            copy_to "${CONTROL_HOST}" /tmp/controller-loop.sh "${HOME}/.config/flare/controller-loop.sh"
            note "controller container on ${CONTROL_HOST} (${image})"
            ssh_to "${CONTROL_HOST}" "
                docker rm -f ${CONTROLLER} >/dev/null 2>&1 || true
                docker run -d --name ${CONTROLLER} --restart unless-stopped --network=host \
                    --user \$(id -u):\$(id -g) --volume \$HOME:\$HOME --env HOME=\$HOME \
                    --entrypoint /bin/sh ${image} ${HOME}/.config/flare/controller-loop.sh >/dev/null
                docker ps --filter name=${CONTROLLER} --format '   {{.Names}} {{.Status}}'
            "
            ;;
        stop) ssh_to "${CONTROL_HOST}" "docker rm -f ${CONTROLLER} >/dev/null 2>&1; echo '   removed'" ;;
        logs) ssh_to "${CONTROL_HOST}" "docker logs --tail 20 ${CONTROLLER} 2>&1" ;;
        *) fatal "usage: ./deploy.sh controller start|stop|logs" ;;
    esac
}

cmd_archive() {
    rank0=$(first_node)
    core=${1:-$(resolve_core)}
    [ -n "${core}" ] || fatal "no prepared core"
    source_dir=$(dirname "${core}")
    name=$(basename "${source_dir}")
    dest="${ARCHIVE_ROOT}/${name}"

    note "archiving ${name} onto ${CONTROL_HOST}"
    ssh_to "${CONTROL_HOST}" "mkdir -p '${ARCHIVE_ROOT}'"
    ssh_to "${rank0}" "rsync -a '${source_dir}/' '${SSH_USER}@${CONTROL_HOST}:${dest}/'"
    remote_bytes=$(ssh_to "${rank0}" "du -sb '${source_dir}' | cut -f1")
    local_bytes=$(ssh_to "${CONTROL_HOST}" "du -sb '${dest}' | cut -f1")
    [ "${remote_bytes}" = "${local_bytes}" ] || fatal "archive ${local_bytes} differs from ${remote_bytes}"
    step "verified ${local_bytes} bytes at ${dest}"
}

cmd_cleanup() {
    keep=$(cat "${HERE}/.last-build" 2>/dev/null || echo "")
    rank0=$(first_node)
    note "disk before"
    for host in ${NODES}; do
        ssh_to "${host}" 'df -h / | tail -1 | awk "{print \"   '\"${host}\"' \"\$4\" free\"}"'
    done
    for host in ${NODES}; do
        note "${host}"
        if [ "${host}" = "${rank0}" ]; then
            step "rank zero holds the core; cache roots untouched"
            cache_cleanup=0
        else
            cache_cleanup=1
        fi
        ssh_to "${host}" "
            set -e
            docker ps -aq --filter status=exited | xargs -r docker rm >/dev/null 2>&1 || true
            keep='flare-node:${keep}'
            docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^flare-node:' | while read -r tag; do
                [ \"\$tag\" = \"\$keep\" ] || { docker rmi -f \"\$tag\" >/dev/null 2>&1 || true; echo \"   removed image \$tag\"; }
            done
            if [ '${cache_cleanup}' = '1' ]; then
                if [ -d \"\$HOME/.cache/flare/models\" ] && [ -d \"\$HOME/.cache/flare/cores\" ]; then
                    size=\$(du -sh \$HOME/.cache/flare/cores 2>/dev/null | cut -f1)
                    rm -rf \"\$HOME/.cache/flare/cores\"
                    echo \"   removed stale core root (\$size)\"
                fi
                ls -1dt \$HOME/.cache/flare/models/*/* 2>/dev/null | tail -n +2 | while read -r old; do
                    rm -rf \"\$old\"; echo \"   removed old entry \$old\"
                done
            fi
            df -h / | tail -1 | awk '{print \"   after: \"\$4\" free\"}'
        "
    done
}

case "${1:-status}" in
    build) shift 2>/dev/null || true; cmd_build "$@" ;;
    rollout) cmd_rollout ;;
    pair) cmd_pair ;;
    up) cmd_up ;;
    down) cmd_down ;;
    status) cmd_status ;;
    controller) shift 2>/dev/null || true; cmd_controller "$@" ;;
    archive) shift 2>/dev/null || true; cmd_archive "$@" ;;
    cleanup) cmd_cleanup ;;
    prepare) shift 2>/dev/null || true; exec ./prepare.sh "$@" ;;
    rollback)
        for host in ${NODES}; do
            ssh_to "${host}" "
                if sudo test -f /opt/flare-previous/flare; then
                    sudo install -m 0755 /opt/flare-previous/flare /usr/bin/flare
                    /usr/bin/flare agent install >/dev/null 2>&1 || true
                    printf '   %s restored\n' '${host}'
                fi
            "
        done
        cmd_up
        ;;
    all)
        cmd_build
        cmd_rollout
        cmd_pair
        cmd_up
        cmd_cleanup
        ;;
    *) fatal "usage: ./deploy.sh build|rollout|pair|up|down|status|controller|archive|cleanup|prepare|rollback|all" ;;
esac
