#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Install the agent on every serving host, read the one-time join code it prints,
# and pair that host with the controller on the control node. Existing pairings
# for the same names are forgotten first so a reinstalled node keeps its entry.
#
#   ./pair.sh
set -eu

cd "$(dirname "$0")"
. ./cluster.env
. ./lib.sh

for host in ${NODES}; do
    note "${host}"

    name=$(ssh_to "${host}" 'hostname')
    code=$(ssh_to "${host}" \
        '/usr/bin/flare agent install 2>&1 | sed -n "s/^join code:[[:space:]]*//p"' | tr -d '\r' | head -1)
    if [ -z "${code}" ]; then
        # A node that is already installed and paired needs no new code.
        step "no join code printed; assuming an existing pairing"
        continue
    fi

    ssh_to "${CONTROL_HOST}" "~/.local/bin/flare orbit forget '${name}' >/dev/null 2>&1 || true"
    ssh_to "${CONTROL_HOST}" "~/.local/bin/flare orbit pair '${name}' --code '${code}'" \
        | sed 's/^/   /'
done

note "cluster membership"
ssh_to "${CONTROL_HOST}" "~/.local/bin/flare orbit status --cluster ${CLUSTER}" \
    | grep -E '^(NODE|thinkstation|gx10)' | sed 's/^/   /'
