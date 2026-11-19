#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers. Every script sources this after cluster.env.

set -eu

fatal() { echo "error: $*" >&2; exit 1; }
note() { echo "== $*"; }
step() { echo "   $*"; }

# ssh_to HOST COMMAND...  runs a command on another host as SSH_USER, or locally
# when HOST is this machine, so the control node never SSHes to itself.
ssh_to() {
    host=$1
    shift
    if [ "${host}" = "${CONTROL_HOST}" ]; then
        sh -c "$*"
    else
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "$@"
    fi
}

# local_host  prints the first management address; advisory only, because a
# node with both wired and wireless addresses may report either one.
local_host() {
    ip -4 -o addr show 2>/dev/null \
        | awk '$2 !~ /^(lo|docker)/ && $4 ~ /^192\.168\.0\./ { sub(/\/.*/, "", $4); print $4; exit }'
}

# commit_sha COMMIT  resolves a branch or tag to a full commit on the build host.
commit_sha() {
    ssh_to "${BUILD_HOST}" \
        "git ls-remote https://github.com/NVIDIA/hyperflare-inference.git '$1' | head -1 | cut -f1"
}

# copy_to HOST SOURCE DEST  copies a file, staying local for the control host so
# the control node never scp's to itself.
copy_to() {
    host=$1
    src=$2
    dest=$3
    if [ "${host}" = "${CONTROL_HOST}" ]; then
        mkdir -p "$(dirname "${dest}")"
        cp -f "${src}" "${dest}"
    else
        scp -q "${src}" "${SSH_USER}@${host}:${dest}"
    fi
}

# wait_health HOST ATTEMPTS  polls the HTTP health endpoint on rank zero.
wait_health() {
    host=$1
    attempts=${2:-60}
    i=0
    while [ "${i}" -lt "${attempts}" ]; do
        code=$(ssh_to "${host}" \
            'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8000/health' 2>/dev/null || true)
        [ "${code}" = "200" ] && { step "health 200 after $((i * 5))s"; return 0; }
        i=$((i + 1))
        sleep 5
    done
    return 1
}

# first_node  prints the rank-zero host.
first_node() { echo "${NODES}" | awk '{print $1}'; }
