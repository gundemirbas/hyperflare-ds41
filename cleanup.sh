#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Reclaim disk on the serving hosts.
#
# Rank zero holds the complete core because it distributes each peer's ranges at
# launch, so its cache root is never pruned. A peer keeps a verified cache entry
# from whichever root its agent last used; an older root left behind by a
# previous launch is dead weight and is removed whole.
#
#   ./cleanup.sh              # reclaim
#   ./cleanup.sh --dry-run    # report only
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

dry=0
[ "${1:-}" = "--dry-run" ] && dry=1
keep_image=$(cat "${HERE}/.last-build" 2>/dev/null || echo "")
rank0=$(first_node)

note "disk before"
for host in ${NODES}; do
    ssh_to "${host}" 'df -h / | tail -1 | awk "{print \"   '\"${host}\"' \"\$4\" free\"}"'
done

[ "${dry}" = "1" ] && { step "dry run: nothing removed"; exit 0; }

for host in ${NODES}; do
    note "${host}"
    if [ "${host}" = "${rank0}" ]; then
        step "rank zero holds the distribution source; cache roots untouched"
        cache_cleanup=0
    else
        cache_cleanup=1
    fi

    ssh_to "${host}" "
        set -e
        docker ps -aq --filter status=exited | xargs -r docker rm >/dev/null 2>&1 || true

        keep="flare-node:${keep_image}"
        docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'flare-node' | while read -r tag; do
            case \"\$tag\" in
                \"\$keep\"|'flare-node:latest'|'flare-node-base:latest') ;;
                *) docker rmi -f \"\$tag\" >/dev/null 2>&1 || true; echo \"   removed image \$tag\" ;;
            esac
        done
        docker image prune -f >/dev/null 2>&1 || true

        if [ '${cache_cleanup}' = '1' ]; then
            # The agent passes --core-cache \$HOME/.cache/flare, so the live entry
            # lands under models/. A newer entry there makes cores/ stale.
            if [ -d \"\$HOME/.cache/flare/models\" ] && [ -d \"\$HOME/.cache/flare/cores\" ]; then
                live=\$(find \$HOME/.cache/flare/models -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
                if [ -n \"\$live\" ]; then
                    size=\$(du -sh \$HOME/.cache/flare/cores 2>/dev/null | cut -f1)
                    rm -rf \"\$HOME/.cache/flare/cores\"
                    echo \"   removed stale core root (\$size)\"
                fi
            fi
            # Older entries inside the live root still go.
            root=\$HOME/.cache/flare/models
            [ -d \"\$root\" ] || root=\$HOME/.cache/flare/cores
            if [ -d \"\$root\" ]; then
                ls -1dt \$root/*/* 2>/dev/null | tail -n +2 | while read -r old; do
                    rm -rf \"\$old\"; echo \"   removed old entry \$old\"
                done
            fi
        fi
        df -h / | tail -1 | awk '{print \"   after: \"\$4\" free\"}'
    "
done

note "disk after"
for host in ${NODES}; do
    ssh_to "${host}" 'df -h / | tail -1 | awk "{print \"   '\"${host}\"' \"\$4\" free\"}"'
done
