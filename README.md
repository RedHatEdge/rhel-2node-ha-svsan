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
from StorMagic's own amd64 binaries. StorMagic also document an `el7` RPM; use
whichever suits your fleet.

## Requirements

| | |
|---|---|
| 2 × x86-64 servers | with BMCs reachable for fencing |
| 1 × RHEL 9 host | arbiter, running both quorum services |
| 2 × NICs per node | management and storage on separate segments |
| The **Hyper-V** SvSAN package | for the appliance image — not the vSphere OVA |
| A trial licence | see below |
| A control node | with Ansible, `qemu-img`, `podman`, `7z` |

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

```
cp inventory/hosts.yml.example              inventory/hosts.yml
cp inventory/host_vars/node1.yml.example    inventory/host_vars/node1.yml
cp inventory/host_vars/node2.yml.example    inventory/host_vars/node2.yml
cp inventory/group_vars/all.yml.example     inventory/group_vars/all.yml
# work down each one — anything marked REPLACE has to change
make substrate            # cluster, quorum, fencing
make nsh-image ZIP=...    # build the witness container
make witness              # deploy it to the arbiter
make vsa-image ZIP=...    # convert the appliance image
make svsan                # deploy the appliances (management only)
   ... appliance setup wizard, per appliance ...
make svsan-attach-san     # add the storage NIC
   ... pools, targets, ACLs ...
make svsan-attach         # present the LUNs to the hosts
make svsan-tune           # failover timing
make guests               # guests on the mirrored LUNs
```

The order matters. Full walkthrough with the reasoning behind each step:
**[docs/BUILD.md](docs/BUILD.md)**.

Every value marked `REPLACE` has to be yours. The rest has a working default.

## A note on the roles

They are written to support either this appliance-based layer or direct block
replication, and branch on `storage_backend`. This repository pins it to `svsan`,
so the other branch never fires.
