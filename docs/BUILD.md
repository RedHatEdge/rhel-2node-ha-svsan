# Build from nothing

Two-node RHEL 9 KVM HA cluster with StorMagic SvSAN shared storage.


Every step here was executed, and the reasoning is given where the order or a
particular setting matters.

**Roughly 2 hours**, most of it waiting for installs and appliance boots.

---

## What you need first

| | |
|---|---|
| 2 × x86-64 servers | with BMCs reachable for fencing. Lab: Simply NUC EE-2000 |
| 1 × RHEL 9 host | the arbiter, in the "datacenter". Can be a VM |
| 2 × NICs per node | one management, one storage. Storage must be its own segment |
| The **Windows/Hyper-V** package | contains the appliance image |
| The **vCenter plugin** package | only used for the witness binaries |
| A trial licence | from StorMagic — see below |
| A control node | with Ansible, `qemu-img`, `podman`, `7z` |

Both packages and a trial licence come from StorMagic's free trial:
**<https://stormagic.com/trial/>**. They are also on a free support account at
**<https://support.stormagic.com>** — worth creating, as trial download links
expire after a few days.

**Take the Hyper-V package, not the vSphere OVA.** The two disk images are
byte-identical (MD5 `90d8e64e678dd8f682f33cd6cc112a2b`) but the OVA declares
`ovf:transport="com.vmware.guestInfo"` and ships no CD-ROM, so it expects
configuration through the VMware Tools channel — which KVM does not have. The VHD
carries no such envelope and the appliance falls back to DHCP and its own web
wizard.

---

## A. Networks — get this right before anything else

| segment | subnet | carries |
|---|---|---|
| management / VLAN 12 | 172.16.7.0/24 | corosync ring0, host and VSA management, witness |
| storage / VLAN 18 | 172.18.8.0/24 | corosync ring1, mirror, iSCSI |

**The storage VLAN must have no DHCP server, no gateway and no DNS.**

This is not tidiness. A pristine VSA takes DHCP on *every* interface and treats
each as management. If the storage segment answers DHCP, the appliance acquires a
second default route, and which one wins is a race. On two identical hosts running
the identical play, one appliance completed setup and the other could not reach
the network it needed. The build brings the appliances up on management first for
that reason; a storage segment handing out leases is also worth avoiding on its
own merits.

---

## B. Install the two nodes

```
cd bootc
./build.sh                 # RHEL 9.8 bootc container image
./build.sh --push --iso    # build, push, then make an installer ISO
```

One ISO installs both nodes. The kickstart matches the machine's own MACs against
a table and emits the right hostname and static addresses; a second `%pre` picks
the OS disk by size. That is what makes the same media work on both, and why the
reversed NVMe enumeration between the two nodes is a non-issue.

PXE boot both. Two things that will cost you an hour each if you forget:

- **Network Stack must be enabled in BIOS.** It is off by default.
- iPXE must use `${proxydhcp/next-server}`, not `${next-server}` — the latter
  resolves to the gateway and breaks every menu entry.

### If your image repository is private

A bootc node updates by pulling its own OS image, so a private repository means
the node needs credentials or it cannot update at all — `bootc upgrade` fails
with `unauthorized` and the node quietly stops receiving updates, including
kernel CVEs, while looking perfectly healthy.

Set `bootc_registry_auth` in your inventory to a pull-only credential and the
role writes it to `/etc/ostree/auth.json`. It then runs `bootc upgrade --check`
and reports loudly if the node still cannot reach its image. A read-only robot
token is the right credential here — a node never needs to push.

Public repository: skip this, no credential needed.

## C. Cluster, quorum and fencing

```
make substrate
```

Three votes, not two: `corosync-qnetd` on the arbiter breaks the tie. Do **not**
set `two_node: 1` and do **not** set `no-quorum-policy=ignore`.

Verify before continuing — everything downstream assumes this works:

```
pcs quorum status          # Total votes: 3
pcs stonith fence node2    # must actually power-cycle it
```

## D. The witness

```
make nsh-image ZIP=~/Downloads/svsan_6-7_plugin_ova.zip
make witness
```

StorMagic ship the witness as an `armhf` .deb and a vSphere appliance; the 6.2
docs also describe an `el7` RPM. The amd64 binaries live inside the vCenter plugin
appliance, and they are self-contained — `smclusterd` and `smdiscod` carry their
own loader and glibc, with the ELF interpreter hard-coded to
`/opt/stormagic/SvSAN/lib`, so installing the tree at that exact path makes the
image independent of the base image's glibc. Both accept `--foreground`.

It runs on the same host as `corosync-qnetd` on purpose, so the two quorum
systems share a failure domain and partition identically.

```
ss -tlnp | grep 4174       # smclusterd listening
```

## E. Appliance image and first boot

```
make vsa-image ZIP=~/Downloads/svsan_6-7_windows_installer_plus_powershell.zip
make svsan
```

`make svsan` passes `svsan_attach_san_nic=false` deliberately — the appliances come
up on **management only**, for the DHCP reason in section A.

The appliances come up on **management only** at this stage, for the DHCP reason
in section A. Their MACs are set from inventory rather than generated, so each
appliance keeps a stable identity across rebuilds.

## F. The wizard — per appliance

Find them with `virsh -c qemu:///system net-dhcp-leases default`, then browse to
`https://<mgmt-ip>/`, **`admin` / `password`**.

1. **License Agreement** — accept
2. **Before You Begin** — Next
3. **Activate** — **mandatory**, the wizard will not advance past it.
   Follow the prompts.
4. **Identify** — hostname `vsa1` / `vsa2`, domain **blank**
5. **Password** — `<VSA-ADMIN-PASSWORD>`
6. **Finish**

Mirroring becomes available once the wizard completes.

## G. Snapshot — before anything else

```
make vsa-snapshot
```

**Do this now, not later.** The useful restore point is *activated but empty*. A
snapshot taken after a mirror exists carries that mirror's metadata, so restoring
it brings back a target whose backing store no longer exists.

## H. Storage NIC

```
make svsan-attach-san
```

Then per appliance, **Network → Interface 1**:

| | |
|---|---|
| Network Device | the storage MAC — ends `:02`, **not** `:01` |
| DHCP | off |
| IP | `172.18.8.20` / `172.18.8.21`, `255.255.255.0`, **no gateway** |
| Traffic Types | **iSCSI only** |
| Mirror Traffic Policy | **Preferred** |

And **Interface 0**: Management **and** iSCSI ticked, Mirror Traffic Policy
**Failover**, "Enable on all Targets" ticked.

**Both interfaces keep iSCSI.** It is tempting to untick it on management to keep
replication off the store LAN, and that is wrong: it removes the mirror's second
path, which StorMagic's own split-brain guidance says to keep. Placement is
expressed by `Preferred`/`Failover`, not by availability. Host iSCSI is kept off
the store LAN separately, in section L.

If an appliance ever loses a NIC, the logical interface is disabled and its device
binding cleared. When re-enabling it, set the Assigned Network Device explicitly —
check that column shows the storage MAC and not the management one.

## I. Pools

**Pools → Create Pool** on each: name **`pool1`** — identical on both, because a
mirrored target is created by naming the remote pool — RAID level **JBOD**, on the
`KVM:virtio` device (~90 GB, the `lv-svsan-pool` logical volume).

JBOD is right: one data disk per node, and redundancy comes from the network
mirror, not from local RAID.

## J. Witness and targets

Discovery is **automatic** — the appliances find each other and the witness with
no configuration.

**Targets → Mirroring** on each: untick "Clear Global Witness", select
`qnetd1`, tick "Apply to all online mirrors", APPLY.

Then **once**, on either appliance, **Pools → pool1 → Create Target on pool1**:

| target | size | notes |
|---|---|---|
| `pos` | 20 GB | point-of-sale |
| `pgsql` | 40 GB | PostgreSQL |

Mirroring ticked, **Isolation Policy `Majority`**, remote host the other
appliance, and **select the Remote Pool radio** — it is unset by default and
CREATE stays greyed until it is set.

`Majority` is what gives the mirror split-brain protection. Without a witness the
only choice is `Up`, in which a plex stays online whenever it is healthy.

## K. Access control

**Initiators → Create Initiator**, twice, OS Type **Linux**:

```
iqn.2026-01.com.example.lab:node1    hostname node1
iqn.2026-01.com.example.lab:node2    hostname node2
```

Then **Targets → <target> → Initiators** and add **both** to **both** targets.

Both hosts on both targets — a host needs access to the target it is not normally
running, or it cannot take over. A target with an empty ACL accepts nobody and
says so only as an informational event, so from the host it looks like a network
fault.

## L. Present to the hosts

```
make svsan-attach
make svsan-tune
```

`make svsan-attach` first checks that every appliance interface is actually
attached to the bridge libvirt claims. That is not paranoia: libvirt's domain XML
records intent, and if a bridge is rebuilt beneath a running guest the tap is
silently orphaned — the domain runs, `virsh domiflist` still reports the intended
bridge, and the NIC is connected to nothing. It presents as a DHCP or storage
failure and is invisible from either. Nothing in libvirt or Pacemaker detects it.

```
```

`svsan-attach` discovers, logs in, binds multipath aliases, and **discards node
records for portals outside the storage subnet** — `sendtargets` advertises every
portal a target is on, including management, so without this the host runs iSCSI
over the store LAN.

`svsan-tune` sets failure detection and recovery. Note that tuning
`replacement_timeout` alone does nothing: multipath overrides `recovery_tmo`
per-device. Detection is the larger half of the wait.

```
multipath -ll        # /dev/mapper/pos and /dev/mapper/pgsql, 2 paths each
```

## M. Guests

```
make guests
```

Ubuntu, deliberately — the stores run Ubuntu today and `virt-v2v` leaves the guest
OS untouched, so the demo carries their workload rather than substituting ours.

Rebuilding is opt-in (`-e guest_rebuild=true`) because the write is destructive;
without that guard, applying an unrelated change silently destroys the running
workload.

Live migration needs three things the play now sets up, each of which fails
silently on its own — Pacemaker just falls back to stop-and-start and reports
healthy:

- **SSH host keys** between the nodes, as root
- **A unique libvirt host UUID.** The Simply NUC ships the *same* DMI system UUID
  in firmware on every unit, so libvirt sees a single host and declines to migrate. `machine-id` is
  correctly unique, so `host_uuid_source = "machine-id"` fixes it. On identical
  hardware deployed from one image — the several thousand-store model exactly — every site
  would hit this.
- **Ports 49152-49215** open, or migration authenticates, starts, then fails with
  "no route to host"

## N. Operator access — Cockpit

```
make admin
```

Creates the `admin` account (in `wheel`, `libvirt` and `qemu`), sets a password
for it and for root, and brings up Cockpit on **:9090**.

`make admin` touches no networking, so it is safe against a running cluster.
Prefer it over a full `make substrate` when access is all you are changing —
substrate reconfigures the storage NIC, and on a live system that drops storage.

Three things about this are easy to get wrong:

- **Cockpit authenticates through PAM, not SSH keys.** A key-only account cannot
  log into the web UI at all, so the account needs a password even if you only
  ever use keys over SSH. The role refuses to create an account with neither.
- **Cockpit's Machines page needs `libvirt-dbus`.** It reaches libvirt over
  D-Bus, not by talking to `libvirtd` or `virtqemud`. Without it the page reports
  *"Virtualization service (libvirt) is not active"* while `virsh` on the same
  host lists every guest — so `virsh` is not a valid check for this.
- **`libvirt-dbus` runs as the `libvirtdbus` user**, and the D-Bus policy grants
  it ownership of `org.libvirt`. On an image-mode host the RPM's scriptlet user
  does not survive into the deployed system, which is why the image declares it
  in `/usr/lib/sysusers.d`.

Change the demo password before this touches anything real — see
`roles/common_base/defaults/main.yml`.

## O. Verify

```
pcs status                                  # both guests Started, no failures
multipath -ll                               # 4 paths, all "active ready"
ss -tn '( sport = :4174 )'                  # 2 witness connections
curl http://<pos-guest>:8080/               # live transaction view
busctl --system list | grep org.libvirt     # Cockpit can see the guests
virsh capabilities | grep -A1 '<uuid>'      # MUST differ between the two hosts
```

Two of these are worth understanding rather than just running.

**The host UUID must differ between nodes.** Many small-form-factor machines ship
the same DMI system UUID in firmware on every unit; libvirt then believes both
hosts are the same machine and refuses to migrate with *"Attempt to migrate guest
to the same host"*. The fix is `host_uuid_source = "machine-id"`, and it has to be
set in the config file of the daemon actually in use — `virtqemud.conf` for the
modular daemons, `libvirtd.conf` for the monolithic one. Setting it in the wrong
file looks identical to not setting it at all.

**`org.libvirt` must be on the system bus**, or Cockpit shows no virtual machines
regardless of how healthy libvirt is.

From the hosts, never from a workstation — the storage segment is not routed.

---

## What this produces

```
node1, node2      RHEL 9.8, Pacemaker, 3-vote quorum, Redfish fencing
                  vgstore: lv-svsan-pool
vsa1, vsa2        SvSAN appliances, MACs set from inventory
targets           pos 20 GB, pgsql 40 GB, mirrored, Majority + witness
qnetd1            corosync-qnetd :5403 and nsh-witness :4174, both quorum systems
guests            pos and pgsql, Ubuntu, on the mirrored LUNs, Pacemaker-managed
```

The roles reserve a separate logical volume for the appliance pool, so a
direct-replication variant can coexist on the same hardware if you want to
compare them.

## Measured behaviour

| scenario | POS outage |
|---|---|
| Planned maintenance | **0 s** — live migration |
| Witness lost | **0 s** |
| VSA lost, then witness lost | **0 s** |
| Mirror link failure | 8.1 s |
| VSA offline | 10.3 s |
| Host offline, fenced | 20.1 s, zero transactions lost |

