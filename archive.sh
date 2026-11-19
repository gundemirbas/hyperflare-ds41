#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Copy the complete core from the source node onto the control node. A peer that
# loses its staged directory is restored from this archive instead of a re-export,
# and with it present the source node no longer has to hold the other ranks'
# payloads.
#
#   ./archive.sh              # newest core on the first node
#   ./archive.sh <core path>  # a specific core
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

rank0=$(first_node)
core=${1:-$(ssh_to "${rank0}" "ls -1dt ${CORE_ROOT}/models/*/*/model.safetensors 2>/dev/null | head -1")}
[ -n "${core}" ] || fatal "no prepared core under ${CORE_ROOT}"

source_dir=$(dirname "${core}")
name=$(basename "${source_dir}")
dest="${ARCHIVE_ROOT}/${name}"

note "archiving ${name} onto ${CONTROL_HOST}"
ssh_to "${CONTROL_HOST}" "mkdir -p '${ARCHIVE_ROOT}'"
ssh_to "${rank0}" \
    "rsync -a --info=progress2 '${source_dir}/' '${SSH_USER}@${CONTROL_HOST}:${dest}/'" | tail -2

# The archive is the recovery source, so compare the tree size rather than trust
# rsync's exit status alone.
remote_bytes=$(ssh_to "${rank0}" "du -sb '${source_dir}' | cut -f1")
local_bytes=$(ssh_to "${CONTROL_HOST}" "du -sb '${dest}' | cut -f1")
[ "${remote_bytes}" = "${local_bytes}" ] \
    || fatal "archive size ${local_bytes} differs from ${remote_bytes}"
step "verified ${local_bytes} bytes"

echo "${dest}" > "${HERE}/.archive"
step "recorded in .archive"
