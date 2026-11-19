#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Produce a new core from the checkpoint, entirely inside the node image: rank
# zero exports on the first host and the peers join. The checkpoint is mounted
# over SSHFS rather than copied, so the host disk stays free for the core.
#
#   ./prepare.sh          # mount, run both sides, wait, print the core path
#   ./prepare.sh --start  # start the containers and return
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

wait_after=${1:-}
short=$(cat "${HERE}/.last-build" 2>/dev/null || echo "")
[ -n "${short}" ] || fatal "no build recorded; run ./build.sh first"
image="flare-node:${short}"

rank0=$(first_node)
rendezvous="${rank0}:29630"

# Preparation peers authenticate their checkpoint transfers with one shared
# credential that has to be identical on every host and private to its owner.
note "preparation credential"
token=$(ssh_to "${rank0}" '
    set -e
    f=$HOME/.config/flare/agent.token
    if [ ! -s "$f" ]; then
        mkdir -p "$(dirname "$f")"
        head -c 48 /dev/urandom | base64 | tr -d "\n" > "$f"
        chmod 600 "$f"
    fi
    chmod 600 "$f"
    cat "$f"
')
[ ${#token} -ge 32 ] || fatal "checkpoint token is shorter than 32 bytes"
for host in ${NODES}; do
    ssh_to "${host}" "mkdir -p \$HOME/.config/flare \$HOME/.cache/flare && printf '%s' '${token}' > \$HOME/.config/flare/agent.token && chmod 600 \$HOME/.config/flare/agent.token"
done
step "shared on $(echo ${NODES} | wc -w) hosts"

note "checkpoint mount on ${rank0}"
ssh_to "${rank0}" "
    set -e
    mountpoint -q '${CHECKPOINT_MOUNT}' && { echo '   already mounted'; exit 0; }
    mkdir -p '${CHECKPOINT_MOUNT}'
    command -v sshfs >/dev/null || { echo 'sshfs missing on this host' >&2; exit 1; }
    grep -q '^user_allow_other' /etc/fuse.conf || echo user_allow_other | sudo tee -a /etc/fuse.conf >/dev/null
    sshfs '${CHECKPOINT_SSH}' '${CHECKPOINT_MOUNT}' -o ro,allow_other,reconnect,ServerAliveInterval=15,StrictHostKeyChecking=no
    echo '   mounted read-only'
"

note "rank zero export on ${rank0}"
ssh_to "${rank0}" "
    docker rm -f flare-export >/dev/null 2>&1 || true
    docker run -d --name flare-export --gpus all --network=host --privileged \
        --ulimit memlock=-1:-1 \
        --user \$(id -u):\$(id -g) -e HOME=\$HOME \
        --volume '${CHECKPOINT_MOUNT}:/checkpoint:ro' \
        --volume \$HOME/.cache:\$HOME/.cache \
        --volume \$HOME/.config/flare:\$HOME/.config/flare \
        '${image}' export /checkpoint --gpus 0 --ranks 3 --rendezvous '${rendezvous}' \
        --max-concurrency '${CONCURRENCY}' --speculative-token-capacity '${SPECULATIVE_TOKEN_CAPACITY}' --verbose
    echo '   container started'
"

rank=1
for host in ${NODES}; do
    [ "${host}" = "${rank0}" ] && continue
    note "rank ${rank} join on ${host}"
    ssh_to "${host}" "
        docker rm -f flare-join >/dev/null 2>&1 || true
        docker run -d --name flare-join --gpus all --network=host --privileged \
            --ulimit memlock=-1:-1 \
            --user \$(id -u):\$(id -g) -e HOME=\$HOME \
            --volume \$HOME/.cache:\$HOME/.cache \
            --volume \$HOME/.config/flare:\$HOME/.config/flare \
            '${image}' join --rank ${rank} --ranks 3 '${rendezvous}' --gpu 0
        echo '   container started'
    "
    rank=$((rank + 1))
done

[ "${wait_after}" = "--start" ] && { note "started; follow with docker logs"; exit 0; }

note "waiting for preparation to finish (this takes hours)"
while ssh_to "${rank0}" 'docker ps --format "{{.Names}}" | grep -qx flare-export'; do
    sleep 60
    ssh_to "${rank0}" 'docker logs --tail 1 flare-export 2>&1 | tail -1' | sed 's/^/   /'
done

code=$(ssh_to "${rank0}" 'docker inspect -f "{{.State.ExitCode}}" flare-export' 2>/dev/null || echo unknown)
[ "${code}" = "0" ] || fatal "export exited with ${code}; see docker logs flare-export"
note "export finished; newest core:"
ssh_to "${rank0}" 'ls -1dt $HOME/.cache/flare/cores/models/*/* 2>/dev/null | head -1' | sed 's/^/   /'
