# Patches

Optional source changes applied to the node image build. `cluster.env` names the
files in `PATCHES`; an empty value builds the plain `FLARE_COMMIT` checkout, and
`build.sh` passes the list to the image as `FLARE_PATCHES`.

## 0001-peer-loads-its-own-staged-core.patch

A peer already accepts a local core: `distribution::peer` takes the path from
`--core`, leases the cache entry, and `verify_local_core` rejects a core whose
signed envelope, model, tensor-parallel size or cluster export differs from rank
zero's. The agent passes such a path only when the grant names that node as the
core's source, and the controller names exactly one holder, so every peer
receives its ranges at launch even when `orbit push` has already staged that
rank's directory on the node.

The patch adds a per-member `staged` flag. The controller sets it when the node's
STATUS reports that rank's staged directory verified, and the agent starts the
rank from its own copy. Rank zero keeps distributing whatever a peer cannot
supply, so partial staging stays correct.

### Why it matters

A three-rank core is about 470 GB on the source node: three rank shards of 93 GB
and the Engram tables. One rank needs about 157 GB, so roughly two thirds of that
core exists only to be sent to the other two ranks. With every peer staged, the
source node needs its own share alone.

### Enabling it

```sh
# Once per export, from the control node: stage each rank's directory.
./stage.sh

# Then build with the patch and roll out.
PATCHES=0001-peer-loads-its-own-staged-core.patch ./build.sh
./rollout.sh
./group.sh up
```

`stage.sh` prints the directories each node holds; `./deploy.sh control` and
`orbit cores` show their verification state. A rank whose directory is not
verified falls back to receiving from rank zero.

### Status

The patch applies to the checkout that `build.sh` clones and has passed
`git apply --check`, but it has not been built or run against a cluster. It
changes which node supplies a rank's core data, which is a core-loading concern:
upstream requires a maintainer decision for changes there, so treat this as a
local fork rather than a contribution.

### Pin the commit

The patch applies to one checkout. Build with an explicit revision when `PATCHES`
is set — `./build.sh <sha>` — because `main` moves and a moved tree can reject
the hunks. The revision the patch was generated against is the clone this
directory was written in; `git apply --check` against the build host's clone
confirms it before an image is built.
