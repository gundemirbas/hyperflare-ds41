#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Reclaim disk on the serving hosts. Every rollout leaves the previous image and
# every export leaves a core, so this keeps the current image and the newest core
# per host and drops the rest.
#
#   ./cleanup.sh              # report and reclaim
#   ./cleanup.sh --dry-run    # report only
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}"
. ./cluster.env
. ./lib.sh

keep_image=${1:-$(cat "${HERE}/.last-build" 2>/dev/null || echo "")}
dry=0
[ "${1:-}" = "--dry-run" ] && dry=1

note "disk before"
for host in ${NODES}; do
    ssh_to "${host}" 'df -h / | tail -1 | awk "{print \"   '\"${host}\"' \"\$4\" free\"}"'
done

[ "${dry}" = "1" ] && { step "dry run: nothing removed"; exit 0; }

for host in ${NODES}; do
    note "${host}"
    ssh_to "${host}" "
        set -e
        # Dead containers from earlier preparations.
        docker ps -aq --filter status=exited | xargs -r docker rm >/dev/null 2>&1 || true

        # Images: keep the current tag and the one before it, drop the rest.
        keep='${REGISTRY}/flare-node:${keep_image}'
        docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'flare-node' | while read -r tag; do
            case \"\$tag\" in
                \"\$keep\"|'${REGISTRY}/flare-node:latest'|'flare-node:latest'|'flare-node-base:latest'|'flare-serving:latest') ;;
                *) docker rmi -f \"\$tag\" >/dev/null 2>&1 || true; echo \"   removed image \$tag\" ;;
            esac
        done
        docker image prune -f >/dev/null 2>&1 || true

        # Cores: keep the entry the group serves from, drop older ones.
        for root in \$HOME/.cache/flare/cores/models \$HOME/.cache/flare/models; do
            [ -d \"\$root\" ] || continue
            newest=\$(ls -1dt \$root/*/* 2>/dev/null | head -1 || true)
            [ -n \"\$newest\" ] || continue
            ls -1dt \$root/*/* 2>/dev/null | tail -n +2 | while read -r old; do
                rm -rf \"\$old\"; echo \"   removed core \$old\"
            done
        done
        df -h / | tail -1 | awk '{print \"   after: \"\$4\" free\"}'
    "
done

note "disk after"
for host in ${NODES}; do
    ssh_to "${host}" 'df -h / | tail -1 | awk "{print \"   '\"${host}\"' \"\$4\" free\"}"'
done
