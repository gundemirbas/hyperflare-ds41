# Deploy

One entry point for a prepared model served across three DGX Sparks, plus the
machine that holds the checkpoint.

## Hosts

| Host | Role |
|---|---|
| rank zero (248) | controller identity, build host, rank zero of the model |
| peers (247, 246) | ranks one and two |
| checkpoint host (245) | holds the checkpoint, exports it read-only over SSHFS |

`flare-node` is the only image: the `flare` binary plus the Ignition preparation
environment. `./deploy.sh rollout` takes the binary out of it and installs it as
`/usr/bin/flare` on every host. Serving stays on the host under the Orbit agents,
because a rank needs the host's GPUs, fabric devices and RoCE stack.

Each rank keeps its prefix cache on local disk; there is no pool. A multi-host
instance requires that tier.

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | every command |
| `cluster.env` | hosts, group name, concurrency, paths |
| `lib.sh` | SSH, copy, commit and health helpers |
| `prepare.sh` | export and join inside the node image |
| `node/` | the image definition |

## Commands

```sh
./deploy.sh build        # node image at COMMIT on the control node
./deploy.sh rollout      # image and binary on every host, agents refreshed
./deploy.sh pair         # install each agent and pair it with the controller
./deploy.sh up           # launch the group, wait for health
./deploy.sh status       # group state and health
./deploy.sh controller   # keep the group running as a container
./deploy.sh archive      # complete core onto the control node
./deploy.sh cleanup      # reclaim disk on the serving hosts
./deploy.sh prepare      # export and join, inside the node image
./deploy.sh all          # build, rollout, pair, up, cleanup
```

`./deploy.sh rollback` restores the binary that the rollout saved in
`/opt/flare-previous` and restarts the group.

Replacing an agent restarts it, and a restart stops the ranks it supervises, so
`rollout` and `pair` take a running service down. Run `up` afterwards.

## Keeping it up

The agents are enabled user units with linger, so they return after a reboot. The
group does not: Orbit's controller is a command, and an agent does not relaunch a
group after its own restart. `./deploy.sh controller start` runs a container from
the node image that re-issues the launch whenever the group is not running, with
`--restart unless-stopped` so it returns with docker.

## Disk

A three-rank core is about 470 GB on rank zero: three rank shards of 93 GB and the
Engram tables. Its manifest names every file, so a launch from it requires all of
them and the source node keeps the complete artifact.

A peer receives its own ranges on first launch and reuses the verified cache entry
afterwards. `./deploy.sh archive` keeps the complete core on the control node as a
recovery source, and `./deploy.sh cleanup` removes dead containers, older image
tags and cache roots the launcher no longer uses. It never touches rank zero's
cache root or `ARCHIVE_ROOT`.

## Preparation

`./deploy.sh prepare` mounts the checkpoint over SSHFS on rank zero and runs the
export there, with each peer joining in its own container. It needs one shared
credential, at least 32 bytes, private to its owner, identical on every host; the
script creates it when absent.
