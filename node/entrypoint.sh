#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Dispatch for the serving-node image: ignition (default), export, join, flare.
set -eu

mode="${1:-ignition}"
[ $# -gt 0 ] && shift

case "${mode}" in
    export|join) exec ignition "${mode}" "$@" ;;
    flare) exec /usr/local/bin/flare "$@" ;;
    check)
        /usr/local/bin/flare --version
        ignition --help | head -3
        ;;
    *) exec "${mode}" "$@" ;;
esac
