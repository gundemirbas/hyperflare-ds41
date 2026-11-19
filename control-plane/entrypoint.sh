#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# First run creates the pool directory and socket directory; later runs reuse
# them. Modes: selene (default), orbit <args>, check, or any command verbatim.
set -eu

prepare() {
    mkdir -p "${SELENE_ROOT}" /run/selene
    chmod 0750 "${SELENE_ROOT}"
}

mode="${1:-selene}"
[ $# -gt 0 ] && shift

case "${mode}" in
    selene)
        prepare
        exec selene \
            --name "${SELENE_NAME}" \
            --socket "/run/selene/${SELENE_NAME}.sock" \
            --root "${SELENE_ROOT}" \
            --memory "${SELENE_MEMORY}" \
            --nvme "${SELENE_NVME}" \
            --staging "${SELENE_STAGING}" \
            --listen "${SELENE_LISTEN}" \
            --listen-data "${SELENE_LISTEN_DATA}" \
            --metrics "${SELENE_METRICS}"
        ;;
    orbit) exec flare orbit "$@" ;;
    check)
        flare --version
        printf 'pool %s root %s listen %s data %s metrics %s\n' \
            "${SELENE_NAME}" "${SELENE_ROOT}" "${SELENE_LISTEN}" "${SELENE_LISTEN_DATA}" "${SELENE_METRICS}"
        selene --help | head -2
        ;;
    *) exec "${mode}" "$@" ;;
esac
