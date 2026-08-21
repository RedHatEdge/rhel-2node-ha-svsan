# Build from nothing

Two-node RHEL 9 KVM HA cluster with StorMagic SvSAN shared storage.


Every step here was executed, and the reasoning is given where the order or a
particular setting matters.

**Roughly 2 hours**, most of it waiting for installs and appliance boots.

---

## What you need first

Hardware and software. **If you are starting from nothing, read Stage 0 below
first** — it covers the accounts, the build host, and the order things have to
happen in.

| | |
|---|---|
| 2 × x86-64 servers | with BMCs reachable for fencing. Lab: Simply NUC EE-2000 |
| 1 × RHEL 9 host | the arbiter, in the "datacenter". Can be a VM |
| 2 × NICs per node | one management, one storage. Storage must be its own segment |
| The **Windows/Hyper-V** package | contains the appliance image |
| The **vCenter plugin** package | only used for the witness binaries |
| A trial licence | from StorMagic — see below |
| A control node | RHEL 9, subscribed — see Stage 0. Builds the image and runs Ansible; not part of the cluster |

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

> Prefer to drive Ansible yourself rather than through `make`? Every target and
> its equivalent command is in the appendix at the end.

## Stage 0 — before you touch the servers

If you have two machines out of their boxes and nothing else, start here. This
stage is entirely about the things the rest of the guide assumes you already
have.

### The order, and why it is this order

The installer ISO decides which machine is which **by MAC address**, so you need
both MACs from both nodes *before* you can build it. But the nodes have no
operating system yet, so you cannot ask them. That is the one genuinely awkward
step, and it is resolved by reading the MACs out of firmware rather than from a
running system.

```
0. decide the two networks             on paper, before anything else
1. accounts and subscriptions          you, on the web
2. a build host                        one RHEL 9 machine or VM
3. read the MACs out of BIOS/BMC       no OS needed — the machines have no OS yet
4. write MACs and addresses into bootc/config.toml
5. build the image, then the ISO       on the build host
6. install both nodes from that ISO
7. fill in the inventory               copy the .example files, edit them
8. make discover                       the nodes describe their own hardware
9. the lettered sections below         cluster, storage, guests
```

Steps 3 and 8 look similar but are not. Step 3 is you, reading two MACs off a
screen so the installer can tell the two machines apart. Step 8 is the cluster
recording every disk and interface by an identifier that cannot move — a
different job, and only possible once there is an OS to ask.

### 0. Decide the two networks first

| segment | subnet | carries |
|---|---|---|
| management | 172.16.7.0/24 (example) | corosync ring0, host and VSA management, witness |
| storage | 172.18.8.0/24 (example) | corosync ring1, mirror, iSCSI |

Use your own subnets — the examples above are what this was built on, and the
inventory ships with them as defaults, so reusing them saves editing.

**The storage segment must have no DHCP server, no gateway and no DNS.**

This is not tidiness. A pristine VSA takes DHCP on *every* interface and treats
each as management. If the storage segment answers DHCP, the appliance acquires a
second default route, and which one wins is a race. On two identical hosts running
the identical play, one appliance completed setup and the other could not reach
the network it needed. The build brings the appliances up on management first for
that reason; a storage segment handing out leases is also worth avoiding on its
own merits.

### 1. Accounts you will need

| | | |
|---|---|---|
| **Red Hat** | developers.redhat.com | free Developer Subscription covers 16 systems; entitles RHEL and the bootc base image |
| **registry.redhat.io** | same login | pulls the RHEL bootc base image |
| **An image registry** | quay.io free tier, or any OCI registry | the nodes pull their OS from here, so it must be reachable from the store |
| **StorMagic** | stormagic.com/trial | the appliance packages and a trial licence |

The Red Hat account is the one to do first — the base image will not pull without
it, and everything else waits on that.

### 2. A build host

One RHEL 9 machine or VM. It builds the OS image and runs Ansible; it does not
become part of the cluster and can be switched off afterwards. Modest: 2 vCPU,
8 GB RAM, **40 GB free disk** — image builds are large.

```
sudo subscription-manager register --username <you>
sudo subscription-manager attach --auto
sudo dnf -y install podman git make python3-pip
```

Then log in to both registries — the first pulls the base image, the second is
where your built image goes:

```
podman login registry.redhat.io
podman login <your-registry>
```

**A subscribed RHEL build host is the shortest path.** Its entitlements are
passed into the build automatically, so the image installs RHEL packages with no
further setup. Anywhere else that runs podman will build this just as well —
Fedora, another distribution, a Mac — you supply the entitlement yourself as an
activation key in `bootc/secrets/`, which the build picks up on its own. The
resulting image is the same; the only difference is where the entitlement comes
from and how much you set up first.

### 3. Read the MACs out of firmware

Two per node — the management NIC and the storage NIC. No operating system
required:

- **From the BMC web interface**, if the machines have one. Usually under System
  or Network Inventory. This is also worth doing first because you need the BMC
  reachable later for fencing.
- **From the BIOS setup screen**, under the network or boot device list.
- **From a PXE or live-boot screen**, which prints the MAC as it requests an
  address.

Write down which physical port each belongs to. Getting management and storage
the wrong way round produces a node that installs cleanly and then cannot see its
own storage network, which is a confusing thing to debug later.

### 4. Put them in the MAC table

`bootc/config.toml` carries one line per node:

```
control_mac|hostname|control_ip|storage_mac|storage_ip
```

That table is what makes a single ISO able to install both machines: each one
matches its own MACs on boot and takes the matching hostname and addresses.
Nothing else distinguishes them, so this table has to be right.

Set your SSH public key in the same file while you are there — the build refuses
to proceed with the placeholder still in place, deliberately, because an image
you cannot log into is no use.

### 5. Build the image and the ISO

`build.sh` needs to know where to push. Set `REGISTRY` to your own namespace —
it has no sensible default and the script stops rather than guess:

```
cd bootc
REGISTRY=quay.io/<your-namespace> ./build.sh --push --iso
```

`IMAGE` (default `store-node`) and `TAG` (default `latest`) override the same
way, which is also how you build a second image without disturbing one already
in use:

```
REGISTRY=quay.io/<your-namespace> IMAGE=store-node-test ./build.sh --push --iso
```

Export them instead if you would rather not repeat them:

```
export REGISTRY=quay.io/<your-namespace>
./build.sh --push --iso
```

Before it builds anything the script checks the things that would otherwise
waste a full build: entitlements, that you are logged in to both registries,
that `REGISTRY` is set, and that the SSH key placeholder is gone.

The build prints one error you can ignore:

```
System has not been booted with systemd as init system (PID 1). Can't operate.
Error in POSTTRANS scriptlet in rpm package pcs
```

`pcs` tries to talk to systemd when it installs, and nothing is running as PID 1
inside a build container. The package installs correctly and the service starts
normally on a booted node. The build does not stop, and neither should you.

The result is an installer ISO that installs either node. Write it to a USB stick
or attach it through the BMC's virtual media.

### 6. Install both nodes

Boot each machine from the ISO. It matches MACs, picks the OS disk by size, and
installs unattended. Nothing to answer.

If you PXE boot rather than using media: **most BIOSes ship with the network
stack disabled**, and it has to be turned on before the machine will PXE at all.

### 7. Fill in the inventory

Everything the playbooks need about *your* environment lives in three files. Each
ships as a `.example` — copy it, then edit. Nothing is generated for you at this
point except the per-node hardware facts in step 8.

```
cp inventory/hosts.yml.example          inventory/hosts.yml
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
```

**`inventory/hosts.yml`** — which machines, and how Ansible reaches them. Set
`ansible_host` for `node1`, `node2` and the arbiter to the management addresses
you chose in step 0.

**`inventory/group_vars/all.yml`** — everything else, and the one file worth
reading top to bottom. Anything marked `REPLACE` must change; the rest has a
working default. The values that matter most:

| | |
|---|---|
| `lan_gateway`, `lan_dns` | your management network |
| `repl_network` | your storage segment |
| `redfish_user`, `redfish_password` | BMC credentials — fencing does not work without them |
| `admin_ssh_key` | your public key, or you cannot log in |
| `admin_password_hash` | needed for Cockpit, which authenticates via PAM |
| `bootc_image` | where the nodes pull their OS from |

The real `hosts.yml` and `all.yml` are gitignored, so your addresses and
credentials stay out of version control while the `.example` files remain as the
template.

You do **not** create `inventory/host_vars/` by hand. The examples there show
what the files look like, but step 8 generates the real ones from the hardware
itself, which is more reliable than transcribing MAC addresses.

### 8. Now let the nodes describe themselves

```
make discover
```

This runs against each node and writes `inventory/host_vars/<node>.yml`,
recording disks by `/dev/disk/by-id/` and interfaces by MAC — overwriting
anything already there, which is why step 7 says not to write them yourself.

**This is not optional and it is easy to skip**, because the rest of the guide
does not obviously fail without it — it fails later, on the wrong disk. Kernel
names move: `/dev/nvme0n1` can become `/dev/nvme1n1` after a reboot or a drive
swap, and interface names shift when firmware changes. Anything written into
configuration has to be pinned to something that cannot move, and this is the
step that captures it.

Read the generated files before continuing:

```
cat inventory/host_vars/node1.yml
```

Check `storage_device` is the disk you intend to give to storage and **not** the
OS disk, and that `control_mac` and `repl_mac` are the right way round. If a node
picked wrong, correct the file now — not after it has been overwritten.

### 9. Continue

From here, work through the lettered sections below in order.

---

## A. Install the two nodes

Covered in Stage 0 steps 5 and 6 — this section is the detail behind them.

One ISO installs both nodes. The kickstart matches the machine's own MACs against
the table you filled in, and emits the right hostname and static addresses; a
second `%pre` picks the OS disk by size rather than by kernel name. That is what
makes the same media work on both, and why the reversed NVMe enumeration between
the two nodes is a non-issue.

If you PXE boot rather than using media, two things that will cost you an hour
each if you forget:

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

## B. Cluster, quorum and fencing

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

## C. Operator access — Cockpit

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
up on **management only** at this stage, for the DHCP reason in Stage 0 step 0. The
storage NIC gets attached in section H, once the wizard is done.

Their MACs are set from inventory rather than generated, so each appliance keeps a
stable identity across rebuilds.

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
the store LAN separately — see Stage 0 step 0.

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

Ubuntu guests, to show that the platform is indifferent to what runs on it.
`virt-v2v` leaves a guest's operating system untouched when importing, so an
existing workload can move onto this platform as-is rather than being rebuilt.

Rebuilding is opt-in (`-e guest_rebuild=true`) because the write is destructive;
without that guard, applying an unrelated change silently destroys the running
workload.

Live migration needs three things the play now sets up, each of which fails
silently on its own — Pacemaker just falls back to stop-and-start and reports
healthy:

- **SSH host keys** between the nodes, as root
- **A unique libvirt host UUID.** The Simply NUC ships the *same* DMI system UUID
  in firmware on every unit, so libvirt sees a single host and declines to migrate. `machine-id` is
  correctly unique, so `host_uuid_source = "machine-id"` fixes it. Anywhere identical
  hardware is deployed from a single image, every site hits this the same way.
- **Ports 49152-49215** open, or migration authenticates, starts, then fails with
  "no route to host"

## N. Verify

```
pcs status                                  # both guests Started, no failures
multipath -ll                               # 4 paths, all "active ready"
ss -tn '( sport = :4174 )'                  # 2 witness connections
curl http://<pos-guest>:8080/               # live transaction view
busctl --system list | grep org.libvirt     # Cockpit can see the guests
virsh capabilities | grep -A1 '<uuid>'      # MUST differ between the two hosts
```

Run these from the hosts, not from a workstation — the storage segment is not
routed off the nodes.

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

---

## Appendix — running the playbooks without make

`make` is a thin wrapper. Every target runs an ordinary playbook, and you can run
them yourself if you prefer — nothing in this repository requires make.

What the wrapper does add is worth knowing before you skip it:

- **A pinned toolchain.** `make venv` builds a virtualenv from `requirements.txt`
  (`ansible-core>=2.16,<2.20`) and installs the collections into `./collections`,
  deliberately never touching system Python. Run playbooks with a distro Ansible
  and you get whatever version it ships, against collections that may not match.
- **The extra-vars.** `00-substrate.yml` decides how the storage NIC is attached
  from `storage_backend`, and the make targets pin it to `svsan` so you cannot get
  it wrong. Run that playbook by hand without it and the variable falls back to a
  value that leaves the storage NIC unbridged — the host then cannot reach the
  appliance running on itself, which presents as a storage failure rather than a
  configuration one. Pass it.

Activate the virtualenv first so you get the pinned Ansible:

```
make venv                      # once
source .venv/bin/activate
```

Run from the repository root — `ansible.cfg` there supplies the inventory path,
the roles path and the collections path, so the commands below need no `-i`.

Then each target maps to:

| make | ansible-playbook |
|---|---|
| `make discover` | `ansible-playbook playbooks/01-discover.yml` |
| `make substrate` | `ansible-playbook playbooks/00-substrate.yml -e storage_backend=svsan -e fence_backend=redfish` |
| `make admin` | `… playbooks/00-substrate.yml -e storage_backend=svsan -e fence_backend=redfish --tags admin` |
| `make witness` | `… playbooks/10-storage-svsan.yml -e storage_backend=svsan --limit arbiter` |
| `make svsan` | `… playbooks/10-storage-svsan.yml -e storage_backend=svsan -e svsan_attach_san_nic=false` |
| `make svsan-attach-san` | `… playbooks/10-storage-svsan.yml -e storage_backend=svsan -e svsan_attach_san_nic=true --limit cluster` |
| `make svsan-attach` | `… playbooks/11-present-targets.yml -e storage_backend=svsan` |
| `make svsan-tune` | `… playbooks/12-failover-tuning.yml -e storage_backend=svsan` |
| `make guests` | `… playbooks/30-guests.yml -e storage_backend=svsan` |

`FENCE` defaults to `redfish`; override with `make substrate FENCE=ipmilan` or by
changing `-e fence_backend=`.

The image build is not Ansible at all — `bootc/build.sh` is a shell script and is
run directly either way.

Useful additions when running playbooks by hand:

```
--check --diff        # dry run, show what would change
--limit node1         # one host
--tags admin          # one part of a play
-v                    # or -vvv when something is not doing what you expect
```

`--check` is worth knowing about: several plays in here are destructive by
design, and a dry run tells you which tasks would fire before they do.
