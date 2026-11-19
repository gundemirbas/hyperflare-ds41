# Deploy

Automation for one prepared model served across three DGX Sparks. Rank zero runs
the Orbit controller and the registry; a fourth machine keeps the checkpoint and
serves it over SSHFS so a preparation never has to copy it.

## Hosts

| Host | Role |
|---|---|
| rank zero (248) | controller identity, registry, rank zero of the model |
| peers (247, 246) | ranks one and two |
| checkpoint host (245) | holds the checkpoint, exports it read-only over SSHFS |

The container images carry the work, so a repository update is a rebuild rather
than a manual install:

| Image | Built on | Purpose |
|---|---|---|
| `flare-node` | rank zero | the `flare` binary plus the Ignition preparation environment |

`flare-node` is both the source of the serving binary, extracted and installed as
`/usr/bin/flare` on every host, and the container that runs `ignition export` and
`ignition join`. Serving itself stays on the host under the Orbit agents: a rank
needs the host's GPUs, fabric devices and RoCE stack.

There is no pool: each rank keeps its prefix cache on local disk. A multi-host
instance requires that tier, because the host prefix store has to see every rank.

## Files

| File | Purpose |
|---|---|
| `cluster.env` | hosts, group name, registry, concurrency, paths |
| `lib.sh` | SSH, copy, commit and health helpers |
| `build.sh` | build the node image at a revision |
| `rollout.sh` | get the image onto every host, extract the binary, install it |
| `pair.sh` | install each agent and pair it with the controller |
| `group.sh` | Orbit group up, down, status, health |
| `archive.sh` | copy the complete core onto the control node |
| `cleanup.sh` | reclaim disk on the serving hosts |
| `prepare.sh` | export and join, inside the node image |
| `deploy.sh` | the entry point that sequences the above |
| `node/` | the image definition |

## Commands

```sh
./deploy.sh build        # node image at COMMIT
./deploy.sh rollout      # binary and agent on every host
./deploy.sh pair         # pair every host with the controller
./deploy.sh up           # Orbit group, waits for /health
./deploy.sh status       # group state
./deploy.sh archive      # complete core onto the control node
./deploy.sh cleanup      # reclaim disk on the serving hosts
```

`./deploy.sh all` runs build, rollout, pair and up in that order, then cleans
up. `./deploy.sh rollback` restores the binary that `rollout.sh` saved in
`/opt/flare-previous` and restarts the group.

A preparation change — kernels, capacities, concurrency — needs a new core before
the group can serve it:

```sh
./deploy.sh prepare      # hours; runs export and joins in containers
./deploy.sh up
```

`prepare.sh` mounts the checkpoint over SSHFS on rank zero and runs the export
there, with each peer joining in its own container. It needs one shared
credential, at least 32 bytes, private to its owner, identical on every host;
the script creates it when absent and copies it to the peers.

## Disk

A three-rank core is about 470 GB on rank zero: three rank shards of 93 GB and the
Engram tables. Its manifest names every file, so a launch from it requires all of
them present and the source node keeps the complete artifact.

A peer receives its own ranges on first launch and reuses the verified cache entry
afterwards, so later launches transfer nothing. `archive.sh` keeps the complete
core on the control node as a recovery source; a peer that loses its cache is
restored without another export.

`cleanup.sh` removes dead containers, image tags older than the recorded build,
and cache roots the launcher no longer uses. It never touches rank zero's cache
root or `ARCHIVE_ROOT`.

## Prerequisites

- The control node reaches every host over SSH as an unprivileged user with sudo.
- `docker` on the hosts; the registry runs under `docker` or `podman`.

A host without the image receives it from the build host with
`docker save … | ssh … docker load`, so no registry is involved.
