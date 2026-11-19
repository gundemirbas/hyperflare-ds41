#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Stage a prepared core onto the serving hosts before a launch, so each rank
# holds its own verified directory. With the peer-core patch this lets every rank
# load locally; without it, staging only informs placement.
#
#   ./stage.sh                # newest core, all hosts in rank order
#   ./stage.sh <core path>
set -eu

cd "$(dirname "$0")"
. ./cluster.env
. ./lib.sh

rank0=$(first_node)
core=${1:-$(ssh_to "${rank0}" "ls -1dt ${CORE_ROOT}/models/*/*/model.safetensors 2>/dev/null | head -1")}
[ -n "${core}" ] || fatal "no prepared core under ${CORE_ROOT}"

note "staging ${core}"
targets=$(echo ${NODES} | tr ' ' ',')
ssh_to "${CONTROL_HOST}" \
    "~/.local/bin/flare orbit push '${rank0}:${core}' --to '${targets}' --cluster '${CLUSTER}'" | tail -6

note "verified directories"
ssh_to "${CONTROL_HOST}" "~/.local/bin/flare orbit cores --cluster '${CLUSTER}'" | head -12
