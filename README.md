# Deploy

Automation for the Spark cluster: builds both container images, pushes them to a
registry on the control node, installs the serving binary on every Spark, and
drives the Orbit group.

Everything here runs on the control node and reaches the other hosts over SSH. A
repository update is followed by `./deploy.sh all`; the images carry the commit
they were built from.

## Images

| Image | Built on | Purpose |
|---|---|---|
| `flare-node` | an aarch64 Spark | `flare` binary plus the Ignition preparation environment |
| `flare-control-plane` | the x86_64 control node | `flare` CLI and the `selene` pool manager |

`flare-node` is both the source of the serving binary — extracted and installed
as `/usr/bin/flare` — and the container that runs `ignition export` and
`ignition join`. Serving itself stays on the host under the Orbit agents, because
a rank needs the host's GPUs, fabric devices and RoCE stack.

## Files

| File | Purpose |
|---|---|
| `cluster.env` | hosts, group name, registry, concurrency, commit |
| `lib.sh` | SSH and health helpers |
| `registry.sh` | local registry container on port 5000 |
| `build.sh` | build both images at a revision and push them |
| `rollout.sh` | pull, extract the binary, install it, refresh the agent |
| `prepare.sh` | export on rank zero plus joins, inside the node image |
| `group.sh` | start, stop, list or health-check the Orbit group |
| `deploy.sh` | the entry point that sequences the above |
| `node/ensure-registry-trust.sh` | make one Docker daemon trust the plain-HTTP registry |

## First run

```sh
./deploy.sh registry     # registry container on this node
./deploy.sh build        # both images, tagged with the commit
./deploy.sh rollout      # binary and agent on every Spark
./deploy.sh up           # Orbit group, waits for /health
```

A preparation change — prepared kernels, capacities, concurrency — needs a new
core before the group can serve:

```sh
./deploy.sh prepare      # hours; runs export and joins in containers
./deploy.sh up
```

Rollback restores the binary that `rollout.sh` saved in `/opt/flare-previous`:

```sh
./deploy.sh rollback
```

## Prerequisites

- The control node can SSH to every Spark as an unprivileged user with sudo.
  The Spark accounts use passwordless sudo; the control node's own sudo is not
  needed by these scripts.
- `docker` on the Sparks, `podman` on the control node.
- The checkpoint is reachable over SSHFS from the first node in `NODES`;
  `prepare.sh` mounts it at `CHECKPOINT_MOUNT` and leaves the copy on the source
  host, never on the Sparks.
- The registry listens on plain HTTP, so each Docker daemon trusts it through
  `insecure-registries`; `rollout.sh` configures that once per host.

## Where the complete core lives

The export writes the complete core on rank zero: every rank's shard plus the
Engram tables, about 470 GB for three ranks. Its manifest names every file, so a
launch from that core requires all of them present; the source node keeps the
complete artifact.

A peer receives its own ranges on first launch and reuses the verified cache
entry afterwards, so later launches transfer nothing. `archive.sh` copies the
complete core onto the control node as a recovery source: a peer that loses its
cache is restored without another export.
