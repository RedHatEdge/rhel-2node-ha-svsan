# Two-node RHEL KVM HA cluster — StorMagic SvSAN storage

A complete, working two-node high-availability platform for edge sites: two RHEL 9
hosts running KVM guests on shared iSCSI storage, provided by a StorMagic SvSAN
virtual storage appliance on each host, mirrored synchronously between them.

Built to be reproduced in a lab or POC from bare hardware. The platform is
automated with Ansible, and the appliance's own setup steps are documented click
by click so the whole build is repeatable.

## The shape of it

```
                        ┌─────────────────────────────────┐
                        │  ARBITER (datacenter)           │
                        │  corosync-qnetd :5403  cluster  │
                        │  NSH witness    :4174  mirror   │
                        └───────────┬─────────────────────┘
                     two quorum systems, one failure domain
              ┌─────────────────────┴───────────────────────┐
    ┌─────────┴──────────┐                        ┌─────────┴──────────┐
    │  NODE 1  RHEL 9    │                        │  NODE 2  RHEL 9    │
    │  ┌──────────────┐  │                        │  ┌──────────────┐  │
    │  │ VSA (guest)  │──┼──── synchronous ───────┼──│ VSA (guest)  │  │
    │  └──────┬───────┘  │        mirror          │  └──────┬───────┘  │
    │  iSCSI  │ to its   │                        │  iSCSI  │          │
    │  own VSA▼ + peer   │                        │         ▼          │
    │  guest on the LUN  │                        │  guest on the LUN  │
    └────────────────────┘                        └────────────────────┘
```

Each host runs an appliance that takes local disk and re-presents it as mirrored
iSCSI. Both hosts see both LUNs, so a guest can run on either — which is what
makes live migration and failover work without a storage array.

**The host is a client of a VM it hosts.** That single fact drives several design
decisions, most importantly that the storage NIC must be a real bridge: a macvtap
guest can reach every host except the one it runs on, so the local path would not
form.

**Architecture diagram:** [`docs/diagrams/svsan-architecture.png`](docs/diagrams/svsan-architecture.png)
— both hosts, the appliance on each, the synchronous mirror, the host-side
initiator path, and the witness. [`svsan-quorum.png`](docs/diagrams/svsan-quorum.png)
covers why the witness exists.

## Two quorum systems, and they are not the same thing

| | arbitrates | port |
|---|---|---|
| `corosync-qnetd` | cluster membership — which node may run resources | 5403 |
| SvSAN NSH witness | mirror ownership — which plex may serve data | 4174 |

Both run on the same arbiter so they share a failure domain and partition
identically. Without the witness the only available isolation policy is `Up`, in
which a plex stays online whenever it is healthy. `Majority` is what gives the
mirror split-brain protection, so plan for a witness from the start.

The witness here runs as a **container** (`containers/nsh-witness`) on UBI9, built
from the amd64 binaries in a StorMagic package you supply. StorMagic also document
an `el7` RPM — if you have one, prefer it.

## Requirements

| | |
|---|---|
| 2 × x86-64 servers | with BMCs reachable for fencing |
| 1 × RHEL 9 host | arbiter, running both quorum services |
| 2 × NICs per node | management and storage on separate segments |
| The **Hyper-V** SvSAN package | for the appliance image — not the vSphere OVA |
| The **vCenter plugin** package | supplies the amd64 binaries the witness container is built from |
| A trial licence | see below |
| A control node | RHEL 9, subscribed — builds the image and runs Ansible. See Stage 0 |

### Getting the software

StorMagic run a free trial that includes the download packages and licences:
**<https://stormagic.com/trial/>**. The packages are also available from a free
account at **<https://support.stormagic.com>**, which is worth creating anyway —
trial download links expire.

You need two packages: the **Windows/Hyper-V installation package**, which
contains the appliance image, and the **vCenter plugin package**, which is only
used to build the witness container.

**Use the Hyper-V package.** Its disk image is byte-identical to the vSphere OVA's,
but the OVA declares `ovf:transport="com.vmware.guestInfo"` and ships no CD-ROM, so
it expects configuration through a VMware Tools channel that KVM does not have.

## Build it

**Starting from bare machines?** Read
**[docs/BUILD.md](docs/BUILD.md)** first — Stage 0 covers the accounts, the build
host, and the ordering, including the one awkward part: the installer identifies
each machine by MAC address, so you need both MACs before you can build the ISO.

Once the two nodes are installed and reachable:

```
cp inventory/hosts.yml.example          inventory/hosts.yml
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml

# hosts.yml  — the three addresses, matching the MAC table in bootc/config.toml
# all.yml    — work down it; anything marked REPLACE will not work until changed

make discover             # each node records its own disks and NICs
make substrate            # cluster, quorum, fencing
make admin                # admin account and Cockpit on :9090

make nsh-image ZIP=...    # build the witness container
make witness              # deploy it to the arbiter

make vsa-image ZIP=...    # convert the appliance image
make svsan                # deploy the appliances (management only)
   ... appliance setup wizard, per appliance ...
make vsa-snapshot         # snapshot now — before any pool or target exists
make svsan-attach-san     # add the storage NIC
   ... pools, targets, ACLs ...
make svsan-attach         # present the LUNs to the hosts
make svsan-tune           # failover timing
make guests               # guests on the mirrored LUNs
```

The order matters, and `make discover` comes first for a reason: it pins every
disk and interface to an identifier that cannot change on reboot. Skip it and the
build works until something is renumbered, then writes to the wrong disk.

You do **not** create `inventory/host_vars/` by hand — `make discover` generates
those from the hardware. The `.example` files there show the shape only.

Every value marked `REPLACE` has to be yours. The rest has a working default.

### Three keys, for three different things

Easy to conflate, and each fails in a different place:

| | goes in | gets you |
|---|---|---|
| node root key | `bootc/config.toml`, before the ISO is built | Ansible's access to the nodes |
| `admin_ssh_key` | `all.yml` | the `admin` account, alongside its password |
| `guest_ssh_key` | `all.yml` | the guests, once they exist |

One key can serve all three — `~/.ssh/store-cluster.pub` from Stage 0 step 4 is
the obvious candidate — but each has to be filled in separately, and the first is
fixed at image build time rather than by Ansible. [docs/BUILD.md](docs/BUILD.md)
covers creating that key.

## Running it without make

`make` is a wrapper around ordinary playbooks. It pins the Ansible version in a
virtualenv and passes the extra-vars that decide how the storage NIC is attached
— which is destructive to get wrong on a running system. If you would rather call
the playbooks yourself, every target is listed with its equivalent command in
**[docs/BUILD.md](docs/BUILD.md)**.
