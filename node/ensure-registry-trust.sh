#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Make one Docker daemon trust a plain-HTTP registry. Runs on the node as root:
#
#   sudo ./ensure-registry-trust.sh 192.168.0.245:5000
#
# Idempotent: an entry that is already present leaves the daemon untouched.
set -eu

registry="$1"
conf=/etc/docker/daemon.json

if [ -f "${conf}" ] && grep -q "\"${registry}\"" "${conf}"; then
    echo "   registry ${registry} already trusted"
    exit 0
fi

mkdir -p /etc/docker

if [ -f "${conf}" ]; then
    cp -a "${conf}" "${conf}.bak-$(date +%s)"
    python3 - "${conf}" "${registry}" <<'PY'
import json, sys
path, registry = sys.argv[1], sys.argv[2]
data = json.load(open(path))
entries = data.setdefault("insecure-registries", [])
if registry not in entries:
    entries.append(registry)
json.dump(data, open(path, "w"), indent=2)
PY
else
    printf '{\n  "insecure-registries": ["%s"]\n}\n' "${registry}" > "${conf}"
fi

systemctl restart docker
echo "   registry ${registry} trusted"
