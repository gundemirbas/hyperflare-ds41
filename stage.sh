#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Place a prepared core on the hosts before a launch.
#
# With --to NODE,...,NODE in rank order, every rank receives its own directory.
# With a single node, that node receives the complete core, which is how an
# archive survives after the source node stops holding the other ranks' payloads.
#
#   ./stage.sh                        # per-rank directories, newest core
#   ./stage.sh --archive 246          # complete core on one host
#   ./stage.sh --core /path/to/core   # a specific core
set -eu

cd "$(dirname "$0")"
. ./cluster.env
. ./lib.sh

archive=""
core=""
while [ $# -gt 0 ]; do
    case "$1" in
        --archive) archive=$2; shift 2 ;;
        --core) core=$2; shift 2 ;;
        *) core=$1; shift ;;
    esac
done

rank0=$(first_node)
[ -n "${core}" ] || core=$(ssh_to "${rank0}" "ls -1dt ${CORE_ROOT}/models/*/*/model.safetensors 2>/dev/null | head -1")
[ -n "${core}" ] || fatal "no prepared core under ${CORE_ROOT}"

if [ -n "${archive}" ]; then
    # Prefer the archive on the control node: a local path is uploaded directly,
    # and it is the copy that survives the source node being trimmed.
    name=$(basename "$(dirname "${core}")")
    local_core="${ARCHIVE_ROOT}/${name}/model.safetensors"
    if ssh_to "${CONTROL_HOST}" "test -f '${local_core}'"; then
        source_path=${local_core}
        step "source: archive on ${CONTROL_HOST}"
    else
        source_path="${rank0}:${core}"
        step "source: ${rank0} (no archive yet; run ./archive.sh)"
    fi
    note "complete core onto ${archive}"
    ssh_to "${CONTROL_HOST}" \
        "~/.local/bin/flare orbit push '${source_path}' --to '${archive}' --cluster '${CLUSTER}'" | tail -4
    note "verified directories"
    ssh_to "${CONTROL_HOST}" "~/.local/bin/flare orbit cores --cluster '${CLUSTER}'" | head -12
    exit 0
fi

note "per-rank directories from ${core}"
targets=$(echo ${NODES} | tr ' ' ',')
ssh_to "${CONTROL_HOST}" \
    "~/.local/bin/flare orbit push '${rank0}:${core}' --to '${targets}' --cluster '${CLUSTER}'" | tail -6

note "verified directories"
ssh_to "${CONTROL_HOST}" "~/.local/bin/flare orbit cores --cluster '${CLUSTER}'" | head -12
